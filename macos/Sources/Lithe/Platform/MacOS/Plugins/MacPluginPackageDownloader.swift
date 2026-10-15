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
            try extract(archiveOnDisk, into: extractionRoot)
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
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func extract(_ archiveURL: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, directory.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw MacPluginPackageDownloadError.extractionFailed(error.localizedDescription)
        }
        // `ditto` is an external process, so waiting without a local deadline
        // would leave a cancelled or wedged download task alive indefinitely.
        // Poll on a bounded interval and terminate the process before
        // propagating cancellation or timeout to the caller.
        let deadline = Date().addingTimeInterval(Self.extractionTimeout)
        var nextMeasurement = Date()
        while process.isRunning {
            // Declared sizes can lie; measure what was actually written.
            if Date() >= nextMeasurement {
                nextMeasurement = Date().addingTimeInterval(Self.extractionMeasureInterval)
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
            guard Date() < deadline else {
                terminateExtractionProcess(process)
                throw MacPluginPackageDownloadError.extractionFailed(
                    "ditto did not finish within \(Int(Self.extractionTimeout)) seconds"
                )
            }
            Thread.sleep(forTimeInterval: Self.extractionPollInterval)
        }
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacPluginPackageDownloadError.extractionFailed(detail ?? "ditto exited with status \(process.terminationStatus)")
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

    /// Reads the ZIP central directory and checks the declared entry count
    /// and uncompressed total against the limits. ZIP64 archives, which can
    /// declare sizes beyond 4 GB, are refused; plugin packages never need
    /// them.
    static func checkDeclaredContents(of archiveURL: URL, limits: Limits) throws {
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        // End of central directory: 22 bytes plus a comment of up to 64 KB.
        let tailLength = min(fileSize, 22 + 65_535)
        try handle.seek(toOffset: fileSize - tailLength)
        let tail = [UInt8](try handle.read(upToCount: Int(tailLength)) ?? Data())
        guard tail.count >= 22,
              let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
                  tail[$0] == 0x50 && tail[$0 + 1] == 0x4b && tail[$0 + 2] == 0x05 && tail[$0 + 3] == 0x06
              }) else {
            throw MacPluginPackageDownloadError.invalidArchive
        }
        func u16(_ bytes: [UInt8], _ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ bytes: [UInt8], _ at: Int) -> UInt64 {
            UInt64(bytes[at]) | UInt64(bytes[at + 1]) << 8 | UInt64(bytes[at + 2]) << 16 | UInt64(bytes[at + 3]) << 24
        }
        let entryCount = u16(tail, end + 10)
        let directorySize = u32(tail, end + 12)
        let directoryOffset = u32(tail, end + 16)
        guard entryCount != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else {
            throw MacPluginPackageDownloadError.extractionLimitExceeded("ZIP64 archives are not supported")
        }
        guard entryCount <= limits.entries else {
            throw MacPluginPackageDownloadError.extractionLimitExceeded("more than \(limits.entries) files")
        }
        guard directoryOffset + directorySize <= fileSize else {
            throw MacPluginPackageDownloadError.invalidArchive
        }
        try handle.seek(toOffset: directoryOffset)
        let directory = [UInt8](try handle.read(upToCount: Int(directorySize)) ?? Data())
        var offset = 0
        var total: UInt64 = 0
        for _ in 0..<entryCount {
            guard offset + 46 <= directory.count,
                  directory[offset] == 0x50, directory[offset + 1] == 0x4b,
                  directory[offset + 2] == 0x01, directory[offset + 3] == 0x02 else {
                throw MacPluginPackageDownloadError.invalidArchive
            }
            let uncompressed = u32(directory, offset + 24)
            guard uncompressed != 0xFFFF_FFFF else {
                throw MacPluginPackageDownloadError.extractionLimitExceeded("ZIP64 archives are not supported")
            }
            total += uncompressed
            guard total <= UInt64(limits.extractedBytes) else {
                throw MacPluginPackageDownloadError.extractionLimitExceeded(
                    "more than \(formatted(limits.extractedBytes))"
                )
            }
            offset += 46 + u16(directory, offset + 28) + u16(directory, offset + 30) + u16(directory, offset + 32)
        }
    }

    private func terminateExtractionProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: Self.extractionPollInterval)
        }
        if process.isRunning {
            process.interrupt()
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
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
