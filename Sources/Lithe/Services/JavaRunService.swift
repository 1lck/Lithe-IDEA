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

    private let process: any StreamingProcess
    private let processFactory: () -> any StreamingProcess
    private let fileStorage: any FileStorage
    private let preferences: any KeyValueStore
    private let javaMavenOperations: any JavaMavenOperations
    private var projectURL: URL?
    private var projectFiles: [URL] = []
    private var mavenProject: MavenProject?
    private var projectLoadID = UUID()
    private var lastRunConfiguration: JavaRunConfiguration?
    private var lastCurrentFileURL: URL?
    private var moduleProcesses: [String: any StreamingProcess] = [:]
    private var activeOperationID: String?
    private var moduleOperationIDs: [String: String] = [:]
    private let maximumOutputCharacters = 500_000
    private let runtimeService: ProjectRuntimeService

    init(
        runtimeService: ProjectRuntimeService,
        process: any StreamingProcess,
        processFactory: @escaping () -> any StreamingProcess,
        fileStorage: any FileStorage,
        preferences: any KeyValueStore,
        javaMavenOperations: any JavaMavenOperations
    ) {
        self.runtimeService = runtimeService
        self.process = process
        self.processFactory = processFactory
        self.fileStorage = fileStorage
        self.preferences = preferences
        self.javaMavenOperations = javaMavenOperations
        process.onOutput = { [weak self] chunk in
            Task { @MainActor [weak self] in
                self?.append(chunk)
            }
        }
        process.onTermination = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                self?.finishProcess(exitCode: exitCode)
            }
        }
        process.onStateChange = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consumeLifecycle(event)
            }
        }
    }

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
        let javaMavenOperations = javaMavenOperations
        let scannedConfigurations = await Task.detached(priority: .utility) {
            javaMavenOperations.scanRunConfigurations(
                at: projectURL,
                files: files,
                mavenProject: mavenProject
            )
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
        if !configuredJavaHome.isEmpty && runtimeService.javaHomeURL(overridePath: configuredJavaHome) == nil {
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
            guard let javaURL = runtimeService.javaExecutableURL(overridePath: options.javaHomePath) else {
                fail("No Java runtime was found. Set JAVA_HOME or install a JDK.")
                return
            }
            executable = javaURL
            var currentFileArguments = Self.arguments(from: options.vmArguments)
            if let classPath = classPath(for: currentFileURL) {
                // Source-file mode still needs the compiled project classes when
                // the current file references sibling Maven classes.
                currentFileArguments += ["--class-path", classPath]
            }
            currentFileArguments += [currentFileURL.standardizedFileURL.path]
            currentFileArguments += Self.arguments(from: options.programArguments)
            arguments = currentFileArguments
            workingDirectory = resolvedWorkingDirectory(
                options.workingDirectoryPath,
                fallback: currentFileURL.deletingLastPathComponent()
            )

        case .springBoot, .mavenModule:
            guard let mavenProject else {
                fail("No Maven project is available for this run configuration.")
                return
            }
            guard let mavenExecutable = runtimeService.mavenExecutable(for: mavenProject) else {
                fail("No Maven executable was found. Configure Maven in Project Settings.")
                return
            }
            executable = mavenExecutable
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

        let processKind: ProjectRuntimeProcessKind = configuration.kind == .currentFile ? .java : .maven
        let operationID = UUID().uuidString
        activeOperationID = operationID
        do {
            try process.start(ProcessRequest(
                operationID: operationID,
                executablePath: executable.path,
                arguments: arguments,
                workingDirectory: workingDirectory.path,
                environment: runtimeService.environment(
                    for: processKind,
                    javaHomeOverride: configuredJavaHome
                )
            ))
        } catch {
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
        process.stop()
        isRunning = false
        runningTitle = nil
        activeOperationID = nil
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

    private func finishProcess(exitCode: Int32) {
        isRunning = false
        runningTitle = nil
        lastExitCode = exitCode
        activeOperationID = nil
    }

    private func consumeLifecycle(_ event: ProcessLifecycleEvent) {
        guard event.operationID == activeOperationID else { return }
        switch event.state {
        case .starting, .running:
            isRunning = true
        case .stopping, .finished:
            isRunning = false
        case .failed:
            isRunning = false
            runningTitle = nil
            lastExitCode = event.exitCode ?? 1
            if let message = event.message, !message.isEmpty {
                append("Unable to run: " + message + "\n")
            }
        }
    }

    private func append(_ value: String) {
        output.append(value.replacingOccurrences(of: "\r", with: ""))
        if output.count > maximumOutputCharacters {
            output.removeFirst(output.count - maximumOutputCharacters)
        }
    }

    private func classPath(for fileURL: URL) -> String? {
        var candidateRoots: [URL] = []
        if let mavenProject {
            candidateRoots += mavenProject.allModules
                .filter { Self.isInside(fileURL, directory: $0.url) }
                .sorted { $0.url.path.count > $1.url.path.count }
                .map(\.url)
            candidateRoots.append(mavenProject.rootURL)
        }
        if let projectURL {
            candidateRoots.append(projectURL)
        }

        var seenPaths = Set<String>()
        for root in candidateRoots {
            let classesURL = root.appendingPathComponent("target/classes", isDirectory: true)
            guard seenPaths.insert(classesURL.standardizedFileURL.path).inserted else { continue }
            guard fileStorage.metadata(for: classesURL)?.isDirectory == true else { continue }
            return classesURL.standardizedFileURL.path
        }
        return nil
    }

    private func startModuleSession(_ configuration: JavaRunConfiguration) {
        guard let mavenProject else { return }
        moduleSessions.removeAll { $0.id == configuration.id }
        let options = self.options(for: configuration)
        let configuredJavaHome = options.javaHomePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredJavaHome.isEmpty && runtimeService.mavenJavaHomeURL(overridePath: configuredJavaHome) == nil {
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

        guard let executable = runtimeService.mavenExecutable(for: mavenProject) else {
            moduleSessions.append(JavaRunSession(
                id: configuration.id,
                configurationID: configuration.id,
                title: configuration.name,
                output: "No Maven executable was found. Configure Maven in Project Settings.\n",
                isRunning: false,
                exitCode: 1
            ))
            return
        }
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
        let environment = runtimeService.environment(
            for: .maven,
            javaHomeOverride: configuredJavaHome
        )

        let session = JavaRunSession(
            id: configuration.id,
            configurationID: configuration.id,
            title: configuration.name,
            output: "$ " + executable.lastPathComponent + " " + arguments.joined(separator: " ") + "\n\n",
            isRunning: true,
            exitCode: nil
        )
        moduleSessions.append(session)

        let process = processFactory()
        process.onOutput = { [weak self] chunk in
            Task { @MainActor [weak self] in
                self?.appendModuleOutput(chunk, sessionID: configuration.id)
            }
        }
        process.onTermination = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                self?.finishModule(sessionID: configuration.id, exitCode: exitCode)
            }
        }
        let operationID = UUID().uuidString
        process.onStateChange = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consumeModuleLifecycle(event, sessionID: configuration.id)
            }
        }

        moduleProcesses[configuration.id] = process
        moduleOperationIDs[configuration.id] = operationID
        do {
            try process.start(ProcessRequest(
                operationID: operationID,
                executablePath: executable.path,
                arguments: arguments,
                workingDirectory: workingDirectory.path,
                environment: environment
            ))
        } catch {
            moduleProcesses[configuration.id] = nil
            moduleOperationIDs[configuration.id] = nil
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
        moduleProcesses[sessionID]?.stop()
        moduleProcesses[sessionID] = nil
        moduleOperationIDs[sessionID] = nil
        if let index = moduleSessions.firstIndex(where: { $0.id == sessionID }) {
            moduleSessions[index].isRunning = false
        }
    }

    private func finishModule(sessionID: String, exitCode: Int32) {
        guard moduleProcesses[sessionID] != nil else { return }
        if let index = moduleSessions.firstIndex(where: { $0.id == sessionID }) {
            moduleSessions[index].isRunning = false
            moduleSessions[index].exitCode = exitCode
        }
        moduleProcesses[sessionID] = nil
        moduleOperationIDs[sessionID] = nil
    }

    private func consumeModuleLifecycle(_ event: ProcessLifecycleEvent, sessionID: String) {
        guard event.operationID == moduleOperationIDs[sessionID] else { return }
        switch event.state {
        case .starting, .running:
            if let index = moduleSessions.firstIndex(where: { $0.id == sessionID }) {
                moduleSessions[index].isRunning = true
            }
        case .stopping, .finished:
            if let index = moduleSessions.firstIndex(where: { $0.id == sessionID }) {
                moduleSessions[index].isRunning = false
            }
        case .failed:
            if let index = moduleSessions.firstIndex(where: { $0.id == sessionID }) {
                moduleSessions[index].isRunning = false
                moduleSessions[index].exitCode = event.exitCode ?? 1
                if let message = event.message, !message.isEmpty {
                    appendModuleOutput(message + "\n", sessionID: sessionID)
                }
            }
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
            guard let data = try? fileStorage.readData(from: fileURL, options: []),
                  let contents = String(data: data, encoding: .utf8),
                  let port = javaMavenOperations.serverPort(
                      content: contents,
                      fileExtension: fileURL.pathExtension.lowercased()
                  ) else {
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

    private static func isInside(_ fileURL: URL, directory: URL) -> Bool {
        let filePath = fileURL.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return filePath.hasPrefix(directoryPath + "/")
    }

    private func resolvedWorkingDirectory(_ path: String, fallback: URL) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let url = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : URL(fileURLWithPath: trimmed, relativeTo: projectURL ?? fallback)
        let standardized = url.standardizedFileURL
        guard fileStorage.metadata(for: standardized)?.isDirectory == true else { return fallback }
        return standardized
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
              let data = preferences.data(forKey: key),
              let options = try? JSONDecoder().decode(JavaRunOptions.self, from: data) else {
            return JavaRunOptions()
        }
        return options
    }

    private func persist(_ options: JavaRunOptions, for configurationID: String) {
        guard let key = optionsKey(for: configurationID),
              let data = try? JSONEncoder().encode(options) else { return }
        preferences.set(data, forKey: key)
    }
}
