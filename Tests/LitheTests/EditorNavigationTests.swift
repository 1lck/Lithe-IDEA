import AppKit
import Foundation
import Testing
@testable import Lithe

@Suite("Editor navigation")
struct EditorNavigationTests {
    @Test
    @MainActor
    func targetIsPublishedOnlyAfterItsDocumentActivates() async {
        let feature = EditorNavigationFeatureModel()
        let gate = NavigationActivationGate()
        let target = EditorNavigationTarget(
            url: URL(fileURLWithPath: "/workspace/Target.swift"),
            line: 12,
            utf16Column: 4
        )

        feature.navigate(to: target) {
            await gate.wait()
            return true
        }
        await Task.yield()

        #expect(feature.isNavigating)
        #expect(feature.target == nil)

        await gate.open()
        await waitUntil { feature.target != nil }

        #expect(!feature.isNavigating)
        #expect(feature.target?.url == target.url)
        #expect(feature.target?.range == target.range)
    }

    @Test
    @MainActor
    func newerNavigationCannotBeOverwrittenByAStaleCompletion() async {
        let feature = EditorNavigationFeatureModel()
        let staleGate = NavigationActivationGate()
        let staleTarget = EditorNavigationTarget(
            url: URL(fileURLWithPath: "/workspace/Stale.swift"),
            line: 1,
            utf16Column: 0
        )
        let latestTarget = EditorNavigationTarget(
            url: URL(fileURLWithPath: "/workspace/Latest.swift"),
            line: 8,
            utf16Column: 2
        )

        feature.navigate(to: staleTarget) {
            await staleGate.wait()
            return true
        }
        feature.navigate(to: latestTarget) { true }
        await waitUntil { feature.target?.url == latestTarget.url }

        await staleGate.open()
        for _ in 0..<10 { await Task.yield() }

        #expect(feature.target?.url == latestTarget.url)
        #expect(feature.target?.line == 8)
    }

    @Test
    func viewportKeepsComfortablyVisibleTargetsStable() {
        let destination = EditorNavigationViewport.destinationY(
            currentY: 400,
            viewportHeight: 600,
            contentHeight: 3_000,
            targetMinY: 650,
            targetHeight: 20
        )

        #expect(destination == 400)
    }

    @Test
    func viewportPositionsOffscreenTargetsAboveCenterAndClampsEdges() {
        #expect(EditorNavigationViewport.destinationY(
            currentY: 0,
            viewportHeight: 500,
            contentHeight: 3_000,
            targetMinY: 1_500,
            targetHeight: 20
        ) == 1_320)

        #expect(EditorNavigationViewport.destinationY(
            currentY: 0,
            viewportHeight: 500,
            contentHeight: 2_200,
            targetMinY: 2_180,
            targetHeight: 20
        ) == 1_700)
    }

    @Test
    @MainActor
    func lspRangeUsesUTF16OffsetsWithoutScanningFromTheDocumentStart() {
        let textView = CodeTextView(frame: .zero)
        textView.string = "zero\n  func café😀() {}\n"
        textView.rebuildLineIndex()
        let range = textView.navigationCharacterRange(
            for: LanguageServerRange(
                start: LanguageServerPosition(line: 1, utf16Column: 2),
                end: LanguageServerPosition(line: 1, utf16Column: 6)
            ),
            in: textView.string as NSString
        )

        #expect(range == NSRange(location: 7, length: 4))
        #expect((textView.string as NSString).substring(with: range) == "func")
    }

    @Test
    @MainActor
    func repeatedViewUpdatesDoNotRepublishUnchangedFindState() {
        let textView = CodeTextView(frame: .zero)
        textView.string = "alpha beta alpha"
        textView.rebuildLineIndex()
        var reports: [(Int, Int)] = []
        textView.onFindStateChange = { reports.append(($0, $1)) }

        textView.syncFindState(isVisible: true, query: "alpha")
        textView.syncFindState(isVisible: true, query: "alpha")
        textView.syncFindState(isVisible: true, query: "alpha")

        #expect(reports.count == 1)
        #expect(reports.first?.0 == 0)
        #expect(reports.first?.1 == 2)

        textView.string = "alpha"
        textView.rebuildLineIndex()
        textView.syncFindState(isVisible: true, query: "alpha")

        #expect(reports.count == 2)
        #expect(reports.last?.1 == 1)
    }

    @MainActor
    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for navigation state")
    }
}

private actor NavigationActivationGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
