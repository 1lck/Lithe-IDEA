import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
struct LanguageTestPresentationTests {
    @Test
    func resultTreeUsesReportStatusesAndNormalizesMethodSelectors() {
        let statuses = LanguageTestsView.resultStatuses([
            MavenTestCaseOutcome(className: "demo.Example", method: "passes", status: "passed"),
            MavenTestCaseOutcome(className: "demo.Example", method: "skips", status: "skipped"),
            MavenTestCaseOutcome(className: "demo.Example", method: "fails(String)[1]", status: "passed"),
            MavenTestCaseOutcome(className: "demo.Example", method: "fails(String)[2]", status: "error"),
            MavenTestCaseOutcome(className: "demo.Skipped", method: "disabled", status: "skipped"),
            MavenTestCaseOutcome(className: "demo.Unknown", method: "pending", status: "unknown")
        ])
        #expect(statuses["demo.Example"] == "Failed")
        #expect(statuses["demo.Example#passes"] == "Passed")
        #expect(statuses["demo.Example#skips"] == "Ignored")
        #expect(statuses["demo.Example#fails"] == "Failed")
        #expect(statuses["demo.Skipped"] == "Ignored")
        #expect(statuses["demo.Unknown"] == nil)
        let item = testItem("method", selector: "demo.Example#passes()", depth: 2)
        #expect(statuses[LanguageTestsView.resultKey(item)] == "Passed")
    }

    @Test
    func collapsedClassesHideOnlyTheirOwnDescendants() {
        let items = [testItem("first", depth: 1), testItem("method", depth: 2),
                     testItem("nested", depth: 2), testItem("nestedMethod", depth: 3),
                     testItem("second", depth: 1), testItem("otherMethod", depth: 2)]
        #expect(LanguageTestsView.visibleItems(items, collapsed: ["first"]).map(\.id)
            == ["first", "second", "otherMethod"])
        #expect(LanguageTestsView.visibleItems(items, collapsed: ["nested"]).map(\.id)
            == ["first", "method", "nested", "second", "otherMethod"])
        #expect(LanguageTestsView.visibleItems(items, collapsed: []).map(\.id) == items.map(\.id))
    }

    private func testItem(_ id: String, selector: String? = nil, depth: Int) -> LanguageTestItem {
        LanguageTestItem(id: id, providerID: "java", label: id, kind: .testCase,
                         fileURL: nil, testIdentifier: selector, depth: depth)
    }
}
