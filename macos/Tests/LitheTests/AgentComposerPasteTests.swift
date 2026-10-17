import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Agent composer paste ownership", .serialized)
struct AgentComposerPasteTests {
    @Test
    func attachmentPasteBelongsOnlyToTheEditingFieldAndEventWindow() throws {
        var attached = [AgentPasteboardAttachment]()
        let host = NSHostingView(rootView: HStack(spacing: 20) {
            LitheSearchTextField("Agent", text: .constant(""), axis: .vertical)
                .background(AgentPasteAttachments(isActive: true, onPaste: { attached.append($0); return true }))
                .frame(width: 180)
            LitheSearchTextField("Other", text: .constant(""), axis: .vertical).frame(width: 180)
        }.frame(width: 380, height: 80))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 80),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        otherWindow.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
            otherWindow.close()
        }
        host.layoutSubtreeIfNeeded()
        func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
        }
        let fields = descendants(host, of: NSTextField.self).sorted {
            $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX
        }
        #expect(fields.count == 2)
        let field = try #require(fields.first)
        let otherField = try #require(fields.last)
        let monitor = try #require(descendants(host, of: AgentPasteAttachmentView.self).first)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let file = URL(fileURLWithPath: "/tmp/Agent paste ownership.png")
        #expect(pasteboard.writeObjects([file as NSURL]))
        func paste(in target: NSWindow, flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: target.windowNumber, context: nil,
                characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        }
        let ownEvent = try paste(in: window)
        #expect(window.makeFirstResponder(field))
        #expect(monitor.handle(ownEvent, pasteboard: pasteboard) == nil)
        #expect(attached == [.files([file])])

        // SwiftUI focus may still be true in a background window.
        let foreignEvent = try paste(in: otherWindow)
        #expect(monitor.handle(foreignEvent, pasteboard: pasteboard) === foreignEvent)
        #expect(attached.count == 1)

        // The window field editor is shared; its current geometry identifies the owner.
        #expect(window.makeFirstResponder(otherField))
        #expect(monitor.handle(ownEvent, pasteboard: pasteboard) === ownEvent)
        #expect(attached.count == 1)
        #expect(window.makeFirstResponder(field))
        let shiftedEvent = try paste(in: window, flags: [.command, .shift])
        #expect(monitor.handle(shiftedEvent, pasteboard: pasteboard) === shiftedEvent)
        #expect(attached.count == 1)

        pasteboard.clearContents()
        pasteboard.setString("ordinary text", forType: .string)
        #expect(monitor.handle(ownEvent, pasteboard: pasteboard) === ownEvent)
        #expect(attached.count == 1)

        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([file as NSURL]))
        let capsLockEvent = try paste(in: window, flags: [.command, .capsLock])
        #expect(monitor.handle(capsLockEvent, pasteboard: pasteboard) == nil)
        #expect(attached.count == 2)
        monitor.onPaste = { _ in false }
        #expect(monitor.handle(ownEvent, pasteboard: pasteboard) === ownEvent)
        monitor.onPaste = nil
        #expect(monitor.handle(ownEvent, pasteboard: pasteboard) === ownEvent)
    }
}
