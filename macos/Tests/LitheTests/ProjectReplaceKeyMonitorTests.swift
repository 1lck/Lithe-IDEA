import AppKit
import Testing
@testable import Lithe

@Suite("Project replacement keyboard scope")
@MainActor
struct ProjectReplaceKeyMonitorTests {
    @Test
    func onlyConsumesKeysFromTheOwningWindow() throws {
        let session = SearchSessionFeatureModel()
        session.isProjectReplaceVisible = true
        let owner = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        let other = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        let view = ProjectReplaceKeyMonitorView(session: session)
        owner.contentView = view
        defer {
            view.removeFromSuperview()
            view.removeKeyMonitor()
            owner.close()
            other.close()
        }

        func key(_ code: UInt16, _ text: String, in window: NSWindow, command: Bool = false) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: command ? .command : [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code
            ))
        }

        // A second project window must keep its shortcuts and must not dismiss the first window's overlay.
        let otherSave = try key(1, "s", in: other, command: true)
        let otherEscape = try key(53, "\u{1b}", in: other)
        #expect(view.handleKeyEvent(otherSave) === otherSave)
        #expect(view.handleKeyEvent(otherEscape) === otherEscape)
        #expect(session.isProjectReplaceVisible)

        let ownerSave = try key(1, "s", in: owner, command: true)
        let ownerCopy = try key(8, "c", in: owner, command: true)
        let ownerEscape = try key(53, "\u{1b}", in: owner)
        #expect(view.handleKeyEvent(ownerSave) == nil)
        #expect(view.handleKeyEvent(ownerCopy) === ownerCopy)
        #expect(view.handleKeyEvent(ownerEscape) == nil)
        #expect(!session.isProjectReplaceVisible)
        #expect(view.handleKeyEvent(ownerSave) === ownerSave)

        // A detached overlay must no longer consume even its former owner's events.
        session.isProjectReplaceVisible = true
        owner.contentView = nil
        #expect(view.handleKeyEvent(ownerEscape) === ownerEscape)
        #expect(session.isProjectReplaceVisible)
    }
}
