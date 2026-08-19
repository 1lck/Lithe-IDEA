import Foundation
import Testing
@testable import Lithe

@Suite("macOS application log writer")
struct MacApplicationLogWriterTests {
    @Test
    func changingDirectoryMovesSubsequentApplicationLogOutputToTheSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let writer = MacApplicationLogWriter()
        let defaultDirectory = root.appendingPathComponent("default", isDirectory: true)
        let selectedDirectory = root.appendingPathComponent("selected", isDirectory: true)

        try writer.redirect(to: defaultDirectory)
        try writer.append("default log line\n")

        try writer.redirect(to: selectedDirectory)
        try writer.append("selected log line\n")

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
