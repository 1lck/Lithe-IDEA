import Darwin
import Foundation

final class MacApplicationLogWriter {
    static let fileName = "lithe.log"

    private let targetFileDescriptor: Int32

    init(targetFileDescriptor: Int32 = STDERR_FILENO) {
        self.targetFileDescriptor = targetFileDescriptor
    }

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
        defer { close(descriptor) }

        guard dup2(descriptor, targetFileDescriptor) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
