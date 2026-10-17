import AppKit
import SwiftUI

/// IDEA expands the selected tree renderer in place, rather than showing help text.
/// The row owns its hover expansion; automatic cell tooltips do not cover this hosted control.
struct BranchPopupRowView<Label: View>: NSViewRepresentable {
    @Environment(\.self) private var environment
    var isPresented: Bool
    let accessibilityTitle: String
    let onPress: () -> Void
    @ViewBuilder let label: (Bool, Bool) -> Label

    func makeNSView(context: Context) -> BranchPopupRowControl { BranchPopupRowControl() }

    func updateNSView(_ view: BranchPopupRowControl, context: Context) {
        view.onPress = onPress
        view.render = { expanded, highlighted in
            AnyView(Button {} label: { label(expanded, highlighted) }
                .buttonStyle(LitheDropdownRowStyle(isSelected: highlighted, tracksHover: false))
                .fixedSize(horizontal: expanded, vertical: true)
                .environment(\.self, environment)
                .fontWeight(.regular))
        }
        view.update(BranchPopupRowControl.RenderState(title: accessibilityTitle, isPresented: isPresented,
                                                      isEnabled: environment.isEnabled,
                                                      colorScheme: environment.colorScheme))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BranchPopupRowControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? LitheDropdownMetrics.branchMinimumWidth, height: LitheDropdownMetrics.rowHeight)
    }
}

final class BranchPopupRowControl: NSControl {
    /// Representable inputs that change the drawn row. Label closures are rebuilt
    /// on every SwiftUI update and cannot be compared, so the title stands in for
    /// the label content; hover highlight is owned by the control itself.
    struct RenderState: Equatable {
        var title: String
        var isPresented: Bool
        var isEnabled: Bool
        var colorScheme: ColorScheme
    }

    var render: ((Bool, Bool) -> AnyView)?
    var onPress: (() -> Void)?
    var onSecondaryPress: ((NSPoint) -> Void)?
    var isPresented = false
    private var isHovered = false
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private var expansion: NSPanel?
    private var parentCloseObserver: NSObjectProtocol?
    private var hoverTracking: NSTrackingArea?
    private var renderedState: RenderState?
    private var needsDeferredRefresh = false
    private var isDeferredRefreshScheduled = false
    private var deferredRefreshGeneration = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: .zero)
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityChildren([])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// SwiftUI also calls updateNSView from inside a window layout pass, e.g. when
    /// FocusBridge rebuilds the key view loop as the app activates or resigns.
    /// Replacing the hosted root view or resizing the expansion there marks the
    /// window for another constraint pass, and AppKit aborts with
    /// NSGenericException (issue 1277). Unchanged state is ignored; a changed row
    /// in a window renders once on the next run loop turn, after layout finishes.
    func update(_ state: RenderState) {
        if isEnabled != state.isEnabled { isEnabled = state.isEnabled }
        isPresented = state.isPresented
        if accessibilityLabel() != state.title { setAccessibilityLabel(state.title) }
        guard state != renderedState else { return }
        renderedState = state
        // A detached row cannot be part of a window layout pass; rendering it now
        // avoids showing an empty row for a frame when a lazy list inserts it.
        guard window != nil else { refresh(); return }
        needsDeferredRefresh = true
        scheduleDeferredRefresh()
    }

    private func scheduleDeferredRefresh() {
        guard needsDeferredRefresh, window != nil, !isDeferredRefreshScheduled else { return }
        isDeferredRefreshScheduled = true
        let generation = deferredRefreshGeneration
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.deferredRefreshGeneration else { return }
                self.isDeferredRefreshScheduled = false
                guard self.needsDeferredRefresh, self.window != nil else { return }
                self.refresh()
            }
        }
    }

    func refresh() {
        // Event-driven refreshes already render the latest state.
        needsDeferredRefresh = false
        hosting.rootView = render?(false, isHovered || isPresented) ?? AnyView(EmptyView())
        hosting.frame = bounds
        updateExpansion()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
        // Scrolling rebuilds tracking regions without guaranteeing an exit
        // event for the removed region. Reconcile against the stationary pointer.
        let hovered = window.map {
            let point = convert($0.mouseLocationOutsideOfEventStream, from: nil)
            return bounds.contains(point) && visibleRect.contains(point)
        } ?? false
        if isHovered != hovered {
            isHovered = hovered
            refresh()
        } else if expansion != nil {
            updateExpansion()
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; refresh() }
    override func mouseExited(with event: NSEvent) {
        if let window, let expansion,
           expansion.frame.contains(window.convertPoint(toScreen: window.mouseLocationOutsideOfEventStream)) { return }
        isHovered = false
        refresh()
    }
    override func mouseDown(with event: NSEvent) { performClick(nil) }
    override func rightMouseDown(with event: NSEvent) {
        guard let onSecondaryPress else { super.rightMouseDown(with: event); return }
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        closeExpansion()
        onSecondaryPress(point)
    }
    override func performClick(_ sender: Any?) { if isEnabled { closeExpansion(); onPress?() } }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { performClick(nil) }
        else { super.keyDown(with: event) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            closeExpansion()
            // A pending render targets the old window; reschedule after the move.
            deferredRefreshGeneration &+= 1
            isDeferredRefreshScheduled = false
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleDeferredRefresh()
    }

    private func closeExpansion() {
        if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
        parentCloseObserver = nil
        guard let closing = expansion else { return }
        expansion = nil
        closing.parent?.removeChildWindow(closing)
        closing.close()
    }

    private func updateExpansion() {
        guard isHovered, isEnabled, !isPresented, visibleRect.contains(bounds),
              let window, let render else { closeExpansion(); return }
        let content = NSHostingView(rootView: render(true, true))
        content.appearance = effectiveAppearance
        var frame = window.convertToScreen(convert(bounds, to: nil))
        let availableWidth = (window.screen?.visibleFrame.maxX ?? frame.maxX) - frame.minX
        frame.size.width = min(ceil(content.fittingSize.width), availableWidth)
        guard frame.width > bounds.width else { closeExpansion(); return }
        let panel = expansion ?? NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = window.level
        let overlay = BranchPopupExpansionView(frame: NSRect(origin: .zero, size: frame.size))
        content.frame = overlay.bounds
        content.autoresizingMask = [.width, .height]
        overlay.addSubview(content)
        overlay.onPress = { [weak self] in self?.performClick(nil) }
        overlay.onSecondaryPress = { [weak self] point in
            self?.closeExpansion()
            self?.onSecondaryPress?(point)
        }
        overlay.onExit = { [weak self] in self?.isHovered = false; self?.refresh() }
        overlay.onScroll = { [weak self] event in
            guard let self else { return }
            self.isHovered = false
            self.refresh()
            self.scrollWheel(with: event)
        }
        panel.contentView = overlay
        panel.setFrame(frame, display: false)
        if expansion == nil {
            window.addChildWindow(panel, ordered: .above)
            parentCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.closeExpansion() } }
        }
        expansion = panel
        panel.orderFrontRegardless()
    }
}

/// The expansion remains clickable, while its parent popup retains keyboard focus.
private final class BranchPopupExpansionView: NSView {
    var onPress: (() -> Void)?
    var onSecondaryPress: ((NSPoint) -> Void)?
    var onExit: (() -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func rightMouseDown(with event: NSEvent) {
        onSecondaryPress?(event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation)
    }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
}

/// GitIncomingOutgoingUi colors and New UI 12pt assets, Community c7f91397daa3.
struct BranchPopupTrackingCounts: View {
    @Environment(\.colorScheme) private var colorScheme
    let ahead: Int
    let behind: Int

    var body: some View {
        HStack(spacing: 2) {
            if behind > 0 { counter(behind, icon: "changesUpdate@12x12", light: 0x3574F0, dark: 0x548AF7) }
            if ahead > 0 { counter(ahead, icon: "changesPush@12x12", light: 0x369650, dark: 0x57965C) }
        }
        .fixedSize()
    }

    private func counter(_ count: Int, icon: String, light: UInt32, dark: UInt32) -> some View {
        let rgb = colorScheme == .dark ? dark : light
        return HStack(spacing: 1) {
            LitheIDEAIcon(resourcePath: "dvcs/\(icon).svg", size: 12, preservesOriginalColors: true)
            Text(count > 99 ? "99+" : String(count))
                .font(LitheTheme.uiFont(size: LitheDropdownMetrics.shortcutFont.pointSize))
                .foregroundStyle(Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                                       green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255))
        }
    }
}
