import Foundation
import Testing
@testable import Lithe

/// The fixtures under shared/fixtures are the contract both hosts are tested against.
struct KeymapTerminalCoreFixtureTests {
    private static func fixture(_ name: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/\(name)"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test
    func doubleShiftAdapterMatchesTheSharedGestureFixtureThroughCore() throws {
        let fixture = try Self.fixture("keymap/modifier-gesture-v1.json")
        for sequence in try #require(fixture["sequences"] as? [[String: Any]]) {
            let name = sequence["name"] as? String ?? ""
            var recognizer = DoubleShiftGestureRecognizer()
            for (index, step) in (sequence["steps"] as? [[String: Any]] ?? []).enumerated() {
                switch step["event"] as? String {
                case "keyDown": recognizer.handleKeyDown()
                case "reset": recognizer.reset()
                default:
                    let triggered = recognizer.handleFlagsChanged(
                        isShiftDown: step["shift"] as? Bool ?? false,
                        hasOtherModifiers: step["otherModifiers"] as? Bool ?? false,
                        timestamp: step["timestamp"] as? Double ?? 0
                    )
                    #expect(triggered == (step["expected"] as? Bool), "\(name) step \(index)")
                }
            }
        }
    }

    @Test
    func terminalLinksResolveThroughCoreAndCheckExistenceNatively() throws {
        let fixture = try Self.fixture("terminal/link-target-v1.json")
        let cases = try #require(fixture["cases"] as? [[String: Any]])
        let workspace = URL(fileURLWithPath: "/work/project")
        let relative = try #require(cases.first { $0["name"] as? String == "relative-path-with-line-and-column" })
        let expected = try #require((relative["expected"] as? [[String: Any]])?.first)
        let bridge = RustCoreBridge()

        let target = bridge.terminalLinkTarget(
            "Sources/App.swift:12:4",
            relativeTo: workspace, homeDirectory: URL(fileURLWithPath: "/Users/me"),
            fileExists: { $0.path == expected["path"] as? String }
        )
        #expect(target == .file(TerminalLinkLocation(
            url: URL(fileURLWithPath: "/work/project/Sources/App.swift"), line: 12, column: 4)))
        #expect(bridge.terminalLinkTarget("Sources/App.swift:12:4", relativeTo: workspace, homeDirectory: URL(fileURLWithPath: "/Users/me"), fileExists: { _ in false }) == nil)
        // A location suffix must not be mistaken for a URL scheme.
        #expect(bridge.terminalLinkTarget("App.swift:12", relativeTo: workspace, homeDirectory: URL(fileURLWithPath: "/Users/me"), fileExists: { _ in true })
            == .file(TerminalLinkLocation(url: workspace.appendingPathComponent("App.swift"), line: 12, column: nil)))
        #expect(bridge.terminalLinkTarget("https://example.com/docs", relativeTo: workspace, homeDirectory: URL(fileURLWithPath: "/Users/me"), fileExists: { _ in false })
            == .external(URL(string: "https://example.com/docs")!))
    }

    private struct FixtureEntry: Codable { let command: String; let key: String; let when: String?; let enabled: Bool? }
    private struct FixtureLayer: Codable { let entries: [FixtureEntry]?; let disabledCommands: [String]? }
    private struct FixtureConflict: Codable, Equatable { let key: String; let when: String?; let commands: [String] }
    private struct FixtureExpected: Codable { let conflicts: [FixtureConflict] }
    private struct FixtureCase: Codable { let name: String; let platform: String; let layers: [FixtureLayer]; let expected: FixtureExpected }
    private struct FixtureFile: Codable { let cases: [FixtureCase] }
    private struct ConflictRequest: Encodable { let platform: String; let layers: [FixtureLayer] }
    private struct ConflictResponse: Decodable { let conflicts: [FixtureConflict] }

    @Test
    func keymapConflictsMatchTheSharedFixture() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/keymap/binding-conflicts-v1.json"))
        for item in try JSONDecoder().decode(FixtureFile.self, from: data).cases {
            let result: Result<ConflictResponse, RustCoreBridge.CoreCallError> = RustCoreBridge().executeResult(
                command: "keymap.analyzeConflicts",
                payload: ConflictRequest(platform: item.platform, layers: item.layers))
            #expect(try result.get().conflicts == item.expected.conflicts, "\(item.name)")
        }
    }

    @Test
    func nativeBindingsReachCoreInTheSameGrammarAsStoredText() {
        let binding = KeyboardShortcutBinding.keyPress(key: "p", modifiers: [.command, .shift])
        #expect(binding.coreBindingText == "shift+meta+p")
        #expect(KeyboardShortcutBinding.keyPress(key: "delete", modifiers: [.command]).coreBindingText == "meta+backspace")
        #expect(KeyboardShortcutBinding.doubleTap(.shift).coreBindingText == "doubleshift")
    }
}
