import Foundation

@MainActor
final class JavaRunService: ObservableObject {
    @Published private(set) var configurations: [JavaRunConfiguration] = [.currentFile]
    @Published var selectedConfigurationID = JavaRunConfiguration.currentFileID
    @Published private(set) var isLoadingProject = false
    @Published private(set) var isRunning = false
    @Published private(set) var runningTitle: String?
    @Published private(set) var output = ""
    @Published private(set) var lastExitCode: Int32?
    @Published private(set) var optionsByConfigurationID: [String: JavaRunOptions] = [:]
    @Published private(set) var mavenProfiles: [MavenProfile] = []
    @Published private(set) var moduleSessions: [JavaRunSession] = []
    @Published private(set) var portConflicts: [JavaRunPortConflict] = []

    private var process: Process?
    private var outputPipe: Pipe?
    private var projectURL: URL?
    private var projectFiles: [URL] = []
    private var mavenProject: MavenProject?
    private var projectLoadID = UUID()
    private var lastRunConfiguration: JavaRunConfiguration?
    private var lastCurrentFileURL: URL?
    private var moduleProcesses: [String: Process] = [:]
    private var moduleOutputPipes: [String: Pipe] = [:]
    private let maximumOutputCharacters = 500_000

    var selectedConfiguration: JavaRunConfiguration? {
        configurations.first { $0.id == selectedConfigurationID }
    }

    /// 供输出文本定位源码使用:项目根 + 各 Maven 模块根。
    var sourceSearchRoots: [URL] {
        var roots = projectURL.map { [$0] } ?? []
        if let mavenProject {
            roots.append(contentsOf: mavenProject.allModules.map(\.url))
        }
        return roots
    }

    func loadProject(
        at projectURL: URL,
        files: [URL],
        mavenProject: MavenProject?
    ) async {
        let loadID = UUID()
        projectLoadID = loadID
        isLoadingProject = true
        let scannedConfigurations = await Task.detached(priority: .utility) {
            JavaRunConfigurationScanner.scan(files: files, mavenProject: mavenProject)
        }.value
        guard !Task.isCancelled, projectLoadID == loadID else { return }
        self.projectURL = projectURL.standardizedFileURL
        self.mavenProject = mavenProject
        configurations = [.currentFile] + scannedConfigurations
        reconcileModuleSessions(validConfigurationIDs: Set(scannedConfigurations.map(\.id)))
        mavenProfiles = mavenProject?.profiles ?? []
        self.projectFiles = files
        optionsByConfigurationID = Dictionary(uniqueKeysWithValues: configurations.map { configuration in
            (configuration.id, loadOptions(for: configuration.id))
        })
        refreshPortConflicts()
        if !configurations.contains(where: { $0.id == selectedConfigurationID }) {
            selectedConfigurationID = scannedConfigurations.first(where: { $0.kind == .springBoot })?.id
                ?? JavaRunConfiguration.currentFileID
        } else if selectedConfigurationID == JavaRunConfiguration.currentFileID,
                  let springBootConfiguration = scannedConfigurations.first(where: { $0.kind == .springBoot }) {
            // A detected Spring Boot app is the useful default for a newly opened Maven project.
            selectedConfigurationID = springBootConfiguration.id
        }
        isLoadingProject = false
    }

    func select(_ configuration: JavaRunConfiguration) {
        selectedConfigurationID = configuration.id
    }

    func options(for configuration: JavaRunConfiguration) -> JavaRunOptions {
        optionsByConfigurationID[configuration.id] ?? JavaRunOptions()
    }

    func updateOptions(_ options: JavaRunOptions, for configuration: JavaRunConfiguration) {
        optionsByConfigurationID[configuration.id] = options
        persist(options, for: configuration.id)
        refreshPortConflicts()
    }

    func resetOptions(for configuration: JavaRunConfiguration) {
        let options = JavaRunOptions()
        updateOptions(options, for: configuration)
    }

    func runSelected(currentFileURL: URL?) {
        guard let configuration = selectedConfiguration else { return }
        run(configuration: configuration, currentFileURL: currentFileURL)
    }

    func restart() {
        guard let lastRunConfiguration else { return }
        run(configuration: lastRunConfiguration, currentFileURL: lastCurrentFileURL)
    }

    func run(configuration: JavaRunConfiguration, currentFileURL: URL?) {
        stop()
        output = ""
        lastExitCode = nil
        lastRunConfiguration = configuration
        lastCurrentFileURL = currentFileURL
        let options = self.options(for: configuration)
        let configuredJavaHome = options.javaHomePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredJavaHome.isEmpty && Self.resolvedJavaHome(configuredJavaHome) == nil {
            fail("JDK Home does not point to a directory: " + configuredJavaHome)
            return
        }

        let executable: URL
        let arguments: [String]
        let workingDirectory: URL

        switch configuration.kind {
        case .currentFile:
            guard let currentFileURL,
                  currentFileURL.pathExtension.lowercased() == "java" else {
                fail("Select a Java file before running Current File.")
                return
            }
            guard let javaURL = Self.javaExecutableURL(javaHomePath: options.javaHomePath) else {
                fail("No Java runtime was found. Set JAVA_HOME or install a JDK.")
                return
            }
            executable = javaURL
            arguments = Self.arguments(from: options.vmArguments)
                + [currentFileURL.standardizedFileURL.path]
                + Self.arguments(from: options.programArguments)
            workingDirectory = resolvedWorkingDirectory(
                options.workingDirectoryPath,
                fallback: currentFileURL.deletingLastPathComponent()
            )

        case .springBoot, .mavenModule:
            guard let mavenProject else {
                fail("No Maven project is available for this run configuration.")
                return
            }
            executable = MavenService.executableURL(for: mavenProject)
            var mavenArguments = ["-B", "-ntp"]
            if let modulePath = configuration.modulePath {
                mavenArguments += ["-pl", modulePath]
            }
            if !options.activeProfiles.isEmpty {
                mavenArguments += ["-P", options.activeProfiles.sorted().joined(separator: ",")]
            }
            if let mainClass = configuration.mainClass {
                mavenArguments.append("-Dspring-boot.run.main-class=" + mainClass)
            }
            let vmArguments = options.vmArguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if !vmArguments.isEmpty {
                mavenArguments.append("-Dspring-boot.run.jvmArguments=" + vmArguments)
            }
            let programArguments = options.programArguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if !programArguments.isEmpty {
                mavenArguments.append("-Dspring-boot.run.arguments=" + programArguments)
            }
            mavenArguments.append("spring-boot:run")
            arguments = mavenArguments
            let moduleDirectory = configuration.modulePath.flatMap { modulePath in
                mavenProject.allModules.first(where: { $0.relativePath == modulePath })?.url
            } ?? mavenProject.rootURL
            workingDirectory = resolvedWorkingDirectory(options.workingDirectoryPath, fallback: moduleDirectory)
        }

        runningTitle = configuration.name
        isRunning = true
        append("$ " + executable.lastPathComponent + " " + arguments.joined(separator: " ") + "\n\n")

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        var environment = ProcessInfo.processInfo.environment
        if !configuredJavaHome.isEmpty {
            environment["JAVA_HOME"] = Self.resolvedJavaHome(configuredJavaHome)?.path
        }
        process.environment = environment
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
            fail("Unable to start " + configuration.name + ": " + error.localizedDescription)
        }
    }

    func runAllModules() {
        guard mavenProject != nil else {
            fail("No Maven project is available for module run configurations.")
            return
        }
        let moduleConfigurations = configurations.filter { $0.kind == .mavenModule }
        guard !moduleConfigurations.isEmpty else {
            fail("No Maven module run configurations were detected.")
            return
        }
        stopAllModules()
        moduleSessions = []
        for configuration in moduleConfigurations {
            startModuleSession(configuration)
        }
    }

    func stopModule(_ session: JavaRunSession) {
        stopModule(sessionID: session.id)
    }

    func restartModule(_ session: JavaRunSession) {
        guard let configuration = configurations.first(where: { $0.id == session.configurationID }) else { return }
        stopModule(sessionID: session.id)
        moduleSessions.removeAll { $0.id == session.id }
        startModuleSession(configuration)
    }

    func stopAllModules() {
        for sessionID in Array(moduleProcesses.keys) {
            stopModule(sessionID: sessionID)
        }
    }

    func clearModuleOutput() {
        for index in moduleSessions.indices {
            moduleSessions[index].output = ""
        }
    }

    func clearModuleOutput(_ session: JavaRunSession) {
        guard let index = moduleSessions.firstIndex(where: { $0.id == session.id }) else { return }
        moduleSessions[index].output = ""
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
        stopAllModules()
        projectLoadID = UUID()
        projectURL = nil
        projectFiles = []
        mavenProject = nil
        configurations = [.currentFile]
        selectedConfigurationID = JavaRunConfiguration.currentFileID
        optionsByConfigurationID = [:]
        mavenProfiles = []
        moduleSessions = []
        portConflicts = []
        isLoadingProject = false
        output = ""
        lastExitCode = nil
        lastRunConfiguration = nil
        lastCurrentFileURL = nil
    }

    func clearOutput() {
        output = ""
        lastExitCode = nil
    }

    private func fail(_ message: String) {
        output = message + "\n"
        lastExitCode = 1
        isRunning = false
        runningTitle = nil
    }

    private func append(_ value: String) {
        output.append(value.replacingOccurrences(of: "\r", with: ""))
        if output.count > maximumOutputCharacters {
            output.removeFirst(output.count - maximumOutputCharacters)
        }
    }

    private func startModuleSession(_ configuration: JavaRunConfiguration) {
        guard let mavenProject else { return }
        moduleSessions.removeAll { $0.id == configuration.id }
        let options = self.options(for: configuration)
        let configuredJavaHome = options.javaHomePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredJavaHome.isEmpty && Self.resolvedJavaHome(configuredJavaHome) == nil {
            moduleSessions.append(JavaRunSession(
                id: configuration.id,
                configurationID: configuration.id,
                title: configuration.name,
                output: "JDK Home does not point to a directory: " + configuredJavaHome + "\n",
                isRunning: false,
                exitCode: 1
            ))
            return
        }
        guard let modulePath = configuration.modulePath else { return }

        let executable = MavenService.executableURL(for: mavenProject)
        var arguments = ["-B", "-ntp", "-pl", modulePath]
        if !options.activeProfiles.isEmpty {
            arguments += ["-P", options.activeProfiles.sorted().joined(separator: ",")]
        }
        if let mainClass = configuration.mainClass {
            arguments.append("-Dspring-boot.run.main-class=" + mainClass)
        }
        let vmArguments = options.vmArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vmArguments.isEmpty {
            arguments.append("-Dspring-boot.run.jvmArguments=" + vmArguments)
        }
        let programArguments = options.programArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if !programArguments.isEmpty {
            arguments.append("-Dspring-boot.run.arguments=" + programArguments)
        }
        arguments.append("spring-boot:run")

        let moduleDirectory = mavenProject.allModules.first(where: { $0.relativePath == modulePath })?.url
            ?? mavenProject.rootURL
        let workingDirectory = resolvedWorkingDirectory(options.workingDirectoryPath, fallback: moduleDirectory)
        var environment = ProcessInfo.processInfo.environment
        if !configuredJavaHome.isEmpty {
            environment["JAVA_HOME"] = Self.resolvedJavaHome(configuredJavaHome)?.path
        }

        let session = JavaRunSession(
            id: configuration.id,
            configurationID: configuration.id,
            title: configuration.name,
            output: "$ " + executable.lastPathComponent + " " + arguments.joined(separator: " ") + "\n\n",
            isRunning: true,
            exitCode: nil
        )
        moduleSessions.append(session)

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.appendModuleOutput(chunk, sessionID: configuration.id)
            }
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                guard let self, self.moduleProcesses[configuration.id] === terminatedProcess else { return }
                self.moduleOutputPipes[configuration.id]?.fileHandleForReading.readabilityHandler = nil
                if let index = self.moduleSessions.firstIndex(where: { $0.id == configuration.id }) {
                    self.moduleSessions[index].isRunning = false
                    self.moduleSessions[index].exitCode = terminatedProcess.terminationStatus
                }
                self.moduleProcesses[configuration.id] = nil
                self.moduleOutputPipes[configuration.id] = nil
            }
        }

        moduleProcesses[configuration.id] = process
        moduleOutputPipes[configuration.id] = outputPipe
        do {
            try process.run()
        } catch {
            moduleProcesses[configuration.id] = nil
            moduleOutputPipes[configuration.id] = nil
            if let index = moduleSessions.firstIndex(where: { $0.id == configuration.id }) {
                moduleSessions[index].isRunning = false
                moduleSessions[index].exitCode = 1
                appendModuleOutput(
                    "Unable to start " + configuration.name + ": " + error.localizedDescription + "\n",
                    sessionID: configuration.id
                )
            }
        }
    }

    private func stopModule(sessionID: String) {
        moduleOutputPipes[sessionID]?.fileHandleForReading.readabilityHandler = nil
        if let process = moduleProcesses[sessionID], process.isRunning {
            process.terminate()
        }
        moduleProcesses[sessionID] = nil
        moduleOutputPipes[sessionID] = nil
        if let index = moduleSessions.firstIndex(where: { $0.id == sessionID }) {
            moduleSessions[index].isRunning = false
        }
    }

    private func reconcileModuleSessions(validConfigurationIDs: Set<String>) {
        let staleSessionIDs = moduleProcesses.keys.filter { !validConfigurationIDs.contains($0) }
        for sessionID in staleSessionIDs {
            stopModule(sessionID: sessionID)
        }
        moduleSessions.removeAll { !validConfigurationIDs.contains($0.configurationID) }
    }

    private func appendModuleOutput(_ value: String, sessionID: String) {
        guard let index = moduleSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        moduleSessions[index].output.append(value.replacingOccurrences(of: "\r", with: ""))
        if moduleSessions[index].output.count > maximumOutputCharacters {
            moduleSessions[index].output.removeFirst(
                moduleSessions[index].output.count - maximumOutputCharacters
            )
        }
    }

    private func refreshPortConflicts() {
        let moduleConfigurations = configurations.filter { $0.kind == .mavenModule }
        var configurationsByPort: [Int: [String]] = [:]
        for configuration in moduleConfigurations {
            let port = configuredPort(for: configuration) ?? 8080
            guard (1...65_535).contains(port) else { continue }
            configurationsByPort[port, default: []].append(configuration.name)
        }
        portConflicts = configurationsByPort
            .filter { $0.value.count > 1 }
            .map { port, names in
                JavaRunPortConflict(
                    port: port,
                    configurationNames: names.sorted {
                        $0.localizedStandardCompare($1) == .orderedAscending
                    }
                )
            }
            .sorted { $0.port < $1.port }
    }

    private func configuredPort(for configuration: JavaRunConfiguration) -> Int? {
        let options = self.options(for: configuration)
        if let port = Self.port(in: options.programArguments) ?? Self.port(in: options.vmArguments) {
            return port
        }

        let moduleRoot = configuration.modulePath.flatMap { modulePath in
            mavenProject?.modules.first(where: { $0.relativePath == modulePath })?.url
        } ?? projectURL
        guard let moduleRoot else { return nil }
        let resourceFiles = projectFiles.filter { fileURL in
            let name = fileURL.lastPathComponent.lowercased()
            return Self.isInside(fileURL, directory: moduleRoot) &&
                (name == "application.properties" || name == "application.yml" || name == "application.yaml" ||
                 (name.hasPrefix("application-") &&
                  (name.hasSuffix(".properties") || name.hasSuffix(".yml") || name.hasSuffix(".yaml"))))
        }
        for fileURL in resourceFiles {
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8),
                  let port = Self.port(inResource: contents, fileExtension: fileURL.pathExtension.lowercased()) else {
                continue
            }
            return port
        }
        return nil
    }

    private static func port(in input: String) -> Int? {
        let tokens = arguments(from: input)
        for (index, token) in tokens.enumerated() {
            let keys = ["--server.port=", "-Dserver.port=", "--server.port", "-Dserver.port"]
            for key in keys where token.hasPrefix(key) {
                let value: String
                if token == key {
                    guard tokens.indices.contains(index + 1) else { continue }
                    value = tokens[index + 1]
                } else {
                    value = String(token.dropFirst(key.count))
                }
                if let port = Int(value), port > 0 { return port }
            }
        }
        return nil
    }

    private static func port(inResource contents: String, fileExtension: String) -> Int? {
        if fileExtension == "properties" {
            let pattern = #"(?m)^\s*server\.port\s*[:=]\s*(\d+)\s*$"#
            return firstInteger(pattern: pattern, in: contents)
        }

        var inServerSection = false
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line)
            if value.first(where: { !$0.isWhitespace }) == "#" { continue }
            if value.range(of: #"^\s*server\s*:\s*$"#, options: .regularExpression) != nil {
                inServerSection = true
                continue
            }
            if inServerSection,
               let match = value.range(of: #"^\s{2,}port\s*:\s*(\d+)\s*$"#, options: .regularExpression) {
                let matched = String(value[match])
                return firstInteger(pattern: #"(\d+)"#, in: matched)
            }
            if !value.hasPrefix(" ") && !value.hasPrefix("\t") && !value.trimmingCharacters(in: .whitespaces).isEmpty {
                inServerSection = false
            }
        }
        return firstInteger(pattern: #"(?m)^\s*server\.port\s*:\s*(\d+)\s*$"#, in: contents)
    }

    private static func firstInteger(pattern: String, in input: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: input,
                range: NSRange(input.startIndex..<input.endIndex, in: input)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: input) else { return nil }
        return Int(input[range])
    }

    private static func isInside(_ fileURL: URL, directory: URL) -> Bool {
        let filePath = fileURL.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return filePath.hasPrefix(directoryPath + "/")
    }

    private static func javaExecutableURL(javaHomePath: String) -> URL? {
        let configuredPath = javaHomePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredPath.isEmpty {
            guard let javaHome = resolvedJavaHome(configuredPath) else { return nil }
            let candidate = javaHome.appendingPathComponent("bin/java")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            return nil
        }
        if let javaHome = ProcessInfo.processInfo.environment["JAVA_HOME"] {
            let candidate = URL(fileURLWithPath: javaHome).appendingPathComponent("bin/java")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        let candidates = [
            "/opt/homebrew/opt/openjdk/bin/java",
            "/usr/local/opt/openjdk/bin/java",
            "/usr/bin/java"
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private func resolvedWorkingDirectory(_ path: String, fallback: URL) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let url = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : URL(fileURLWithPath: trimmed, relativeTo: projectURL ?? fallback)
        let standardized = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else { return fallback }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return fallback }
        return standardized
    }

    private static func resolvedJavaHome(_ path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
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
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                } else {
                    current.append(character)
                }
                continue
            }
            if character.isWhitespace && quote == nil {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func optionsKey(for configurationID: String) -> String? {
        guard let projectURL else { return nil }
        let projectKey = projectURL.path.replacingOccurrences(of: "/", with: "_")
        return "lithe.java-run-options.\(projectKey).\(configurationID)"
    }

    private func loadOptions(for configurationID: String) -> JavaRunOptions {
        guard let key = optionsKey(for: configurationID),
              let data = UserDefaults.standard.data(forKey: key),
              let options = try? JSONDecoder().decode(JavaRunOptions.self, from: data) else {
            return JavaRunOptions()
        }
        return options
    }

    private func persist(_ options: JavaRunOptions, for configurationID: String) {
        guard let key = optionsKey(for: configurationID),
              let data = try? JSONEncoder().encode(options) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
