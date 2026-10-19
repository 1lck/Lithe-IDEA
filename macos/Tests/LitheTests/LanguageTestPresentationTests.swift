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

    @Test func unsuccessfulMavenRunOverridesZeroOrPassingReportCounts() {
        for passed in [0, 3] {
            let results = MavenTestResults(testsRun: passed, failures: 0, errors: 0, skipped: 0,
                passed: passed, success: true, failureDetails: [])
            for state in [LanguageTestRunState.failed(exitCode: 1), .timedOut] {
                #expect(LanguageTestsView.runFailed(state))
                #expect(LanguageTestsView.summaryIcon(for: results, state: state) == "expui/run/testError.svg")
            }
        }
        #expect(!LanguageTestsView.runFailed(.passed))
        #expect(!LanguageTestsView.runFailed(.cancelled))
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

    @Test
    func parseDurationsExtractsClassAndMethodDurations() {
        let output = """
        [INFO] Running demo.CalculatorTest
        Checking 2 + 3
        [INFO] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 0.582 s -- in demo.CalculatorTest
        [INFO] Results:
        [INFO] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 9.999 s
        """
        let outcomes = [
            MavenTestCaseOutcome(className: "demo.CalculatorTest", method: "addsPositiveNumbers()", status: "passed", durationMillis: 17)
        ]
        let durations = LanguageTestsView.parseDurations(from: output, outcomes: outcomes)
        #expect(durations["demo.CalculatorTest"] == "582 ms")
        #expect(durations["CalculatorTest"] == "582 ms")
        #expect(durations["demo.CalculatorTest#addsPositiveNumbers"] == "17 ms")
        #expect(durations["addsPositiveNumbers"] == nil, "Method names from different classes must not share a duration")
    }

    @Test
    func methodDurationsComeFromReportsAndNeverFromASuiteSummary() throws {
        struct Fixture: Decodable { let expected: [MavenTestCaseOutcome] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            root.appendingPathComponent("shared/fixtures/maven/testcase-durations-v1.json")))
        let durations = LanguageTestsView.parseDurations(from: "Time elapsed: 9.999 s", outcomes: fixture.expected)
        #expect(durations["demo.DurationTest#fast"] == "10 ms")
        #expect(durations["demo.DurationTest#slow"] == "125 ms")
        #expect(durations["demo.DurationTest#repeat"] == "50 ms")
        #expect(durations["demo.DurationTest#zero"] == "0 ms")
        for method in ["missing", "partial", "invalid", "negative", "overflow"] {
            #expect(durations["demo.DurationTest#" + method] == nil)
        }
        let unknown = MavenTestCaseOutcome(className: "demo.OtherTest", method: "fast", status: "passed")
        #expect(LanguageTestsView.parseDurations(from: "Time elapsed: 9.999 s", outcomes: [unknown]).isEmpty)
    }

    @Test
    func synthesizeResultItemsGeneratesClassAndMethodNodes() {
        let outcomes = [
            MavenTestCaseOutcome(className: "demo.CalculatorTest", method: "addsPositiveNumbers()", status: "passed"),
            MavenTestCaseOutcome(className: "demo.CalculatorTest", method: "handlesZero()", status: "passed")
        ]
        let items = LanguageTestsView.synthesizeResultItems(from: outcomes, providerID: "java")
        #expect(items.count == 3)
        #expect(items[0].label == "CalculatorTest")
        #expect(items[0].depth == 1)
        #expect(items[0].kind == .testCase)
        #expect(items[1].label == "addsPositiveNumbers")
        #expect(items[1].depth == 2)
        #expect(items[2].label == "handlesZero")
        #expect(items[2].depth == 2)
    }

    @Test
    func reportOnlyRowsRemainSelectableAndKeepTheirExecutableIdentifiers() throws {
        let source = URL(fileURLWithPath: "/fixture/Tests.java")
        let discovered = [LanguageTestItem(id: "file", providerID: "java", label: "Tests.java",
            kind: .file, fileURL: source, testIdentifier: nil, depth: 0)]
        let outcomes = [MavenTestCaseOutcome(className: "demo.Tests", method: "passes()", status: "passed")]
        let results = MavenTestResults(testsRun: 1, failures: 0, errors: 0, skipped: 0, passed: 1,
            success: true, failureDetails: [], testCases: outcomes)
        let rows = LanguageTestsView.presentedItems(discovered: discovered, results: results, resultProviderID: "java", providerID: "java")
        #expect(rows.count == 2)
        for row in rows {
            let selected = try #require(LanguageTestsView.presentedItems(discovered: discovered,
                results: results, resultProviderID: "java", providerID: "java").first { $0.id == row.id })
            #expect(selected.kind == .testCase)
            #expect(selected.testIdentifier == (row.depth == 1 ? "demo.Tests" : "demo.Tests#passes"))
            #expect(selected.fileURL == nil, "A report does not establish semantic source ownership for Debug")
        }
        #expect(LanguageTestsView.presentedItems(discovered: discovered, results: nil, resultProviderID: "java", providerID: "java") == discovered)
        let semantic = LanguageTestItem(id: "jdt-method", providerID: "java", label: "passes()",
            kind: .testCase, fileURL: source, testIdentifier: "demo.Tests#passes()", depth: 2)
        #expect(LanguageTestsView.presentedItems(discovered: [semantic], results: results, resultProviderID: "java", providerID: "java") == [semantic])
    }

    @Test
    func currentResultsBelongOnlyToTheirProviderAndDisappearWhenCleared() {
        let outcomes = [MavenTestCaseOutcome(className: "demo.Tests", method: "passes", status: "passed")]
        let results = MavenTestResults(testsRun: 1, failures: 0, errors: 0, skipped: 0, passed: 1,
            success: true, failureDetails: [], testCases: outcomes)
        for provider in ["java", "node", "python"] {
            let discovered = [LanguageTestItem(id: "workspace-" + provider, providerID: provider,
                label: provider, kind: .workspace, fileURL: nil, testIdentifier: nil, depth: 0),
                LanguageTestItem(id: "file-" + provider, providerID: provider, label: "Unrun file",
                    kind: .file, fileURL: URL(fileURLWithPath: "/fixture/Unrun"), testIdentifier: nil, depth: 1),
                LanguageTestItem(id: "unrun-" + provider, providerID: provider, label: "Unrun test",
                    kind: .testCase, fileURL: nil, testIdentifier: "demo.Unrun#check", depth: 2)]
            let rows = LanguageTestsView.presentedItems(discovered: discovered, results: results,
                resultProviderID: "java", providerID: provider)
            #expect(provider == "java" ? rows.count == 2 : rows == discovered)
            #expect(rows.allSatisfy { $0.providerID == provider })
            // Clear retains the plan; Close clears both. Neither may reuse editor history.
            for owner in ["java", nil] as [String?] {
                #expect(LanguageTestsView.presentedItems(discovered: discovered, results: nil,
                    resultProviderID: owner, providerID: provider) == discovered)
            }
        }
    }

    @Test
    func activeTestTargetFormatsMethodAndClassNamesCorrectly() {
        #expect(ActiveTestTarget.formattedName(for: "demo.CalculatorTest#addsPositiveNumbers()") == "CalculatorTest.addsPositiveNumbers")
        #expect(ActiveTestTarget.formattedName(for: "demo.CalculatorTest#intentionalFailureForPreview()") == "CalculatorTest.intentionalFailureForPreview")
        #expect(ActiveTestTarget.formattedName(for: "demo.CalculatorTest") == "CalculatorTest")
    }

    @Test(arguments: [false, true])
    func resolvedTestNameKeepsTheFullScopeAndDebugToolbarBinding(method: Bool) {
        let source = URL(fileURLWithPath: "/fixture/Tests.java")
        let scope: LanguageTestScope = method ? .testCase(identifier: "demo.Tests#logsIn()", fileURL: source) : .file(source)
        var target = ActiveTestTarget(providerID: "java", scope: scope)
        let launchName = method ? "logsIn()" : "ActualTestClass"
        target.resolvedName = launchName
        #expect(target.scope == scope)
        #expect(DebugToolbarPresentation.mainToolbarControl(state: .paused,
            debugTarget: launchName, selectedTarget: target.name) == .resume)
    }

    private func testItem(_ id: String, selector: String? = nil, depth: Int) -> LanguageTestItem {
        LanguageTestItem(id: id, providerID: "java", label: id, kind: .testCase,
                         fileURL: nil, testIdentifier: selector, depth: depth)
    }
}
