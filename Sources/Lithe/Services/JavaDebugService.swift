import Foundation

@MainActor
final class JavaDebugService: ObservableObject {
    @Published private(set) var state: JavaDebugSessionState = .idle
    @Published private(set) var output = ""
    @Published private(set) var inspectionTitle: String?
    @Published private(set) var inspectionOutput = ""
    @Published private(set) var variables: [JavaDebugVariable] = []
    @Published private(set) var threads: [JavaDebugThread] = []
    @Published private(set) var callStack: [JavaDebugStackFrame] = []
    @Published private(set) var expandingVariableID: String?
    @Published private(set) var exceptionMessage: String?
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

    private enum InspectionKind {
        case threads
        case stack
        case locals
        case dump(variableID: String)
    }

    private var inspectionKind: InspectionKind?

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
            project.allModules.first(where: { $0.relativePath == modulePath })?.url
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
        inspect(title: "Threads", command: "threads", kind: .threads)
    }

    func inspectStack() {
        inspect(title: "Call Stack", command: "where all", kind: .stack)
    }

    func inspectVariables() {
        inspect(title: "Local Variables", command: "locals", kind: .locals)
    }

    func toggleVariable(_ variable: JavaDebugVariable) {
        guard variable.canExpand else { return }
        if variable.isExpanded {
            updateVariable(variable.id) { $0.isExpanded = false }
            return
        }
        guard canControl else { return }
        updateVariable(variable.id) { $0.isExpanded = true }
        expandingVariableID = variable.id
        inspectionTitle = "Local Variables"
        inspectionKind = .dump(variableID: variable.id)
        inspectionOutput = "> dump \(variable.expression)\n"
        send("dump \(variable.expression)")
    }

    func clearOutput() {
        output = ""
        inspectionOutput = ""
        variables = []
        threads = []
        callStack = []
        expandingVariableID = nil
        exceptionMessage = nil
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
        variables = []
        threads = []
        callStack = []
        expandingVariableID = nil
        exceptionMessage = nil
        inspectionKind = nil
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
        variables = []
        threads = []
        callStack = []
        expandingVariableID = nil
        exceptionMessage = nil
        inspectionKind = nil
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
        _ = detectException(in: chunk)
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
        let didDetectException = detectException(in: chunk)
        if inspectionTitle != nil {
            inspectionOutput.append(chunk)
            if inspectionOutput.count > 80_000 {
                inspectionOutput.removeFirst(inspectionOutput.count - 80_000)
            }
            refreshInspectionData()
        }
        if chunk.contains("Breakpoint hit:") || chunk.contains("Step completed:") || chunk.contains("Method entered:") || didDetectException {
            state = .paused
        }
    }

    private func inspect(title: String, command: String, kind: InspectionKind) {
        inspectionTitle = title
        inspectionOutput = "> \(command)\n"
        inspectionKind = kind
        expandingVariableID = nil
        switch kind {
        case .threads: threads = []
        case .stack: callStack = []
        case .locals: variables = []
        case .dump: break
        }
        send(command)
    }

    private func refreshInspectionData() {
        guard let inspectionKind else { return }
        switch inspectionKind {
        case .threads:
            threads = Self.parseThreads(inspectionOutput)
        case .stack:
            callStack = Self.parseStackFrames(inspectionOutput)
        case .locals:
            variables = Self.parseVariables(inspectionOutput)
        case .dump(let variableID):
            guard let variable = variable(with: variableID) else { return }
            let children = Self.parseDumpChildren(inspectionOutput, parent: variable)
            guard !children.isEmpty else { return }
            updateVariable(variableID) {
                $0.children = children
                $0.isExpanded = true
            }
            expandingVariableID = nil
        }
    }

    private func variable(with id: String, in values: [JavaDebugVariable]? = nil) -> JavaDebugVariable? {
        let values = values ?? variables
        for value in values {
            if value.id == id { return value }
            if let child = variable(with: id, in: value.children) { return child }
        }
        return nil
    }

    @discardableResult
    private func updateVariable(
        _ id: String,
        in values: inout [JavaDebugVariable],
        update: (inout JavaDebugVariable) -> Void
    ) -> Bool {
        for index in values.indices {
            if values[index].id == id {
                update(&values[index])
                return true
            }
            if updateVariable(id, in: &values[index].children, update: update) {
                return true
            }
        }
        return false
    }

    private func updateVariable(
        _ id: String,
        update: (inout JavaDebugVariable) -> Void
    ) {
        _ = updateVariable(id, in: &variables, update: update)
    }

    private static func parseVariables(_ text: String) -> [JavaDebugVariable] {
        var result: [JavaDebugVariable] = []
        for line in text.components(separatedBy: .newlines) {
            guard let assignment = parseAssignment(line) else { continue }
            let expression = assignment.name
            guard !result.contains(where: { $0.id == expression }) else { continue }
            result.append(JavaDebugVariable(
                id: expression,
                name: assignment.name,
                expression: expression,
                value: assignment.value,
                children: [],
                isExpanded: false,
                isExpandable: looksExpandable(assignment.value)
            ))
        }
        return result
    }

    private static func parseDumpChildren(
        _ text: String,
        parent: JavaDebugVariable
    ) -> [JavaDebugVariable] {
        var result: [JavaDebugVariable] = []
        for line in text.components(separatedBy: .newlines) {
            guard let assignment = parseAssignment(line),
                  assignment.name != parent.name,
                  assignment.name != parent.expression else { continue }
            let expression: String
            if assignment.name.hasPrefix("[") {
                expression = parent.expression + assignment.name
            } else {
                expression = parent.expression + "." + assignment.name
            }
            guard !result.contains(where: { $0.id == expression }) else { continue }
            result.append(JavaDebugVariable(
                id: expression,
                name: assignment.name,
                expression: expression,
                value: assignment.value,
                children: [],
                isExpanded: false,
                isExpandable: looksExpandable(assignment.value)
            ))
        }
        return result
    }

    private static func parseAssignment(_ line: String) -> (name: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix(">"),
              !trimmed.hasSuffix(":"),
              let separator = trimmed.range(of: " = ") else { return nil }
        let name = String(trimmed[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
        let value = String(trimmed[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard isValidVariableName(name), !value.isEmpty else { return nil }
        return (name, value)
    }

    private static func isValidVariableName(_ name: String) -> Bool {
        if name.hasPrefix("[") && name.hasSuffix("]") { return true }
        guard let first = name.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_$")).contains(first) else {
            return false
        }
        return name.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$")).contains($0)
        }
    }

    private static func looksExpandable(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return value.hasSuffix("{") ||
            lowercased.contains("instance of ") ||
            lowercased.contains("[length") ||
            lowercased.contains("array")
    }

    private static func parseThreads(_ text: String) -> [JavaDebugThread] {
        var result: [JavaDebugThread] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.lowercased().hasPrefix("group ") else { continue }

            let id: String
            let name: String
            let status: String
            if let colon = trimmed.firstIndex(of: ":"),
               Int(trimmed[..<colon].trimmingCharacters(in: .whitespaces)) != nil {
                id = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                let remainder = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if remainder.first == "\"", let closing = remainder.dropFirst().firstIndex(of: "\"") {
                    name = String(remainder[remainder.index(after: remainder.startIndex)..<closing])
                    status = String(remainder[remainder.index(after: closing)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    let parts = remainder.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
                    name = parts.first.map(String.init) ?? "Thread \(id)"
                    status = parts.dropFirst().first.map(String.init) ?? ""
                }
            } else if trimmed.hasPrefix("("),
                      let close = trimmed.firstIndex(of: ")") {
                let afterClose = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
                let parts = afterClose.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
                id = String(afterClose[..<(parts.first?.endIndex ?? afterClose.endIndex)])
                name = parts.dropFirst().first.map(String.init) ?? String(trimmed[..<close])
                status = parts.dropFirst(2).first.map(String.init) ?? ""
            } else {
                continue
            }
            guard !result.contains(where: { $0.id == id }) else { continue }
            result.append(JavaDebugThread(
                id: id,
                name: name,
                status: status,
                isCurrent: trimmed.contains("*") || status.localizedCaseInsensitiveContains("current")
            ))
        }
        return result
    }

    private static func parseStackFrames(_ text: String) -> [JavaDebugStackFrame] {
        var result: [JavaDebugStackFrame] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("[") else { continue }
            guard let closing = trimmed.firstIndex(of: "]"),
                  let level = Int(trimmed[trimmed.index(after: trimmed.startIndex)..<closing]) else { continue }
            let description = trimmed[trimmed.index(after: closing)...]
                .trimmingCharacters(in: .whitespaces)
            guard !description.isEmpty else { continue }
            result.append(JavaDebugStackFrame(level: level, description: description))
        }
        return result
    }

    @discardableResult
    private func detectException(in text: String) -> Bool {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = trimmed.lowercased()
            guard lowercased.contains("exception") || lowercased.hasPrefix("caused by:") else { continue }
            if lowercased.contains("exception occurred") ||
                lowercased.hasPrefix("exception in thread") ||
                lowercased.hasPrefix("uncaught exception") ||
                lowercased.hasPrefix("caused by:") {
                exceptionMessage = trimmed
                return true
            }
        }
        return false
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
