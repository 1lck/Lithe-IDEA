import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Lithe

@Suite("Output Copy cursor ownership")
@MainActor
struct OutputCopyCursorTests {
    @Test(arguments: [false, true])
    func databaseTextAndCopyIgnoreLateEventsOverDivider(editable: Bool) throws {
        let previousCursor = NSCursor.current
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { previousCursor.set(); window.contentView = nil; window.close() }
        let content = try #require(window.contentView)
        let output = OutputNativeTextView(frame: NSRect(x: 0, y: 0, width: 160, height: 240))
        output.isEditable = false; output.isSelectable = true; output.string = "output"
        let console = SQLTextView(frame: NSRect(x: 180, y: 0, width: 180, height: 240))
        console.isEditable = editable; console.string = "select 1;"
        let copy = OutputCopyButtonHost(rootView: AnyView(Button("Copy") {}))
        copy.frame = NSRect(x: 100, y: 200, width: 50, height: 22)
        let handle = SplitHandleInteractionView(frame: NSRect(x: 160, y: 0, width: 10, height: 240))
        for view in [output, console, copy, handle] { content.addSubview(view) }
        output.copyButtonView = copy
        let point = NSPoint(x: 165, y: 120)
        #expect(content.hitTest(point) === handle)
        func tracking(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        }
        let cursor = try tracking(.cursorUpdate, at: point)
        let entered = try tracking(.mouseEntered, at: point)
        let exited = try tracking(.mouseExited, at: point)
        let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        for view in [output, console, copy] {
            for event in [cursor, entered, moved, exited] {
                handle.cursorUpdate(with: cursor)
                switch event.type {
                case .cursorUpdate: view.cursorUpdate(with: event)
                case .mouseEntered: view.mouseEntered(with: event)
                case .mouseExited: view.mouseExited(with: event)
                default: view.mouseMoved(with: event)
                }
                #expect(NSCursor.current === NSCursor.resizeLeftRight)
            }
        }
        // Normal body tracking still supplies the native text cursor (or the read-only preview arrow).
        output.cursorUpdate(with: try tracking(.cursorUpdate, at: NSPoint(x: 20, y: 120)))
        #expect(NSCursor.current === NSCursor.iBeam)
        console.cursorUpdate(with: try tracking(.cursorUpdate, at: NSPoint(x: 200, y: 120)))
        #expect(NSCursor.current === (editable ? NSCursor.iBeam : NSCursor.arrow))
        copy.cursorUpdate(with: try tracking(.cursorUpdate, at: NSPoint(x: 125, y: 211)))
        #expect(NSCursor.current === NSCursor.arrow)
        content.subviews.forEach { $0.removeFromSuperview() }
        NSCursor.resizeLeftRight.set()
        output.cursorUpdate(with: cursor); console.cursorUpdate(with: cursor); copy.cursorUpdate(with: cursor)
        #expect(NSCursor.current === NSCursor.resizeLeftRight)
    }

    @Test(arguments: [false, true])
    func copyExcludesNativeTextHitsAndCursorRectsAcrossResize(dark: Bool) throws {
        let host = NSHostingView(rootView: OutputTextView(output: "select * from customers;", searchRoots: [], fileExists: { _ in false },
            emptyMessage: "", onOpenLocation: { _, _, _ in }).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { NSCursor.arrow.set(); window.contentView = nil; window.close() }
        window.contentView = host; host.layoutSubtreeIfNeeded()
        func scroll(_ view: NSView) -> OutputNativeScrollView? {
            if let output = view as? OutputNativeScrollView { return output }
            return view.subviews.lazy.compactMap { scroll($0) }.first
        }
        let output = try #require(scroll(host))
        let text = try #require(output.documentView as? OutputNativeTextView)
        let button = try #require(output.copyButtonHost)
        for width in [520.0, 360.0] {
            window.setContentSize(NSSize(width: width, height: 240)); host.layoutSubtreeIfNeeded()
            let rect = try #require(text.copyButtonRect)
            try #require(rect.width == LitheTheme.Metrics.toolbarIconButtonSize && rect.height == LitheTheme.Metrics.toolbarIconButtonSize)
            let cursorRects = text.textCursorRects(text.visibleRect)
            #expect(cursorRects.allSatisfy { !$0.intersects(rect) })
            #expect(abs(cursorRects.reduce(0) { $0 + $1.width * $1.height } + rect.intersection(text.visibleRect).width * rect.intersection(text.visibleRect).height
                - text.visibleRect.width * text.visibleRect.height) < 0.01)
            // Icon and padding belong to Copy; a stale cursor-update event from NSTextView must also restore the arrow.
            for x in [button.bounds.minX + 2, button.bounds.midX, button.bounds.maxX - 2] {
                let point = NSPoint(x: x, y: button.bounds.midY)
                let hit = try #require(output.hitTest(button.convert(point, to: output.superview)))
                #expect(hit === button || hit.isDescendant(of: button))
                #expect(hit !== text)
                let windowHit = try #require(host.hitTest(button.convert(point, to: host.superview)))
                #expect(windowHit === button || windowHit.isDescendant(of: button))
                let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: button.convert(point, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
                let cursor = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: event.locationInWindow,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, trackingNumber: 0, userData: nil))
                NSCursor.iBeam.set(); text.cursorUpdate(with: cursor)
                #expect(NSCursor.current === NSCursor.arrow)
                NSCursor.iBeam.set(); button.cursorUpdate(with: cursor)
                #expect(NSCursor.current === NSCursor.arrow)
                NSCursor.iBeam.set(); button.mouseMoved(with: event)
                #expect(NSCursor.current === NSCursor.arrow)
                NSCursor.iBeam.set(); text.mouseMoved(with: event)
                #expect(NSCursor.current === NSCursor.arrow)
            }
            let bodyPoint = NSPoint(x: 20, y: text.visibleRect.midY)
            #expect(cursorRects.contains { $0.contains(bodyPoint) })
            #expect(output.hitTest(text.convert(bodyPoint, to: output.superview)) === text)
        }
    }
}

@Suite("Output timestamping")
struct OutputTimestamperTests {
    private let noon = Date(timeIntervalSince1970: 0)

    /// Maven's `[INFO]` lines carry no clock, which is exactly the output that
    /// leaves "when did this stall" unanswerable.
    @Test
    func stampsLinesThatHaveNoClockOfTheirOwn() {
        let stamped = OutputTimestamper.stamped(
            "[INFO] Building backend-api\n[ERROR] Port in use\n",
            continuingLine: false,
            now: noon
        )
        let lines = stamped.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0].hasSuffix("[INFO] Building backend-api"))
        #expect(lines[1].hasSuffix("[ERROR] Port in use"))
        #expect(OutputTimestamper.hasLeadingTime(String(lines[0])))
        #expect(OutputTimestamper.hasLeadingTime(String(lines[1])))
    }

    /// Spring Boot prints its own timestamp; a second one would just be noise.
    @Test
    func leavesLinesThatAlreadyCarryATimestampAlone() {
        let line = "2026-08-08T10:12:33.123  INFO 1 --- [main] Started App"
        let stamped = OutputTimestamper.stamped(line + "\n", continuingLine: false, now: noon)
        #expect(stamped == line + "\n")
    }

    /// A chunk boundary can land mid-line. Stamping there would inject a clock
    /// into the middle of a message.
    @Test
    func doesNotStampAContinuationOfAPartialLine() {
        let stamped = OutputTimestamper.stamped("rest of message\n", continuingLine: true, now: noon)
        #expect(stamped == "rest of message\n")
    }

    /// A chunk that ends without a newline must not gain one, or the next
    /// chunk's continuation would be pushed onto its own line.
    @Test
    func preservesWhetherTheChunkEndedWithANewline() {
        let stamped = OutputTimestamper.stamped("partial", continuingLine: false, now: noon)
        #expect(!stamped.hasSuffix("\n"))
        #expect(stamped.hasSuffix("partial"))
    }

    @Test
    func doesNotStampBlankLines() {
        let stamped = OutputTimestamper.stamped("\n\n", continuingLine: false, now: noon)
        #expect(stamped == "\n\n")
    }

    /// The dimmed gutter has to cover the fractional seconds too, otherwise the
    /// milliseconds stay bright while the hours recede.
    @Test
    func measuresTheWholeClockIncludingFractionalSeconds() throws {
        let length = try #require(
            OutputTimestamper.leadingTimeLength(of: "10:12:33.123 [INFO] hello")
        )
        #expect(length == "10:12:33.123 ".count)
    }

    @Test
    func reportsNoClockForAPlainLine() {
        #expect(OutputTimestamper.leadingTimeLength(of: "[INFO] hello") == nil)
    }
}

@Suite("ANSI output colors")
@MainActor
struct ANSIOutputColorTests {
    /// Maven commonly emits bold/reset SGR codes without choosing a foreground
    /// color. The fallback must be resolved for the tool window's appearance;
    /// leaving it as an adaptive SwiftUI color turns it black when bridged into
    /// an AppKit text storage under the dark theme.
    @Test
    func darkAppearanceResolvesDefaultForegroundBeforeAppKitBridging() throws {
        let foreground = LitheTheme.nsColor(.primaryText, theme: .lithe, isDark: true)
        let parsed = ANSIOutputRenderer.parse(
            "\u{1B}[1m[INFO] Building\u{1B}[0m\n",
            defaultForeground: foreground
        )
        let rendered = ANSIOutputRenderer.render(parsed, fontSize: 11.5)
        let color = try #require(
            (rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?
                .usingColorSpace(.sRGB)
        )

        #expect(color.brightnessComponent > 0.75)
    }
}

@Suite("Output text updates")
struct OutputTextUpdateTests {
    @Test
    func appendsOnlyTheNewCompleteLines() {
        #expect(
            OutputTextUpdate.plan(
                previous: "first\n",
                next: "first\nsecond\n",
                previousHadANSI: false
            ) == .append("second\n")
        )
    }

    @Test
    func leavesUnchangedOutputAlone() {
        #expect(
            OutputTextUpdate.plan(previous: "same", next: "same", previousHadANSI: false) == .unchanged
        )
    }

    @Test
    func replacesTruncatedOrRewrittenOutput() {
        #expect(OutputTextUpdate.plan(previous: "old\n", next: "new\n", previousHadANSI: false) == .replace)
        #expect(OutputTextUpdate.plan(previous: "old\nline\n", next: "line\n", previousHadANSI: false) == .replace)
    }

    @Test
    func trimsOnlyTheExpiredPrefixOfALargeSlidingWindow() {
        let removed = "expired 🙂\n"
        let retained = String(repeating: "retained line\n", count: 400)

        #expect(
            OutputTextUpdate.plan(
                previous: removed + retained,
                next: retained + "new tail\n",
                previousHadANSI: false
            ) == .trimPrefix(length: removed.utf16.count, append: "new tail\n")
        )
    }

    @Test
    func rerendersAnIncompleteTailWhileTrimmingASlidingWindow() {
        let removed = "expired\n"
        let completeLines = String(repeating: "retained line\n", count: 400)
        let incompleteTail = "at example.Main.main(Main."
        let retained = completeLines + incompleteTail

        #expect(
            OutputTextUpdate.plan(
                previous: removed + retained,
                next: retained + "java:42)\n",
                previousHadANSI: false
            ) == .trimPrefixAndReplaceTail(
                prefixLength: removed.utf16.count,
                tailLength: incompleteTail.utf16.count,
                with: "at example.Main.main(Main.java:42)\n"
            )
        )
    }

    @Test
    func redrawsOnlyTheIncompleteTrailingLine() {
        #expect(
            OutputTextUpdate.plan(
                previous: "complete\npartial",
                next: "complete\npartial line\n",
                previousHadANSI: false
            ) == .replaceTail(length: 7, with: "partial line\n")
        )
    }

    @Test
    func replacesWhenANSIStateCouldCrossTheBoundary() {
        #expect(OutputTextUpdate.plan(previous: "\u{1B}[31mred\n", next: "\u{1B}[31mred\nmore\n", previousHadANSI: true) == .replace)
    }
}
