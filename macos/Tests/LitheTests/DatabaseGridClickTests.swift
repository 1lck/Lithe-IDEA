import AppKit
import Testing
@testable import Lithe

@MainActor
struct DatabaseGridClickTests {
    @Test
    func selectionIsDeliveredOnMouseDownWithoutWaitingForMouseUpOrSecondClick() throws {
        let view = DatabaseGridCellClickView()
        var clickCounts: [Int] = []
        view.onMouseDown = { clickCounts.append($0) }
        func event(_ type: NSEvent.EventType, count: Int, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: modifiers,
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           eventNumber: 0, clickCount: count, pressure: 1))
        }
        // No run-loop advance, mouse-up, timer or second click is needed for selection.
        view.mouseDown(with: try event(.leftMouseDown, count: 1))
        #expect(clickCounts == [1])
        view.mouseDown(with: try event(.leftMouseDown, count: 2))
        #expect(clickCounts == [1, 2])
        // Context-menu events remain owned by the existing right-click presenter.
        view.mouseDown(with: try event(.rightMouseDown, count: 1))
        view.mouseDown(with: try event(.leftMouseDown, count: 1, modifiers: .control))
        #expect(clickCounts == [1, 2])
    }
}
