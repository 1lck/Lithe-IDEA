import CryptoKit
import Darwin
import Foundation
import LitheModuleAPI

struct MacDownloadedPluginPackage {
    let packageURL: URL
    let temporaryDirectory: URL
}

/// Downloads a marketplace archive, checks it against the index checksum,
/// and extracts it into a private temporary directory. The package store
/// still validates the declaration, trust, and executables before install.
protocol MacPluginPackageDownloading {
    func download(
        archiveURL: URL,
        expectedSHA256: String,
        pluginID: PluginID
    ) async throws -> MacDownloadedPluginPackage
}

enum MacPluginPackageDownloadError: Error, Equatable, LocalizedError {
    case invalidEndpoint
    case httpStatus(Int)
    case archiveTooLarge(Int64)
    /// `plugin.archive.checksumMismatch`
    case checksumMismatch(expected: String, actual: String)
    case invalidArchive
    case extractionFailed(String)
    /// The archive would expand beyond the extraction limits (size or file
    /// count), as a ZIP bomb would.
    case extractionLimitExceeded(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The plugin download address is invalid."
        case .httpStatus(let status):
            return "The plugin server returned HTTP \(status)."
        case .archiveTooLarge(let limit):
            return "The plugin archive is larger than \(limit / 1_048_576) MB."
        case .checksumMismatch(let expected, let actual):
            return "The downloaded plugin archive does not match the plugin repository (SHA-256 \(actual), expected \(expected))."
        case .invalidArchive:
            return "The downloaded plugin archive does not contain a valid plugin package."
        case .extractionFailed(let detail):
            return "The downloaded plugin archive could not be extracted: \(detail)"
        case .extractionLimitExceeded(let detail):
            return "The plugin archive expands beyond the allowed size: \(detail)"
        }
    }
}

/// Where marketplace HTTPS requests go. Production uses URLSession; debug
/// verification builds may map them onto a local fixture mirror.
protocol MacPluginMarketplaceTransport: Sendable {
    func data(from url: URL, maximumBytes: Int64) async throws -> Data
    /// Downloads to a temporary file owned by the caller.
    func download(from url: URL, maximumBytes: Int64) async throws -> URL
}

struct MacURLSessionPluginMarketplaceTransport: MacPluginMarketplaceTransport {
    private static let requestTimeout: TimeInterval = 60
    private static let writeChunkBytes = 256 * 1024
    let session: URLSession
    private let temporaryDirectory: URL

    init(session: URLSession = .shared, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.session = session
        self.temporaryDirectory = temporaryDirectory
    }

    func data(from url: URL, maximumBytes: Int64) async throws -> Data {
        let fileURL = try await download(from: url, maximumBytes: maximumBytes)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        return try Data(contentsOf: fileURL)
    }

    /// Streams the body to a file the caller owns and stops as soon as it
    /// passes `maximumBytes`, so an oversized or endless response never
    /// fills the disk first.
    func download(from url: URL, maximumBytes: Int64) async throws -> URL {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw MacPluginPackageDownloadError.invalidEndpoint
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = Self.requestTimeout
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            bytes.task.cancel()
            throw MacPluginPackageDownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        // A declared length over the limit is refused before reading the body.
        guard response.expectedContentLength <= maximumBytes else {
            bytes.task.cancel()
            throw MacPluginPackageDownloadError.archiveTooLarge(maximumBytes)
        }
        let owned = temporaryDirectory
            .appendingPathComponent("lithe-plugin-transfer-\(UUID().uuidString)", isDirectory: false)
        guard FileManager.default.createFile(atPath: owned.path, contents: nil) else {
            bytes.task.cancel()
            throw MacPluginPackageDownloadError.extractionFailed("Cannot create a temporary download file.")
        }
        do {
            let handle = try FileHandle(forWritingTo: owned)
            defer { try? handle.close() }
            var buffer = Data()
            buffer.reserveCapacity(Self.writeChunkBytes)
            var received: Int64 = 0
            for try await byte in bytes {
                received += 1
                guard received <= maximumBytes else {
                    throw MacPluginPackageDownloadError.archiveTooLarge(maximumBytes)
                }
                buffer.append(byte)
                if buffer.count >= Self.writeChunkBytes {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try handle.write(contentsOf: buffer)
            return owned
        } catch {
            bytes.task.cancel()
            try? FileManager.default.removeItem(at: owned)
            throw error
        }
    }
}

final class MacPluginPackageDownloader: MacPluginPackageDownloading {
    /// Bounds on what one marketplace archive may cost. The checksum only
    /// proves the archive is the one the index named; a third-party index can
    /// still name a ZIP bomb, so the expanded size and file count are capped
    /// both from the archive's directory and while `ditto` runs.
    struct Limits: Equatable {
        var archiveBytes: Int64
        var extractedBytes: Int64
        var entries: Int

        static let standard = Limits(
            archiveBytes: 512 * 1_048_576,
            extractedBytes: 2 * 1_073_741_824,
            entries: 50_000
        )
    }

    static let maximumArchiveBytes: Int64 = Limits.standard.archiveBytes
    private static let extractionTimeout: TimeInterval = 5 * 60
    private static let maximumZIPPathComponents = 64
    /// Caps retained normalized path text independently of payload size. Also
    /// respect a smaller archive budget, so metadata cannot exceed that budget.
    private static let maximumZIPPathBytes = 16 * 1_048_576
    private static let extractionPollInterval: TimeInterval = 0.05
    /// How often the extracted tree is measured while `ditto` runs.
    private static let extractionMeasureInterval: TimeInterval = 0.25
    private let transport: any MacPluginMarketplaceTransport
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let limits: Limits

    init(
        transport: any MacPluginMarketplaceTransport = MacURLSessionPluginMarketplaceTransport(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        limits: Limits = .standard
    ) {
        self.transport = transport
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
        self.limits = limits
    }

    func download(
        archiveURL: URL,
        expectedSHA256: String,
        pluginID: PluginID
    ) async throws -> MacDownloadedPluginPackage {
        try Task.checkCancellation()
        let archiveOnDisk = try await transport.download(from: archiveURL, maximumBytes: limits.archiveBytes)
        defer { try? fileManager.removeItem(at: archiveOnDisk) }
        // The checksum comes from the index the user browsed; nothing from an
        // archive that does not match it is extracted.
        let actual = try Self.sha256(of: archiveOnDisk)
        guard actual == expectedSHA256.lowercased() else {
            throw MacPluginPackageDownloadError.checksumMismatch(expected: expectedSHA256, actual: actual)
        }
        try Task.checkCancellation()
        // Refuse before writing anything when the archive's own directory
        // already declares too much.
        try Self.checkDeclaredContents(of: archiveOnDisk, limits: limits)

        let extractionRoot = temporaryDirectory
            .appendingPathComponent("lithe-plugin-download-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
        do {
            try extractArchive(archiveOnDisk, into: extractionRoot)
            let packageURL = try Self.findPackage(in: extractionRoot, pluginID: pluginID, fileManager: fileManager)
            return MacDownloadedPluginPackage(
                packageURL: packageURL,
                temporaryDirectory: extractionRoot
            )
        } catch {
            try? fileManager.removeItem(at: extractionRoot)
            throw error
        }
    }

    /// Streams the file so a large archive is never held in memory at once.
    static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Shared by marketplace downloads and local, already-snapshotted ZIPs.
    /// The caller owns `directory` and removes it on every failed operation.
    func extractArchive(_ archiveURL: URL, into directory: URL) throws {
        try Task.checkCancellation()
        try Self.checkDeclaredContents(of: archiveURL, limits: limits)
        // MacManagedProcess resolves Foundation's null-device sentinel only
        // for stdin. Its output dup2 actions require a real, open descriptor.
        let sink = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        defer { try? sink.close() }
        let process = MacManagedProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archiveURL.path, directory.path],
            standardInput: .nullDevice, standardOutput: sink, standardError: sink
        )
        do {
            try process.run()
        } catch {
            throw MacPluginPackageDownloadError.extractionFailed(error.localizedDescription)
        }
        // `ditto` is an external process, so waiting without a local deadline
        // would leave a cancelled or wedged download task alive indefinitely.
        // Poll on a bounded interval and terminate the process before
        // propagating cancellation or timeout to the caller.
        let deadline = ProcessInfo.processInfo.systemUptime + Self.extractionTimeout
        var nextMeasurement = ProcessInfo.processInfo.systemUptime
        while process.isRunning {
            // Declared sizes can lie; measure what was actually written.
            if ProcessInfo.processInfo.systemUptime >= nextMeasurement {
                nextMeasurement = ProcessInfo.processInfo.systemUptime + Self.extractionMeasureInterval
                if let exceeded = Self.limitExceeded(in: directory, limits: limits, fileManager: fileManager) {
                    terminateExtractionProcess(process)
                    throw MacPluginPackageDownloadError.extractionLimitExceeded(exceeded)
                }
            }
            do {
                try Task.checkCancellation()
            } catch {
                terminateExtractionProcess(process)
                throw error
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                terminateExtractionProcess(process)
                throw MacPluginPackageDownloadError.extractionFailed(
                    "ditto did not finish within \(Int(Self.extractionTimeout)) seconds"
                )
            }
            Thread.sleep(forTimeInterval: Self.extractionPollInterval)
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            throw MacPluginPackageDownloadError.extractionFailed("ditto exited with status \(process.terminationStatus)")
        }
        // A fast extraction can finish between two measurements.
        if let exceeded = Self.limitExceeded(in: directory, limits: limits, fileManager: fileManager) {
            throw MacPluginPackageDownloadError.extractionLimitExceeded(exceeded)
        }
    }

    /// Measures an extracted tree without following links; returns why it
    /// is over the limits, or nil.
    private static func limitExceeded(in directory: URL, limits: Limits, fileManager: FileManager) -> String? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return nil }
        var bytes: Int64 = 0
        var entries = 0
        for case let item as URL in enumerator {
            entries += 1
            if entries > limits.entries {
                return "more than \(limits.entries) files"
            }
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                bytes += Int64(values?.fileSize ?? 0)
                if bytes > limits.extractedBytes {
                    return "more than \(formatted(limits.extractedBytes))"
                }
            }
        }
        return nil
    }

    private static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Checks bounded ZIP metadata before `ditto` sees it. Both directory and
    /// local headers are inspected: extractors can use either filename. Links,
    /// special files, ambiguous paths, encryption and ZIP64 are not packages.
    static func checkDeclaredContents(of archiveURL: URL, limits: Limits) throws {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard limits.archiveBytes >= 0, fileSize <= UInt64(limits.archiveBytes) else {
            throw MacPluginPackageDownloadError.archiveTooLarge(limits.archiveBytes)
        }
        let tailLength = min(fileSize, 22 + 65_535)
        try handle.seek(toOffset: fileSize - tailLength)
        let tail = [UInt8](try handle.read(upToCount: Int(tailLength)) ?? Data())
        guard tail.count >= 22,
              let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
                  tail[$0] == 0x50 && tail[$0 + 1] == 0x4b && tail[$0 + 2] == 0x05 && tail[$0 + 3] == 0x06
                      && $0 + 22 + zipUInt16(tail, $0 + 20) == tail.count
              }) else {
            throw MacPluginPackageDownloadError.invalidArchive
        }
        let entryCount = zipUInt16(tail, end + 10)
        let directorySize = zipUInt32(tail, end + 12)
        let directoryOffset = zipUInt32(tail, end + 16)
        guard entryCount != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else {
            throw MacPluginPackageDownloadError.extractionLimitExceeded("ZIP64 archives are not supported")
        }
        guard zipUInt16(tail, end + 4) == 0, zipUInt16(tail, end + 6) == 0,
              zipUInt16(tail, end + 8) == entryCount,
              directoryOffset + directorySize == fileSize - tailLength + UInt64(end) else {
            throw MacPluginPackageDownloadError.invalidArchive
        }
        guard entryCount <= limits.entries else {
            throw MacPluginPackageDownloadError.extractionLimitExceeded("more than \(limits.entries) files")
        }
        var offset = directoryOffset
        var total: UInt64 = 0
        var paths = Set<String>()
        var filePaths = Set<String>()
        var parentPaths = Set<String>()
        var objectCount = 0
        var pathBytes: Int64 = 0
        let pathByteLimit = min(limits.archiveBytes, Int64(Self.maximumZIPPathBytes))
        func reservePath(_ path: String) throws {
            guard objectCount < limits.entries else {
                throw MacPluginPackageDownloadError.extractionLimitExceeded("more than \(limits.entries) files")
            }
            let bytes = Int64(path.utf8.count)
            guard bytes <= pathByteLimit - pathBytes else {
                throw MacPluginPackageDownloadError.extractionLimitExceeded("more than \(pathByteLimit) path bytes")
            }
            objectCount += 1
            pathBytes += bytes
        }
        var localEntries: [(offset: UInt64, end: UInt64, descriptor: Bool)] = []
        for _ in 0..<entryCount {
            try Task.checkCancellation()
            guard offset + 46 <= directoryOffset + directorySize else {
                throw MacPluginPackageDownloadError.invalidArchive
            }
            let header = try zipRead(handle, at: offset, count: 46)
            guard Array(header.prefix(4)) == [0x50, 0x4b, 0x01, 0x02],
                  zipUInt16(header, 34) == 0 else {
                throw MacPluginPackageDownloadError.invalidArchive
            }
            let compressed = zipUInt32(header, 20)
            let uncompressed = zipUInt32(header, 24)
            let localOffset = zipUInt32(header, 42)
            guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else {
                throw MacPluginPackageDownloadError.extractionLimitExceeded("ZIP64 archives are not supported")
            }
            total += uncompressed
            guard limits.extractedBytes >= 0, total <= UInt64(limits.extractedBytes) else {
                throw MacPluginPackageDownloadError.extractionLimitExceeded("more than \(formatted(limits.extractedBytes))")
            }
            let nameLength = zipUInt16(header, 28)
            let extraLength = zipUInt16(header, 30)
            let nextOffset = offset + 46 + UInt64(nameLength + extraLength + zipUInt16(header, 32))
            guard nextOffset <= directoryOffset + directorySize else {
                throw MacPluginPackageDownloadError.invalidArchive
            }
            let name = try zipRead(handle, at: offset + 46, count: nameLength)
            let path = try safeZIPPath(name)
            if name.last == 0x2f, uncompressed != 0 {
                throw MacPluginPackageDownloadError.invalidArchive
            }
            // APFS commonly ignores case and normalizes Unicode. A duplicate
            // must not silently replace a manifest or turn a file into a parent.
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            guard !paths.contains(key) else {
                throw MacPluginPackageDownloadError.invalidArchive
            }
            let components = key.split(separator: "/")
            guard components.count <= Self.maximumZIPPathComponents else {
                throw MacPluginPackageDownloadError.extractionLimitExceeded("more than \(Self.maximumZIPPathComponents) path components")
            }
            var parent = ""
            for component in components.dropLast() {
                parent = parent.isEmpty ? String(component) : parent + "/" + component
                guard !filePaths.contains(parent) else { throw MacPluginPackageDownloadError.invalidArchive }
                if !parentPaths.contains(parent) {
                    try reservePath(parent)
                    parentPaths.insert(parent)
                }
            }
            // The filesystem creates omitted parents too. Count every unique
            // file/directory once, including explicit empty directories, before
            // retaining its path or allowing extraction to start.
            if name.last == 0x2f {
                if !parentPaths.contains(key) {
                    try reservePath(key)
                    parentPaths.insert(key)
                }
            } else {
                guard !parentPaths.contains(key) else { throw MacPluginPackageDownloadError.invalidArchive }
                try reservePath(key)
                filePaths.insert(key)
            }
            paths.insert(key)
            let mode = zipUInt32(header, 38) >> 16
            let type = mode & 0xF000
            guard type == 0 || type == 0x8000 || type == 0x4000,
                  type != 0x4000 || name.last == 0x2f,
                  type != 0x8000 || name.last != 0x2f,
                  zipUInt16(header, 8) & 1 == 0 else {
                throw MacPluginPackageDownloadError.invalidArchive
            }
            try checkZIPExtra(try zipRead(handle, at: offset + 46 + UInt64(nameLength), count: extraLength), name: name)
            guard localOffset + 30 <= directoryOffset else {
                throw MacPluginPackageDownloadError.invalidArchive
            }
            let local = try zipRead(handle, at: localOffset, count: 30)
            let localNameLength = zipUInt16(local, 26)
            let localExtraLength = zipUInt16(local, 28)
            let dataOffset = localOffset + 30 + UInt64(localNameLength + localExtraLength)
            guard Array(local.prefix(4)) == [0x50, 0x4b, 0x03, 0x04],
                  zipUInt16(local, 6) == zipUInt16(header, 8),
                  zipUInt16(local, 8) == zipUInt16(header, 10),
                  dataOffset + compressed <= directoryOffset,
                  try zipRead(handle, at: localOffset + 30, count: localNameLength) == name else {
                throw MacPluginPackageDownloadError.invalidArchive
            }
            try checkZIPExtra(try zipRead(handle, at: localOffset + 30 + UInt64(localNameLength), count: localExtraLength), name: name)
            localEntries.append((localOffset, dataOffset + compressed, zipUInt16(local, 6) & 8 != 0))
            offset = nextOffset
        }
        guard offset == directoryOffset + directorySize else {
            throw MacPluginPackageDownloadError.invalidArchive
        }
        // Every local entry must be indexed. Otherwise an extractor walking
        // local headers could write an unchecked path hidden from the directory.
        var localEnd: UInt64 = 0
        for entry in localEntries.sorted(by: { $0.offset < $1.offset }) {
            try Task.checkCancellation()
            guard entry.offset == localEnd else {
                throw MacPluginPackageDownloadError.invalidArchive
            }
            localEnd = entry.end
            if entry.descriptor {
                let signature = try zipRead(handle, at: localEnd, count: 4)
                localEnd += signature == [0x50, 0x4b, 0x07, 0x08] ? 16 : 12
            }
            guard localEnd <= directoryOffset else {
                throw MacPluginPackageDownloadError.invalidArchive
            }
        }
        guard localEnd == directoryOffset else {
            throw MacPluginPackageDownloadError.invalidArchive
        }
    }

    private static func zipUInt16(_ bytes: [UInt8], _ at: Int) -> Int {
        Int(bytes[at]) | Int(bytes[at + 1]) << 8
    }

    private static func zipUInt32(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        UInt64(bytes[at]) | UInt64(bytes[at + 1]) << 8 | UInt64(bytes[at + 2]) << 16 | UInt64(bytes[at + 3]) << 24
    }

    private static func zipRead(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> [UInt8] {
        try handle.seek(toOffset: offset)
        let bytes = [UInt8](try handle.read(upToCount: count) ?? Data())
        guard bytes.count == count else { throw MacPluginPackageDownloadError.invalidArchive }
        return bytes
    }

    private static func safeZIPPath(_ bytes: [UInt8]) throws -> String {
        guard let path = String(bytes: bytes, encoding: .utf8), !path.isEmpty,
              !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("\0") else {
            throw MacPluginPackageDownloadError.invalidArchive
        }
        let components = (path.hasSuffix("/") ? String(path.dropLast()) : path)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw MacPluginPackageDownloadError.invalidArchive
        }
        return components.joined(separator: "/")
    }

    private static func checkZIPExtra(_ bytes: [UInt8], name: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            guard offset + 4 <= bytes.count else { throw MacPluginPackageDownloadError.invalidArchive }
            let tag = zipUInt16(bytes, offset)
            let size = zipUInt16(bytes, offset + 2)
            let end = offset + 4 + size
            guard end <= bytes.count, tag != 0x0001 else {
                throw MacPluginPackageDownloadError.invalidArchive
            }
            // The Unicode path extension can override the header filename.
            // Accept it only when it names exactly the same checked path.
            if tag == 0x7075 {
                guard size >= 5, bytes[offset + 4] == 1,
                      Array(bytes[(offset + 9)..<end]) == name else {
                    throw MacPluginPackageDownloadError.invalidArchive
                }
            }
            // ASi and PKWARE Unix metadata can carry a second mode or link
            // target, independent of the central directory's regular-file mode.
            if tag == 0x756e || (tag == 0x000d && size > 12) {
                throw MacPluginPackageDownloadError.invalidArchive
            }
            offset = end
        }
    }

    private func terminateExtractionProcess(_ process: MacManagedProcess) {
        _ = process.terminateAndWait(gracePeriod: 0.2, forcedTerminationTimeout: 1)
    }

    /// Identifies the package by its `id` only. Any manifest schema is
    /// accepted here; the package store owns schema, signature, and trust
    /// validation, so a declarative (schema 2) package is found as reliably
    /// as a retired native one.
    static func findPackage(in root: URL, pluginID: PluginID, fileManager: FileManager = .default) throws -> URL {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw MacPluginPackageDownloadError.invalidArchive
        }
        var matches: [URL] = []
        for case let candidate as URL in enumerator {
            guard candidate.lastPathComponent == "plugin.json",
                  let isDirectory = try? candidate.deletingLastPathComponent()
                    .resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDirectory == true else { continue }
            let packageURL = candidate.deletingLastPathComponent().standardizedFileURL
            guard let data = try? Data(contentsOf: candidate),
                  let identity = try? JSONDecoder().decode(PackageIdentity.self, from: data),
                  identity.id == pluginID.rawValue else { continue }
            matches.append(packageURL)
        }
        guard matches.count == 1 else {
            throw MacPluginPackageDownloadError.invalidArchive
        }
        return matches[0]
    }

    private struct PackageIdentity: Decodable {
        let id: String
    }
}
