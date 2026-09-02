import Darwin
import Foundation
import LitheGitModule

final class MacApplicationLogWriter: @unchecked Sendable {
    static let fileName = "lithe.log"

    private let lock = NSLock()
    private var directory: URL?

    func redirect(to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let logURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        let descriptor: Int32 = logURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        close(descriptor)

        lock.lock()
        self.directory = directory
        lock.unlock()
    }

    func append(_ message: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let directory else {
            throw CocoaError(.fileNoSuchFile)
        }

        let logURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        let descriptor: Int32 = logURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        let data = Data(message.utf8)
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard written == data.count else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}


/// Bridges Git performance diagnostics into the application's configured log file.
struct MacGitPerformanceLogger: GitPerformanceLogger, Sendable {
    private let writer: MacApplicationLogWriter
    private let queue = DispatchQueue(
        label: "com.openres.Lithe.git-performance-log",
        qos: .utility
    )

    init(writer: MacApplicationLogWriter) {
        self.writer = writer
    }

    func record(_ message: String) {
        let timestampMilliseconds = Int(Date().timeIntervalSince1970 * 1_000)
        queue.async { [writer] in
            do {
                try writer.append("timestamp_ms=\(timestampMilliseconds) \(message)\n")
            } catch {
                let fallback = "Could not write Git performance log: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(fallback.utf8))
            }
        }
    }
}
