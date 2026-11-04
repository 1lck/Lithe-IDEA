import AppKit
import Foundation
import LitheCoreContracts
import LitheExecutionModule
import Testing
@testable import Lithe

@MainActor
struct LanguageTestPresentationTests {
    @Test
    func sameNamedResultsRetainTheirProjectsAndReportRerunSelectors() throws {
        let a = BuildTestReference(pluginID: "org.example.build", buildSystemID: "build", root: ".", projectID: "a", suite: "demo.Same", testCase: "checks")
        let b = BuildTestReference(pluginID: "org.example.build", buildSystemID: "build", root: ".", projectID: "b", suite: "demo.Same", testCase: "checks")
        let outcomes = [
            BuildTestResults.TestCase(project: "a", suite: "demo.Same", name: "checks", status: .passed, durationMillis: 10),
            BuildTestResults.TestCase(project: "b", suite: "demo.Same", name: "checks", status: .failed, durationMillis: 20)
        ]
        let items = LanguageTestsView.synthesizeResultItems(from: outcomes, references: [BuildTestCaseKey(outcomes[0]): a, BuildTestCaseKey(outcomes[1]): b], providerID: "java")
        #expect(items.count == 4)
        #expect(Set(items.map(\.id)).count == 4)
        let first = try #require(items.first { $0.projectPath == "a" && $0.depth == 2 })
        let second = try #require(items.first { $0.projectPath == "b" && $0.depth == 2 })
        let statuses = LanguageTestsView.resultStatuses(outcomes)
        #expect(statuses[LanguageTestsView.resultKey(first)] == "Passed")
        #expect(statuses[LanguageTestsView.resultKey(second)] == "Failed")
        let durations = LanguageTestsView.reportDurations(outcomes)
        #expect(durations[LanguageTestsView.resultKey(first)] == "10 ms")
        #expect(durations[LanguageTestsView.resultKey(second)] == "20 ms")
        #expect(first.buildReference == a)
        #expect(second.buildReference == b)
        #expect(items.first?.buildReference == a.suiteReference)
        let scope = LanguageTestScope.testCase(identifier: "demo.Same#checks", fileURL: nil, buildReference: b)
        #expect(scope.buildReference == b)
    }

    @Test
    func resultTreeUsesReportStatusesAndPreservesExactCaseNames() {
        let statuses = LanguageTestsView.resultStatuses([
            BuildTestResults.TestCase(suite: "demo.Example", name: "passes", status: .passed),
            BuildTestResults.TestCase(suite: "demo.Example", name: "skips", status: .skipped),
            BuildTestResults.TestCase(suite: "demo.Example", name: "fails(String)[1]", status: .passed),
            BuildTestResults.TestCase(suite: "demo.Example", name: "fails(String)[2]", status: .error),
            BuildTestResults.TestCase(suite: "demo.Failed", name: "assertion", status: .failed),
            BuildTestResults.TestCase(suite: "demo.Skipped", name: "disabled", status: .skipped)
        ])
        #expect(statuses[key("demo.Example")] == "Error")
        #expect(statuses[key("demo.Example", "passes")] == "Passed")
        #expect(statuses[key("demo.Example", "skips")] == "Ignored")
        #expect(statuses[key("demo.Example", "fails(String)[1]")] == "Passed")
        #expect(statuses[key("demo.Example", "fails(String)[2]")] == "Error")
        #expect(statuses[key("demo.Example", "fails")] == nil)
        #expect(statuses[key("demo.Failed")] == "Failed")
        #expect(statuses[key("demo.Failed", "assertion")] == "Failed")
        #expect(statuses[key("demo.Skipped")] == "Ignored")
        let item = LanguageTestItem(id: "method", providerID: "example", label: "passes", kind: .testCase,
            fileURL: nil, testIdentifier: "opaque-selector", depth: 2,
            reportIdentity: .init(suite: "demo.Example", name: "passes"))
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

    @Test func unsuccessfulProviderRunOverridesZeroOrPassingReportCounts() {
        for passed in [0, 3] {
            let results = BuildTestResults(tests: [], summary: .init(total: passed, passed: passed, failed: 0, errors: 0, skipped: 0), success: true)
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
            let results = BuildTestResults(tests: [], summary: .init(total: failures + errors + passed + skipped, passed: passed, failed: failures, errors: errors, skipped: skipped), success: failures + errors == 0)
            #expect(LanguageTestsView.summaryIcon(for: results) == "expui/run/test\(icon).svg")
        }
    }

    @Test
    func durationsAndCaseNamesComeDirectlyFromTheGenericReport() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let report = try JSONDecoder().decode(BuildTestResults.self, from: Data(contentsOf:
            root.appendingPathComponent("shared/fixtures/build-provider/test-results-v1.json")))
        let durations = LanguageTestsView.reportDurations(report.tests)
        #expect(durations[key("checkout / HTTP", "accepts(payload)[1]")] == "10 ms")
        #expect(durations[key("checkout / HTTP", "accepts(payload)[2]")] == "125 ms")
        #expect(durations[key("checkout / HTTP", "disabled")] == "0 ms")
        #expect(durations[key("checkout / HTTP", "unmeasured")] == nil)
        #expect(durations[key("checkout / HTTP")] == nil, "A report does not supply a suite duration")
        let rows = LanguageTestsView.synthesizeResultItems(from: report.tests, providerID: "example")
        #expect(rows.map(\.label) == ["checkout / HTTP", "accepts(payload)[1]", "accepts(payload)[2]", "disabled", "unmeasured"])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test
    func reportIdentityDoesNotCollideWhenNamesContainSeparators() {
        let tests: [BuildTestResults.TestCase] = [
            .init(suite: "a#b", name: "c", status: .passed),
            .init(suite: "a", name: "b#c", status: .failed),
            .init(project: "module:part", suite: "a", name: "b#c", status: .skipped)
        ]
        let rows = LanguageTestsView.synthesizeResultItems(from: tests, providerID: "example")
        #expect(Set(tests.map(\.id)).count == 3)
        #expect(Set(rows.map(\.id)).count == rows.count)
        let statuses = LanguageTestsView.resultStatuses(tests)
        #expect(rows.filter { $0.depth == 2 }.map { statuses[LanguageTestsView.resultKey($0)] } == ["Passed", "Failed", "Ignored"])
    }

    @Test
    func synthesizeResultItemsGeneratesClassAndMethodNodes() {
        let outcomes = [
            BuildTestResults.TestCase(suite: "demo.CalculatorTest", name: "addsPositiveNumbers()", status: .passed),
            BuildTestResults.TestCase(suite: "demo.CalculatorTest", name: "handlesZero()", status: .passed)
        ]
        let items = LanguageTestsView.synthesizeResultItems(from: outcomes, providerID: "java")
        #expect(items.count == 3)
        #expect(items[0].label == "demo.CalculatorTest")
        #expect(items[0].depth == 1)
        #expect(items[0].kind == .testCase)
        #expect(items[1].label == "addsPositiveNumbers()")
        #expect(items[1].depth == 2)
        #expect(items[2].label == "handlesZero()")
        #expect(items[2].depth == 2)
    }

    @Test
    func reportOnlyRowsRemainSelectableAndKeepTheirExecutableIdentifiers() throws {
        let source = URL(fileURLWithPath: "/fixture/Tests.java")
        let discovered = [LanguageTestItem(id: "file", providerID: "java", label: "Tests.java",
            kind: .file, fileURL: source, testIdentifier: nil, depth: 0)]
        let outcomes = [BuildTestResults.TestCase(suite: "demo.Tests", name: "passes()", status: .passed)]
        let results = BuildTestResults(tests: outcomes, summary: .init(total: 1, passed: 1, failed: 0, errors: 0, skipped: 0), success: true)
        let rows = LanguageTestsView.presentedItems(discovered: discovered, results: results, resultProviderID: "java", providerID: "java")
        #expect(rows.count == 2)
        for row in rows {
            let selected = try #require(LanguageTestsView.presentedItems(discovered: discovered,
                results: results, resultProviderID: "java", providerID: "java").first { $0.id == row.id })
            #expect(selected.kind == .testCase)
            #expect(selected.testIdentifier == (row.depth == 1 ? "demo.Tests" : "demo.Tests#passes()"))
            #expect(selected.fileURL == nil, "A report does not establish semantic source ownership for Debug")
        }
        #expect(LanguageTestsView.presentedItems(discovered: discovered, results: nil, resultProviderID: "java", providerID: "java") == discovered)
        let semantic = LanguageTestItem(id: "jdt-method", providerID: "java", label: "passes()",
            kind: .testCase, fileURL: source, testIdentifier: "demo.Tests#passes()", depth: 2, reportIdentity: .init(suite: "demo.Tests", name: "passes()"))
        #expect(LanguageTestsView.presentedItems(discovered: [semantic], results: results, resultProviderID: "java", providerID: "java").first { $0.id == semantic.id } == semantic)
    }

    @Test
    func partialSemanticDiscoveryKeepsEveryReportedCaseAndOnlyExactSourceAssociations() throws {
        let source = URL(fileURLWithPath: "/fixture/example.test")
        let discovered = LanguageTestItem(id: "semantic", providerID: "example", label: "Known", kind: .testCase,
            fileURL: source, testIdentifier: "opaque-engine-selector", depth: 2, reportIdentity: .init(suite: "Suite", name: "known"))
        let tests: [BuildTestResults.TestCase] = [.init(suite: "Suite", name: "known", status: .passed),
            .init(suite: "Suite", name: "orphan(payload)[1]", status: .failed)]
        let report = BuildTestResults(tests: tests, summary: .init(total: 2, passed: 1, failed: 1, errors: 0, skipped: 0), success: false)
        let rows = LanguageTestsView.presentedItems(discovered: [discovered], results: report, resultProviderID: "example", providerID: "example")
        #expect(rows.count == 3)
        let known = try #require(rows.first { $0.id == "semantic" })
        #expect(known.fileURL == source && known.testIdentifier == "opaque-engine-selector")
        let orphan = try #require(rows.first { $0.label == "orphan(payload)[1]" })
        #expect(orphan.fileURL == nil)
        #expect(LanguageTestsView.resultStatuses(tests)[LanguageTestsView.resultKey(orphan)] == "Failed")
    }

    @Test
    func currentResultsBelongOnlyToTheirProviderAndDisappearWhenCleared() {
        let outcomes = [BuildTestResults.TestCase(suite: "demo.Tests", name: "passes", status: .passed)]
        let results = BuildTestResults(tests: outcomes, summary: .init(total: 1, passed: 1, failed: 0, errors: 0, skipped: 0), success: true)
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

    private func key(_ suite: String, _ name: String? = nil) -> LanguageTestsView.ResultKey {
        .init(project: nil, suite: suite, name: name)
    }

    private func testItem(_ id: String, selector: String? = nil, depth: Int) -> LanguageTestItem {
        LanguageTestItem(id: id, providerID: "java", label: id, kind: .testCase,
                         fileURL: nil, testIdentifier: selector, depth: depth)
    }
}
