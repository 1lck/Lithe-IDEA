import AppKit
import SwiftUI

/// SquareStripeButtonLook paints a normal floating surface, independent of source selection.
struct LitheToolWindowDragButtonStyle: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let surface = LitheTheme.toolWindowFloatingButtonBackground(for: scheme)
        content
            .frame(width: ActivityBarMetrics.buttonWidth, height: ActivityBarMetrics.buttonHeight)
            .background(surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(surface, lineWidth: 1) }
    }
}

/// Drag geometry and preview are view-local; only mouse-up commits application layout.
@MainActor
final class ToolWindowDragState: ObservableObject {
    struct Target: Equatable {
        let position: DockPosition
        let before: WorkbenchFeatureModel.ToolWindow?
    }
    enum Region: Hashable {
        case editor
        case insertion
        case pane(DockPosition)
    }
    var workspaceFrame: CGRect = .zero
    var regions: [Region: (frame: CGRect, owner: ObjectIdentifier)] = [:]
    var sideWidths: [DockAnchor: CGFloat] = [.left: 350, .right: 350]
    var entries: [WorkbenchFeatureModel.ToolWindow: (frame: () -> CGRect, position: DockPosition, owner: ObjectIdentifier)] = [:]
    private var sourcePosition: DockPosition?
    private var dragRegions: [Region: CGRect]?
    private var dragWorkspaceFrame: CGRect?
    @Published var source: WorkbenchFeatureModel.ToolWindow?
    @Published var target: Target?

    private func area(for anchor: DockAnchor) -> CGRect {
        let frames = dragRegions ?? regions.mapValues(\.frame)
        let panes = DockGroup.allCases.compactMap { frames[.pane(.init(anchor: anchor, group: $0))] }
            .filter { !$0.isEmpty && !$0.isNull }
        if let first = panes.first { return panes.dropFirst().reduce(first) { $0.union($1) } }
        let workspace = dragWorkspaceFrame ?? workspaceFrame
        if anchor == .bottom {
            let height = min(workspace.height, max(200, workspace.height / 4))
            return CGRect(x: workspace.minX, y: workspace.minY, width: workspace.width, height: height)
        }
        let document = frames[.editor] ?? workspace
        let width = min(workspace.width, sideWidths[anchor] ?? 350)
        return CGRect(x: anchor == .left ? workspace.minX : workspace.maxX - width,
                      y: document.minY, width: width, height: document.height)
    }

    func previewFrame(for target: Target) -> CGRect {
        let frames = dragRegions ?? regions.mapValues(\.frame)
        let position = target.position
        let first = frames[.pane(.init(anchor: position.anchor, group: .primary))]
        let second = frames[.pane(.init(anchor: position.anchor, group: .secondary))]
        if let first, let second, !first.isEmpty, !second.isEmpty {
            return position.group == .primary ? first : second
        }
        var bounds = area(for: position.anchor)
        if position.anchor == .bottom {
            bounds.size.width /= 2
            if position.group == .secondary { bounds.origin.x += bounds.width }
        } else {
            bounds.size.height /= 2
            if position.group == .primary { bounds.origin.y += bounds.height }
        }
        return bounds
    }

    func target(at point: CGPoint) -> Target? {
        if source != nil, let target, regions[.insertion]?.frame.contains(point) == true { return target }
        let frames = entries.mapValues { (frame: $0.frame(), position: $0.position) }
        // AbstractDroppableStripe.processDropButton/recomputeBounds projects the point onto the
        // stripe's major axis, including when the pointer has moved into the content area.
        func insertionTarget(_ position: DockPosition) -> Target {
            if source != nil, let target, target.position == position,
               let slot = regions[.insertion]?.frame, !slot.isEmpty,
               point.y >= slot.minY, point.y <= slot.maxY { return target }
            let buttons = frames.filter {
                $0.key != source && $0.value.position == position && !$0.value.frame.isEmpty
            }.sorted {
                if $0.value.frame.midY != $1.value.frame.midY { return $0.value.frame.midY > $1.value.frame.midY }
                return $0.key.rawValue < $1.key.rawValue
            }
            // AppKit Y runs upwards; the first midpoint below the pointer is the next entry.
            let before = buttons.first { point.y >= $0.value.frame.midY }?.key
            return .init(position: position, before: before)
        }
        if let entry = frames.first(where: { $0.key != source && $0.value.frame.contains(point) }) {
            return insertionTarget(entry.value.position)
        }
        let frame = dragWorkspaceFrame ?? workspaceFrame
        guard frame.width > 0, frame.height > 0, point.y >= frame.minY, point.y <= frame.maxY,
              point.x >= frame.minX - ActivityBarMetrics.width,
              point.x <= frame.maxX + ActivityBarMetrics.rightWidth else { return nil }
        // IDEA gives the source stripe priority where visible dock areas overlap.
        let preferred = sourcePosition?.anchor
        for anchor in (preferred.map { preferred in [preferred] + DockAnchor.allCases.filter { $0 != preferred } } ?? DockAnchor.allCases) {
            var bounds = area(for: anchor)
            if anchor == .left { bounds.origin.x -= ActivityBarMetrics.width; bounds.size.width += ActivityBarMetrics.width }
            if anchor == .right { bounds.size.width += ActivityBarMetrics.rightWidth }
            guard bounds.contains(point) else { continue }
            let secondary = previewFrame(for: .init(position: .init(anchor: anchor, group: .secondary), before: nil))
            let group: DockGroup = anchor == .bottom
                ? (point.x >= secondary.minX ? .secondary : .primary)
                : (point.y <= secondary.maxY ? .secondary : .primary)
            return insertionTarget(.init(anchor: anchor, group: group))
        }
        return nil
    }
    func begin(_ tool: WorkbenchFeatureModel.ToolWindow) {
        sourcePosition = entries[tool]?.position
        dragRegions = regions.mapValues(\.frame)
        dragWorkspaceFrame = workspaceFrame
        source = tool
    }
    func finish() {
        source = nil; target = nil; sourcePosition = nil; dragRegions = nil; dragWorkspaceFrame = nil
    }
}

/// Records AppKit window coordinates, matching the native drag source rather than a moving pane.
struct ToolWindowWorkspaceAnchor: NSViewRepresentable {
    let drag: ToolWindowDragState
    var region: ToolWindowDragState.Region? = nil
    var sideWidths: [DockAnchor: CGFloat]? = nil
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {
        view.drag = drag; view.region = region
        if let sideWidths { drag.sideWidths = sideWidths }
        view.record()
    }
    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        if let region = view.region, view.drag?.regions[region]?.owner == ObjectIdentifier(view) {
            view.drag?.regions[region] = nil
        }
    }
    final class AnchorView: NSView {
        weak var drag: ToolWindowDragState?
        var region: ToolWindowDragState.Region?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); record() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); record() }
        func record() {
            guard window != nil else { return }
            let visible = region == .insertion ? bounds.intersection(visibleRect) : bounds
            let frame = convert(visible, to: nil)
            if let region { drag?.regions[region] = (frame, ObjectIdentifier(self)) }
            else { drag?.workspaceFrame = frame }
        }
    }
}

/// Keeps both groups visible and delegates high-frequency resizing to the shared split.
struct WorkbenchDockGroups<Content: View>: View {
    let anchor: DockAnchor
    let primaryVisible: Bool
    let secondaryVisible: Bool
    let fraction: Double
    var hasWorkbenchBackground = false
    var showsFrameGradient = false
    var drag: ToolWindowDragState? = nil
    let commitFraction: (Double) -> Void
    let content: (DockGroup) -> Content

    var body: some View {
        let primary = pane(.primary)
        let secondary = pane(.secondary)
        GeometryReader { geometry in
            if primaryVisible && secondaryVisible {
                let length = anchor == .bottom ? geometry.size.width : geometry.size.height
                let minimum = min(CGFloat(WorkbenchLayout.minimumPaneSize), max(0, length / 2))
                LitheSplitPaneView(
                    axis: anchor == .bottom ? .horizontal : .vertical,
                    placement: .leading, defaultSize: length * fraction,
                    minimum: minimum, maximum: max(minimum, length - minimum - SplitHandleView.thickness),
                    flexibleMinimum: minimum, clipsSizedPane: true,
                    trackBackground: hasWorkbenchBackground ? LitheTheme.titlebar.opacity(0.7) : .clear,
                    showsIdleDivider: false,
                    onCommit: { size in if length > 0 { commitFraction(Double(size / length)) } },
                    sized: { primary }, flexible: { secondary }
                )
            } else {
                if primaryVisible { primary } else { secondary }
            }
        }
    }

    private func pane(_ group: DockGroup) -> some View {
        content(group).workbenchResizablePaneChrome(
            background: hasWorkbenchBackground ? .clear : LitheTheme.editor,
            surrounding: hasWorkbenchBackground ? .clear : LitheTheme.titlebar,
            roundsCorners: !hasWorkbenchBackground,
            showsFrameGradient: showsFrameGradient
        )
        .background {
            if let drag { ToolWindowWorkspaceAnchor(drag: drag, region: .pane(.init(anchor: anchor, group: group))) }
        }
    }
}

/// Uses the editor tab drag pattern: capture once, move a nonactivating panel, commit on release.
struct ToolWindowDragSource: NSViewRepresentable {
    let tool: WorkbenchFeatureModel.ToolWindow
    let position: DockPosition
    let drag: ToolWindowDragState
    let image: () -> NSImage?
    let click: () -> Void
    let commit: (WorkbenchFeatureModel.ToolWindow, ToolWindowDragState.Target) -> Void
    var isEnabled = true

    func makeNSView(context: Context) -> SourceView { SourceView() }
    func updateNSView(_ view: SourceView, context: Context) {
        view.tool = tool; view.position = position; view.drag = drag; view.click = click; view.commit = commit
        view.image = image
        view.isEnabled = isEnabled
        view.record()
        view.cancelIfInactive()
    }
    static func dismantleNSView(_ view: SourceView, coordinator: ()) { view.dismantle() }

    final class SourceView: NSView {
        var isEnabled = true
        var tool: WorkbenchFeatureModel.ToolWindow?
        var position: DockPosition?
        weak var drag: ToolWindowDragState?
        var image: (() -> NSImage?)?
        var click: (() -> Void)?
        var commit: ((WorkbenchFeatureModel.ToolWindow, ToolWindowDragState.Target) -> Void)?
        private var pressed: NSEvent?
        private var dragging = false
        private var cancelled = false
        private var mouseMonitor: Any?
        private var preview: NSPanel?
        private var imageOrigin: NSPoint = .zero

        private var visibleHitRect: CGRect {
            guard !isHiddenOrHasHiddenAncestor else { return .null }
            return bounds.intersection(visibleRect)
        }

        // The local monitor owns presses; the SwiftUI button still owns hover and help.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); record() }
        func record() {
            guard window != nil, let tool, let position else { return }
            drag?.entries[tool] = ({ [weak self] in
                guard let self, self.window != nil else { return .zero }
                let visible = self.visibleHitRect
                return visible.isEmpty ? .null : self.convert(visible, to: nil)
            }, position, ObjectIdentifier(self))
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
            guard window != nil else { cancel(); return }
            record()
            // ponytail: at most 16 built-in entries; consolidate monitoring if the catalog becomes unbounded.
            // SwiftUI Buttons can intercept events before an overlaid NSView. Capture only this entry's press.
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                guard let self, self.isEnabled else { return event }
                if event.type == .keyDown {
                    if self.dragging && event.keyCode == 53 { self.cancel(); self.cancelled = true; return nil }
                    return event
                }
                guard event.window === self.window else { return event }
                if event.type == .leftMouseDown {
                    guard !event.modifierFlags.contains(.control),
                          self.visibleHitRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                    self.mouseDown(with: event); return nil
                }
                guard self.pressed != nil else { return event }
                if event.type == .leftMouseDragged { self.mouseDragged(with: event) }
                else { self.mouseUp(with: event) }
                return nil
            }
        }
        func dismantle() {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
            if let tool, drag?.entries[tool]?.owner == ObjectIdentifier(self) { drag?.entries[tool] = nil }
            cancel(); pressed = nil
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard isEnabled, visibleHitRect.contains(convert(event.locationInWindow, from: nil)) else { return }
            pressed = event; cancelled = false
        }
        override func mouseUp(with event: NSEvent) {
            guard pressed != nil else { return }
            guard isEnabled else { cancel(); pressed = nil; return }
            let wasDragging = dragging
            let destination = drag?.target(at: event.locationInWindow)
            let tool = tool
            let commit = commit
            cancel(); pressed = nil
            defer { cancelled = false }
            guard !cancelled else { return }
            if wasDragging, let destination, let tool { commit?(tool, destination) }
            else if !wasDragging, visibleHitRect.contains(convert(event.locationInWindow, from: nil)) { click?() }
        }
        override func mouseDragged(with event: NSEvent) {
            guard !cancelled, let pressed, let tool, let drag, let window else { return }
            let delta = NSPoint(x: event.locationInWindow.x - pressed.locationInWindow.x,
                                y: event.locationInWindow.y - pressed.locationInWindow.y)
            guard dragging || hypot(delta.x, delta.y) >= 5 else { return }
            if !dragging {
                // Paint the normal floating button; never snapshot source selection or hover.
                guard let image = image?() else { return }
                let rect = convert(NSRect(x: bounds.midX - image.size.width / 2,
                                          y: bounds.midY - image.size.height / 2,
                                          width: image.size.width, height: image.size.height), to: nil)
                imageOrigin = window.convertToScreen(rect).origin
                let panel = NSPanel(contentRect: NSRect(origin: imageOrigin, size: rect.size),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.identifier = NSUserInterfaceItemIdentifier("lithe.tool-window-drag-preview")
                panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
                panel.ignoresMouseEvents = true; panel.level = .floating; panel.alphaValue = 0.85
                panel.animationBehavior = .none
                let imageView = NSImageView(frame: NSRect(origin: .zero, size: rect.size))
                imageView.image = image; imageView.wantsLayer = true
                imageView.layer?.cornerRadius = 6
                imageView.layer?.masksToBounds = true
                panel.contentView = imageView
                preview = panel; window.addChildWindow(panel, ordered: .above); panel.orderFront(nil)
                dragging = true; drag.begin(tool)
            }
            preview?.setFrameOrigin(NSPoint(x: imageOrigin.x + delta.x, y: imageOrigin.y + delta.y))
            let target = drag.target(at: event.locationInWindow)
            if drag.target != target { drag.target = target }
        }
        func cancelIfInactive() {
            if dragging && (drag?.source != tool || !isEnabled) { cancel(); cancelled = true }
        }
        func cancel() {
            if let preview { preview.parent?.removeChildWindow(preview) }
            preview?.contentView = nil
            preview?.orderOut(nil); preview?.close(); preview = nil
            if dragging && drag?.source == tool { drag?.finish() }
            dragging = false
        }
    }
}
