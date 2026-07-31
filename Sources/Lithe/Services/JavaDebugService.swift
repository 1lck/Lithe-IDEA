import Foundation

@MainActor
final class JavaDebugService: ObservableObject {
    @Published private(set) var state: JavaDebugSessionState = .idle
    @Published private(set) var output = ""
    @Published private(set) var inspectionTitle: String?
    @Published private(set) var inspectionOutput = ""
    @Published private(set) var port: Int?
    @Published private(set) var breakpoints: [JavaDebugBreakpoint] = []
    @Published var targetKind: JavaDebugTargetKind = .currentFile
    @Published var remoteHost = "127.0.0.1"
    @Published var remotePort = "5005"
    @Published var remoteJavaHomePath = ""

    private var debuggeeProcess: Process?
    private var debuggeeOutputPipe: Pipe?
    private var jdbProcess: Process?
    private var jdbInputPipe: Pipe?
    private var jdbOutputPipe: Pipe?
    private var sessionID = UUID()
    private var debugClassName: String?
    private var activeJDBURL: URL?
    private var activeJDBHost = "127.0.0.1"
    private var launchesDebuggee = false
    @Published private(set) var runningTargetTitle: String?
    private var didBootstrap = false
    private let maximumOutputCharacters = 400_000

    var isSessionActive: Bool { state != .idle }
    var canControl: Bool { jdbProcess?.isRunning == true }

    func start(fileURL: URL, sourceText: String, projectURL: URL?, options: JavaRunOptions) {
        stop()
        guard fileURL.pathExtension.lowercased() == "java" else {
            fail("Select a Java file before starting Debug.")
            return
        }
        guard let javaURL = javaExecutableURL(javaHomePath: options.javaHomePath),
              let jdbURL = jdbExecutableURL(javaExecutableURL: javaURL) else {
            fail("No JDK with jdb was found. Set JDK Home or JAVA_HOME.")
            return
        }

        let debugPort = Self.nextPort()
        let id = prepareSession(
            port: debugPort,
            host: "127.0.0.1",
            title: fileURL.lastPathComponent,
            launchesDebuggee: true
        )
        debugClassName = Self.className(for: fileURL, sourceText: sourceText)
        var arguments = [
            "-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=127.0.0.1:\(debugPort)",
            "-Duser.language=en",
            "-Duser.country=US"
        ]
        arguments += Self.arguments(from: options.vmArguments)
        arguments.append(fileURL.standardizedFileURL.path)
        arguments += Self.arguments(from: options.programArguments)
        startDebuggee(
            executable: javaURL,
            arguments: arguments,
            workingDirectory: workingDirectory(
                options.workingDirectoryPath,
                fallback: fileURL.deletingLastPathComponent(),
                relativeTo: projectURL
            ),
            environment: environment(javaHomePath: options.javaHomePath),
            jdbURL: jdbURL,
            host: "127.0.0.1",
            port: debugPort,
            sessionID: id
        )
    }

    func startMaven(
        configuration: JavaRunConfiguration,
        project: MavenProject,
        projectURL: URL,
        options: JavaRunOptions
    ) {
        stop()
        guard configuration.kind == .springBoot || configuration.kind == .mavenModule else {
            fail("Select a Spring Boot or Maven Module configuration before starting Debug.")
            return
        }
        guard let javaURL = javaExecutableURL(javaHomePath: options.javaHomePath),
              let jdbURL = jdbExecutableURL(javaExecutableURL: javaURL) else {
            fail("No JDK with jdb was found. Set JDK Home or JAVA_HOME.")
            return
        }

        let debugPort = Self.nextPort()
        let id = prepareSession(
            port: debugPort,
            host: "127.0.0.1",
            title: configuration.name,
            launchesDebuggee: true
        )
        var arguments = ["-B", "-ntp"]
        if let modulePath = configuration.modulePath {
            arguments += ["-pl", modulePath]
        }
        if !options.activeProfiles.isEmpty {
            arguments += ["-P", options.activeProfiles.sorted().joined(separator: ",")]
        }
        if let mainClass = configuration.mainClass {
            arguments.append("-Dspring-boot.run.main-class=" + mainClass)
        }
        let debugVMArguments = (
            ["-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=127.0.0.1:\(debugPort)"]
            + Self.arguments(from: options.vmArguments)
        ).joined(separator: " ")
        arguments.append("-Dspring-boot.run.jvmArguments=" + debugVMArguments)
        let programArguments = options.programArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if !programArguments.isEmpty {
            arguments.append("-Dspring-boot.run.arguments=" + programArguments)
        }
        arguments.append("spring-boot:run")

        let moduleDirectory = configuration.modulePath.flatMap { modulePath in
            project.modules.first(where: { $0.relativePath == modulePath })?.url
        } ?? project.rootURL
        let executable = MavenService.executableURL(for: project)
        append("$ " + executable.lastPathComponent + " " + arguments.joined(separator: " ") + "\n\n")
        startDebuggee(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory(
                options.workingDirectoryPath,
                fallback: moduleDirectory,
                relativeTo: projectURL
            ),
            environment: environment(javaHomePath: options.javaHomePath),
            jdbURL: jdbURL,
            host: "127.0.0.1",
            port: debugPort,
            sessionID: id
        )
    }

    func attachRemote() {
        stop()
        let host = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            fail("Enter a remote JVM host.")
            return
        }
        guard let port = Int(remotePort.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(port) else {
            fail("Enter a valid JDWP port.")
            return
        }
        guard let javaURL = javaExecutableURL(javaHomePath: remoteJavaHomePath),
              let jdbURL = jdbExecutableURL(javaExecutableURL: javaURL) else {
            fail("No local JDK with jdb was found for the attach session.")
            return
        }
        let id = prepareSession(
            port: port,
            host: host,
            title: host + ":" + String(port),
            launchesDebuggee: false
        )
        append("Attach jdb to \(host):\(port)\n\n")
        attachJDB(jdbURL: jdbURL, host: host, port: port, sessionID: id)
    }

    func toggleBreakpoint(fileURL: URL, line: Int, className: String) {
        guard line > 0 else { return }
        let normalizedURL = fileURL.standardizedFileURL
        let id = normalizedURL.path + ":" + String(line)
        if let index = breakpoints.firstIndex(where: { $0.id == id }) {
            let breakpoint = breakpoints.remove(at: index)
            if canControl {
                send("clear \(breakpoint.className):\(breakpoint.line)")
            }
            return
        }

        let breakpoint = JavaDebugBreakpoint(
            id: id,
            fileURL: normalizedURL,
            line: line,
            className: className
        )
        breakpoints.append(breakpoint)
        breakpoints.sort { lhs, rhs in
            if lhs.fileURL != rhs.fileURL { return lhs.fileURL.path < rhs.fileURL.path }
            return lhs.line < rhs.line
        }
        if canControl {
            send("stop at \(className):\(line)")
        }
    }

    func continueExecution() {
        send("cont")
        state = .running
    }

    func pause() {
        send("halt")
        state = .paused
    }

    func stepInto() {
        send("step")
        state = .running
    }

    func stepOver() {
        send("next")
        state = .running
    }

    func stepOut() {
        send("step up")
        state = .running
    }

    func inspectThreads() {
        inspect(title: "Threads", command: "threads")
    }

    func inspectStack() {
        inspect(title: "Call Stack", command: "where all")
    }

    func inspectVariables() {
        inspect(title: "Local Variables", command: "locals")
    }

    func clearOutput() {
        output = ""
        inspectionOutput = ""
    }

    func stop() {
        sessionID = UUID()
        debuggeeOutputPipe?.fileHandleForReading.readabilityHandler = nil
        jdbOutputPipe?.fileHandleForReading.readabilityHandler = nil
        if let jdbProcess, jdbProcess.isRunning {
            try? jdbInputPipe?.fileHandleForWriting.write(contentsOf: Data("quit\n".utf8))
            jdbProcess.terminate()
        }
        if let debuggeeProcess, debuggeeProcess.isRunning {
            debuggeeProcess.terminate()
        }
        debuggeeProcess = nil
        debuggeeOutputPipe = nil
        jdbProcess = nil
        jdbInputPipe = nil
        jdbOutputPipe = nil
        didBootstrap = false
        debugClassName = nil
        activeJDBURL = nil
        activeJDBHost = "127.0.0.1"
        launchesDebuggee = false
        runningTargetTitle = nil
        port = nil
        inspectionTitle = nil
        inspectionOutput = ""
        state = .idle
    }

    func reset() {
        stop()
        output = ""
        breakpoints = []
        targetKind = .currentFile
        remoteHost = "127.0.0.1"
        remotePort = "5005"
        remoteJavaHomePath = ""
    }

    static func className(for fileURL: URL, sourceText: String) -> String {
        let packagePattern = #"(?m)^\s*package\s+([A-Za-z_][A-Za-z0-9_.]*)\s*;"#
        let packageName: String? = if let expression = try? NSRegularExpression(pattern: packagePattern),
                                      let match = expression.firstMatch(
                                          in: sourceText,
                                          range: NSRange(sourceText.startIndex..<sourceText.endIndex, in: sourceText)
                                      ),
                                      let range = Range(match.range(at: 1), in: sourceText) {
            String(sourceText[range])
        } else {
            nil
        }
        let simpleName = fileURL.deletingPathExtension().lastPathComponent
        return packageName.map { "\($0).\(simpleName)" } ?? simpleName
    }

    private static func nextPort() -> Int {
        Int.random(in: 49_152...60_000)
    }

    private func prepareSession(
        port: Int?,
        host: String,
        title: String,
        launchesDebuggee: Bool
    ) -> UUID {
        let id = UUID()
        sessionID = id
        self.port = port
        activeJDBHost = host
        runningTargetTitle = title
        self.launchesDebuggee = launchesDebuggee
        activeJDBURL = nil
        output = ""
        inspectionTitle = nil
        inspectionOutput = ""
        didBootstrap = false
        state = .launching
        return id
    }

    private func startDebuggee(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        jdbURL: URL,
        host: String,
        port: Int,
        sessionID: UUID
    ) {
        activeJDBURL = jdbURL
        let debuggee = Process()
        let debuggeeOutput = Pipe()
        debuggee.executableURL = executable
        debuggee.arguments = arguments
        debuggee.currentDirectoryURL = workingDirectory
        debuggee.environment = environment
        debuggee.standardOutput = debuggeeOutput
        debuggee.standardError = debuggeeOutput
        debuggeeOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.appendDebuggeeOutput(chunk, sessionID: sessionID)
            }
        }
        debuggee.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                self.debuggeeOutputPipe?.fileHandleForReading.readabilityHandler = nil
                if self.state != .failed {
                    self.state = process.terminationStatus == 0 ? .finished : .failed
                }
                self.append("[debuggee exited with code \(process.terminationStatus)]\n")
            }
        }

        debuggeeProcess = debuggee
        debuggeeOutputPipe = debuggeeOutput
        append("$ " + executable.lastPathComponent + " " + arguments.joined(separator: " ") + "\n\n")
        do {
            try debuggee.run()
        } catch {
            fail("Unable to start debuggee: \(error.localizedDescription)")
            return
        }

        // Maven can buffer the JDWP listener line, so keep a delayed attach fallback.
        Task { @MainActor [weak self, weak debuggee] in
            try? await Task.sleep(for: .seconds(5))
            guard let self,
                  self.sessionID == sessionID,
                  self.jdbProcess == nil,
                  debuggee?.isRunning == true else { return }
            self.attachJDB(
                jdbURL: jdbURL,
                host: host,
                port: port,
                sessionID: sessionID
            )
        }
    }

    private func attachJDB(jdbURL: URL, host: String, port: Int, sessionID: UUID) {
        guard self.sessionID == sessionID,
              jdbProcess == nil else { return }

        let jdb = Process()
        let input = Pipe()
        let output = Pipe()
        jdb.executableURL = jdbURL
        jdb.arguments = ["-J-Duser.language=en", "-J-Duser.country=US", "-attach", "\(host):\(port)"]
        jdb.standardInput = input
        jdb.standardOutput = output
        jdb.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.appendJDBOutput(chunk, sessionID: sessionID)
            }
        }
        jdb.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                self.jdbOutputPipe?.fileHandleForReading.readabilityHandler = nil
                if self.state == .launching || self.state == .running {
                    self.state = .failed
                    self.append("[jdb exited with code \(process.terminationStatus)]\n")
                }
                self.jdbProcess = nil
                self.jdbInputPipe = nil
                self.jdbOutputPipe = nil
            }
        }

        jdbProcess = jdb
        jdbInputPipe = input
        jdbOutputPipe = output
        do {
            try jdb.run()
        } catch {
            fail("Unable to start jdb: \(error.localizedDescription)")
            return
        }

        Task { @MainActor [weak self, weak jdb] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self,
                  self.sessionID == sessionID,
                  jdb?.isRunning == true,
                  !self.didBootstrap else { return }
            self.didBootstrap = true
            for breakpoint in self.breakpoints {
                self.send("stop at \(breakpoint.className):\(breakpoint.line)")
            }
            if self.launchesDebuggee {
                self.send("run")
                self.state = .running
            } else {
                self.state = .paused
            }
        }
    }

    private func appendDebuggeeOutput(_ chunk: String, sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        append("[debuggee] " + chunk)
        if chunk.localizedCaseInsensitiveContains("Listening for transport") {
            guard let port, let activeJDBURL else { return }
            attachJDB(
                jdbURL: activeJDBURL,
                host: activeJDBHost,
                port: port,
                sessionID: sessionID
            )
        }
    }

    private func appendJDBOutput(_ chunk: String, sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        append("[jdb] " + chunk)
        if inspectionTitle != nil {
            inspectionOutput.append(chunk)
            if inspectionOutput.count > 80_000 {
                inspectionOutput.removeFirst(inspectionOutput.count - 80_000)
            }
        }
        if chunk.contains("Breakpoint hit:") || chunk.contains("Step completed:") || chunk.contains("Method entered:") {
            state = .paused
        }
    }

    private func inspect(title: String, command: String) {
        inspectionTitle = title
        inspectionOutput = "> \(command)\n"
        send(command)
    }

    private func send(_ command: String) {
        guard let jdbInputPipe,
              jdbProcess?.isRunning == true else { return }
        try? jdbInputPipe.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
    }

    private func append(_ value: String) {
        output.append(value.replacingOccurrences(of: "\r", with: ""))
        if output.count > maximumOutputCharacters {
            output.removeFirst(output.count - maximumOutputCharacters)
        }
    }

    private func fail(_ message: String) {
        output = message + "\n"
        state = .failed
        if let debuggeeProcess, debuggeeProcess.isRunning { debuggeeProcess.terminate() }
    }

    private func environment(javaHomePath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let configured = javaHomePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty, let home = resolvedJavaHome(configured) {
            environment["JAVA_HOME"] = home.path
        }
        return environment
    }

    private func workingDirectory(_ path: String, fallback: URL, relativeTo projectURL: URL?) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = (expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: expanded, relativeTo: projectURL ?? fallback)
        ).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return fallback
        }
        return url
    }

    private func javaExecutableURL(javaHomePath: String) -> URL? {
        let configured = javaHomePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty,
           let home = resolvedJavaHome(configured),
           FileManager.default.isExecutableFile(atPath: home.appendingPathComponent("bin/java").path) {
            return home.appendingPathComponent("bin/java")
        }
        if let home = ProcessInfo.processInfo.environment["JAVA_HOME"],
           FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: home).appendingPathComponent("bin/java").path) {
            return URL(fileURLWithPath: home).appendingPathComponent("bin/java")
        }
        return [
            "/opt/homebrew/opt/openjdk/bin/java",
            "/usr/local/opt/openjdk/bin/java",
            "/usr/bin/java"
        ].map(URL.init(fileURLWithPath:)).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        })
    }

    private func jdbExecutableURL(javaExecutableURL: URL) -> URL? {
        let candidate = javaExecutableURL.deletingLastPathComponent().appendingPathComponent("jdb")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        return ["/opt/homebrew/bin/jdb", "/usr/local/bin/jdb", "/usr/bin/jdb"]
            .map(URL.init(fileURLWithPath:))
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private func resolvedJavaHome(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private static func arguments(from input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in input {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" && quote != "'" {
                escaped = true
                continue
            }
            if character == "'" || character == "\"" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                else { current.append(character) }
                continue
            }
            if character.isWhitespace && quote == nil {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
