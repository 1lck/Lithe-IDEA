import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Stored option values. They follow the build-system ID, as `build.detect`
/// takes them, so a plugin update keeps the user's choices.
@MainActor
final class MacBuildOptionsStore: BuildOptionsStoring {
    private static let keyPrefix = "BuildSystems.Options."
    private let store: any KeyValueStore
    private let storage: (any FileStorage)?
    private let immutableRoots: [URL]

    init(store: any KeyValueStore, storage: (any FileStorage)? = nil, immutableRoots: [URL] = [Bundle.main.bundleURL]) {
        self.store = store
        self.storage = storage
        self.immutableRoots = immutableRoots
    }

    func migrateLegacyConfiguration(workspaceURL: URL, instances: [BuildSystemInstance]) throws -> Bool {
        let roots = instances.filter {
            $0.pluginID == "io.github.lithe-idea.maven-build" && $0.buildSystemID == "maven"
        }.map(\.root)
        guard !roots.isEmpty else { return false }
        let files = storage ?? MacFileStorage()
        return try MacLegacyMavenConfigurationMigration(storage: files, preferences: store,
            runStore: MacRunConfigurationStore(core: RustCoreBridge(), storage: files, preferences: store),
            options: self, immutableRoots: immutableRoots).migrate(workspace: workspaceURL, reactorRoots: roots)
    }

    func options(workspaceURL: URL, buildSystemID: String) throws -> [String: ToolingJSONValue] {
        let shared = try projectDocument(workspaceURL).document.systems[buildSystemID]?.options ?? [:]
        return shared.merging(try read([String: ToolingJSONValue].self, key: Self.key(workspaceURL: workspaceURL, buildSystemID: buildSystemID)) ?? [:]) { _, local in local }
    }

    func setOptions(_ options: [String: ToolingJSONValue], workspaceURL: URL, buildSystemID: String) throws {
        let key = Self.key(workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        let shared = try projectDocument(workspaceURL).document.systems[buildSystemID]?.options ?? [:]
        let local = options.filter { shared[$0.key] != $0.value }
        try write(local.isEmpty ? nil : local, key: key)
    }

    func instanceOptions(workspaceURL: URL, buildSystemID: String) throws -> [String: [String: ToolingJSONValue]] {
        let key = Self.key(workspaceURL: workspaceURL, buildSystemID: buildSystemID) + ".Instances"
        var shared = try projectDocument(workspaceURL).document.systems[buildSystemID]?.instances ?? [:]
        for (root, values) in try read([String: [String: ToolingJSONValue]].self, key: key) ?? [:] {
            shared[root, default: [:]].merge(values) { _, local in local }
        }
        return shared
    }

    func setInstanceOptions(_ options: [String: [String: ToolingJSONValue]], workspaceURL: URL, buildSystemID: String) throws {
        let key = Self.key(workspaceURL: workspaceURL, buildSystemID: buildSystemID) + ".Instances"
        let shared = try projectDocument(workspaceURL).document.systems[buildSystemID] ?? BuildProjectOptionsDocument.System()
        let defaults = try instanceDefaults(workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        let nonempty = options.mapValues { $0 }.reduce(into: [String: [String: ToolingJSONValue]]()) { result, item in
            let inherited = defaults.merging(shared.instances[item.key] ?? [:]) { _, root in root }
            let values = item.value.filter { inherited[$0.key] != $0.value }
            if !values.isEmpty { result[item.key] = values }
        }
        try write(nonempty.isEmpty ? nil : nonempty, key: key)
    }

    func instanceDefaults(workspaceURL: URL, buildSystemID: String) throws -> [String: ToolingJSONValue] {
        let shared = try projectDocument(workspaceURL).document.systems[buildSystemID]?.instanceDefaults ?? [:]
        let key = Self.key(workspaceURL: workspaceURL, buildSystemID: buildSystemID) + ".InstanceDefaults"
        return shared.merging(try read([String: ToolingJSONValue].self, key: key) ?? [:]) { _, local in local }
    }

    /// Machine-wide choices for this workspace remain local, including defaults
    /// transferred from old runtime preferences before any reactor was selected.
    func setInstanceDefaults(_ values: [String: ToolingJSONValue], workspaceURL: URL, buildSystemID: String) throws {
        let shared = try projectDocument(workspaceURL).document.systems[buildSystemID]?.instanceDefaults ?? [:]
        let local = values.filter { shared[$0.key] != $0.value }
        try write(local.isEmpty ? nil : local,
                  key: Self.key(workspaceURL: workspaceURL, buildSystemID: buildSystemID) + ".InstanceDefaults")
    }

    func savedChoices(workspaceURL: URL, buildSystemID: String) throws -> [String: [String]] {
        try projectDocument(workspaceURL).document.systems[buildSystemID]?.savedChoices ?? [:]
    }

    func projectDocument(_ workspace: URL) throws -> (document: BuildProjectOptionsDocument, bytes: Data?) {
        guard let storage else { return (BuildProjectOptionsDocument(), nil) }
        let url = try projectURL(workspace)
        guard storage.fileExists(at: url) else { return (BuildProjectOptionsDocument(), nil) }
        guard let metadata = storage.metadata(for: url), metadata.isRegularFile,
              let size = metadata.byteCount, size <= 2 * 1024 * 1024 else { throw BuildOptionsStorageError.invalid }
        let data = try storage.readData(from: url, options: [])
        guard data.count <= 2 * 1024 * 1024 else { throw BuildOptionsStorageError.invalid }
        let json = try JSONSerialization.jsonObject(with: data)
        try BuildProjectOptionsDocument.validate(json)
        return (try JSONDecoder().decode(BuildProjectOptionsDocument.self, from: data), data)
    }

    func saveProjectDocument(_ document: BuildProjectOptionsDocument, workspace: URL, expecting expected: Data?) throws {
        guard let storage else { throw BuildOptionsStorageError.write }
        let url = try projectURL(workspace)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        try BuildProjectOptionsDocument.validate(JSONSerialization.jsonObject(with: data))
        guard data.count <= 2 * 1024 * 1024 else { throw BuildOptionsStorageError.invalid }
        try storage.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard try storage.replaceDataPreservingMetadata(data, at: url, expecting: expected) else { throw BuildOptionsStorageError.conflict }
        guard try projectDocument(workspace).document == document else { throw BuildOptionsStorageError.write }
    }

    private func projectURL(_ workspace: URL) throws -> URL {
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL
        let url = workspace.appendingPathComponent(".lithe/build/options.json")
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/"), !immutableRoots.contains(where: {
            let path = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return resolved.path == path || resolved.path.hasPrefix(path + "/")
        }) else { throw BuildOptionsStorageError.invalid }
        return url
    }

    func emptyMultiSelectOptions(workspaceURL: URL, buildSystemID: String) throws -> [String: Set<String>] {
        let key = Self.key(workspaceURL: workspaceURL, buildSystemID: buildSystemID) + ".EmptyMultiSelect"
        let options = try read([String: [String]].self, key: key) ?? [:]
        return options.mapValues { Set($0) }
    }

    func setEmptyMultiSelectOptions(_ options: [String: Set<String>], workspaceURL: URL, buildSystemID: String) throws {
        let key = Self.key(workspaceURL: workspaceURL, buildSystemID: buildSystemID) + ".EmptyMultiSelect"
        let nonempty = options.filter { !$0.value.isEmpty }
        try write(nonempty.isEmpty ? nil : nonempty.mapValues { $0.sorted() }, key: key)
    }

    private func read<Value: Decodable>(_ type: Value.Type, key: String) throws -> Value? {
        guard let data = store.data(forKey: key) else {
            guard store.object(forKey: key) == nil else { throw BuildOptionsStorageError.invalid }
            return nil
        }
        guard data.count <= 2 * 1024 * 1024 else { throw BuildOptionsStorageError.invalid }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw BuildOptionsStorageError.invalid }
    }

    private func write<Value: Encodable>(_ value: Value?, key: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try value.map(encoder.encode)
        if let data, data.count > 2 * 1024 * 1024 { throw BuildOptionsStorageError.invalid }
        store.set(data, forKey: key)
        guard store.data(forKey: key) == data else { throw BuildOptionsStorageError.write }
    }

    private static func key(workspaceURL: URL, buildSystemID: String) -> String {
        keyPrefix + buildSystemID + "." + MacPluginStateDirectories.workspaceDigest(workspaceURL)
    }
}

/// Team-owned Build preferences, independent of any tool's native configuration.
/// Local edits are sparse overrides in the existing platform preferences.
struct BuildProjectOptionsDocument: Codable, Equatable {
    struct System: Codable, Equatable {
        var options: [String: ToolingJSONValue] = [:]
        var instanceDefaults: [String: ToolingJSONValue] = [:]
        var instances: [String: [String: ToolingJSONValue]] = [:]
        /// User-defined choices may remain useful while they are not selected.
        var savedChoices: [String: [String]] = [:]
        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            options = try values.decodeIfPresent([String: ToolingJSONValue].self, forKey: .options) ?? [:]
            instanceDefaults = try values.decodeIfPresent([String: ToolingJSONValue].self, forKey: .instanceDefaults) ?? [:]
            instances = try values.decodeIfPresent([String: [String: ToolingJSONValue]].self, forKey: .instances) ?? [:]
            savedChoices = try values.decodeIfPresent([String: [String]].self, forKey: .savedChoices) ?? [:]
        }
        private enum CodingKeys: String, CodingKey { case options, instanceDefaults, instances, savedChoices }
    }
    var version = 1
    var systems: [String: System] = [:]

    static func validate(_ value: Any) throws {
        struct Payload: Encodable { let document: ToolingJSONValue }
        struct Reply: Decodable { let status: String }
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
            let document = try JSONDecoder().decode(ToolingJSONValue.self, from: data)
            let result: Reply = try RustCoreBridge().executeResult(
                command: "build.projectOptions", payload: Payload(document: document)).get()
            guard result.status == "ok" else { throw BuildOptionsStorageError.invalid }
        } catch {
            throw BuildOptionsStorageError.invalid
        }
    }

    static func validRoot(_ root: String) -> Bool {
        root == "." || !root.isEmpty && root.count <= 1024 && !root.contains("\\") && !root.contains(":")
            && !root.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && root.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

enum BuildOptionsStorageError: LocalizedError {
    case invalid, write, conflict
    var errorDescription: String? {
        switch self {
        case .invalid: L10n.string("The saved build options are invalid. The original configuration has been kept.")
        case .write: L10n.string("The build options could not be saved or verified. Reload before retrying.")
        case .conflict: L10n.string("Build options changed on disk. Reload before saving; your changes have been kept.")
        }
    }
}
