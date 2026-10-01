import Foundation
import Testing
@testable import Lithe

struct MacRuntimeToolDiscoveryTests {
    @Test
    func prefersTheExecutableOwnedByTheInstalledPHPPlugin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-php-tool-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("bin/intelephense")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let discovery = MacRuntimeToolDiscovery(
            homeDirectoryURL: root,
            resourceDirectoryURL: nil,
            pluginToolRoots: [root]
        )
        let candidates = discovery.candidates(
            for: "intelephense",
            projectURL: nil,
            environment: [:]
        )

        #expect(candidates.first?.executableURL == executable.standardizedFileURL)
        #expect(candidates.first?.source == .bundled)
        #expect(candidates.first?.detail == "PHP Support plugin")
    }
}
