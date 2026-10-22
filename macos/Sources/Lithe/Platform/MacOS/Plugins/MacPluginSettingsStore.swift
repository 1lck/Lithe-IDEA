import Foundation
import LitheCoreContracts

// Note: 插件设置注册面与生效方式见 .agents/notes/implemented/architecture/2026-10-21-plugin-settings-surfaces.md

/// Keeps the user's values for declarative plugin settings: global values in
/// the app's preferences, one record per plugin; project values in the
/// project's `.lithe/plugin-settings.json`, keyed by plugin, so a team shares
/// them through version control. Each record holds only what the user
/// changed; Rust Core supplies the declared default for everything else.
final class MacPluginSettingsStore: PluginSettingsStoring, @unchecked Sendable {
    private let store: any KeyValueStore
    private let lock = NSLock()
    /// The last project document read or written per file, with the file's
    /// modification date and size when it was. Settings pages resolve every
    /// plugin's snapshot on each render; an unchanged file is not read again.
    private var projectDocuments: [String: (stamp: ProjectFileStamp, document: ProjectDocument)] = [:]

    private typealias ProjectDocument = [String: [String: ToolingJSONValue]]

    private struct ProjectFileStamp: Equatable {
        let modified: Date?
        let size: Int?
    }

    init(store: any KeyValueStore) {
        self.store = store
    }

    func values(forPlugin pluginID: String) -> [String: ToolingJSONValue] {
        lock.lock(); defer { lock.unlock() }
        return recordLocked(pluginID)
    }

    func setValue(_ value: ToolingJSONValue?, forSetting settingID: String, plugin pluginID: String) {
        lock.lock(); defer { lock.unlock() }
        var record = recordLocked(pluginID)
        record[settingID] = value
        // An empty record is removed so an untouched plugin leaves nothing behind.
        let data = record.isEmpty ? nil : try? JSONEncoder().encode(record)
        store.set(data, forKey: Self.key(pluginID))
    }

    /// A record that cannot be read is treated as empty, so a damaged
    /// preference never blocks the language server from starting with its
    /// defaults; the next change replaces it.
    private func recordLocked(_ pluginID: String) -> [String: ToolingJSONValue] {
        guard let data = store.data(forKey: Self.key(pluginID)),
              let record = try? JSONDecoder().decode([String: ToolingJSONValue].self, from: data)
        else { return [:] }
        return record
    }

    func projectValues(forPlugin pluginID: String, projectRoot: URL) -> [String: ToolingJSONValue] {
        lock.lock(); defer { lock.unlock() }
        // A damaged project file reads as empty, as with the global record,
        // so a launch still starts with the other layers.
        return ((try? projectDocumentLocked(at: projectRoot)) ?? [:])[pluginID] ?? [:]
    }

    func setProjectValue(
        _ value: ToolingJSONValue?,
        forSetting settingID: String,
        plugin pluginID: String,
        projectRoot: URL
    ) throws {
        lock.lock(); defer { lock.unlock() }
        // Unlike the global record, the project file is shared through
        // version control: a file this host cannot read is refused rather
        // than replaced, so one change never drops the team's other values.
        var document = try projectDocumentLocked(at: projectRoot)
        var record = document[pluginID] ?? [:]
        record[settingID] = value
        document[pluginID] = record.isEmpty ? nil : record
        let url = try Self.projectFile(at: projectRoot)
        if document.isEmpty {
            // Nothing overridden: leave no file behind for the team to review.
            if Self.itemType(at: url) != nil {
                try FileManager.default.removeItem(at: url)
            }
            projectDocuments[url.path] = nil
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
        if let stamp = Self.stamp(at: url) {
            projectDocuments[url.path] = (stamp, document)
        }
    }

    /// The project file. A symbolic link at `.lithe` or at the file itself
    /// is refused, dangling or not, so a checked-out link cannot redirect a
    /// read or a write outside the project.
    private static func projectFile(at projectRoot: URL) throws -> URL {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent(".lithe", isDirectory: true)
        let file = directory.appendingPathComponent("plugin-settings.json")
        let directoryType = itemType(at: directory)
        guard directoryType == nil || directoryType == .typeDirectory,
              itemType(at: file).map({ $0 == .typeRegular }) ?? true
        else { throw CocoaError(.fileWriteNoPermission) }
        return file
    }

    /// The item's own type without following a symbolic link; nil when
    /// nothing is there.
    private static func itemType(at url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    /// The whole project document; empty when there is no file. Throws when
    /// the file exists but is not a document this host can read.
    private func projectDocumentLocked(at projectRoot: URL) throws -> ProjectDocument {
        let url = try Self.projectFile(at: projectRoot)
        guard let stamp = Self.stamp(at: url) else {
            projectDocuments[url.path] = nil
            return [:]
        }
        if let cached = projectDocuments[url.path], cached.stamp == stamp { return cached.document }
        let data = try Data(contentsOf: url)
        let document: ProjectDocument
        do {
            document = try JSONDecoder().decode(ProjectDocument.self, from: data)
        } catch {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        projectDocuments[url.path] = (stamp, document)
        return document
    }

    /// Modification date and size of the file itself; nil when there is none.
    private static func stamp(at url: URL) -> ProjectFileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return ProjectFileStamp(
            modified: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.intValue
        )
    }

    private static func key(_ pluginID: String) -> String {
        "lithe.plugins.\(pluginID).settings"
    }
}
