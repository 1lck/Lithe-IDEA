import Compression
import CryptoKit
import Foundation

final class MacDatabaseRecoveryStore: DatabaseRecoveryStoring, @unchecked Sendable {
    private static let executionLogLock = NSRecursiveLock()
    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    convenience init(fileStorage: any FileStorage) {
        self.init(
            rootURL: fileStorage.applicationSupportDirectory()
                .appendingPathComponent("Lithe/DatabaseRecovery", isDirectory: true)
        )
    }

    func createRecoveryPoint(profileID: UUID, reason: String, data: Data) throws -> DatabaseRecoveryPoint {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let id = UUID()
        let compressed = DatabaseBackupCompression.compress(data)
        let storedData = compressed ?? data
        let fileName = "\(id.uuidString).sql\(compressed == nil ? "" : ".lzfse")"
        try storedData.write(to: rootURL.appendingPathComponent(fileName), options: [.atomic])
        let point = DatabaseRecoveryPoint(id: id, profileID: profileID, reason: reason, createdAt: Date(), byteCount: storedData.count, fileName: fileName, originalByteCount: data.count, isCompressed: compressed != nil, sha256: Self.sha256(data: data))
        try persist(point)
        return point
    }

    func createRecoveryPoint(profileID: UUID, reason: String, fileURL: URL, expectedSHA256: String = "", progress: ((Double) -> Void)? = nil) throws -> DatabaseRecoveryPoint {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let checksum = try Self.sha256(fileURL: fileURL)
        if !expectedSHA256.isEmpty && checksum != expectedSHA256 {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The database backup checksum did not match."])
        }
        let id = UUID()
        let fileName = "\(id.uuidString).sql"
        try copyFile(fileURL, to: rootURL.appendingPathComponent(fileName), progress: progress)
        let point = DatabaseRecoveryPoint(id: id, profileID: profileID, reason: reason, createdAt: Date(), byteCount: byteCount, fileName: fileName, originalByteCount: byteCount, isCompressed: false, sha256: checksum)
        try persist(point)
        return point
    }

    private func persist(_ point: DatabaseRecoveryPoint) throws {
        var points = try loadRecoveryPoints().filter { $0.id != point.id }
        points.insert(point, at: 0)
        try encoder.encode(points).write(to: manifestURL, options: [.atomic])
    }

    func recoveryPoints(for profileID: UUID? = nil) -> [DatabaseRecoveryPoint] {
        let points = (try? decoder.decode([DatabaseRecoveryPoint].self, from: Data(contentsOf: manifestURL))) ?? []
        guard let profileID else { return points }
        return points.filter { $0.profileID == profileID }
    }

    func data(for point: DatabaseRecoveryPoint) throws -> Data {
        let stored = try Data(contentsOf: rootURL.appendingPathComponent(point.fileName))
        if point.isCompressed {
            guard let restored = DatabaseBackupCompression.decompress(stored, originalSize: point.originalByteCount) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try validated(restored, for: point)
        }
        return try validated(stored, for: point)
    }

    func fileURL(for point: DatabaseRecoveryPoint) throws -> URL {
        let url = rootURL.appendingPathComponent(point.fileName)
        guard fileManager.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
        if !point.sha256.isEmpty {
            let checksum = try Self.sha256(fileURL: url)
            if checksum != point.sha256 { throw CocoaError(.fileReadCorruptFile) }
        }
        return url
    }

    func delete(_ point: DatabaseRecoveryPoint) throws {
        let fileURL = rootURL.appendingPathComponent(point.fileName)
        if fileManager.fileExists(atPath: fileURL.path) { try fileManager.removeItem(at: fileURL) }
        let remaining = recoveryPoints().filter { $0.id != point.id }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try encoder.encode(remaining).write(to: manifestURL, options: [.atomic])
    }

    func appendAudit(_ entry: DatabaseAuditEntry, maximumEntries: Int = 500) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var entries = auditEntries().filter { $0.id != entry.id }
        entries.insert(entry, at: 0)
        try encoder.encode(Array(entries.prefix(maximumEntries))).write(to: auditURL, options: [.atomic])
    }

    func auditEntries(for profileID: UUID? = nil) -> [DatabaseAuditEntry] {
        let entries = (try? decoder.decode([DatabaseAuditEntry].self, from: Data(contentsOf: auditURL))) ?? []
        guard let profileID else { return entries }
        return entries.filter { $0.profileID == profileID }
    }

    func appendExecutionEvent(_ event: DatabaseExecutionEvent, maximumEntries: Int = 1_000) throws {
        Self.executionLogLock.lock()
        defer { Self.executionLogLock.unlock() }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var entries = executionEvents().filter { $0.id != event.id }
        entries.insert(event, at: 0)
        try encoder.encode(Array(entries.prefix(maximumEntries))).write(to: executionURL, options: [.atomic])
    }

    func executionEvents(for profileID: UUID? = nil) -> [DatabaseExecutionEvent] {
        Self.executionLogLock.lock()
        defer { Self.executionLogLock.unlock() }
        let entries = (try? decoder.decode([DatabaseExecutionEvent].self, from: Data(contentsOf: executionURL))) ?? []
        guard let profileID else { return entries }
        return entries.filter { $0.profileID == profileID }
    }

    func deleteExecutionEvents(for profileID: UUID) throws {
        Self.executionLogLock.lock()
        defer { Self.executionLogLock.unlock() }
        let remaining = executionEvents().filter { $0.profileID != profileID }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try encoder.encode(remaining).write(to: executionURL, options: [.atomic])
    }

    private func loadRecoveryPoints() throws -> [DatabaseRecoveryPoint] {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return [] }
        return try decoder.decode([DatabaseRecoveryPoint].self, from: Data(contentsOf: manifestURL))
    }

    private var manifestURL: URL { rootURL.appendingPathComponent("recovery-points.json") }
    private var auditURL: URL { rootURL.appendingPathComponent("audit.json") }
    private var executionURL: URL { rootURL.appendingPathComponent("execution-events.json") }

    private func validated(_ data: Data, for point: DatabaseRecoveryPoint) throws -> Data {
        if !point.sha256.isEmpty && Self.sha256(data: data) != point.sha256 {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    private func copyFile(_ sourceURL: URL, to destinationURL: URL, progress: ((Double) -> Void)?) throws {
        guard let input = InputStream(url: sourceURL), let output = OutputStream(url: destinationURL, append: false) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let total: Double
        if let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path), let size = attributes[.size] as? NSNumber {
            total = size.doubleValue
        } else {
            total = 0
        }
        input.open()
        output.open()
        defer { input.close(); output.close() }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var copied = 0.0
        while input.hasBytesAvailable {
            let count = input.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw input.streamError ?? CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            var written = 0
            while written < count {
                let amount = buffer.withUnsafeBufferPointer { pointer in
                    output.write(pointer.baseAddress!.advanced(by: written), maxLength: count - written)
                }
                if amount <= 0 { throw output.streamError ?? CocoaError(.fileWriteUnknown) }
                written += amount
            }
            copied += Double(count)
            progress?(total > 0 ? min(1, copied / total) : 1)
        }
    }

    private static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(fileURL: URL) throws -> String {
        guard let stream = InputStream(url: fileURL) else { throw CocoaError(.fileReadNoPermission) }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func defaultRootURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Lithe/DatabaseRecovery", isDirectory: true)
    }
}

private enum DatabaseBackupCompression {
    static func compress(_ data: Data) -> Data? {
        guard data.count >= 64 * 1_024 else { return nil }
        let destinationCapacity = data.count + max(64 * 1_024, data.count / 8)
        var destination = [UInt8](repeating: 0, count: destinationCapacity)
        let count = data.withUnsafeBytes { source in
            destination.withUnsafeMutableBytes { output in
                guard let sourceAddress = source.baseAddress, let outputAddress = output.baseAddress else { return 0 }
                return compression_encode_buffer(outputAddress.assumingMemoryBound(to: UInt8.self), output.count, sourceAddress.assumingMemoryBound(to: UInt8.self), source.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard count > 0, count < data.count else { return nil }
        return Data(destination.prefix(count))
    }

    static func decompress(_ data: Data, originalSize: Int) -> Data? {
        guard originalSize > 0 else { return Data() }
        var destination = [UInt8](repeating: 0, count: originalSize)
        let count = data.withUnsafeBytes { source in
            destination.withUnsafeMutableBytes { output in
                guard let sourceAddress = source.baseAddress, let outputAddress = output.baseAddress else { return 0 }
                return compression_decode_buffer(outputAddress.assumingMemoryBound(to: UInt8.self), output.count, sourceAddress.assumingMemoryBound(to: UInt8.self), source.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard count == originalSize else { return nil }
        return Data(destination)
    }
}
