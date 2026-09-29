import Foundation
import Testing
@testable import Lithe

@Suite("Shared document text classification")
struct TextContentPolicyTests {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let name: String
            let text: String
            let isPlainText: Bool
        }
        let cases: [Case]
    }

    @Test func decodedTextMatchesSharedContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            root.appendingPathComponent("shared/fixtures/editor/text-content-v1.json")))
        for item in fixture.cases {
            #expect(WorkspaceTextFilePolicy.isPlainText(item.text) == item.isPlainText, "\(item.name)")
        }
    }
}
