import Darwin
import Foundation
import Testing
@testable import Lithe

@Suite("macOS application log writer")
struct MacApplicationLogWriterTests {
    @Test
    func changingDirectoryMovesSubsequentStandardErrorOutputToTheSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let originalTarget = root.appendingPathComponent("original-target")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let targetDescriptor: Int32 = originalTarget.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
        }
        #expect(targetDescriptor >= 0)
        defer {
            close(targetDescriptor)
            try? FileManager.default.removeItem(at: root)
        }

        let writer = MacApplicationLogWriter(targetFileDescriptor: targetDescriptor)
        let defaultDirectory = root.appendingPathComponent("default", isDirectory: true)
        let selectedDirectory = root.appendingPathComponent("selected", isDirectory: true)

        try writer.redirect(to: defaultDirectory)
        try write("default log line\n", to: targetDescriptor)

        try writer.redirect(to: selectedDirectory)
        try write("selected log line\n", to: targetDescriptor)

        let defaultContents = try String(
            contentsOf: defaultDirectory.appendingPathComponent("lithe.log"),
            encoding: .utf8
        )
        let selectedContents = try String(
            contentsOf: selectedDirectory.appendingPathComponent("lithe.log"),
            encoding: .utf8
        )
        #expect(defaultContents == "default log line\n")
        #expect(selectedContents == "selected log line\n")
    }

    @Test
    func defaultDirectoryProviderUsesTheMacUserLogsDirectory() {
        let directory = MacLogDirectoryProvider().defaultLogDirectory

        #expect(directory.path.hasSuffix("/Library/Logs/Lithe"))
    }

    private func write(_ value: String, to descriptor: Int32) throws {
        let data = Data(value.utf8)
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard written == data.count, fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
