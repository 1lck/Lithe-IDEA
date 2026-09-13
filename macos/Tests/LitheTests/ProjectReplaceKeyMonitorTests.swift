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

    @Test
    func preservesNativeTextCommandsWithoutAllowingWorkbenchVariants() throws {
        let session = SearchSessionFeatureModel()
        session.isProjectReplaceVisible = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let monitor = ProjectReplaceKeyMonitorView(session: session)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        // SwiftUI text fields use an NSTextView field editor as their first responder.
        editor.isFieldEditor = true
        window.contentView = monitor
        monitor.addSubview(editor)
        defer { monitor.removeKeyMonitor(); window.contentView = nil; window.close() }
        #expect(window.makeFirstResponder(editor))
        func key(_ code: UInt16, _ text: String = "", _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        for code: UInt16 in [123, 124, 125, 126, 51, 117] {
            for flags: NSEvent.ModifierFlags in [.command, [.command, .shift]] {
                let event = try key(code, "", flags.union([.function, .numericPad, .capsLock]))
                #expect(monitor.handleKeyEvent(event) === event)
            }
        }
        for (code, text, flags): (UInt16, String, NSEvent.ModifierFlags) in [
            (0, "a", .command), (8, "c", .command), (9, "v", .command),
            (7, "x", .command), (6, "z", .command), (6, "z", [.command, .shift]),
            (9, "v", [.command, .option, .shift])
        ] {
            let event = try key(code, text, flags)
            #expect(monitor.handleKeyEvent(event) === event)
        }
        for (code, text, flags): (UInt16, String, NSEvent.ModifierFlags) in [
            (1, "s", .command), (3, "f", .command), (13, "w", .command),
            (8, "c", [.command, .shift]), (0, "a", [.command, .shift]),
            (123, "", [.command, .option])
        ] {
            #expect(monitor.handleKeyEvent(try key(code, text, flags)) == nil)
        }
        #expect(window.makeFirstResponder(nil))
        #expect(monitor.handleKeyEvent(try key(123, "", .command)) == nil)
        #expect(session.isProjectReplaceVisible)
    }

    @Test
    func escapeCancelsCompositionBeforeDismissingDialog() throws {
        let session = SearchSessionFeatureModel()
        session.isProjectReplaceVisible = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let monitor = ProjectReplaceKeyMonitorView(session: session)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        editor.isFieldEditor = true
        window.contentView = monitor
        monitor.addSubview(editor)
        defer { editor.unmarkText(); monitor.removeKeyMonitor(); window.contentView = nil; window.close() }
        #expect(window.makeFirstResponder(editor))
        editor.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(monitor.handleKeyEvent(escape) === escape)
        #expect(session.isProjectReplaceVisible)
        // Simulate the native input client ending composition, then press Escape again.
        editor.unmarkText()
        #expect(monitor.handleKeyEvent(escape) == nil)
        #expect(!session.isProjectReplaceVisible)
    }

}
