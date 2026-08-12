import Foundation

enum MacRunConfigurationStoreError: LocalizedError, Sendable {
    case invalidProject
    case generationFailed
    case writeFailed(String)
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .invalidProject: "The project directory is unavailable."
        case .generationFailed: "Project identification did not produce a run configuration."
        case .writeFailed(let message): "Could not write project run configuration: \(message)"
        case .invalidConfiguration(let message): message
        }
    }
}

/// macOS file and migration adapter for the shared Rust run-configuration domain.
/// It deliberately contains no merge or launch-command logic.
struct MacRunConfigurationStore: RunConfigurationOperations, @unchecked Sendable {
    private let core: RustCoreBridge
    private let documentMutator: any RunConfigurationDocumentMutating
    private let storage: any FileStorage
    private let preferences: any KeyValueStore

    init(
        core: RustCoreBridge,
        storage: any FileStorage,
        preferences: any KeyValueStore,
        documentMutator: (any RunConfigurationDocumentMutating)? = nil
    ) {
        self.core = core
        self.storage = storage
        self.preferences = preferences
        self.documentMutator = documentMutator ?? RustRunConfigurationDocumentMutator(core: core)
    }

    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        switch core.inspectRunConfiguration(at: projectURL) {
        case .success(let payload):
            return ProjectRunConfigurationInspection(
                status: payload.status == "ready" ? .ready : .missing,
                diagnostics: diagnostics(from: payload.diagnostics),
                recoveryAction: payload.status == "ready" ? .none : .regenerate
            )
        case .failure(let error):
            return ProjectRunConfigurationInspection(
                status: .invalid(error.userMessage),
                diagnostics: [],
                recoveryAction: Self.recoveryAction(for: error.code),
                recoveryPath: Self.recoveryPath(in: error.userMessage)
            )
        }
    }

    /// Explicit user action. Opening a project never calls this method implicitly.
    func generate(at projectURL: URL, files: [URL], modulePaths: [String]) throws -> RunConfigurationGenerationResult {
        let root = projectURL.standardizedFileURL
        guard storage.metadata(for: root)?.isDirectory == true else { throw MacRunConfigurationStoreError.invalidProject }
        let paths = files.compactMap { file -> String? in
            let value = file.standardizedFileURL
            guard value.path.hasPrefix(root.path + "/") else { return nil }
            return String(value.path.dropFirst(root.path.count + 1))
        }
        let result = try core.generateRunConfiguration(
            at: root,
            paths: paths,
            modulePaths: modulePaths
        ).get()
        try writeGenerated(result, at: root)
        return RunConfigurationGenerationResult(entryCount: result.entryCount)
    }

    func resolve(
        at projectURL: URL,
        toolchainCandidates: [ProjectToolchainCandidate]
    ) throws -> RunConfigurationResolution {
        let payload: RustCoreBridge.RunConfigurationPayload
        switch core.resolveRunConfiguration(at: projectURL, toolchainCandidates: toolchainCandidates) {
        case .success(let value): payload = value
        case .failure(let error): throw RunConfigurationOperationFailure(message: error.userMessage)
        }
        let configurations: [EffectiveRunConfiguration] = payload.configurations.map { value in
            let kind = configurationKind(value.provider)
            let maven = value.maven
            let java = value.extensions?.java
            return EffectiveRunConfiguration(
                configuration: RunConfiguration(
                    id: value.id,
                    name: value.name,
                    kind: kind,
                    execution: value.execution.flatMap(RunConfigurationExecution.init(rawValue:)),
                    modulePath: maven?.module == "." ? nil : maven?.module,
                    mainClass: maven?.mainClass
                ),
                options: RunOptions(
                    javaHomePath: java?.homePath ?? "",
                    workingDirectoryPath: (value.cwd ?? ".") == "." ? "" : (value.cwd ?? "."),
                    vmArguments: (maven?.jvmArguments ?? []).joined(separator: " "),
                    programArguments: (maven?.programArguments ?? value.args ?? []).joined(separator: " "),
                    activeProfiles: Set(maven?.profiles ?? []),
                    mavenExecutablePath: java?.mavenExecutablePath ?? "",
                    mavenJavaHomePath: java?.mavenJavaHomePath ?? "",
                    environment: value.env ?? [:]
                ),
                source: RunConfigurationSource(rawValue: value.source ?? "generated") ?? .generated
            )
        }
        return RunConfigurationResolution(
            configurations: configurations,
            diagnostics: diagnostics(from: payload.diagnostics),
            defaultConfigurationID: payload.defaultRunConfiguration
        )
    }

    func launchPlan(
        at projectURL: URL,
        configurationID: String,
        currentFile: String?,
        classPath: String?,
        debugPort: Int?
    ) throws -> SharedLaunchPlan {
        let value: RustCoreBridge.LaunchPlanPayload
        switch core.createLaunchPlan(
            at: projectURL,
            configurationID: configurationID,
            currentFile: currentFile,
            classPath: classPath,
            debugPort: debugPort
        ) {
        case .success(let payload): value = payload
        case .failure(let error): throw RunConfigurationOperationFailure(message: error.userMessage)
        }
        let executable: SharedLaunchPlan.Executable
        if let toolchain = value.executable.toolchain {
            executable = .toolchain(toolchain)
        } else if let command = value.executable.command {
            executable = .command(command)
        } else {
            throw RunConfigurationOperationFailure(
                message: "The launch plan names neither a toolchain nor a command."
            )
        }
        return SharedLaunchPlan(
            executable: executable,
            arguments: value.arguments,
            workingDirectory: value.workingDirectory,
            environment: value.env ?? [:]
        )
    }

    func saveOptions(
        _ options: RunOptions,
        configurationID: String,
        scope: RunConfigurationSaveScope,
        at projectURL: URL
    ) throws {
        let root = projectURL.standardizedFileURL
        let fileName = scope == .local ? "local.json" : "configurations.json"
        let url = root.appendingPathComponent(".lithe/run/\(fileName)")
        let mutation = try documentMutator.updateOptionsDocument(
            at: root,
            configurationID: configurationID,
            scope: scope,
            options: options
        )
        try writeMutation(mutation, to: url, root: root)
    }

    func createConfiguration(_ draft: RunConfigurationDraft, at projectURL: URL) throws -> String {
        let root = projectURL.standardizedFileURL
        let fileName = draft.scope == .local ? "local.json" : "configurations.json"
        let url = root.appendingPathComponent(".lithe/run/\(fileName)")
        let mutation = try documentMutator.createConfigurationDocument(at: root, draft: draft)
        guard let id = mutation.configurationID else {
            throw MacRunConfigurationStoreError.invalidConfiguration(
                "The shared core did not return a configuration ID."
            )
        }
        try writeMutation(mutation, to: url, root: root)
        return id
    }

    /// Converts the legacy per-project UserDefaults values into local-only JSON once.
    /// Existing values are retained as a rollback source for one release cycle.
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws {
        let root = projectURL.standardizedFileURL
        let projectKey = root.path.replacingOccurrences(of: "/", with: "_")
        let markerKey = "lithe.run-configuration-migrated.\(projectKey)"
        if preferences.object(forKey: markerKey) as? Bool == true { return }
        let localURL = root.appendingPathComponent(".lithe/run/local.json")
        if !storage.fileExists(at: localURL) {
            let document: [String: Any] = ["version": 1, "configurations": []]
            let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .prettyPrinted])
            try validateWriteTarget(localURL, root: root)
            try storage.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try atomicWrite(data, to: localURL, root: root)
            for id in configurationIDs {
                let key = "lithe.java-run-options.\(projectKey).\(id)"
                guard let data = preferences.data(forKey: key),
                      let options = try? JSONDecoder().decode(RunOptions.self, from: data) else { continue }
                let mutation = try documentMutator.updateOptionsDocument(
                    at: root,
                    configurationID: id,
                    scope: .local,
                    options: options
                )
                try writeMutation(mutation, to: localURL, root: root)
            }
            try migrateLegacyToolchainsIntoServices(
                root: root,
                projectKey: projectKey,
                configurationIDs: configurationIDs,
                localURL: localURL
            )
        }
        preferences.set(true, forKey: markerKey)
    }

    private func writeGenerated(_ result: RustCoreBridge.RunConfigurationGeneratePayload, at root: URL) throws {
        let directory = root.appendingPathComponent(".lithe/run")
        let requirementsDirectory = root.appendingPathComponent(".lithe/toolchains")
        let generatedURL = directory.appendingPathComponent("generated.json")
        let requirementsURL = requirementsDirectory.appendingPathComponent("requirements.json")
        let ignoreURL = root.appendingPathComponent(".lithe/.gitignore")
        let manifestURL = root.appendingPathComponent(".lithe/project.json")
        do {
            for url in [generatedURL, requirementsURL, ignoreURL, manifestURL] {
                try validateWriteTarget(url, root: root)
            }
            try storage.createDirectory(at: directory, withIntermediateDirectories: true)
            try storage.createDirectory(at: requirementsDirectory, withIntermediateDirectories: true)
            let generatedData = try JSONEncoder.prettySorted.encode(result.generated)
            let requirementsData = try JSONEncoder.prettySorted.encode(result.toolchainRequirements)
            try atomicWrite(requirementsData, to: requirementsURL, root: root)
            let ignore = "run/local.json\n**/*.tmp\n"
            if !storage.fileExists(at: ignoreURL) { try atomicWrite(Data(ignore.utf8), to: ignoreURL, root: root) }
            if !storage.fileExists(at: manifestURL) {
                // A framework service is what the user most likely wants to
                // start first, whichever framework the project uses.
                let frameworkProviders = Set(MavenFrameworkKind.allCases.map(\.provider))
                let defaultID = result.generated.configurations
                    .first(where: { frameworkProviders.contains($0.provider) })?.id
                    ?? result.generated.configurations.first?.id
                var manifest: [String: Any] = ["version": 1]
                if let defaultID { manifest["defaultRunConfiguration"] = defaultID }
                try writeJSONObject(manifest, to: manifestURL, root: root)
            }
            // generated.json is the commit marker for a complete identification pass.
            try atomicWrite(generatedData, to: generatedURL, root: root)
        } catch {
            throw MacRunConfigurationStoreError.writeFailed(error.localizedDescription)
        }
    }

    private func atomicWrite(_ data: Data, to url: URL, root: URL) throws {
        try validateWriteTarget(url, root: root)
        if storage.fileExists(at: url),
           let existing = try? storage.readData(from: url, options: []),
           existing == data {
            return
        }
        try storage.writeData(data, to: url, options: .atomic)
        MacFileWriteEventSuppression.markWritten(url)
    }

    private func diagnostics(from values: [[String: String]]?) -> [RunConfigurationDiagnostic] {
        (values ?? []).compactMap { value in
            guard let code = value["code"], let message = value["message"] else { return nil }
            return RunConfigurationDiagnostic(
                configurationID: value["id"],
                code: code,
                message: message
            )
        }
    }

    static func recoveryAction(for coreErrorCode: String) -> RunConfigurationRecoveryAction {
        switch coreErrorCode {
        case "not_supported": .upgradeApplication
        case "parse_failed": .editConfiguration
        case "permission_denied": .fixPermissions
        default: .regenerate
        }
    }

    static func recoveryPath(in message: String) -> String? {
        [
            ".lithe/run/generated.json",
            ".lithe/run/configurations.json",
            ".lithe/run/local.json",
            ".lithe/toolchains/requirements.json",
            ".lithe/project.json"
        ].first(where: message.contains)
    }

    private func migrateLegacyToolchainsIntoServices(
        root: URL,
        projectKey: String,
        configurationIDs: [String],
        localURL: URL
    ) throws {
        let key = "lithe.project-runtime.\(projectKey)"
        guard let data = preferences.data(forKey: key),
              let settings = try? JSONDecoder().decode(ProjectRuntimeSettings.self, from: data) else { return }
        let mavenExecutable = settings.mavenHomeSelection == .custom && !settings.mavenHomePath.isEmpty
            ? URL(fileURLWithPath: settings.mavenHomePath).appendingPathComponent("bin/mvn").path
            : (settings.mavenHomeSelection == .wrapper ? "./mvnw" : "")
        guard !settings.javaHomePath.isEmpty || !mavenExecutable.isEmpty || !settings.mavenJavaHomePath.isEmpty else { return }
        for id in configurationIDs {
            let legacyKey = "lithe.java-run-options.\(projectKey).\(id)"
            var options = preferences.data(forKey: legacyKey)
                .flatMap { try? JSONDecoder().decode(RunOptions.self, from: $0) }
                ?? RunOptions()
            options.javaHomePath = settings.javaHomePath
            options.mavenExecutablePath = mavenExecutable
            options.mavenJavaHomePath = settings.mavenJavaHomePath
            let mutation = try documentMutator.updateOptionsDocument(
                at: root,
                configurationID: id,
                scope: .local,
                options: options
            )
            try writeMutation(mutation, to: localURL, root: root)
        }
    }

    private func jsonDocument(
        at url: URL,
        fallbackKey: String,
        fallbackValue: Any = []
    ) throws -> [String: Any] {
        guard storage.fileExists(at: url) else { return ["version": 1, fallbackKey: fallbackValue] }
        let data = try storage.readData(from: url, options: [])
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MacRunConfigurationStoreError.writeFailed("Existing local configuration is invalid.")
        }
        return value
    }

    private func set(_ value: String, key: String, in dictionary: inout [String: String]) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { dictionary.removeValue(forKey: key) }
        else { dictionary[key] = normalized }
    }

    private func writeJSONObject(_ value: [String: Any], to url: URL, root: URL) throws {
        try validateWriteTarget(url, root: root)
        try storage.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        try atomicWrite(data, to: url, root: root)
    }

    private func writeMutation(
        _ mutation: RunConfigurationDocumentMutation,
        to url: URL,
        root: URL
    ) throws {
        try validateWriteTarget(url, root: root)
        try storage.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try atomicWrite(mutation.document, to: url, root: root)
    }

    private func validateWriteTarget(_ url: URL, root: URL) throws {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedParent = url.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard resolvedParent == resolvedRoot || resolvedParent.hasPrefix(resolvedRoot + "/") else {
            throw MacRunConfigurationStoreError.writeFailed(
                "Refusing to write outside the project directory."
            )
        }
    }

    private func configurationKind(_ value: String) -> RunConfigurationKind {
        switch value {
        case "java.current-file": .currentFile
        case "java.main": .javaMain
        case "maven.module": .mavenModule
        default:
            if let framework = MavenFrameworkKind.allCases.first(where: { $0.provider == value }) {
                .mavenFramework(framework)
            } else {
                .process(provider: value)
            }
        }
    }
}

private struct RustRunConfigurationDocumentMutator: RunConfigurationDocumentMutating {
    let core: RustCoreBridge

    func updateOptionsDocument(
        at projectURL: URL,
        configurationID: String,
        scope: RunConfigurationSaveScope,
        options: RunOptions
    ) throws -> RunConfigurationDocumentMutation {
        try mutation(from: core.updateRunConfigurationOptions(
            at: projectURL,
            configurationID: configurationID,
            scope: scope,
            options: options
        ).get())
    }

    func createConfigurationDocument(
        at projectURL: URL,
        draft: RunConfigurationDraft
    ) throws -> RunConfigurationDocumentMutation {
        try mutation(from: core.createUserRunConfiguration(at: projectURL, draft: draft).get())
    }

    private func mutation(
        from payload: RustCoreBridge.RunConfigurationMutationPayload
    ) throws -> RunConfigurationDocumentMutation {
        guard let data = payload.document.data(using: .utf8) else {
            throw MacRunConfigurationStoreError.writeFailed(
                "The shared core returned invalid UTF-8 configuration data."
            )
        }
        return RunConfigurationDocumentMutation(configurationID: payload.id, document: data)
    }
}

private extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
