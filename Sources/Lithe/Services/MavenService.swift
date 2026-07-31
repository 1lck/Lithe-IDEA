import Foundation

@MainActor
final class MavenService: ObservableObject {
    @Published private(set) var project: MavenProject?
    @Published private(set) var isLoadingProject = false
    @Published private(set) var isRunning = false
    @Published private(set) var runningTitle: String?
    @Published private(set) var output = ""
    @Published private(set) var issues: [MavenBuildIssue] = []
    @Published private(set) var lastExitCode: Int32?

    private var process: Process?
    private var outputPipe: Pipe?
    private var projectLoadID = UUID()
    private let maximumOutputCharacters = 500_000

    func loadProject(at workspaceURL: URL) async {
        let loadID = UUID()
        projectLoadID = loadID
        isLoadingProject = true
        let rootURL = workspaceURL.standardizedFileURL
        let scannedProject = await Task.detached(priority: .utility) {
            MavenProjectScanner.scan(at: rootURL)
        }.value
        guard !Task.isCancelled, projectLoadID == loadID else { return }
        project = scannedProject
        isLoadingProject = false
    }

    func run(
        phase: MavenLifecyclePhase,
        module: MavenModule?,
        profiles: Set<String>
    ) {
        guard project != nil else { return }
        stop()
        resetOutput()
        var arguments = baseArguments(profiles: profiles)
        if let module {
            arguments += ["-pl", module.relativePath, "-am"]
        }
        arguments.append(phase.rawValue)
        startProcess(arguments: arguments, title: taskTitle(phase: phase, module: module))
    }

    func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        outputPipe = nil
        isRunning = false
        runningTitle = nil
    }

    func reset() {
        stop()
        projectLoadID = UUID()
        project = nil
        isLoadingProject = false
        output = ""
        issues = []
        lastExitCode = nil
    }

    func clearOutput() {
        output = ""
        issues = []
        lastExitCode = nil
    }

    // MARK: - 进程执行

    private func baseArguments(profiles: Set<String>) -> [String] {
        var arguments = ["-B", "-ntp"]
        if !profiles.isEmpty {
            arguments += ["-P", profiles.sorted().joined(separator: ",")]
        }
        return arguments
    }

    private func resetOutput() {
        output = ""
        issues = []
        lastExitCode = nil
    }

    private func startProcess(arguments: [String], title: String) {
        guard let project else { return }
        let executable = MavenService.executableURL(for: project)
        isRunning = true
        runningTitle = title
        append("$ " + executable.lastPathComponent + " " + arguments.joined(separator: " ") + "\n\n")

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = project.rootURL

        process.standardOutput = outputPipe
        process.standardError = outputPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.append(chunk)
            }
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                guard let self, self.process === terminatedProcess else { return }
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.isRunning = false
                self.runningTitle = nil
                self.lastExitCode = terminatedProcess.terminationStatus
                self.issues = Self.parseIssues(in: self.output, projectRoot: project.rootURL)
                self.process = nil
                self.outputPipe = nil
            }
        }

        self.process = process
        self.outputPipe = outputPipe
        do {
            try process.run()
        } catch {
            self.process = nil
            self.outputPipe = nil
            append("Unable to start Maven: " + error.localizedDescription + "\n")
            isRunning = false
            runningTitle = nil
            lastExitCode = 1
            issues = [MavenBuildIssue(
                id: "start-error",
                fileURL: nil,
                line: nil,
                column: nil,
                severity: .error,
                message: error.localizedDescription
            )]
        }
    }

    private func append(_ value: String) {
        output.append(value.replacingOccurrences(of: "\r", with: ""))
        if output.count > maximumOutputCharacters {
            output.removeFirst(output.count - maximumOutputCharacters)
        }
    }

    private func taskTitle(phase: MavenLifecyclePhase, module: MavenModule?) -> String {
        let target = module?.displayName ?? project?.displayName ?? "Project"
        return phase.title + " · " + target
    }

    static func executableURL(for project: MavenProject) -> URL {
        let wrapper = project.rootURL.appendingPathComponent("mvnw")
        if FileManager.default.isExecutableFile(atPath: wrapper.path) {
            return wrapper
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for component in path.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: component).appendingPathComponent("mvn")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        for path in ["/opt/homebrew/bin/mvn", "/usr/local/bin/mvn", "/usr/bin/mvn"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return URL(fileURLWithPath: "/usr/bin/mvn")
    }

    private static func parseIssues(in output: String, projectRoot: URL) -> [MavenBuildIssue] {
        let pattern = #"\[(ERROR|WARNING)\]\s+(.*?):\[(\d+)(?:,(\d+))?\]\s+(.*)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        var issues: [MavenBuildIssue] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = expression.firstMatch(in: line, range: range), match.numberOfRanges == 6 else { continue }
            func capture(_ index: Int) -> String? {
                let range = match.range(at: index)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else { return nil }
                return String(line[swiftRange])
            }
            guard let severityValue = capture(1),
                  let path = capture(2),
                  let lineNumber = capture(3).flatMap(Int.init),
                  let message = capture(5) else { continue }
            let column = capture(4).flatMap(Int.init)
            let fileURL: URL
            if path.hasPrefix("/") {
                fileURL = URL(fileURLWithPath: path)
            } else {
                fileURL = projectRoot.appendingPathComponent(path).standardizedFileURL
            }
            let severity: MavenIssueSeverity = severityValue == "ERROR" ? .error : .warning
            let id = fileURL.path + ":" + String(lineNumber) + ":" + String(column ?? 0) + ":" + message
            guard !issues.contains(where: { $0.id == id }) else { continue }
            issues.append(MavenBuildIssue(
                id: id,
                fileURL: fileURL,
                line: lineNumber,
                column: column,
                severity: severity,
                message: message
            ))
        }
        return issues
    }
}
