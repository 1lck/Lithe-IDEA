import Foundation
import Testing
@testable import Lithe

@Suite("Navigation history")
@MainActor
struct NavigationHistoryFeatureModelTests {
    @Test
    func backAndForwardPreserveLiveCaretLocations() throws {
        let model = NavigationHistoryFeatureModel()
        let first = location("First.java", line: 4, column: 2)
        let second = location("Second.java", line: 9, column: 7)
        let movedSecond = location("Second.java", line: 14, column: 3)

        model.recordJump(from: first, to: second)

        #expect(model.canNavigateBack)
        #expect(model.navigateBack(from: movedSecond) == first)
        #expect(model.canNavigateForward)
        #expect(model.navigateForward(from: first) == movedSecond)
    }

    @Test
    func newJumpClearsForwardHistory() {
        let model = NavigationHistoryFeatureModel()
        let first = location("First.java", line: 1)
        let second = location("Second.java", line: 2)
        let third = location("Third.java", line: 3)

        model.recordJump(from: first, to: second)
        #expect(model.navigateBack(from: second) == first)
        model.recordJump(from: first, to: third)

        #expect(!model.canNavigateForward)
        #expect(model.navigateBack(from: third) == first)
    }

    @Test
    func historyIsDeduplicatedAndBounded() {
        let model = NavigationHistoryFeatureModel(maximumEntryCount: 2)
        let first = location("First.java", line: 1)
        let second = location("Second.java", line: 2)
        let third = location("Third.java", line: 3)
        let fourth = location("Fourth.java", line: 4)

        model.recordJump(from: first, to: second)
        model.recordJump(from: second, to: third)
        model.recordJump(from: third, to: fourth)

        #expect(model.backLocations == [second, third])
        #expect(model.navigateBack(from: fourth) == third)
        #expect(model.navigateBack(from: third) == second)
        #expect(!model.canNavigateBack)
    }

    @Test
    func resetClearsBothDirections() {
        let model = NavigationHistoryFeatureModel()
        let first = location("First.java", line: 1)
        let second = location("Second.java", line: 2)
        model.recordJump(from: first, to: second)
        _ = model.navigateBack(from: second)

        model.reset()

        #expect(!model.canNavigateBack)
        #expect(!model.canNavigateForward)
    }

    @Test
    func failedNavigationCanRestoreBothStacks() {
        let model = NavigationHistoryFeatureModel()
        let first = location("First.java", line: 1)
        let second = location("Second.java", line: 2)
        model.recordJump(from: first, to: second)
        let snapshot = model.snapshot()

        _ = model.navigateBack(from: second)
        model.restore(snapshot)

        #expect(model.backLocations == [first])
        #expect(model.forwardLocations.isEmpty)
    }

    @Test
    func virtualLocationsKeepTheirOwningProvider() throws {
        let url = try #require(URL(string: "jdt://contents/java.base/java/lang/String.class"))
        let location = EditorNavigationLocation(
            url: url,
            line: 8,
            utf16Column: 4,
            isReadOnly: true,
            displayPath: "java.base/java/lang/String.class",
            virtualProviderID: "java"
        )

        #expect(location.url == url)
        #expect(location.virtualProviderID == "java")
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
