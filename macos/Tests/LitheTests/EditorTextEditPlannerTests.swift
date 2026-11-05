import Foundation
import Testing
@testable import Lithe

private func at(_ line: Int, _ column: Int) -> EditorTextPosition { EditorTextPosition(line: line, column: column) }
private func edit(_ start: EditorTextPosition, _ end: EditorTextPosition, _ text: String) -> EditorTextEdit {
    EditorTextEdit(range: EditorTextRange(start: start, end: end), text: text)
}

/// The shared fixture is the rule set; these tests pin the bridge mapping of
/// Core's plan and rejection codes onto the host's service errors.
@Suite("Plugin text edit planning")
struct EditorTextEditPlannerTests {
    private struct Fixture: Decodable {
        struct Position: Decodable { let line: Int; let column: Int }
        struct Range: Decodable { let start: Position; let end: Position }
        struct Edit: Decodable { let range: Range; let text: String }
        struct Planned: Decodable { let index: Int; let utf16Offset: Int; let utf16Length: Int; let text: String; let normalizedText: String }
        struct Rejection: Decodable { let reason: String; let editIndex: Int?; let otherEditIndex: Int?; let positionIndex: Int? }
        struct Expected: Decodable { let lineEnding: String; let lineSeparator: String; let edits: [Planned]; let rejection: Rejection? }
        struct Case: Decodable {
            let name: String
            let text: String
            let edits: [Edit]
            let positions: [Position]?
            let expected: Expected
            let expectedText: String?
        }
        let cases: [Case]
    }

    private static func position(_ value: Fixture.Position) -> EditorTextPosition { at(value.line, value.column) }

    @Test func followsSharedFixture() throws {
        let url = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/fixtures/editor/text-edit-plan-v1.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        for item in fixture.cases {
            let edits = item.edits.map { edit(Self.position($0.range.start), Self.position($0.range.end), $0.text) }
            let positions = (item.positions ?? []).map(Self.position)
            if let rejection = item.expected.rejection {
                let expected: EditorDocumentServiceError
                switch (rejection.reason, rejection.editIndex) {
                case ("rangeOutOfBounds", let index?): expected = .rangeOutOfBounds(editIndex: index)
                case ("reversed", let index?): expected = .invalidRange(editIndex: index, reason: .reversed)
                case ("splitsSurrogatePair", let index?): expected = .invalidRange(editIndex: index, reason: .splitsSurrogatePair)
                case ("overlappingRanges", let index?):
                    expected = .overlappingRanges(editIndex: index, otherEditIndex: try #require(rejection.otherEditIndex))
                default: expected = .editorUnavailable
                }
                #expect(throws: expected, "\(item.name)") {
                    try EditorTextEditPlanner.plan(edits, in: item.text, positions: positions)
                }
                continue
            }
            let plan = try EditorTextEditPlanner.plan(edits, in: item.text, positions: positions)
            #expect(plan.lineEnding.rawValue == item.expected.lineEnding, "\(item.name)")
            #expect(plan.lineSeparator == item.expected.lineSeparator, "\(item.name)")
            #expect(plan.edits.map(\.index) == item.expected.edits.map(\.index), "\(item.name)")
            #expect(plan.edits.map(\.utf16Offset) == item.expected.edits.map(\.utf16Offset), "\(item.name)")
            #expect(plan.edits.map(\.utf16Length) == item.expected.edits.map(\.utf16Length), "\(item.name)")
            #expect(plan.edits.map(\.text) == item.expected.edits.map(\.text), "\(item.name)")
            #expect(plan.edits.map(\.normalizedText) == item.expected.edits.map(\.normalizedText), "\(item.name)")
            #expect(plan.edits.map(\.range) == plan.edits.map { edits[$0.index].range }, "\(item.name)")
            if let expectedText = item.expectedText {
                #expect(EditorTextEditPlanner.apply(plan.edits, to: item.text) == expectedText, "\(item.name)")
            }
        }
    }
}
