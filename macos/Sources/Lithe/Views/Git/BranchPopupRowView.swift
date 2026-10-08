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
        view.isEnabled = environment.isEnabled
        view.isPresented = isPresented
        view.onPress = onPress
        view.setAccessibilityLabel(accessibilityTitle)
        view.render = { expanded, highlighted in
            AnyView(Button {} label: { label(expanded, highlighted) }
                .buttonStyle(LitheDropdownRowStyle(isSelected: highlighted, tracksHover: false))
                .fixedSize(horizontal: expanded, vertical: true)
                .environment(\.self, environment)
                .fontWeight(.regular))
        }
        view.refresh()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BranchPopupRowControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? LitheDropdownMetrics.branchMinimumWidth, height: LitheDropdownMetrics.rowHeight)
    }
}

final class BranchPopupRowControl: NSControl {
    var render: ((Bool, Bool) -> AnyView)?
    var onPress: (() -> Void)?
    var onSecondaryPress: ((NSPoint) -> Void)?
    var isPresented = false
    private var isHovered = false
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private var expansion: NSPanel?
    private var parentCloseObserver: NSObjectProtocol?
    private var hoverTracking: NSTrackingArea?

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

    func refresh() {
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
        if newWindow !== window { closeExpansion() }
        super.viewWillMove(toWindow: newWindow)
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
