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

    private var debuggeeProcess: (any StreamingProcess)?
    private var jdbProcess: (any StreamingProcess)?
    private var sessionID = UUID()
    private var debugClassName: String?
    private var activeJDBURL: URL?
    private var activeJDBHost = "127.0.0.1"
    private var launchesDebuggee = false
    private var debuggeeOperationID: String?
    private var jdbOperationID: String?
    @Published private(set) var runningTargetTitle: String?
    private var didBootstrap = false
    private let maximumOutputCharacters = 400_000
    private let runtimeService: ProjectRuntimeService
    private let processFactory: () -> any StreamingProcess
    private let fileStorage: any FileStorage
    private let javaMavenOperations: any JavaMavenOperations
    private let runConfigurationOperations: any RunConfigurationOperations

    init(
        runtimeService: ProjectRuntimeService,
        processFactory: @escaping () -> any StreamingProcess,
        fileStorage: any FileStorage,
        javaMavenOperations: any JavaMavenOperations,
        runConfigurationOperations: any RunConfigurationOperations
    ) {
        self.runtimeService = runtimeService
        self.processFactory = processFactory
        self.fileStorage = fileStorage
        self.javaMavenOperations = javaMavenOperations
        self.runConfigurationOperations = runConfigurationOperations
    }

    private enum InspectionKind {
        case threads
        case stack
        case locals
        case dump(variableID: String)
        case evaluate
    }

    private var inspectionKind: InspectionKind?

    var isSessionActive: Bool { state != .idle }
    var canControl: Bool { jdbProcess?.isRunning == true }

    func start(fileURL: URL, sourceText: String, projectURL: URL?, options: RunOptions) {
        stop()
        guard fileURL.pathExtension.lowercased() == "java" else {
            fail("Select a Java file before starting Debug.")
            return
        }
        guard let projectURL else {
            fail("Open a project before starting Debug.")
            return
        }
        let debugPort = Self.nextPort()
        guard let currentFile = relativePath(for: fileURL, root: projectURL) else {
            fail("The selected Java file is outside the project.")
            return
        }
        let plan: SharedLaunchPlan
        do {
            plan = try runConfigurationOperations.launchPlan(
                at: projectURL,
                configurationID: RunConfiguration.currentFileID,
                currentFile: currentFile,
                classPath: nil,
                debugPort: debugPort
            )
            guard plan.toolchainID == "project-jdk" else {
                throw RunConfigurationOperationFailure(message: "Current File does not use the project JDK.")
            }
        } catch {
            fail(error.localizedDescription)
            return
        }
        guard let javaURL = runtimeService.javaExecutableURL(overridePath: options.javaHomePath),
              let jdbURL = runtimeService.jdbExecutableURL(overridePath: options.javaHomePath) else {
            fail("No JDK with jdb was found. Set JDK Home or JAVA_HOME.")
            return
        }

        let id = prepareSession(
            port: debugPort,
            host: "127.0.0.1",
            title: fileURL.lastPathComponent,
            launchesDebuggee: true
        )
        debugClassName = className(for: fileURL, sourceText: sourceText)
        startDebuggee(
            executable: javaURL,
            arguments: plan.arguments,
            workingDirectory: workingDirectory(
                plan.workingDirectory,
                fallback: fileURL.deletingLastPathComponent(),
                relativeTo: projectURL
            ),
            environment: runtimeService.environment(for: .java, javaHomeOverride: options.javaHomePath),
            jdbURL: jdbURL,
            host: "127.0.0.1",
            port: debugPort,
            sessionID: id
        )
    }

    func startMaven(
        configuration: RunConfiguration,
        project: MavenProject,
        projectURL: URL,
        options: RunOptions,
        mavenContext: MavenLaunchContext? = nil
    ) {
        stop()
        guard configuration.kind.isMavenBacked else {
            fail("Select a Spring Boot or Maven Module configuration before starting Debug.")
            return
        }
        var options = options
        if options.mavenExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            options.mavenExecutablePath = mavenContext?.mavenExecutablePath ?? ""
        }
        if options.mavenJavaHomePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            options.mavenJavaHomePath = mavenContext?.javaHomePath ?? ""
        }
        let debugPort = Self.nextPort()
        let plan: SharedLaunchPlan
        do {
            plan = try runConfigurationOperations.launchPlan(
                at: projectURL,
                configurationID: configuration.id,
                currentFile: nil,
                classPath: nil,
                debugPort: debugPort,
                mavenContext: mavenContext
            )
            guard plan.toolchainID == "project-maven" else {
                throw RunConfigurationOperationFailure(message: "The selected configuration does not use Maven.")
            }
        } catch {
            fail(error.localizedDescription)
            return
        }
        let mavenJavaHome = options.mavenJavaHomePath.isEmpty
            ? options.javaHomePath
            : options.mavenJavaHomePath
        guard runtimeService.mavenJavaHomeURL(overridePath: mavenJavaHome) != nil,
              let jdbURL = runtimeService.jdbExecutableURL(
                  overridePath: mavenJavaHome,
                  for: .maven
              ) else {
            fail("No JDK with jdb was found. Set JDK Home or JAVA_HOME.")
            return
        }

        let id = prepareSession(
            port: debugPort,
            host: "127.0.0.1",
            title: configuration.name,
            launchesDebuggee: true
        )
        guard let executable = runtimeService.mavenExecutable(
            for: project,
            overridePath: options.mavenExecutablePath
        ) else {
            fail("No Maven executable was found. Edit this service configuration.")
            return
        }
        append(
            "$ " + executable.lastPathComponent + " "
                + redactedMavenArgumentsForDisplay(plan.arguments).joined(separator: " ") + "\n\n"
        )
        startDebuggee(
            executable: executable,
            arguments: plan.arguments,
            workingDirectory: workingDirectory(
                plan.workingDirectory,
                fallback: project.rootURL,
                relativeTo: projectURL
            ),
            environment: runtimeService.environment(for: .maven, javaHomeOverride: mavenJavaHome),
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
        guard runtimeService.javaExecutableURL(overridePath: remoteJavaHomePath) != nil,
              let jdbURL = runtimeService.jdbExecutableURL(overridePath: remoteJavaHomePath) else {
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

    func evaluate(_ rawExpression: String) {
        let expression = rawExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { return }
        guard canControl else {
            inspectionTitle = "Evaluate"
            inspectionOutput = "Start or pause a debug session before evaluating an expression.\n"
            inspectionKind = .evaluate
            return
        }
        inspectionTitle = "Evaluate"
        inspectionOutput = "> print \(expression)\n"
        inspectionKind = .evaluate
        expandingVariableID = nil
        send("print \(expression)")
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
        if let jdbProcess, jdbProcess.isRunning {
            try? jdbProcess.send(Data("quit\n".utf8))
            jdbProcess.stop()
        }
        debuggeeProcess?.stop()
        debuggeeProcess = nil
        jdbProcess = nil
        debuggeeOperationID = nil
        jdbOperationID = nil
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

    func className(for fileURL: URL, sourceText: String) -> String {
        let simpleName = fileURL.deletingPathExtension().lastPathComponent
        return javaMavenOperations.className(source: sourceText, simpleName: simpleName) ?? simpleName
    }

    private static func nextPort() -> Int {
        Int.random(in: 49_152...60_000)
    }

    private func relativePath(for fileURL: URL, root: URL) -> String? {
        let file = fileURL.standardizedFileURL.path
        let prefix = root.standardizedFileURL.path + "/"
        guard file.hasPrefix(prefix) else { return nil }
        return String(file.dropFirst(prefix.count))
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
        let debuggee = processFactory()
        debuggee.onOutput = { [weak self] chunk in
            Task { @MainActor [weak self] in
                self?.appendDebuggeeOutput(chunk, sessionID: sessionID)
            }
        }
        debuggee.onTermination = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                if self.state != .failed {
                    self.state = exitCode == 0 ? .finished : .failed
                }
                self.append("[debuggee exited with code \(exitCode)]\n")
            }
        }
        let operationID = UUID().uuidString
        debuggeeOperationID = operationID
        debuggee.onStateChange = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consumeLifecycle(event, sessionID: sessionID, process: .debuggee)
            }
        }

        debuggeeProcess = debuggee
        append("$ " + executable.lastPathComponent + " " + arguments.joined(separator: " ") + "\n\n")
        do {
            try debuggee.start(ProcessRequest(
                operationID: operationID,
                executablePath: executable.path,
                arguments: arguments,
                workingDirectory: workingDirectory.path,
                environment: environment
            ))
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

        let jdb = processFactory()
        jdb.onOutput = { [weak self] chunk in
            Task { @MainActor [weak self] in
                self?.appendJDBOutput(chunk, sessionID: sessionID)
            }
        }
        jdb.onTermination = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                if self.state == .launching || self.state == .running {
                    self.state = .failed
                    self.append("[jdb exited with code \(exitCode)]\n")
                }
                self.jdbProcess = nil
            }
        }
        let operationID = UUID().uuidString
        jdbOperationID = operationID
        jdb.onStateChange = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consumeLifecycle(event, sessionID: sessionID, process: .jdb)
            }
        }

        jdbProcess = jdb
        do {
            try jdb.start(ProcessRequest(
                operationID: operationID,
                executablePath: jdbURL.path,
                arguments: ["-J-Duser.language=en", "-J-Duser.country=US", "-attach", "\(host):\(port)"],
                keepsStandardInputOpen: true
            ))
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
        case .evaluate: break
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
        case .evaluate:
            break
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
        guard let jdbProcess, jdbProcess.isRunning else { return }
        try? jdbProcess.send(Data((command + "\n").utf8))
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
        debuggeeProcess?.stop()
    }

    private enum ProcessKind: Equatable {
        case debuggee
        case jdb
    }

    private func consumeLifecycle(
        _ event: ProcessLifecycleEvent,
        sessionID: UUID,
        process: ProcessKind
    ) {
        guard self.sessionID == sessionID else { return }
        let expectedID = process == .debuggee ? debuggeeOperationID : jdbOperationID
        guard event.operationID == expectedID else { return }
        switch event.state {
        case .starting:
            state = .launching
        case .running:
            if process == .jdb, didBootstrap { state = launchesDebuggee ? .running : .paused }
        case .stopping:
            break
        case .finished:
            break
        case .failed:
            state = .failed
            if let message = event.message, !message.isEmpty {
                append("[" + (process == .jdb ? "jdb" : "debuggee") + ": " + message + "]\n")
            }
        }
    }

    private func workingDirectory(_ path: String, fallback: URL, relativeTo projectURL: URL?) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = (expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: expanded, relativeTo: projectURL ?? fallback)
        ).standardizedFileURL
        guard fileStorage.metadata(for: url)?.isDirectory == true else {
            return fallback
        }
        return url
    }

}
