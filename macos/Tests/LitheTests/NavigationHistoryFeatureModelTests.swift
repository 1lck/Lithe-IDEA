import Foundation
import Testing
@testable import Lithe

@Suite("Navigation history")
@MainActor
struct NavigationHistoryFeatureModelTests {
    @Test
    func backAndForwardPreserveLiveCaretLocations() throws {
        let model = NavigationHistoryFeatureModel(logSink: nil)
        let first = location("First.txt", line: 4, column: 2)
        let second = location("Second.txt", line: 9, column: 7)
        let movedSecond = location("Second.txt", line: 14, column: 3)

        model.recordJump(from: first, to: second)

        #expect(model.canNavigateBack)
        #expect(model.navigateBack(from: movedSecond) == first)
        #expect(model.canNavigateForward)
        #expect(model.navigateForward(from: first) == movedSecond)
    }

    @Test
    func newJumpClearsForwardHistory() {
        let model = NavigationHistoryFeatureModel(logSink: nil)
        let first = location("First.txt", line: 1)
        let second = location("Second.txt", line: 2)
        let third = location("Third.txt", line: 3)

        model.recordJump(from: first, to: second)
        #expect(model.navigateBack(from: second) == first)
        model.recordJump(from: first, to: third)

        #expect(!model.canNavigateForward)
        #expect(model.navigateBack(from: third) == first)
    }

    @Test
    func historyIsDeduplicatedAndBoundedByCore() {
        let model = NavigationHistoryFeatureModel(logSink: nil)
        let destination = location("Target.txt", line: 0)
        let repeated = location("First.txt", line: 1)
        model.recordJump(from: repeated, to: destination)
        model.recordJump(from: repeated, to: destination)
        #expect(model.backLocations == [repeated])

        for line in 0...100 {
            model.recordJump(from: location("Many.txt", line: line + 2), to: destination)
        }

        // Core keeps the newest 100 entries (shared/fixtures/editor/navigation-history-v1.json).
        #expect(model.backLocations.count == 100)
        #expect(model.backLocations.first == location("Many.txt", line: 3))
        #expect(model.backLocations.last == location("Many.txt", line: 102))
    }

    @Test
    func backSkipsTheEntryAtTheLiveLocation() {
        let model = NavigationHistoryFeatureModel(logSink: nil)
        let first = location("First.txt", line: 1)
        let second = location("Second.txt", line: 2)
        let third = location("Third.txt", line: 3)
        model.recordJump(from: first, to: second)
        model.recordJump(from: second, to: third)

        // The caret was moved back onto the newest entry without a jump.
        #expect(model.navigateBack(from: second) == first)
        #expect(model.forwardLocations == [second])
    }

    @Test
    func virtualAndReadOnlyContextSurvivesTheCoreRoundTrip() throws {
        let model = NavigationHistoryFeatureModel(logSink: nil)
        let url = try #require(URL(string: "example-plugin://contents/library/docs/readme.txt?=a%20b"))
        let virtual = EditorNavigationLocation(
            url: url, line: 8, utf16Column: 4, isReadOnly: true,
            displayPath: "library/docs/readme.txt", virtualProviderID: "example-plugin"
        )
        model.recordJump(from: virtual, to: location("Other.txt", line: 1))

        #expect(model.navigateBack(from: nil) == virtual)
    }

    @Test
    func resetClearsBothDirections() {
        let model = NavigationHistoryFeatureModel(logSink: nil)
        let first = location("First.txt", line: 1)
        let second = location("Second.txt", line: 2)
        model.recordJump(from: first, to: second)
        _ = model.navigateBack(from: second)

        model.reset()

        #expect(!model.canNavigateBack)
        #expect(!model.canNavigateForward)
    }

    @Test
    func failedNavigationCanRestoreBothStacks() {
        let model = NavigationHistoryFeatureModel(logSink: nil)
        let first = location("First.txt", line: 1)
        let second = location("Second.txt", line: 2)
        model.recordJump(from: first, to: second)
        let snapshot = model.snapshot()

        _ = model.navigateBack(from: second)
        model.restore(snapshot)

        #expect(model.backLocations == [first])
        #expect(model.forwardLocations.isEmpty)
    }

    @Test
    func virtualLocationsKeepTheirOwningProvider() throws {
        let url = try #require(URL(string: "example-plugin://contents/library/docs/readme.txt"))
        let location = EditorNavigationLocation(
            url: url,
            line: 8,
            utf16Column: 4,
            isReadOnly: true,
            displayPath: "library/docs/readme.txt",
            virtualProviderID: "example-plugin"
        )

        #expect(location.url == url)
        #expect(location.virtualProviderID == "example-plugin")
        #expect(location.isReadOnly)
    }

    private func location(
        _ name: String,
        line: Int,
        column: Int = 0
    ) -> EditorNavigationLocation {
        EditorNavigationLocation(
            url: URL(fileURLWithPath: "/workspace/\(name)"),
            line: line,
            utf16Column: column
        )
    }
}
