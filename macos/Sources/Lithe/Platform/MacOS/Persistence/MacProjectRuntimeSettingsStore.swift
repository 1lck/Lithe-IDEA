import CryptoKit
import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Project-wide tool selections live only in the Core-owned local run document.
/// Other legacy preferences remain in their existing store until their owning
/// domain migration can transfer them without losing user data.
struct MacProjectRuntimeSettingsStore: ProjectRuntimeSettingsStoring {
    let core: RustCoreBridge
    let storage: any FileStorage
    let preferences: any KeyValueStore

    private static let toolKeys = ["javaHomePath", "mavenHomeSelection", "mavenHomePath", "mavenJavaHomePath", "moduleOverrides"]

    func load(at workspace: URL, migrateLegacy: Bool) throws -> ProjectRuntimeSettingsSnapshot {
        let root = workspace.standardizedFileURL
        let key = Self.preferencesKey(root)
        let preferenceData = preferences.data(forKey: key)
        let legacy = try preferenceData.map { try JSONDecoder().decode(ProjectRuntimeSettings.self, from: $0) }
            ?? ProjectRuntimeSettings()
        let before = try localData(root)
        let inspection = try inspect(root)
        let inspected = inspection.projectToolchain
        guard try localData(root) == before else { throw ProjectRuntimeSettingsStoreError.conflict }
        if migrateLegacy, let preferenceData,
           var document = try JSONSerialization.jsonObject(with: preferenceData) as? [String: Any],
           Self.toolKeys.contains(where: { document[$0] != nil }) {
            let paths = legacy.moduleOverrides.map(\.path)
            let known = Set(["path", "javaHomePath", "mavenExecutablePath", "mavenJavaHomePath"])
            let rawOverrides = document["moduleOverrides"] as? [[String: Any]] ?? []
            guard Set(paths).count == paths.count,
                  rawOverrides.allSatisfy({ Set($0.keys).isSubset(of: known) }) else {
                throw ProjectRuntimeSettingsStoreError.readBack
            }
            let previous = legacy.projectToolchainSelection()
            var selection = inspected ?? previous
            if inspected != nil, !inspection.hasSavedToolchainPathOverrides {
                selection.pathOverrides = previous.pathOverrides
            }
            if (inspected == nil && selection != ProjectToolchainSelection())
                || (inspected != nil && !inspection.hasSavedToolchainPathOverrides) {
                try runStore.saveProjectToolchain(selection, at: root, expecting: before)
                guard try inspect(root).projectToolchain == selection else { throw ProjectRuntimeSettingsStoreError.readBack }
            }
            // Keep the source until the target has been read successfully. An
            // existing (including explicitly automatic) toolchain always wins.
            guard preferences.data(forKey: key) == preferenceData else { throw ProjectRuntimeSettingsStoreError.conflict }
            for field in Self.toolKeys { document.removeValue(forKey: field) }
            let cleaned = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            preferences.set(cleaned, forKey: key)
            guard preferences.data(forKey: key) == cleaned else { throw ProjectRuntimeSettingsStoreError.readBack }
            return try load(at: root, migrateLegacy: false)
        }
        var settings = legacy
        settings.applyProjectToolchain(inspected ?? ProjectToolchainSelection())
        return ProjectRuntimeSettingsSnapshot(workspaceURL: root, settings: settings, revision: Self.revision(before, preferenceData), hasSavedToolchain: inspected != nil)
    }

    func save(_ settings: ProjectRuntimeSettings, at workspace: URL,
              expecting snapshot: ProjectRuntimeSettingsSnapshot) throws -> ProjectRuntimeSettingsSnapshot {
        let root = workspace.standardizedFileURL
        guard snapshot.workspaceURL == root else { throw ProjectRuntimeSettingsStoreError.conflict }
        let current = try load(at: root, migrateLegacy: false)
        guard current.revision == snapshot.revision else { throw ProjectRuntimeSettingsStoreError.conflict }
        if settings == current.settings { return current }
        let before = try localData(root)
        let key = Self.preferencesKey(root)
        let preferenceData = preferences.data(forKey: key)
        guard Self.revision(before, preferenceData) == snapshot.revision else { throw ProjectRuntimeSettingsStoreError.conflict }
        let selected = settings.projectToolchainSelection()
        if selected != current.settings.projectToolchainSelection() {
            try runStore.saveProjectToolchain(selected, at: root, expecting: before)
            guard try inspect(root).projectToolchain == selected else { throw ProjectRuntimeSettingsStoreError.readBack }
        }
        guard preferences.data(forKey: key) == preferenceData else { throw ProjectRuntimeSettingsStoreError.conflict }
        // Preserve unrelated legacy fields while removing tool selections now
        // owned by the canonical document, including all subproject overrides.
        var document = try preferenceData.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any] else {
            throw ProjectRuntimeSettingsStoreError.readBack
        }
        for (field, value) in encoded where !Self.toolKeys.contains(field) && !["mavenSettingsPath", "mavenLocalRepositoryPath"].contains(field) { document[field] = value }
        for field in Self.toolKeys { document.removeValue(forKey: field) }
        let saved = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        preferences.set(saved, forKey: key)
        guard preferences.data(forKey: key) == saved else { throw ProjectRuntimeSettingsStoreError.readBack }
        return try load(at: root, migrateLegacy: false)
    }

    private var runStore: MacRunConfigurationStore {
        MacRunConfigurationStore(core: core, storage: storage, preferences: preferences)
    }

    private func inspect(_ root: URL) throws -> ProjectRunConfigurationInspection {
        let result = runStore.inspect(at: root, checkFingerprint: false, javaEntrypoints: nil)
        if case .invalid(let message) = result.status {
            throw MacRunConfigurationStoreError.invalidConfiguration(message)
        }
        return result
    }

    private func localData(_ root: URL) throws -> Data? {
        let url = root.appendingPathComponent(".lithe/run/local.json")
        return storage.fileExists(at: url) ? try storage.readData(from: url, options: []) : nil
    }

    static func preferencesKey(_ workspace: URL) -> String {
        "lithe.project-runtime-settings." + workspace.standardizedFileURL.path.replacingOccurrences(of: "/", with: "_")
    }

    private static func revision(_ local: Data?, _ preferences: Data?) -> String {
        // Separate missing from empty and use independent digests to avoid
        // ambiguous concatenation of two documents.
        [local, preferences].map { data in
            data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "missing"
        }.joined(separator: ":")
    }
}

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
