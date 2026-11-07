import CryptoKit
import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Settings edits use the existing Run document and conditional native writer.
/// No probe or process starts here; a saved path remains an inert input which
/// the normal toolchain resolver rechecks when a consumer actually runs.
@MainActor
final class MacToolchainPreferencesStore: ToolchainPreferencesStoring {
    private let core: RustCoreBridge
    private let storage: any FileStorage
    private let immutableRoots: @MainActor () -> [URL]

    init(core: RustCoreBridge, storage: any FileStorage, immutableRoots: @escaping @MainActor () -> [URL]) {
        self.core = core; self.storage = storage; self.immutableRoots = immutableRoots
    }

    func load(workspace: URL) async throws -> ToolchainPreferencesSnapshot {
        let core = self.core, storage = self.storage, roots = immutableRoots()
        return try await worker { try Self.read(workspace: workspace, core: core, storage: storage, immutable: roots).snapshot }
    }

    func inspect(_ address: ToolchainPreferenceAddress, snapshot: ToolchainPreferencesSnapshot) throws -> ToolchainPreferenceReading {
        let payload: ToolingJSONValue = .object(["document": snapshot.document, "directory": .string(address.directory),
            "consumer": address.consumer.map(ToolingJSONValue.string) ?? .null, "tool": .string(address.tool)])
        struct Outcome: Decodable { let status: String; let preferences: Reading? }
        struct Reading: Decodable { let stored: ToolingJSONValue?; let fixed: FixedToolchainSelection?; let source: Source }
        struct Source: Decodable { let kind: String }
        let result: Result<Outcome, RustCoreBridge.CoreCallError> = core.executeResult(command: "toolchains.resolveConsumerPreferences", payload: payload)
        let outcome = try result.get()
        guard outcome.status == "ok", let reading = outcome.preferences else { throw ToolchainSettingsLoadError.invalidLocal }
        return .init(stored: reading.stored == .null ? nil : reading.stored, fixed: reading.fixed, source: reading.source.kind)
    }

    func save(_ value: ToolingJSONValue?, at address: ToolchainPreferenceAddress,
              expecting snapshot: ToolchainPreferencesSnapshot) async throws -> ToolchainPreferencesSnapshot {
        let core = self.core, storage = self.storage, roots = immutableRoots()
        return try await worker {
            let before = try Self.read(workspace: snapshot.workspace, core: core, storage: storage, immutable: roots)
            guard before.snapshot.revision == snapshot.revision else { throw ProjectRuntimeSettingsStoreError.conflict }
            struct Outcome: Decodable { let status: String; let edit: Edit? }
            struct Edit: Decodable { let document: ToolingJSONValue }
            let payload: ToolingJSONValue = .object(["document": before.snapshot.document, "directory": .string(address.directory),
                "consumer": address.consumer.map(ToolingJSONValue.string) ?? .null, "tool": .string(address.tool), "value": value ?? .null])
            let result: Result<Outcome, RustCoreBridge.CoreCallError> = core.executeResult(command: "toolchains.editConsumerPreferences", payload: payload)
            let outcome = try result.get()
            guard outcome.status == "ok", let edit = outcome.edit else { throw ToolchainSettingsLoadError.invalidLocal }
            if edit.document == before.snapshot.document { return before.snapshot }
            try Task.checkCancellation()
            let store = MacRunConfigurationStore(core: core, storage: storage, preferences: MacUserDefaultsStore(), immutableRoots: roots)
            try store.saveToolPreferences(edit.document, at: snapshot.workspace, expecting: before.bytes)
            let after = try Self.read(workspace: snapshot.workspace, core: core, storage: storage, immutable: roots)
            guard after.snapshot.document == edit.document else { throw ProjectRuntimeSettingsStoreError.readBack }
            return after.snapshot
        }
    }

    private func worker<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { try operation() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private struct Reading: Sendable {
        let snapshot: ToolchainPreferencesSnapshot
        let bytes: Data?
    }

    nonisolated private static func read(workspace: URL, core: RustCoreBridge, storage: any FileStorage, immutable: [URL]) throws -> Reading {
        try Task.checkCancellation()
        let workspace = workspace.standardizedFileURL
        try MacRunConfigurationStore.validateLocalPreferenceTarget(workspace.appendingPathComponent(".lithe/run/local.json"),
            root: workspace, immutableRoots: [Bundle.main.bundleURL] + immutable)
        let canonical = workspace.resolvingSymlinksInPath().path
        let url = workspace.appendingPathComponent(".lithe/run/local.json")
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard target.hasPrefix(canonical + "/"), !([Bundle.main.bundleURL] + immutable).contains(where: {
            let path = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return canonical == path || canonical.hasPrefix(path + "/") || target == path || target.hasPrefix(path + "/")
        }) else { throw ToolchainSettingsLoadError.readFailed }
        let bytes = try MacToolchainSettingsLoader.safeNativeRead(url, maximumBytes: 2_097_152)
        let store = MacRunConfigurationStore(core: core, storage: storage, preferences: MacUserDefaultsStore(), immutableRoots: immutable)
        let inspection = store.inspect(at: workspace, checkFingerprint: false, providerRuns: nil)
        if case .invalid = inspection.status { throw ToolchainSettingsLoadError.invalidLocal }
        guard try MacToolchainSettingsLoader.safeNativeRead(url, maximumBytes: 2_097_152) == bytes else { throw ProjectRuntimeSettingsStoreError.conflict }
        let run = try bytes.map { try JSONDecoder().decode(ToolingJSONValue.self, from: $0) }
        let document: ToolingJSONValue
        if case .object(let object) = run, case .object(let toolchain) = object["toolchain"] {
            document = toolchain["preferences"] ?? .object(["version": .integer(1)])
        } else { document = .object(["version": .integer(1)]) }
        var identity = Data(canonical.utf8); identity.append(0); identity.append(bytes == nil ? 0 : 1); identity.append(bytes ?? Data())
        let revision = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return Reading(snapshot: .init(workspace: workspace, document: document, revision: revision), bytes: bytes)
    }
}

/// Failures shared by the conditional writers of the project's local run
/// document. The messages tell the user that their draft is kept.
enum ProjectRuntimeSettingsStoreError: LocalizedError {
    case conflict
    case readBack
    var errorDescription: String? {
        switch self {
        case .conflict: L10n.string("Project environment settings changed on disk. Reload before saving; your draft has been kept.")
        case .readBack: L10n.string("Could not verify the saved project environment settings. The previous preferences have been kept when possible.")
        }
    }
}
