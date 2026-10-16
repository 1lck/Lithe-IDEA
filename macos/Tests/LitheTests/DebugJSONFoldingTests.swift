import Foundation
import Testing
@testable import Lithe

@Suite("Debug JSON folding")
struct DebugJSONFoldingTests {
    @Test
    func nestedObjectsAndArraysPreserveChildFoldsAndClosingComma() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let source = String(decoding: try encoder.encode(["orders": [["name": "brace { [ } ]", "empty": ""]], "retry": []]), as: UTF8.self)
        let folding = DebugJSONFolding(source)
        let all = folding.visibleLines(collapsed: [])
        #expect(all.map(\.text).joined(separator: "\n") == source)
        let orders = try #require(all.first { $0.text.contains("\"orders\"") })
        let child = try #require(all.first { $0.isFoldable && $0.id > orders.id })
        let childOnly = folding.visibleLines(collapsed: [child.id])
        #expect(childOnly.count < all.count)
        #expect(childOnly.contains { $0.text.contains("brace") } == false)
        let parentAndChild = folding.visibleLines(collapsed: [orders.id, child.id])
        #expect(parentAndChild.first { $0.id == orders.id }?.text.hasSuffix("],") == true)
        #expect(parentAndChild.contains { $0.id == child.id } == false)
        #expect(folding.visibleLines(collapsed: [child.id]) == childOnly)
        #expect(folding.visibleLines(collapsed: [0]).map(\.text) == ["{ … }"])
    }

    @Test
    func quotedBracketsEmptyContainersAndUnmatchedInputDoNotHideContent() {
        for source in ["{}", "[]", "\"{\"", "{\n  \"value\" : \"[\""] {
            let folding = DebugJSONFolding(source)
            #expect(folding.visibleLines(collapsed: [0, 1]).map(\.text).joined(separator: "\n") == source)
        }
    }
}
