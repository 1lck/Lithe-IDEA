import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

/// shared/fixtures/workspace/visibility-v1.json is the contract for hidden paths on every host:
/// Rust Core and lithe-core-rules, macOS (here, through the real FFI) and Windows (through wasm).
struct FileVisibilityFixtureTests {
    private static func fixture() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/workspace/visibility-v1.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test
    func builtInListsComeFromCore() throws {
        let defaults = try #require(try Self.fixture()["defaults"] as? [String: Any])
        #expect(FileVisibilityRules.builtInHiddenDirectories == defaults["hiddenDirectoryNames"] as? [String])
        #expect(FileVisibilityRules.builtInHiddenFilePatterns == defaults["hiddenFilePatterns"] as? [String])
        #expect(FileVisibilityRules.builtInPatterns == defaults["builtInPatterns"] as? [String])
        #expect(FileVisibilityRules.watchedConfigurationDirectory == defaults["configurationDirectory"] as? String)
    }

    @Test
    func everyCaseMatchesTheSharedFixture() throws {
        let root = URL(fileURLWithPath: "/fixture")
        for item in try #require(Self.fixture()["cases"] as? [[String: Any]]) {
            let name = item["name"] as? String ?? ""
            let rules = FileVisibilityRules(
                hiddenDirectoryNames: item["hiddenDirectoryNames"] as? [String] ?? [],
                hiddenFilePatterns: item["hiddenFilePatterns"] as? [String] ?? []
            )
            let entries = try #require(item["entries"] as? [[String: Any]])
            // Entries with an empty path are not a file-system location; the adapter never asks.
            let located = entries.filter { !(($0["path"] as? String) ?? "").isEmpty }
            let batch = rules.hiddenFlags(
                for: located.map { (url: root.appendingPathComponent($0["path"] as? String ?? ""), isDirectory: $0["isDirectory"] as? Bool) },
                relativeTo: root
            )
            for (index, entry) in located.enumerated() {
                let path = entry["path"] as? String ?? ""
                let url = root.appendingPathComponent(path)
                let kind = entry["isDirectory"] as? Bool
                let expected = entry["hidden"] as? Bool
                #expect(rules.isHidden(url, relativeTo: root, isDirectory: kind) == expected, "\(name): \(path)")
                #expect(batch[index] == expected, "\(name): \(path) (batch)")
                let watched = entry["watchedDespiteHiding"] as? Bool ?? false
                if expected == true {
                    #expect(rules.isWatchedDespiteHiding(url, relativeTo: root) == watched, "\(name): \(path)")
                }
                // Event filtering never knows the kind, so compare only where the kind cannot matter.
                if kind == nil || path.hasPrefix(".lithe") {
                    #expect(rules.deliversEvents(at: url, relativeTo: root) == (expected == false || watched), "\(name): \(path)")
                }
            }
        }
    }
}
