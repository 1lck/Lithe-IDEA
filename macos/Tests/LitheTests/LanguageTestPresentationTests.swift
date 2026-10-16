import AppKit
import Foundation
import LitheCoreContracts
import LitheExecutionModule
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
            MavenTestCaseOutcome(className: "demo.Failed", method: "assertion", status: "failed"),
            MavenTestCaseOutcome(className: "demo.Skipped", method: "disabled", status: "skipped"),
            MavenTestCaseOutcome(className: "demo.Unknown", method: "pending", status: "unknown")
        ])
        #expect(statuses["demo.Example"] == "Error")
        #expect(statuses["demo.Example#passes"] == "Passed")
        #expect(statuses["demo.Example#skips"] == "Ignored")
        #expect(statuses["demo.Example#fails"] == "Error")
        #expect(statuses["demo.Failed"] == "Failed")
        #expect(statuses["demo.Failed#assertion"] == "Failed")
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

    @Test func summaryPreservesUnstructuredRunStates() {
        let states: [(LanguageTestRunState, String)] = [(.idle, "Run a test to see its results."),
            (.running, "Running"), (.passed, "Passed"), (.failed(exitCode: 7), "Failed"),
            (.cancelled, "Cancelled"), (.timedOut, "Timed Out")]
        for (state, expected) in states {
            #expect(LanguageTestsView.summaryText(for: state) == expected)
        }
    }

    @Test(arguments: [false, true])
    func resultIconsLoadOriginalSixteenPointLightAndDarkAssets(dark: Bool) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/IDEAIcons")
        for status in [nil, "Passed", "Failed", "Error", "Ignored", "PassedIgnored"] as [String?] {
            let path = LanguageTestsView.testItemIcon(status: status)
            let asset = dark ? LitheIcons.darkIdeaAssetPath(for: path) : path
            let image = try #require(NSImage(contentsOf: root.appendingPathComponent(asset)))
            #expect(image.size == NSSize(width: 16, height: 16))
        }
        #expect(LanguageTestsView.testItemIcon(status: nil) == "expui/run/testNotRunYet.svg")
        #expect(LanguageTestsView.testItemIcon(status: "Error") == "expui/run/testError.svg")
    }

    @Test(arguments: [false, true])
    func discoveryIconsDistinguishScopesAndKeepResultStatusPrecedence(dark: Bool) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/IDEAIcons")
        for (kind, children, expected) in [(LanguageTestItemKind.workspace, false, "testGroup"),
                                         (.testCase, true, "class"), (.testCase, false, "method")] {
            let path = LanguageTestsView.testItemIcon(status: nil, kind: kind, hasChildren: children)
            #expect(path == "expui/nodes/\(expected).svg")
            let asset = dark ? LitheIcons.darkIdeaAssetPath(for: path) : path
            let image = try #require(NSImage(contentsOf: root.appendingPathComponent(asset)))
            #expect(image.size == NSSize(width: 16, height: 16))
            #expect(LanguageTestsView.testItemIcon(status: "Failed", kind: kind, hasChildren: children)
                == "expui/run/testFailed.svg")
        }
        for (path, expected) in [("/fixture/Test.java", LitheIconKind.javaGeneric),
                                 ("/fixture/test_demo.py", .pythonSource), ("/fixture/demo.test.js", .javaScript)] {
            #expect(LitheIcons.kind(for: URL(fileURLWithPath: path), isDirectory: false) == expected)
        }
    }

    @Test func summaryIconDistinguishesMixedAndEmptyOutcomes() {
        for (failures, errors, passed, skipped, icon) in [(1, 0, 2, 1, "Failed"), (0, 1, 0, 0, "Error"),
            (0, 0, 2, 1, "PassedIgnored"), (0, 0, 1, 0, "Passed"),
            (0, 0, 0, 2, "Ignored"), (0, 0, 0, 0, "NotRunYet")] {
            let results = MavenTestResults(testsRun: failures + errors + passed + skipped,
                failures: failures, errors: errors, skipped: skipped, passed: passed,
                success: failures + errors == 0, failureDetails: [])
            #expect(LanguageTestsView.summaryIcon(for: results) == "expui/run/test\(icon).svg")
        }
    }

    private func testItem(_ id: String, selector: String? = nil, depth: Int) -> LanguageTestItem {
        LanguageTestItem(id: id, providerID: "java", label: id, kind: .testCase,
                         fileURL: nil, testIdentifier: selector, depth: depth)
    }
}
