import AppKit
import LitheCoreContracts
import LitheDebugModule
import SwiftUI
import Testing
@testable import Lithe

@Suite("Disassembly layout", .serialized)
@MainActor
struct DebugDisassemblyLayoutTests {
    @Test(arguments: [false, true])
    func shortInstructionsStayAtTheLeadingEdgeAfterRevealAndResize(dark: Bool) async throws {
        try await checkLayout(dark: dark, longInstructions: false)
    }

    @Test(arguments: [false, true])
    func longInstructionsScrollHorizontallyWithoutCenteringTheAddressColumn(dark: Bool) async throws {
        try await checkLayout(dark: dark, longInstructions: true)
    }

    @Test(arguments: [false, true])
    func pagingFailuresStayAtTheLeadingEdge(dark: Bool) async throws {
        try await checkLayout(dark: dark, longInstructions: false, pageFailure: true)
    }

    @Test(arguments: [false, true])
    func scrollingLoadsBothEdgesAndPreservesTheVisibleInstructions(dark: Bool) async throws {
        let session = LayoutDebugSession(longInstructions: false, pages: true)
        let model = GenericDebugDisassemblyModel()
        model.environment = .init(session: { session }, capabilities: { session.capabilities },
                                  selectedFrameID: { 1 }, breakpointsChanged: { _, _ in })
        model.frameSelected(frame(at: 40))
        defer { model.invalidate(); session.stop() }
        let host = NSHostingView(rootView: GenericDebugDisassemblyView(disassembly: model, readMemory: { _ in })
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 320),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        #expect(await settled(host) { descendants(host).contains { $0 is NSScrollView } })
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        #expect(await settled(host) { scroll.contentView.bounds.minY > 0 })
        #expect(session.pageRequests == 0, "Initial instruction reveal must not page to exhaustion")

        // Cross the upper threshold through the real clip view, without pressing a button.
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 120))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(await settled(host) { session.pageRequests == 1 })
        #expect(model.isLoading)
        #expect(await settled(host) { abs(scroll.contentView.bounds.minY - 120) < 1 })
        let before = scroll.contentView.bounds.minY
        let oldHeight = try #require(scroll.documentView).bounds.height
        session.completePage()
        #expect(await settled(host) { model.rows.count == 160 && abs(scroll.contentView.bounds.minY - before - 1280) < 1 },
                "Prepending 64 instructions preserves the old visible row's pixel position, including a shared symbol heading")
        #expect(abs(try #require(scroll.documentView).bounds.height - oldHeight - 1280) < 1)
        #expect(session.pageRequests == 1)

        let bottom = try #require(scroll.documentView).bounds.height - scroll.contentView.bounds.height - 80
        scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(await settled(host) { session.pageRequests == 2 })
        session.completePage()
        #expect(await settled(host) { model.rows.count == 224 && abs(scroll.contentView.bounds.minY - bottom) < 1 },
                "Appending must not reveal the old instruction pointer or move the viewport")
        #expect(session.pageRequests == 2)
    }

    @Test
    func aShortPageCanLoadFromWheelIntentWithoutClipMovement() async throws {
        let session = LayoutDebugSession(longInstructions: false, pages: true)
        session.initialRows = 2
        let model = GenericDebugDisassemblyModel()
        model.environment = .init(session: { session }, capabilities: { session.capabilities },
                                  selectedFrameID: { 1 }, breakpointsChanged: { _, _ in })
        model.frameSelected(frame(at: 1))
        defer { model.invalidate(); session.stop() }
        let host = NSHostingView(rootView: GenericDebugDisassemblyView(disassembly: model, readMemory: { _ in }))
        let window = DisassemblyWheelWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 320),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        #expect(await settled(host) { descendants(host).contains { $0 is NSScrollView } })
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        #expect(await settled(host) { scroll.documentView?.bounds.height ?? 0 > 0 })
        #expect(session.pageRequests == 0)
        let wheel = try #require(DisassemblyWheelEvent(target: window,
            point: host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)))
        // Route through NSApplication so the production local wheel monitor sees the event.
        NSApplication.shared.sendEvent(wheel)
        #expect(await settled(host) { session.pageRequests == 1 },
                "A non-overflowing page still loads in the user's scroll direction")
    }

    private func checkLayout(dark: Bool, longInstructions: Bool, pageFailure: Bool = false) async throws {
        let app = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let enhanced = (app.accessibilityAttributeValue(attribute) as? Bool) ?? false
        app.accessibilitySetValue(true, forAttribute: attribute)
        defer { app.accessibilitySetValue(enhanced, forAttribute: attribute) }
        let session = LayoutDebugSession(longInstructions: longInstructions, pages: pageFailure)
        let model = GenericDebugDisassemblyModel()
        model.environment = .init(session: { session }, capabilities: { session.capabilities },
                                  selectedFrameID: { 1 }, breakpointsChanged: { _, _ in })
        model.frameSelected(frame(at: 40))
        defer { model.invalidate(); session.stop() }

        let host = NSHostingView(rootView: GenericDebugDisassemblyView(disassembly: model, readMemory: { _ in })
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(x: 0, y: 0, width: longInstructions ? 500 : 1400, height: 320)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        let address = session.instructions[40].address
        #expect(await settled(host) { textFrame(address, in: host) != nil }, "Current instruction must be rendered")
        let viewport = window.convertToScreen(host.convert(host.bounds, to: nil))
        let initial = try #require(textFrame(address, in: host))
        #expect(abs(initial.minX - viewport.minX - 32) < 2,
                "The address follows the 22pt gutter and 10pt gap, not a centered content block: \(initial)")
        #expect(abs(initial.midY - (viewport.midY - LitheTheme.Debugger.inspectorHeaderHeight / 2)) < 24,
                "Revealing the instruction must still center it vertically")

        // A step within the existing listing must not move the address column.
        model.frameSelected(frame(at: 41), preservingView: true)
        #expect(await settled(host) { textFrame(session.instructions[41].address, in: host) != nil })
        let stepped = try #require(textFrame(session.instructions[41].address, in: host))
        #expect(abs(stepped.minX - initial.minX) < 1)

        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        if longInstructions {
            #expect(document.bounds.width > scroll.contentView.bounds.width + 100,
                    "Long instructions must retain their natural width and horizontal scrolling")
            var origin = scroll.contentView.bounds.origin
            origin.x = 100
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            model.frameSelected(frame(at: 42), preservingView: true)
            #expect(await settled(host) { textFrame(session.instructions[42].address, in: host) != nil })
            #expect(abs(scroll.contentView.bounds.minX - 100) < 1,
                    "Instruction stepping must preserve a manually chosen horizontal offset")
        } else {
            #expect(abs(scroll.contentView.bounds.minX) < 1)
            window.setContentSize(NSSize(width: 900, height: 320))
            #expect(await settled(host) { abs(host.bounds.width - 900) < 1 })
            let resized = try #require(textFrame(session.instructions[41].address, in: host))
            let resizedViewport = window.convertToScreen(host.convert(host.bounds, to: nil))
            #expect(abs(resized.minX - resizedViewport.minX - 32) < 2,
                    "Resizing must not recenter a short instruction listing")
        }
        if pageFailure {
            model.loadMore(.before, automatically: true)
            let failure = DebugAdapterProtocolError.timedOut("disassemble")
            session.failPage(failure)
            #expect(await settled(host) { textFrame(failure.localizedDescription, in: host) != nil })
            let errorFrame = try #require(textFrame(failure.localizedDescription, in: host))
            let errorViewport = window.convertToScreen(host.convert(host.bounds, to: nil))
            #expect(abs(errorFrame.minX - errorViewport.minX - 10) < 2,
                    "A real paging error aligns with the panel's leading inset, not its center")
        }
    }

    private func frame(at index: Int) -> DebugStackFrame {
        .init(id: 1, name: "main", sourceURL: nil, line: 0, column: 0,
              instructionPointerReference: "0x" + String(0x1000 + index * 4, radix: 16))
    }

    // SwiftUI exposes rendered text and native clip geometry only after a layout pass.
    // Poll those observable boundaries with a local deadline instead of sleeping.
    private func settled(_ host: NSView, until predicate: () -> Bool) async -> Bool {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            if predicate() { return true }
        } while clock.now < deadline
        return predicate()
    }

    private func textFrame(_ text: String, in value: Any) -> NSRect? {
        let item = value as AnyObject
        let string: String? = item.accessibilityValue?()
        if string == text || item.accessibilityLabel?() == text {
            return item.accessibilityFrame?()
        }
        return (item.accessibilityChildren?() ?? []).lazy.compactMap { textFrame(text, in: $0) }.first
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

private final class DisassemblyWheelWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        // This case exercises the local monitor at a non-scrolling boundary. AppKit's
        // private scrolling machinery requires a WindowServer-produced event, so stop
        // the synthetic event after NSApplication has delivered it to real monitors.
        if event.type != .scrollWheel { super.sendEvent(event) }
    }
}

// Isolated native test windows are absent from WindowServer hit testing, so supply
// the event's target explicitly while retaining NSApplication's real event routing.
private final class DisassemblyWheelEvent: NSEvent {
    private let target: NSWindow
    private let targetNumber: Int
    private let point: NSPoint
    private let backingEvent: CGEvent
    @MainActor
    init?(target: NSWindow, point: NSPoint) {
        self.target = target
        targetNumber = target.windowNumber
        self.point = point
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: -40, wheel2: 0, wheel3: 0) else { return nil }
        backingEvent = event
        super.init()
    }
    required init?(coder: NSCoder) { nil }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var windowNumber: Int { targetNumber }
    override var cgEvent: CGEvent? { backingEvent }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaY: CGFloat { -40 }
    override var deltaY: CGFloat { -40 }
}

@MainActor
private final class LayoutDebugSession: DebugAdapterControllingSession {
    let capabilities = DebugAdapterCapabilities(negotiated: true, supportsDisassembleRequest: true)
    let instructions: [DebugDisassembledInstruction]
    var isRunning = true
    var state: DebugAdapterState { .paused }
    var onStateChange: ((DebugAdapterState) -> Void)?
    var onEvent: ((DebugAdapterEvent) -> Void)?
    private let pages: Bool
    private var pendingPage: ((Error?) -> Void)?
    private(set) var pageRequests = 0
    private var didLoad = false
    var initialRows = 96

    init(longInstructions: Bool, pages: Bool = false) {
        self.pages = pages
        instructions = (0..<96).map { index in
            .init(address: "0x" + String(0x1000 + index * 4, radix: 16), instructionBytes: "1f 20 03 d5",
                  instruction: longInstructions ? "bl symbol_" + String(repeating: "long_name_", count: 30) : "nop",
                  symbol: pages ? "main" : nil, sourceURL: nil, line: nil)
        }
    }

    func start(rootURL: URL) throws { isRunning = true }
    func stop() { isRunning = false; pendingPage = nil }
    func completePage() { let page = pendingPage; pendingPage = nil; page?(nil) }
    func failPage(_ error: Error) { let page = pendingPage; pendingPage = nil; page?(error) }
    func launch(_ configuration: DebugLaunchConfiguration) throws {}
    func setBreakpoints(_ breakpoints: [DebugSourceBreakpoint], in fileURL: URL) {}
    func execute(_ command: DebugExecutionCommand, threadID: Int?) {}
    func requestDisassembly(memoryReference: String, instructionOffset: Int, instructionCount: Int,
                            completion: @escaping (Result<[DebugDisassembledInstruction], Error>) -> Void) {
        guard pages, didLoad else {
            didLoad = true
            completion(.success(Array(instructions.prefix(initialRows))))
            return
        }
        pageRequests += 1
        let reference = Int(memoryReference.dropFirst(2), radix: 16) ?? 0
        let rows = (0..<instructionCount).map { index in
            DebugDisassembledInstruction(address: "0x" + String(reference + (instructionOffset + index) * 4, radix: 16),
                instructionBytes: "1f 20 03 d5", instruction: "nop", symbol: "main", sourceURL: nil, line: nil)
        }
        pendingPage = { error in
            if let error { completion(.failure(error)) }
            else { completion(.success(rows)) }
        }
    }
    func requestThreads(_ completion: @escaping (Result<[DebugThread], Error>) -> Void) { completion(.success([])) }
    func requestStackTrace(threadID: Int, completion: @escaping (Result<[DebugStackFrame], Error>) -> Void) { completion(.success([])) }
    func requestScopes(frameID: Int, completion: @escaping (Result<[DebugScope], Error>) -> Void) { completion(.success([])) }
    func requestVariables(reference: Int, completion: @escaping (Result<[DebugVariable], Error>) -> Void) { completion(.success([])) }
    func evaluate(_ expression: String, frameID: Int?, completion: @escaping (Result<DebugVariable, Error>) -> Void) {
        completion(.failure(DebugAdapterCapabilityError.unsupported("evaluation")))
    }
}
