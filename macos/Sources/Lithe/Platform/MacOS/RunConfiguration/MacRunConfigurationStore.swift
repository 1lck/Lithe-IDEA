import LitheModuleAPI
import Foundation
import Darwin

enum MacRunConfigurationStoreError: LocalizedError, Sendable {
    case invalidProject
    case generationFailed
    case writeFailed(String)
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .invalidProject: L10n.string("The project directory is unavailable.")
        case .generationFailed: L10n.string("Project identification did not produce a run configuration.")
        case .writeFailed(let message): L10n.string("Could not write project run configuration: \(message)")
        case .invalidConfiguration(let message): message
        }
    }
}

/// macOS file adapter for the shared Rust run-configuration domain.
/// It deliberately contains no merge, launch-command or language logic.
struct MacRunConfigurationStore: RunConfigurationOperations, @unchecked Sendable {
    private let core: RustCoreBridge
    private let documentMutator: any RunConfigurationDocumentMutating
    private let storage: any FileStorage
    private let preferences: any KeyValueStore
    private let immutableRoots: [URL]

    init(
        core: RustCoreBridge,
        storage: any FileStorage,
        preferences: any KeyValueStore,
        documentMutator: (any RunConfigurationDocumentMutating)? = nil,
        immutableRoots: [URL] = []
    ) {
        self.core = core
        self.storage = storage
        self.preferences = preferences
        self.immutableRoots = [Bundle.main.bundleURL] + immutableRoots
        self.documentMutator = documentMutator ?? RustRunConfigurationDocumentMutator(core: core)
    }

    func inspect(
        at projectURL: URL,
        checkFingerprint: Bool,
        providerRuns: [RunProviderConfiguration]?
    ) -> ProjectRunConfigurationInspection {
        switch core.inspectRunConfiguration(
            at: projectURL,
            checkFingerprint: checkFingerprint,
            providerRuns: providerRuns
        ) {
        case .success(let payload):
            return ProjectRunConfigurationInspection(
                status: payload.status == "ready" ? .ready : .missing,
                diagnostics: diagnostics(from: payload.diagnostics),
                recoveryAction: payload.status == "ready" ? .none : .regenerate,
                requiresGeneration: payload.requiresGeneration ?? (payload.status == "missing")
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

    /// Identifies the project's run entries in memory and the application cache.
    /// Nothing is written into the workspace; plugins own their provider runs.
    func generate(
        at projectURL: URL,
        providerRuns: [RunProviderConfiguration]?,
        lease: RunConfigurationGenerationLease
    ) throws -> RunConfigurationGenerationResult {
        try lease.check()
        let root = projectURL.standardizedFileURL
        guard storage.metadata(for: root)?.isDirectory == true else { throw MacRunConfigurationStoreError.invalidProject }
        try lease.check()
        let result = try core.generateRunConfiguration(
            at: root,
            providerRuns: providerRuns,
            cacheDirectoryURL: storage.cacheDirectory()
        ).get()
        try lease.check()
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
        let argumentLists = payload.configurations.map { $0.args ?? [] }
        let argumentTexts: [String]
        if argumentLists.isEmpty {
            argumentTexts = []
        } else {
            argumentTexts = try core.executeResult(
                command: "runConfig.argumentText", payload: ["argumentLists": argumentLists]
            ).get()
        }
        guard argumentTexts.count == argumentLists.count else {
            throw MacRunConfigurationStoreError.invalidConfiguration(L10n.string("Project run configuration is invalid"))
        }
        let configurations: [EffectiveRunConfiguration] = payload.configurations.enumerated().map { index, value in
            EffectiveRunConfiguration(
                configuration: RunConfiguration(
                    id: value.id,
                    name: value.name,
                    kind: RunConfigurationKind(rawValue: value.provider) ?? .process(provider: value.provider),
                    execution: value.execution.flatMap(RunConfigurationExecution.init(rawValue:)),
                    debugAdapter: value.debug?.adapter,
                    disabled: value.disabled,
                    buildProvider: value.extensions?.build
                ),
                options: RunOptions(
                    workingDirectoryPath: (value.cwd ?? ".") == "." ? "" : (value.cwd ?? "."),
                    programArguments: argumentTexts[index],
                    environment: value.env ?? [:],
                    providerRunOptions: value.extensions?.buildRun
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

    func providerLaunchInputs(at projectURL: URL, configurationID: String, providerRoot: String) throws -> ProviderLaunchInputs {
        switch core.providerLaunchInputs(at: projectURL, configurationID: configurationID, providerRoot: providerRoot) {
        case .success(let value): return value
        case .failure(let error): throw RunConfigurationOperationFailure(message: error.userMessage)
        }
    }

    func launchPlan(at projectURL: URL, configurationID: String) throws -> SharedLaunchPlan {
        let value: RustCoreBridge.LaunchPlanPayload
        switch core.createLaunchPlan(at: projectURL, configurationID: configurationID) {
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

    /// The generic editor replaces only preferences; it must not generate any
    /// legacy language/build defaults or claim those sources were migrated.
    func saveToolPreferences(_ preferences: ToolingJSONValue, at projectURL: URL, expecting expected: Data?) throws {
        try Task.checkCancellation()
        let root = projectURL.standardizedFileURL
        let url = root.appendingPathComponent(".lithe/run/local.json")
        try Self.validateLocalPreferenceTarget(url, root: root, immutableRoots: immutableRoots)
        let current = try MacToolchainSettingsLoader.safeNativeRead(url, maximumBytes: 2_097_152)
        guard current == expected else { throw ProjectRuntimeSettingsStoreError.conflict }
        let local = try expected.map { try JSONDecoder().decode(ToolingJSONValue.self, from: $0) }
            ?? .object(["version": .integer(2), "configurations": .array([])])
        struct Mutation: Decodable { let document: String }
        let payload: ToolingJSONValue = .object(["localDocument": local, "preferences": preferences])
        let result: Result<Mutation, RustCoreBridge.CoreCallError> = core.executeResult(command: "runConfig.updateToolPreferences", payload: payload)
        let data = Data(try result.get().document.utf8)
        guard data.count <= 2_097_152 else { throw ToolchainPreferenceError.invalid }
        if data == expected { return }
        try Task.checkCancellation()
        try ensureLocalRunIgnored(at: root)
        try Self.validateLocalPreferenceTarget(url, root: root, immutableRoots: immutableRoots)
        try storage.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        try Self.validateLocalPreferenceTarget(url, root: root, immutableRoots: immutableRoots)
        guard try storage.replaceDataPreservingMetadata(data, at: url, expecting: expected) else { throw ProjectRuntimeSettingsStoreError.conflict }
        MacFileWriteEventSuppression.markWritten(url)
    }

    /// Foundation does not resolve an existing parent link when the leaf is
    /// absent. Inspect each existing component through the shared no-follow
    /// path adapter so a missing `run` directory cannot hide such an alias.
    static func validateLocalPreferenceTarget(_ url: URL, root: URL, immutableRoots: [URL]) throws {
        let root = root.standardizedFileURL
        let canonical = root.resolvingSymlinksInPath().path
        let source = url.standardizedFileURL.path
        guard source.hasPrefix(root.path + "/") else { throw ToolchainPreferenceError.invalid }
        let relative = String(source.dropFirst(root.path.count + 1))
        let components = try MacWorkspaceSecurePath.components(of: relative)
        let target = canonical + "/" + relative
        guard !immutableRoots.contains(where: {
            let path = $0.standardizedFileURL.resolvingSymlinksInPath().path
            return canonical == path || canonical.hasPrefix(path + "/") || target == path || target.hasPrefix(path + "/")
        }) else { throw ToolchainPreferenceError.invalid }
        var descriptor = try MacWorkspaceSecurePath.openRoot(root)
        defer { Darwin.close(descriptor) }
        do {
            for component in components.dropLast() {
                let next = try MacWorkspaceSecurePath.openDirectory([component][...], below: descriptor)
                Darwin.close(descriptor); descriptor = next
            }
            if let name = components.last {
                let status = try MacWorkspaceSecurePath.status(of: name, in: descriptor)
                guard MacWorkspaceSecurePath.kind(of: status) == .file else { throw ToolchainPreferenceError.invalid }
            }
            // log-exempt: 预期的缺失：Run 本机文件或其父目录尚不存在时，无需校验最终路径
        } catch PluginWorkspaceFileError.notFound { return }
    }

    func saveEditorChanges(
        _ options: RunOptions,
        configurationID: String,
        scope: RunConfigurationSaveScope,
        at projectURL: URL
    ) throws {
        let root = projectURL.standardizedFileURL
        let mutation: RustCoreBridge.RunConfigurationEditorMutationPayload
        switch core.saveRunConfigurationEditorChanges(
            at: root,
            configurationID: configurationID,
            scope: scope,
            options: options
        ) {
        case .success(let value): mutation = value
        case .failure(let error):
            throw RunConfigurationEditorSaveFailure(stage: .prepare, message: error.userMessage)
        }
        guard let localData = mutation.localDocument.data(using: .utf8) else {
            throw RunConfigurationEditorSaveFailure(
                stage: .prepare,
                message: "The shared core returned invalid UTF-8 local configuration data."
            )
        }
        var writes = [PreparedRunDocumentWrite(
            url: root.appendingPathComponent(".lithe/run/local.json"),
            data: localData
        )]
        if scope == .project {
            guard let projectDocument = mutation.projectDocument,
                  let projectData = projectDocument.data(using: .utf8) else {
                throw RunConfigurationEditorSaveFailure(
                    stage: .prepare,
                    message: "The shared core did not return the project configuration data."
                )
            }
            writes.append(PreparedRunDocumentWrite(
                url: root.appendingPathComponent(".lithe/run/configurations.json"),
                data: projectData
            ))
        }
        do {
            try writeTransaction(writes, root: root)
        } catch {
            throw RunConfigurationEditorSaveFailure(stage: .write, message: error.localizedDescription)
        }
    }

    func saveBuildProviderConfiguration(_ reference: BuildProviderRunReference, name: String, at projectURL: URL) throws -> String {
        let root = projectURL.standardizedFileURL
        let url = root.appendingPathComponent(".lithe/run/local.json")
        let baseline = storage.fileExists(at: url) ? try storage.readData(from: url, options: []) : nil
        let result = try core.createBuildProviderRunConfiguration(at: root, reference: reference, name: name).get()
        guard let id = result.id, let data = result.document.data(using: .utf8) else { throw MacRunConfigurationStoreError.generationFailed }
        try ensureLocalRunIgnored(at: root)
        let current = storage.fileExists(at: url) ? try storage.readData(from: url, options: []) : nil
        guard current == baseline else {
            throw MacRunConfigurationStoreError.invalidConfiguration(L10n.string("Run configuration changed while saving. Reload and try again."))
        }
        try writeMutation(RunConfigurationDocumentMutation(configurationID: id, document: data),
                          to: root.appendingPathComponent(".lithe/run/local.json"), root: root)
        return id
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
                message: code == "staleProviderModel" ? L10n.string("Build provider model changed. Regenerate Run configurations before running.") : message,
                toolchain: value["toolchain"]
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
            ".lithe/run/configurations.json",
            ".lithe/run/local.json",
            ".lithe/project.json"
        ].first(where: message.contains)
    }

    private func ensureLocalRunIgnored(at root: URL) throws {
        let url = root.appendingPathComponent(".lithe/.gitignore")
        try validateWriteTarget(url, root: root)
        var contents = ""
        if storage.fileExists(at: url) {
            let data = try storage.readData(from: url, options: [])
            guard let text = String(data: data, encoding: .utf8) else {
                throw MacRunConfigurationStoreError.writeFailed("The Lithe ignore file must be UTF-8.")
            }
            contents = text
        }
        // Preserve every existing line. Append only rules that are absent or
        // overridden by a later user negation, so a file written by an older
        // generation or already repaired stays byte-for-byte unchanged on repeated saves.
        let missing = Self.missingLocalRunIgnoreRules(in: contents)
        if missing.isEmpty { return }
        if !contents.isEmpty && !contents.hasSuffix("\n") { contents += "\n" }
        contents += missing.map { $0 + "\n" }.joined()
        try storage.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try atomicWrite(Data(contents.utf8), to: url, root: root)
    }

    /// Rules keeping machine-local run documents and build output out of Git.
    /// Each entry lists the spellings that satisfy it; the first one is appended.
    /// Older versions' generation wrote the unanchored spellings, so both must count as present.
    private static let localRunIgnoreRules: [[String]] = [
        ["/run/local.json", "run/local.json"],
        ["/run/classes/", "run/classes/"],
        ["**/*.tmp"]
    ]

    static func missingLocalRunIgnoreRules(in contents: String) -> [String] {
        let lines = contents.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return localRunIgnoreRules.compactMap { spellings in
            let ignored = lines.lastIndex { spellings.contains($0) }
            let negated = lines.lastIndex { line in
                line.hasPrefix("!") && spellings.contains(String(line.dropFirst()))
            }
            if let ignored, negated.map({ $0 < ignored }) ?? true { return nil }
            return spellings[0]
        }
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

    private func writeTransaction(_ writes: [PreparedRunDocumentWrite], root: URL) throws {
        let snapshots = try writes.map { write -> PreparedRunDocumentSnapshot in
            try validateWriteTarget(write.url, root: root)
            let existing = storage.fileExists(at: write.url)
                ? try storage.readData(from: write.url, options: [])
                : nil
            return PreparedRunDocumentSnapshot(url: write.url, data: existing)
        }
        for write in writes {
            try storage.createDirectory(
                at: write.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        var completedSnapshots: [PreparedRunDocumentSnapshot] = []
        do {
            for (write, snapshot) in zip(writes, snapshots) {
                try atomicWrite(write.data, to: write.url, root: root)
                completedSnapshots.append(snapshot)
            }
        } catch {
            var rollbackError: (any Error)?
            for snapshot in completedSnapshots.reversed() {
                do {
                    if let data = snapshot.data {
                        try storage.writeData(data, to: snapshot.url, options: .atomic)
                    } else if storage.fileExists(at: snapshot.url) {
                        try storage.removeItem(at: snapshot.url)
                    }
                    MacFileWriteEventSuppression.markWritten(snapshot.url)
                } catch {
                    rollbackError = error
                }
            }
            if let rollbackError {
                throw MacRunConfigurationStoreError.writeFailed(
                    "The save failed and the previous configuration could not be restored: \(rollbackError.localizedDescription)"
                )
            }
            throw error
        }
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
        let resolvedTarget = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolvedTarget.hasPrefix(resolvedRoot + "/"), !immutableRoots.contains(where: {
            let immutable = $0.standardizedFileURL.resolvingSymlinksInPath().path
            return resolvedRoot == immutable || resolvedRoot.hasPrefix(immutable + "/")
                || resolvedTarget == immutable || resolvedTarget.hasPrefix(immutable + "/")
        }) else { throw ProjectRuntimeSettingsStoreError.conflict }
    }

}

private struct PreparedRunDocumentWrite {
    let url: URL
    let data: Data
}

private struct PreparedRunDocumentSnapshot {
    let url: URL
    let data: Data?
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
