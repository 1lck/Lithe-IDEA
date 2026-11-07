import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

/// shared/fixtures/editor/workbench-state-v1.json is the contract both hosts are tested against.
/// Here every case runs through the real linked Rust Core, the same command the model uses.
@MainActor
struct EditorWorkbenchStateCoreTests {
    private static func fixtureCases() throws -> [[String: Any]] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/editor/workbench-state-v1.json"))
        let fixture = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(fixture["cases"] as? [[String: Any]])
    }

    private struct Request: Encodable {
        let state: ToolingJSONValue
        let action: ToolingJSONValue
    }

    private struct Answer: Decodable {
        let state: ToolingJSONValue
        let removedGroupIds: ToolingJSONValue
    }

    @Test
    func everySharedFixtureCaseMatchesThroughCore() throws {
        let core = RustCoreBridge()
        let cases = try Self.fixtureCases()
        #expect(cases.count >= 40)
        for entry in cases {
            let name = entry["name"] as? String ?? ""
            let expected = try #require(entry["expected"] as? [String: Any])
            let result: Result<Answer, RustCoreBridge.CoreCallError> = core.executeResult(
                command: "editor.workbenchState.reduce",
                payload: Request(
                    state: try #require(ToolingJSONValue.fromFoundation(entry["state"] as Any)),
                    action: try #require(ToolingJSONValue.fromFoundation(entry["action"] as Any))
                )
            )
            let answer = try #require(try? result.get(), "\(name)")
            #expect(answer.state == ToolingJSONValue.fromFoundation(expected["state"] as Any), "\(name)")
            #expect(answer.removedGroupIds == ToolingJSONValue.fromFoundation(expected["removedGroupIds"] as Any), "\(name)")
        }
    }

    @Test
    func droppingNextToATabKeepsTheMixedOrderOfOtherGroupsAndTheSelection() throws {
        let feature = EditorTabOrderFeatureModel()
        let a = EditorTabItem.document(UUID()), b = EditorTabItem.document(UUID())
        let c = EditorTabItem.terminal(UUID()), d = EditorTabItem.document(UUID())
        for item in [a, b, c, d] { feature.moveToEnd(item) }
        let left = try #require(feature.groupLayout.groups.first)
        #expect(feature.drop(c, into: left, side: .right))
        let right = try #require(feature.group(containing: c))
        #expect(feature.items(in: left) == [a, b, d])
        feature.focus(a)

        // Reordering inside one group moves membership only; it keeps the group's selection.
        #expect(feature.move(d, before: a))
        #expect(feature.items(in: left) == [d, a, b])
        #expect(feature.selectedItem(in: left) == a)

        // Moving next to a tab of another group joins that group at the anchor.
        #expect(feature.move(b, after: c))
        #expect(feature.items(in: right) == [c, b])
        #expect(feature.items(in: left) == [d, a])
        #expect(feature.items == [d, a, c, b])
        #expect(feature.selectedItem(in: right) == c)
    }

    @Test
    func aMovedSelectedTabLeavesItsOldGroupOnTheFirstRemainingTab() throws {
        let feature = EditorTabOrderFeatureModel()
        let a = EditorTabItem.document(UUID()), b = EditorTabItem.document(UUID()), c = EditorTabItem.document(UUID())
        for item in [a, b, c] { feature.moveToEnd(item) }
        let left = try #require(feature.groupLayout.groups.first)
        feature.focus(b)
        #expect(feature.drop(b, into: left, side: .bottom))
        #expect(feature.selectedItem(in: left) == a)
        #expect(feature.items(in: left) == [a, c])
    }

    @Test
    func tabsWithoutAHomeJoinTheFocusedGroupAndEmptyGroupsDisappear() throws {
        let feature = EditorTabOrderFeatureModel()
        let a = EditorTabItem.document(UUID()), b = EditorTabItem.document(UUID()), x = EditorTabItem.document(UUID())
        feature.moveToEnd(a)
        feature.moveToEnd(x)
        let first = try #require(feature.groupLayout.groups.first)
        #expect(feature.drop(a, into: first, side: .right))
        let second = try #require(feature.group(containing: a))
        feature.focus(a)

        feature.moveToEnd(b)
        #expect(feature.group(containing: b) == second)
        feature.remove(a)
        feature.remove(b)
        #expect(feature.groupLayout.groups == [first])
        #expect(feature.items(in: first) == [x])
        #expect(feature.selectedItem(in: first) == x)
    }
}
