import AppKit
import SwiftUI

/// IDEA expands the selected tree renderer in place, rather than showing help text.
/// The row is drawn inline by SwiftUI; a transparent AppKit control on top owns
/// hover, clicks, accessibility and the hover expansion. Hosting every row in its
/// own NSHostingView made each row that scrolled into a lazy list pay for a new
/// hosting graph, which is what made long branch lists stutter.
struct BranchPopupRowView<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    var isPresented: Bool
    let accessibilityTitle: String
    /// Label inputs that the accessibility title does not already describe.
    var contentKey: AnyHashable = 0
    let onPress: () -> Void
    @ViewBuilder let label: (Bool, Bool) -> Label

    var body: some View {
        row(expanded: false, highlighted: isHovered || isPresented)
            .overlay(BranchPopupRowTracker(isPresented: isPresented, isEnabled: isEnabled,
                                           accessibilityTitle: accessibilityTitle, contentKey: contentKey,
                                           onPress: onPress, onHoverChange: { isHovered = $0 }) {
                row(expanded: true, highlighted: true)
            })
    }

    private func row(expanded: Bool, highlighted: Bool) -> some View {
        Button {} label: { label(expanded, highlighted) }
            .buttonStyle(LitheDropdownRowStyle(isSelected: highlighted, tracksHover: false))
            .fixedSize(horizontal: expanded, vertical: true)
            .fontWeight(.regular)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// AppKit half of a hover-expanding row. It draws nothing itself: the row below
/// renders `highlighted` from `onHoverChange`, and `expansion` is hosted only
/// while the pointer rests on a clipped row.
struct BranchPopupRowTracker<Expansion: View>: NSViewRepresentable {
    @Environment(\.self) private var environment
    var isPresented: Bool
    var isEnabled: Bool
    let accessibilityTitle: String
    var contentKey: AnyHashable
    let onPress: () -> Void
    var onSecondaryPress: ((NSView, NSPoint) -> Void)?
    let onHoverChange: (Bool) -> Void
    @ViewBuilder let expansion: () -> Expansion

    func makeNSView(context: Context) -> BranchPopupRowControl { BranchPopupRowControl() }

    func updateNSView(_ view: BranchPopupRowControl, context: Context) {
        view.onPress = onPress
        view.onSecondaryPress = onSecondaryPress.map { handler in
            { [weak view] point in if let view { handler(view, point) } }
        }
        view.onHoverChange = onHoverChange
        view.renderExpansion = { AnyView(expansion().environment(\.self, environment)) }
        view.update(BranchPopupRowControl.RenderState(title: accessibilityTitle, content: contentKey,
                                                      isPresented: isPresented, isEnabled: isEnabled,
                                                      environment: environment))
    }
}

final class BranchPopupRowControl: NSControl {
    /// Representable inputs that change the expansion. Label closures are rebuilt
    /// on every SwiftUI update and cannot be compared, so callers describe the
    /// label with its title plus a content key.
    struct RenderState: Equatable {
        var title: String
        var content: AnyHashable
        var isPresented: Bool
        var isEnabled: Bool
        var colorScheme: ColorScheme
        var locale: Locale
        var dynamicTypeSize: DynamicTypeSize

        init(title: String, content: AnyHashable, isPresented: Bool, isEnabled: Bool,
             environment: EnvironmentValues) {
            self.title = title
            self.content = content
            self.isPresented = isPresented
            self.isEnabled = isEnabled
            colorScheme = environment.colorScheme
            locale = environment.locale
            dynamicTypeSize = environment.dynamicTypeSize
        }
    }

    var renderExpansion: (() -> AnyView)?
    /// Reports the pointer hover the row below should highlight.
    var onHoverChange: ((Bool) -> Void)?
    var onPress: (() -> Void)?
    var onSecondaryPress: ((NSPoint) -> Void)?
    var isPresented = false
    private var isHovered = false
    private var reportedHover = false
    private var expansion: NSPanel?
    private var parentCloseObserver: NSObjectProtocol?
    private var hoverTracking: NSTrackingArea?
    private var renderedState: RenderState?
    /// The state and fitted width the open expansion was built from. Tracking
    /// rebuilds only move it; re-hosting unchanged content wastes a SwiftUI pass.
    private var expansionContent: (state: RenderState, width: CGFloat)?
    /// Set while hover or expansion is stale; cleared by every refresh.
    private var needsDeferredRefresh = false
    private var pendingRefresh: DispatchWorkItem?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// SwiftUI also calls updateNSView from inside a window layout pass, e.g. when
    /// FocusBridge rebuilds the key view loop as the app activates or resigns.
    /// Hosting or resizing the expansion, or publishing hover back into SwiftUI,
    /// on every such pass keeps marking the window for another constraint pass,
    /// and AppKit aborts with NSGenericException (issue 1277). Unchanged state is
    /// ignored; a changed row in a window refreshes once on the next run loop turn.
    func update(_ state: RenderState) {
        if isEnabled != state.isEnabled { isEnabled = state.isEnabled }
        isPresented = state.isPresented
        if accessibilityLabel() != state.title { setAccessibilityLabel(state.title) }
        // Child-window removal does not touch the parent's layout, and a disabled
        // or presented row must not leave a clickable expansion for one more turn.
        if !state.isEnabled || state.isPresented { closeExpansion() }
        guard state != renderedState else { return }
        renderedState = state
        // A fresh row is not hovered and has no expansion, so it has nothing to
        // refresh; the row content itself is already drawn by SwiftUI.
        guard isHovered || expansion != nil else { return }
        setNeedsDeferredRefresh()
    }

    /// Coalesces hover and representable changes raised during layout into one
    /// refresh after the current pass.
    private func setNeedsDeferredRefresh() {
        needsDeferredRefresh = true
        guard pendingRefresh == nil, window != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingRefresh = nil
                if self.needsDeferredRefresh, self.window != nil { self.refresh() }
            }
        }
        pendingRefresh = work
        DispatchQueue.main.async(execute: work)
    }

    func refresh() {
        // Event-driven refreshes already apply the latest state.
        needsDeferredRefresh = false
        pendingRefresh?.cancel()
        pendingRefresh = nil
        if reportedHover != isHovered {
            reportedHover = isHovered
            onHoverChange?(isHovered)
        }
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
        // AppKit rebuilds tracking areas while it lays out the window, so the
        // hover transfer and expansion reposition wait for the pass to finish.
        if isHovered != hovered {
            isHovered = hovered
            setNeedsDeferredRefresh()
        } else if expansion != nil {
            setNeedsDeferredRefresh()
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
            // A pending refresh targets the old window; reschedule after the move.
            pendingRefresh?.cancel()
            pendingRefresh = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if needsDeferredRefresh { setNeedsDeferredRefresh() }
    }

    private func closeExpansion() {
        if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
        parentCloseObserver = nil
        expansionContent = nil
        guard let closing = expansion else { return }
        expansion = nil
        closing.parent?.removeChildWindow(closing)
        closing.close()
    }

    private func updateExpansion() {
        guard isHovered, isEnabled, !isPresented, visibleRect.contains(bounds),
              let window, let renderExpansion else { closeExpansion(); return }
        if let expansion, let renderedState, let built = expansionContent, built.state == renderedState {
            var frame = window.convertToScreen(convert(bounds, to: nil))
            let availableWidth = (window.screen?.visibleFrame.maxX ?? frame.maxX) - frame.minX
            frame.size.width = min(built.width, availableWidth)
            guard frame.width > bounds.width else { closeExpansion(); return }
            expansion.setFrame(frame, display: false)
            expansion.orderFrontRegardless()
            return
        }
        let content = NSHostingView(rootView: renderExpansion())
        content.appearance = effectiveAppearance
        var frame = window.convertToScreen(convert(bounds, to: nil))
        let availableWidth = (window.screen?.visibleFrame.maxX ?? frame.maxX) - frame.minX
        let fittedWidth = ceil(content.fittingSize.width)
        frame.size.width = min(fittedWidth, availableWidth)
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
        expansionContent = renderedState.map { ($0, fittedWidth) }
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
