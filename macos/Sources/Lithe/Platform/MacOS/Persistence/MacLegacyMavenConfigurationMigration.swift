import CoreFoundation
import CryptoKit
import Foundation
import LitheCoreContracts

/// One-time data transfer at the Maven consumer cutover. These private formats
/// describe saved versions only; the adapter does not interpret Maven settings.
@MainActor
struct MacLegacyMavenConfigurationMigration {
    let storage: any FileStorage
    let preferences: any KeyValueStore
    let runStore: MacRunConfigurationStore
    let options: MacBuildOptionsStore
    let immutableRoots: [URL]

    nonisolated static func storageIdentity(workspacePath: String, reactorPath: String) -> String {
        workspacePath + "\0" + reactorPath
    }

    /// Call only after the old configuration readers and writers are detached.
    /// Every source is retained until all destinations have been read back.
    @discardableResult
    func migrate(workspace: URL, reactorRoots: [String]) throws -> Bool {
        let roots = Array(Set(reactorRoots)).sorted()
        guard roots.count <= 256, roots.allSatisfy(BuildProjectOptionsDocument.validRoot) else { throw BuildOptionsStorageError.invalid }
        let workspace = workspace.standardizedFileURL
        let portableURL = workspace.appendingPathComponent(".lithe/maven/config.json")
        let portable = try source(Portable.self, at: portableURL, within: workspace,
                                  fields: ["version", "selectedProfiles", "customProfiles", "skipTests"])
        let localDirectory = storage.applicationSupportDirectory().appendingPathComponent("Lithe/Maven")
        let local: [(root: String, source: Source<Local>)] = try roots.compactMap { root in
            let identity = Self.storageIdentity(workspacePath: workspace.path, reactorPath: root)
            let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            let url = localDirectory.appendingPathComponent(digest + ".json")
            return try source(Local.self, at: url, within: localDirectory,
                              fields: ["version", "settingsPath", "localRepositoryPath", "mavenExecutablePath", "javaHomePath"])
                .map { (root, $0) }
        }
        let receiptKey = "BuildSystems.Migrations.Maven." + MacPluginStateDirectories.workspaceDigest(workspace)
        let receiptBytes = preferences.data(forKey: receiptKey)
        if receiptBytes == nil, preferences.object(forKey: receiptKey) != nil { throw BuildOptionsStorageError.invalid }
        var receipt = try readReceipt(receiptBytes)
        receipt = receipt.filter { storage.fileExists(at: URL(fileURLWithPath: $0.key)) }
        guard portable != nil || !local.isEmpty else {
            try writeReceipt(receipt, key: receiptKey, expecting: receiptBytes)
            return try migrateRuntimePreferences(workspace: workspace, roots: roots)
        }
        let original = try options.projectDocument(workspace)
        var document = original.document
        var shared = document.systems["maven"] ?? BuildProjectOptionsDocument.System()
        if let portable {
            try portable.value.validate()
            if shared.instanceDefaults["profiles"] == nil {
                shared.instanceDefaults["profiles"] = .array(portable.value.selectedProfiles.map(ToolingJSONValue.string))
            }
            if shared.instanceDefaults["skipTests"] == nil { shared.instanceDefaults["skipTests"] = .bool(portable.value.skipTests) }
            shared.savedChoices["profiles"] = Array(Set((shared.savedChoices["profiles"] ?? []) + portable.value.customProfiles)).sorted()
        }
        document.systems["maven"] = shared
        let existingDefaults = try options.instanceDefaults(workspaceURL: workspace, buildSystemID: "maven")
        let existingWorkspaceOptions = try options.options(workspaceURL: workspace, buildSystemID: "maven")
        let previousOptions = try options.instanceOptions(workspaceURL: workspace, buildSystemID: "maven")
        var instanceOptions = previousOptions
        let runURL = workspace.appendingPathComponent(".lithe/run/local.json")
        let needsTools = local.contains { $0.source.value.mavenExecutablePath != nil || $0.source.value.javaHomePath != nil }
        let runBytes = needsTools ? try readOptional(runURL, within: workspace) : nil
        let inspection = needsTools ? runStore.inspect(at: workspace, checkFingerprint: false, javaEntrypoints: nil) : nil
        if let inspection, case .invalid = inspection.status { throw BuildOptionsStorageError.invalid }
        if needsTools, try readOptional(runURL, within: workspace) != runBytes { throw BuildOptionsStorageError.conflict }
        let originalToolchain = inspection?.projectToolchain ?? ProjectToolchainSelection()
        var toolchain = originalToolchain
        for (root, source) in local {
            try source.value.validate()
            var values = instanceOptions[root] ?? [:]
            if values["settingsFile"] == nil, existingDefaults["settingsFile"] == nil, existingWorkspaceOptions["settingsFile"] == nil, let value = source.value.settingsPath, shared.instanceDefaults["settingsFile"] != .string(value) { values["settingsFile"] = .string(value) }
            if values["localRepository"] == nil, existingDefaults["localRepository"] == nil, existingWorkspaceOptions["localRepository"] == nil, let value = source.value.localRepositoryPath, shared.instanceDefaults["localRepository"] != .string(value) { values["localRepository"] = .string(value) }
            if !values.isEmpty { instanceOptions[root] = values }
            // Reactor-local paths have higher priority than project defaults.
            // An existing root entry, even explicitly automatic, wins intact.
            if root == "." {
                if inspection?.projectToolchain == nil {
                    toolchain.mavenExecutablePath = source.value.mavenExecutablePath ?? ""
                    toolchain.mavenJavaHomePath = source.value.javaHomePath ?? ""
                }
            } else if toolchain.pathOverrides[root] == nil,
                      source.value.mavenExecutablePath != nil || source.value.javaHomePath != nil {
                toolchain.pathOverrides[root] = .init(mavenExecutablePath: source.value.mavenExecutablePath ?? "",
                                                     mavenJavaHomePath: source.value.javaHomePath ?? "")
            }
        }
        let sources = (portable.map { [($0.url, $0.bytes)] } ?? []) + local.map { ($0.source.url, $0.source.bytes) }
        for (url, bytes) in sources {
            let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            if let earlier = receipt[url.path], earlier != fingerprint { throw BuildOptionsStorageError.conflict }
            receipt[url.path] = fingerprint
        }
        try verifySources(sources)
        try writeReceipt(receipt, key: receiptKey, expecting: receiptBytes)
        let pendingReceipt = preferences.data(forKey: receiptKey)
        // Failures may leave verified destination values. A retry preserves
        // those values and completes remaining transfers; it never clears them.
        if document != original.document { try options.saveProjectDocument(document, workspace: workspace, expecting: original.bytes) }
        guard try options.instanceOptions(workspaceURL: workspace, buildSystemID: "maven") == previousOptions else {
            throw BuildOptionsStorageError.conflict
        }
        if instanceOptions != previousOptions {
            try options.setInstanceOptions(instanceOptions, workspaceURL: workspace, buildSystemID: "maven")
        }
        if toolchain != originalToolchain {
            try runStore.saveProjectToolchain(toolchain, at: workspace, expecting: runBytes)
        }
        guard try options.projectDocument(workspace).document == document,
              try options.instanceOptions(workspaceURL: workspace, buildSystemID: "maven") == instanceOptions else {
            throw BuildOptionsStorageError.write
        }
        if needsTools {
            let saved = runStore.inspect(at: workspace, checkFingerprint: false, javaEntrypoints: nil)
            if case .invalid = saved.status { throw BuildOptionsStorageError.write }
            guard (saved.projectToolchain ?? ProjectToolchainSelection()) == toolchain else { throw BuildOptionsStorageError.write }
        }
        try verifySources(sources)
        guard preferences.data(forKey: receiptKey) == pendingReceipt else { throw BuildOptionsStorageError.conflict }
        for (url, bytes) in sources {
            guard try storage.removeData(at: url, expecting: bytes) else { throw BuildOptionsStorageError.conflict }
        }
        for (url, _) in sources { receipt[url.path] = nil }
        try writeReceipt(receipt, key: receiptKey, expecting: pendingReceipt)
        _ = try migrateRuntimePreferences(workspace: workspace, roots: roots)
        return true
    }

    /// This is a separate saved source from the reactor files. Only its two
    /// retired Maven fields are removed after the private default layer verifies.
    private func migrateRuntimePreferences(workspace: URL, roots: [String]) throws -> Bool {
        guard !roots.isEmpty else { return false }
        let key = MacProjectRuntimeSettingsStore.preferencesKey(workspace)
        guard let bytes = preferences.data(forKey: key) else {
            guard preferences.object(forKey: key) == nil else { throw BuildOptionsStorageError.invalid }
            return false
        }
        guard bytes.count <= 2 * 1024 * 1024,
              var document = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw BuildOptionsStorageError.invalid
        }
        let fields = ["mavenSettingsPath": "settingsFile", "mavenLocalRepositoryPath": "localRepository"]
        let receiptKey = "BuildSystems.Migrations.Maven." + MacPluginStateDirectories.workspaceDigest(workspace) + ".Runtime"
        guard fields.keys.contains(where: { document[$0] != nil }) else {
            // A verified cleanup can survive a failure removing its receipt.
            // There is no remaining old Maven field to migrate or overwrite.
            if preferences.object(forKey: receiptKey) != nil { preferences.set(nil, forKey: receiptKey) }
            return false
        }
        var incoming: [String: ToolingJSONValue] = [:]
        for (field, option) in fields {
            guard let raw = document[field] else { continue }
            guard let value = raw as? String, value.count <= 32768, !value.contains("\0") else {
                throw BuildOptionsStorageError.invalid
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { incoming[option] = .string(trimmed) }
        }
        let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        if let previous = preferences.object(forKey: receiptKey) {
            guard previous as? String == fingerprint else { throw BuildOptionsStorageError.conflict }
        }
        var defaults = try options.instanceDefaults(workspaceURL: workspace, buildSystemID: "maven")
        for (id, value) in incoming where defaults[id] == nil { defaults[id] = value }
        guard preferences.data(forKey: key) == bytes else { throw BuildOptionsStorageError.conflict }
        preferences.set(fingerprint, forKey: receiptKey)
        guard preferences.string(forKey: receiptKey) == fingerprint else { throw BuildOptionsStorageError.write }
        try options.setInstanceDefaults(defaults, workspaceURL: workspace, buildSystemID: "maven")
        guard try options.instanceDefaults(workspaceURL: workspace, buildSystemID: "maven") == defaults else {
            throw BuildOptionsStorageError.write
        }
        guard preferences.data(forKey: key) == bytes,
              preferences.string(forKey: receiptKey) == fingerprint else { throw BuildOptionsStorageError.conflict }
        for field in fields.keys { document.removeValue(forKey: field) }
        let cleaned = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        guard cleaned.count <= 2 * 1024 * 1024 else { throw BuildOptionsStorageError.invalid }
        preferences.set(cleaned, forKey: key)
        guard preferences.data(forKey: key) == cleaned else { throw BuildOptionsStorageError.write }
        preferences.set(nil, forKey: receiptKey)
        guard preferences.object(forKey: receiptKey) == nil else { throw BuildOptionsStorageError.write }
        return true
    }

    private func readReceipt(_ bytes: Data?) throws -> [String: String] {
        guard let bytes else { return [:] }
        guard bytes.count <= 2 * 1024 * 1024,
              let value = try JSONSerialization.jsonObject(with: bytes) as? [String: String], value.count <= 512,
              value.allSatisfy({ $0.key.hasPrefix("/") && $0.key.count <= 32768 && !$0.key.contains("\0") && $0.value.count == 64 && $0.value.allSatisfy(\.isHexDigit) }) else {
            throw BuildOptionsStorageError.invalid
        }
        return value
    }

    private func writeReceipt(_ value: [String: String], key: String, expecting expected: Data?) throws {
        guard preferences.data(forKey: key) == expected else { throw BuildOptionsStorageError.conflict }
        let data = value.isEmpty ? nil : try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        if data == expected { return }
        preferences.set(data, forKey: key)
        guard preferences.data(forKey: key) == data else { throw BuildOptionsStorageError.write }
    }

    private struct Source<Value> {
        let url: URL
        let bytes: Data
        let value: Value
    }

    private func source<Value: Decodable>(_ type: Value.Type, at url: URL, within root: URL,
                                          fields: Set<String>) throws -> Source<Value>? {
        guard let bytes = try readOptional(url, within: root) else { return nil }
        guard let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(json.keys).isSubset(of: fields), let version = json["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1 else { throw BuildOptionsStorageError.invalid }
        return Source(url: url, bytes: bytes, value: try JSONDecoder().decode(type, from: bytes))
    }

    private func readOptional(_ url: URL, within root: URL) throws -> Data? {
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        let root = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard target.hasPrefix(root + "/"), !immutableRoots.contains(where: {
            let path = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return target == path || target.hasPrefix(path + "/")
        }) else { throw BuildOptionsStorageError.invalid }
        guard storage.fileExists(at: url) else { return nil }
        guard let metadata = storage.metadata(for: url), metadata.isRegularFile,
              let count = metadata.byteCount, count <= 2 * 1024 * 1024 else { throw BuildOptionsStorageError.invalid }
        let bytes = try storage.readData(from: url, options: [])
        guard bytes.count <= 2 * 1024 * 1024 else { throw BuildOptionsStorageError.invalid }
        return bytes
    }

    private func verifySources(_ sources: [(URL, Data)]) throws {
        for (url, bytes) in sources {
            guard let metadata = storage.metadata(for: url), metadata.isRegularFile,
                  metadata.byteCount == bytes.count,
                  try storage.readData(from: url, options: []) == bytes else { throw BuildOptionsStorageError.conflict }
        }
    }

    private struct Portable: Decodable {
        let version: Int
        let selectedProfiles: [String]
        let customProfiles: [String]
        let skipTests: Bool
        func validate() throws {
            guard selectedProfiles.count <= 256, customProfiles.count <= 256,
                  (selectedProfiles + customProfiles).allSatisfy({ !$0.isEmpty && $0.count <= 1024 && !$0.contains("\0") }) else {
                throw BuildOptionsStorageError.invalid
            }
        }
    }

    private struct Local: Decodable {
        let version: Int
        let settingsPath: String?
        let localRepositoryPath: String?
        let mavenExecutablePath: String?
        let javaHomePath: String?
        func validate() throws {
            guard [settingsPath, localRepositoryPath, mavenExecutablePath, javaHomePath].compactMap({ $0 })
                .allSatisfy({ $0.count <= 32768 && !$0.contains("\0") }) else { throw BuildOptionsStorageError.invalid }
        }
    }
}
