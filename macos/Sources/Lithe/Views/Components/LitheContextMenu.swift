import AppKit
import SwiftUI

private enum LitheContextMenuMetrics {
    static let minimumRootWidth: CGFloat = 230
    static let minimumSubmenuWidth: CGFloat = 220
    static let maximumWidth: CGFloat = 360
    static let itemFont = NSFont.menuFont(ofSize: 12)
    static let shortcutFont = NSFont.menuFont(ofSize: 11)
    static let rowHeight: CGFloat = 26
    static let separatorHeight: CGFloat = 11
    static let verticalPadding: CGFloat = 12
    static let submenuSpacing: CGFloat = 1
}

struct LitheContextMenuItem: Identifiable {
    enum Kind {
        case action
        case separator
        case submenu([LitheContextMenuItem])
    }

    enum Role {
        case standard
        case destructive
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let systemImage: String?
    let iconKind: LitheIconKind?
    let shortcut: String?
    let role: Role
    let isEnabled: Bool
    let action: () -> Void

    static func action(
        _ title: String,
        systemImage: String? = nil,
        iconKind: LitheIconKind? = nil,
        shortcut: String? = nil,
        role: Role = .standard,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> Self {
        Self(
            kind: .action,
            title: title,
            systemImage: systemImage,
            iconKind: iconKind,
            shortcut: shortcut,
            role: role,
            isEnabled: isEnabled,
            action: action
        )
    }

    static var separator: Self {
        Self(
            kind: .separator,
            title: "",
            systemImage: nil,
            iconKind: nil,
            shortcut: nil,
            role: .standard,
            isEnabled: false,
            action: {}
        )
    }

    static func submenu(
        _ title: String,
        systemImage: String? = nil,
        items: [LitheContextMenuItem]
    ) -> Self {
        Self(
            kind: .submenu(items),
            title: title,
            systemImage: systemImage,
            iconKind: nil,
            shortcut: nil,
            role: .standard,
            isEnabled: true,
            action: {}
        )
    }
}

@MainActor
private final class LitheContextMenuSelection: ObservableObject {
    @Published var selectedID: UUID?
    @Published var openSubmenuID: UUID?
    @Published var childID: UUID?
    var inSubmenu = false
    let items: [LitheContextMenuItem]
    let dismiss: () -> Void
    var submenuChanged: ((Bool) -> Void)?

    init(items: [LitheContextMenuItem], dismiss: @escaping () -> Void) {
        self.items = items
        self.dismiss = dismiss
    }

    var children: [LitheContextMenuItem]? {
        guard case .submenu(let children) = items.first(where: { $0.id == openSubmenuID })?.kind else { return nil }
        return children
    }

    func open(_ id: UUID?) {
        guard openSubmenuID != id else { return }
        openSubmenuID = id
        childID = nil
        inSubmenu = false
        submenuChanged?(id != nil)
    }

    func handle(_ event: NSEvent) -> Bool {
        let activeItems = inSubmenu ? children ?? [] : items
        let enabled = activeItems.filter { $0.isEnabled }
        let current = inSubmenu ? childID : selectedID
        switch event.keyCode {
        case 125, 126: // Down / Up
            guard !enabled.isEmpty else { return true }
            let index = enabled.firstIndex { $0.id == current }
            let next = index.map { ($0 + (event.keyCode == 125 ? 1 : enabled.count - 1)) % enabled.count }
                ?? (event.keyCode == 125 ? 0 : enabled.count - 1)
            if inSubmenu { childID = enabled[next].id }
            else { open(nil); selectedID = enabled[next].id }
        case 124, 36, 76: // Right / Return / keypad Enter
            guard let item = activeItems.first(where: { $0.id == current }), item.isEnabled else { return true }
            if case .submenu = item.kind {
                open(item.id)
                inSubmenu = true
                childID = children?.first(where: { $0.isEnabled })?.id
            } else if event.keyCode != 124 {
                dismiss()
                item.action()
            }
        case 123: // Left
            open(nil)
        case 53:
            if openSubmenuID != nil { open(nil) } else { dismiss() }
        default: return false
        }
        return true
    }
}

private struct LitheContextMenuContent: View {
    @ObservedObject var selection: LitheContextMenuSelection
    let width: CGFloat
    let submenuWidth: CGFloat
    let submenuOnLeft: Bool
    let maximumHeight: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: LitheContextMenuMetrics.submenuSpacing) {
            if submenuOnLeft, let children = selection.children {
                menuColumn(children, width: submenuWidth, isChild: true)
            }
            menuColumn(selection.items, width: width, isChild: false)
            if !submenuOnLeft, let children = selection.children {
                menuColumn(children, width: submenuWidth, isChild: true)
            }
        }
    }

    private func menuColumn(_ items: [LitheContextMenuItem], width: CGFloat, isChild: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        if case .separator = item.kind {
                            Rectangle().fill(LitheTheme.divider).frame(height: 1)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                        } else {
                            LitheContextMenuRow(
                                item: item,
                                isSelected: (isChild ? selection.childID : selection.selectedID) == item.id,
                                action: {
                                    if case .submenu = item.kind { selection.open(item.id) }
                                    else { selection.dismiss(); item.action() }
                                },
                                onHover: { hovering in
                                    guard hovering, item.isEnabled else { return }
                                    selection.inSubmenu = isChild
                                    if isChild { selection.childID = item.id }
                                    else {
                                        selection.selectedID = item.id
                                        if case .submenu = item.kind { selection.open(item.id) }
                                        else { selection.open(nil) }
                                    }
                                }
                            )
                            .id(item.id)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: isChild ? selection.childID : selection.selectedID) { id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .frame(width: width, height: min(LitheContextMenuPresenter.menuHeight(for: items), maximumHeight))
        .litheContextMenuSurface()
    }
}

private struct LitheContextMenuRow: View {
    let item: LitheContextMenuItem
    let action: (() -> Void)?
    let onSubmenuHover: ((Bool) -> Void)?
    let isSelected: Bool
    private var isHovering: Bool { isSelected }

    init(
        item: LitheContextMenuItem,
        isSelected: Bool,
        action: @escaping () -> Void,
        onHover: ((Bool) -> Void)? = nil
    ) {
        self.item = item
        self.isSelected = isSelected
        self.action = action
        self.onSubmenuHover = onHover
    }

    private var submenuItems: [LitheContextMenuItem]? {
        guard case .submenu(let items) = item.kind else { return nil }
        return items
    }

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 9) {
                Group {
                    if let iconKind = item.iconKind {
                        LitheIcon(kind: iconKind, size: 16)
                    } else if let systemImage = item.systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 13, weight: .regular))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 16, height: 16)
                .foregroundStyle(
                    isHovering ? LitheTheme.toolWindowSelectedText : LitheTheme.secondaryText
                )

                Text(LocalizedStringKey(item.title))
                    .font(Font(LitheContextMenuMetrics.itemFont))
                    .foregroundStyle(isHovering ? LitheTheme.toolWindowSelectedText : LitheTheme.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 14)

                if submenuItems != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isHovering ? LitheTheme.toolWindowSelectedText : LitheTheme.secondaryText)
                } else if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(Font(LitheContextMenuMetrics.shortcutFont))
                        .foregroundStyle(isHovering ? LitheTheme.toolWindowSelectedText.opacity(0.78) : LitheTheme.tertiaryText)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: LitheContextMenuMetrics.rowHeight)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering ? LitheTheme.selection : .clear)
            }
            .padding(.horizontal, 5)
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.45)
        .onHover { hovering in
            onSubmenuHover?(hovering)
        }
    }
}

@MainActor
private final class LitheContextMenuPanel: NSPanel {
    var handleKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
final class LitheContextMenuPresenter: NSObject, NSWindowDelegate {
    static let shared = LitheContextMenuPresenter()

    private var panel: LitheContextMenuPanel?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var visibleFrame: NSRect = .zero

    func show(
        items: [LitheContextMenuItem],
        at screenPoint: NSPoint,
        appearance: NSAppearance?,
        locale: Locale
    ) {
        dismiss()
        guard !items.isEmpty else { return }

        let menuWidth = Self.menuWidth(
            for: items,
            minimumWidth: LitheContextMenuMetrics.minimumRootWidth
        )
        let visibleFrame = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        self.visibleFrame = visibleFrame.insetBy(dx: 6, dy: 6)
        let maximumHeight = max(1, visibleFrame.height - 12)
        let menuHeight = min(Self.menuHeight(for: items), maximumHeight)
        let submenuWidths = items.compactMap { item -> CGFloat? in
            guard case .submenu(let submenuItems) = item.kind else { return nil }
            return Self.menuWidth(
                for: submenuItems,
                minimumWidth: LitheContextMenuMetrics.minimumSubmenuWidth
            )
        }
        let submenuHeights = items.compactMap { item -> CGFloat? in
            guard case .submenu(let submenuItems) = item.kind else { return nil }
            return Self.menuHeight(for: submenuItems)
        }
        let submenuWidth = submenuWidths.max() ?? 0
        let submenuHeight = min(submenuHeights.max() ?? 0, maximumHeight)
        let preferredOrigin = NSPoint(x: screenPoint.x - 6, y: screenPoint.y - menuHeight + 6)
        let origin = NSPoint(
            x: min(max(preferredOrigin.x, visibleFrame.minX + 6), visibleFrame.maxX - menuWidth - 6),
            y: min(max(preferredOrigin.y, visibleFrame.minY + 6), visibleFrame.maxY - menuHeight - 6)
        )
        let submenuOnLeft = submenuWidth > 0
            && origin.x + menuWidth + submenuWidth + LitheContextMenuMetrics.submenuSpacing > visibleFrame.maxX - 6
            && origin.x - submenuWidth - LitheContextMenuMetrics.submenuSpacing >= visibleFrame.minX + 6
        let selection = LitheContextMenuSelection(items: items, dismiss: { [weak self] in self?.dismiss() })
        selection.submenuChanged = { [weak self] isVisible in
            self?.resizeMenu(
                isSubmenuVisible: isVisible, rootWidth: menuWidth, rootHeight: menuHeight,
                submenuWidth: submenuWidth, submenuHeight: submenuHeight, submenuOnLeft: submenuOnLeft
            )
        }
        let content = LitheContextMenuContent(
            selection: selection, width: menuWidth, submenuWidth: submenuWidth,
            submenuOnLeft: submenuOnLeft, maximumHeight: maximumHeight
        )
        .environment(\.locale, locale)

        let panel = LitheContextMenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: menuWidth, height: menuHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.handleKey = { selection.handle($0) }
        panel.contentViewController = NSHostingController(rootView: content)
        panel.appearance = appearance
        panel.animationBehavior = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.delegate = self

        panel.setFrameOrigin(origin)

        self.panel = panel
        installEventMonitors()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func resizeMenu(
        isSubmenuVisible: Bool,
        rootWidth: CGFloat,
        rootHeight: CGFloat,
        submenuWidth: CGFloat,
        submenuHeight: CGFloat,
        submenuOnLeft: Bool
    ) {
        guard let panel else { return }
        let width = rootWidth + (
            isSubmenuVisible
                ? submenuWidth + LitheContextMenuMetrics.submenuSpacing
                : 0
        )
        let height = max(rootHeight, isSubmenuVisible ? submenuHeight : 0)
        var frame = panel.frame
        let wasSubmenuVisible = frame.width > rootWidth
        if submenuOnLeft, isSubmenuVisible != wasSubmenuVisible {
            frame.origin.x += isSubmenuVisible
                ? -(submenuWidth + LitheContextMenuMetrics.submenuSpacing)
                : submenuWidth + LitheContextMenuMetrics.submenuSpacing
        }
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: width, height: height)
        frame.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)
        frame.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
        panel.setFrame(frame, display: true)
    }

    fileprivate static func menuWidth(
        for items: [LitheContextMenuItem],
        minimumWidth: CGFloat
    ) -> CGFloat {
        let widestItem = items.reduce(CGFloat.zero) { width, item in
            guard case .action = item.kind else {
                guard case .submenu = item.kind else { return width }
                return max(width, menuItemWidth(item))
            }
            return max(width, menuItemWidth(item))
        }
        let contentWidth = widestItem + 67
        return min(
            max(contentWidth, minimumWidth),
            LitheContextMenuMetrics.maximumWidth
        )
    }

    fileprivate static func menuHeight(for items: [LitheContextMenuItem]) -> CGFloat {
        items.reduce(LitheContextMenuMetrics.verticalPadding) { height, item in
            switch item.kind {
            case .separator:
                height + LitheContextMenuMetrics.separatorHeight
            case .action, .submenu:
                height + LitheContextMenuMetrics.rowHeight
            }
        }
    }

    private static func menuItemWidth(_ item: LitheContextMenuItem) -> CGFloat {
        let titleWidth = (item.title as NSString).size(
            withAttributes: [.font: LitheContextMenuMetrics.itemFont]
        ).width
        let shortcutWidth = item.shortcut.map {
            ($0 as NSString).size(
                withAttributes: [.font: LitheContextMenuMetrics.shortcutFont]
            ).width
        } ?? 0
        let shortcutSpacing: CGFloat = item.shortcut == nil ? 0 : 18
        return titleWidth + shortcutWidth + shortcutSpacing
    }

    func dismiss() {
        removeEventMonitors()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    private func installEventMonitors() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, self.panel?.handleKey?(event) == true {
                return nil
            }
            if event.type != .keyDown, event.window !== self.panel {
                self.dismiss()
                // Let the same click reach another menu trigger or the underlying control.
                return event
            }
            return event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func removeEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }
}

@MainActor
private struct LitheContextMenuTrigger: NSViewRepresentable {
    @Environment(\.locale) private var locale
    let items: () -> [LitheContextMenuItem]
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> LitheRightClickCaptureView {
        let view = LitheRightClickCaptureView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: LitheRightClickCaptureView, context: Context) {
        update(nsView)
    }

    private func update(_ view: LitheRightClickCaptureView) {
        view.onRightClick = { screenPoint, appearance in
            onRightClick()
            LitheContextMenuPresenter.shared.show(
                items: items(),
                at: screenPoint,
                appearance: appearance,
                locale: locale
            )
        }
    }
}

@MainActor
private final class LitheRightClickCaptureView: NSView {
    var onRightClick: (@MainActor (NSPoint, NSAppearance?) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else {
            super.mouseDown(with: event)
            return
        }
        rightMouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let window else { return }
        onRightClick?(window.convertPoint(toScreen: event.locationInWindow), effectiveAppearance)
    }
}

extension View {
    func litheContextMenu(
        items: @escaping () -> [LitheContextMenuItem],
        onRightClick: @escaping () -> Void = {}
    ) -> some View {
        overlay {
            LitheContextMenuTrigger(items: items, onRightClick: onRightClick)
        }
    }
}
