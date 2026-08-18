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
        #expect(FileManager.default.createFile(atPath: originalTarget.path, contents: nil))
        let targetHandle = try FileHandle(forWritingTo: originalTarget)
        defer {
            try? targetHandle.close()
            try? FileManager.default.removeItem(at: root)
        }

        let writer = MacApplicationLogWriter(targetFileDescriptor: targetHandle.fileDescriptor)
        let defaultDirectory = root.appendingPathComponent("default", isDirectory: true)
        let selectedDirectory = root.appendingPathComponent("selected", isDirectory: true)

        try writer.redirect(to: defaultDirectory)
        try targetHandle.write(contentsOf: Data("default log line\n".utf8))
        try targetHandle.synchronize()

        try writer.redirect(to: selectedDirectory)
        try targetHandle.write(contentsOf: Data("selected log line\n".utf8))
        try targetHandle.synchronize()

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
}
