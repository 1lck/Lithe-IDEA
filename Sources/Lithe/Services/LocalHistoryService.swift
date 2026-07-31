import Foundation

actor LocalHistoryService {
    static let maximumFileSize = 2 * 1_024 * 1_024
    static let retentionDays = 30
    static let maximumEntriesPerFile = 100

    private let workspaceURL: URL
    private let storageURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL.standardizedFileURL
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        storageURL = applicationSupport
            .appendingPathComponent("Lithe", isDirectory: true)
            .appendingPathComponent("LocalHistory", isDirectory: true)
            .appendingPathComponent(Self.stableIdentifier(for: workspaceURL.path), isDirectory: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func seed(files: [URL]) async {
        for fileURL in files where !Task.isCancelled {
            _ = try? recordFile(at: fileURL, reason: .projectBaseline)
        }
        try? pruneExpiredEntries()
    }

    @discardableResult
    func recordFile(at fileURL: URL, reason: LocalHistoryReason) throws -> LocalHistoryEntry? {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize <= Self.maximumFileSize,
              WorkspaceScanner.isReadableTextFile(fileURL) else { return nil }
        return try record(content: Data(contentsOf: fileURL), for: fileURL, reason: reason)
    }

    @discardableResult
    func record(text: String, for fileURL: URL, reason: LocalHistoryReason) throws -> LocalHistoryEntry? {
        guard let data = text.data(using: .utf8), data.count <= Self.maximumFileSize else { return nil }
        return try record(content: data, for: fileURL, reason: reason)
    }

    func entries(for fileURL: URL) throws -> [LocalHistoryEntry] {
        let directory = historyDirectory(for: fileURL)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(LocalHistoryEntry.self, from: data)
        }
        .filter { $0.relativePath == relativePath(for: fileURL) }
        .sorted { $0.timestamp > $1.timestamp }
    }

    func allEntries() throws -> [LocalHistoryEntry] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return [] }
        let enumerator = FileManager.default.enumerator(
            at: storageURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var entries: [LocalHistoryEntry] = []
        while let metadataURL = enumerator?.nextObject() as? URL {
            guard metadataURL.pathExtension == "json",
                  let data = try? Data(contentsOf: metadataURL),
                  let entry = try? decoder.decode(LocalHistoryEntry.self, from: data),
                  FileManager.default.fileExists(atPath: entry.contentURL.path) else { continue }
            entries.append(entry)
        }
        return entries.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    func content(for entry: LocalHistoryEntry) throws -> String {
        try String(contentsOf: entry.contentURL, encoding: .utf8)
    }

    func relocateHistory(from sourceURL: URL, to destinationURL: URL) throws {
        let sourceDirectory = historyDirectory(for: sourceURL)
        guard FileManager.default.fileExists(atPath: sourceDirectory.path) else { return }
        let destinationDirectory = historyDirectory(for: destinationURL)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        for entry in try entries(for: sourceURL) {
            let destinationContentURL = destinationDirectory.appendingPathComponent(entry.contentURL.lastPathComponent)
            let destinationMetadataURL = destinationDirectory
                .appendingPathComponent(entry.id.uuidString)
                .appendingPathExtension("json")
            if FileManager.default.fileExists(atPath: destinationContentURL.path) {
                try? FileManager.default.removeItem(at: destinationContentURL)
            }
            try FileManager.default.moveItem(at: entry.contentURL, to: destinationContentURL)
            let relocatedEntry = LocalHistoryEntry(
                id: entry.id,
                timestamp: entry.timestamp,
                relativePath: relativePath(for: destinationURL),
                reason: entry.reason,
                contentURL: destinationContentURL,
                byteCount: entry.byteCount
            )
            try encoder.encode(relocatedEntry).write(to: destinationMetadataURL, options: .atomic)
            try? FileManager.default.removeItem(
                at: sourceDirectory.appendingPathComponent(entry.id.uuidString).appendingPathExtension("json")
            )
        }
        try? FileManager.default.removeItem(at: sourceDirectory)
    }

    private func record(
        content: Data,
        for fileURL: URL,
        reason: LocalHistoryReason
    ) throws -> LocalHistoryEntry? {
        guard content.count <= Self.maximumFileSize,
              isInsideWorkspace(fileURL) else { return nil }

        let directory = historyDirectory(for: fileURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let latest = try entries(for: fileURL).first,
           let latestData = try? Data(contentsOf: latest.contentURL),
           latestData == content {
            return nil
        }

        let id = UUID()
        let contentURL = directory.appendingPathComponent("\(id.uuidString).snapshot")
        let metadataURL = directory.appendingPathComponent("\(id.uuidString).json")
        let entry = LocalHistoryEntry(
            id: id,
            timestamp: Date(),
            relativePath: relativePath(for: fileURL),
            reason: reason,
            contentURL: contentURL,
            byteCount: content.count
        )
        try content.write(to: contentURL, options: .atomic)
        try encoder.encode(entry).write(to: metadataURL, options: .atomic)
        try trimEntries(for: fileURL)
        return entry
    }

    private func trimEntries(for fileURL: URL) throws {
        let excess = try entries(for: fileURL).dropFirst(Self.maximumEntriesPerFile)
        for entry in excess {
            try? FileManager.default.removeItem(at: entry.contentURL)
            try? FileManager.default.removeItem(
                at: entry.contentURL.deletingPathExtension().appendingPathExtension("json")
            )
        }
    }

    private func pruneExpiredEntries() throws {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date()) ?? .distantPast
        let enumerator = FileManager.default.enumerator(
            at: storageURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        while let metadataURL = enumerator?.nextObject() as? URL {
            guard metadataURL.pathExtension == "json",
                  let data = try? Data(contentsOf: metadataURL),
                  let entry = try? decoder.decode(LocalHistoryEntry.self, from: data),
                  entry.timestamp < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry.contentURL)
            try? FileManager.default.removeItem(at: metadataURL)
        }
    }

    private func historyDirectory(for fileURL: URL) -> URL {
        storageURL.appendingPathComponent(Self.stableIdentifier(for: relativePath(for: fileURL)), isDirectory: true)
    }

    private func relativePath(for fileURL: URL) -> String {
        let root = workspaceURL.path
        let path = fileURL.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return fileURL.lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }

    private func isInsideWorkspace(_ fileURL: URL) -> Bool {
        let root = workspaceURL.path
        let path = fileURL.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
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
