import Foundation

/// Stores temporary local changes outside Git's object database.
///
/// Each entry is a versioned JSON document under Application Support, scoped by
/// a stable hash of the repository root. Patch text stays portable and the
/// metadata is explicit so a future format migration can reject or upgrade old
/// entries instead of guessing.
struct ShelveService: Sendable {
    private static let formatVersion = 1
    private let storage: any FileStorage

    init(storage: any FileStorage) {
        self.storage = storage
    }

    func entries(for repositoryRoot: URL) async -> [GitShelfEntry] {
        let storage = self.storage
        let root = repositoryRoot.standardizedFileURL.path
        return await Task.detached(priority: .utility) {
            Self.readEntries(storage: storage, repositoryRootPath: root)
        }.value
    }

    func save(
        message: String,
        repositoryRoot: URL,
        paths: [String],
        stagedPatch: String,
        workingPatch: String
    ) async -> GitShelfEntry? {
        let storage = self.storage
        let root = repositoryRoot.standardizedFileURL.path
        let entry = GitShelfEntry(
            id: UUID(),
            message: message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "WIP"
                : message.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date(),
            paths: paths,
            stagedPatch: stagedPatch,
            workingPatch: workingPatch
        )
        return await Task.detached(priority: .userInitiated) {
            Self.write(entry, storage: storage, repositoryRootPath: root)
                ? entry
                : nil
        }.value
    }

    func delete(_ entry: GitShelfEntry, repositoryRoot: URL) async -> Bool {
        let storage = self.storage
        let root = repositoryRoot.standardizedFileURL.path
        return await Task.detached(priority: .utility) {
            let url = Self.fileURL(
                for: entry.id,
                storage: storage,
                repositoryRootPath: root
            )
            guard storage.fileExists(at: url) else { return true }
            do {
                try storage.removeItem(at: url)
                return true
            } catch {
                return false
            }
        }.value
    }

    private struct DiskEntry: Codable {
        let formatVersion: Int
        let id: UUID
        let message: String
        let createdAt: Date
        let paths: [String]
        let stagedPatch: String
        let workingPatch: String

        init(from entry: GitShelfEntry) {
            formatVersion = Self.formatVersion
            id = entry.id
            message = entry.message
            createdAt = entry.createdAt
            paths = entry.paths
            stagedPatch = entry.stagedPatch
            workingPatch = entry.workingPatch
        }

        var model: GitShelfEntry? {
            guard formatVersion == Self.formatVersion else { return nil }
            return GitShelfEntry(
                id: id,
                message: message,
                createdAt: createdAt,
                paths: paths,
                stagedPatch: stagedPatch,
                workingPatch: workingPatch
            )
        }

        private static let formatVersion = 1
    }

    private static func readEntries(
        storage: any FileStorage,
        repositoryRootPath: String
    ) -> [GitShelfEntry] {
        let directory = directoryURL(storage: storage, repositoryRootPath: repositoryRootPath)
        return storage.listDirectory(at: directory)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? storage.readData(from: url, options: []) else { return nil }
                return (try? JSONDecoder().decode(DiskEntry.self, from: data))?.model
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private static func write(
        _ entry: GitShelfEntry,
        storage: any FileStorage,
        repositoryRootPath: String
    ) -> Bool {
        let directory = directoryURL(storage: storage, repositoryRootPath: repositoryRootPath)
        let url = fileURL(for: entry.id, storage: storage, repositoryRootPath: repositoryRootPath)
        do {
            try storage.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(DiskEntry(from: entry))
            try storage.writeData(data, to: url, options: [])
            return true
        } catch {
            return false
        }
    }

    private static func directoryURL(
        storage: any FileStorage,
        repositoryRootPath: String
    ) -> URL {
        storage.applicationSupportDirectory()
            .appendingPathComponent("Lithe", isDirectory: true)
            .appendingPathComponent("Shelves", isDirectory: true)
            .appendingPathComponent(stableIdentifier(for: repositoryRootPath), isDirectory: true)
    }

    private static func fileURL(
        for id: UUID,
        storage: any FileStorage,
        repositoryRootPath: String
    ) -> URL {
        directoryURL(storage: storage, repositoryRootPath: repositoryRootPath)
            .appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private static func stableIdentifier(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
