import AppKit
import SwiftUI

enum LitheDropdownMetrics {
    static let minimumRootWidth: CGFloat = 156
    static let maximumWidth: CGFloat = 360
    static let fontSize: CGFloat = 12.5
    static var itemFont: NSFont { LitheTheme.uiNSFont(size: fontSize) }
    static let itemHorizontalPadding: CGFloat = 8
    static let popupPadding: CGFloat = 6
    static let rowCornerRadius: CGFloat = 4
    static let shortcutFont = LitheTheme.uiNSFont(size: 11)
    static let rowHeight: CGFloat = 24
    static let separatorHeight: CGFloat = 11
    static let verticalPadding: CGFloat = 2 * popupPadding
    static let submenuSpacing: CGFloat = 1
}

/// The Project dropdown row chrome, also used by searchable filter lists.
struct LitheDropdownRowStyle: ButtonStyle {
    var isSelected = false
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = isEnabled && (isSelected || isHovered)
        return configuration.label
            .font(LitheTheme.uiFont(size: LitheDropdownMetrics.fontSize))
            .foregroundStyle(highlighted ? LitheTheme.settingsSelectionText : LitheTheme.primaryText)
            .padding(.horizontal, LitheDropdownMetrics.itemHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: LitheDropdownMetrics.rowHeight, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: LitheDropdownMetrics.rowCornerRadius)
                    .fill(highlighted ? LitheTheme.settingsSelection : .clear)
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
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
        HStack(alignment: .top, spacing: LitheDropdownMetrics.submenuSpacing) {
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
        let showsIcons = items.contains { $0.systemImage != nil || $0.iconKind != nil }
        return ScrollViewReader { proxy in
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
                                showsIcons: showsIcons,
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
                .padding(.vertical, LitheDropdownMetrics.popupPadding)
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
    let showsIcons: Bool
    private var isHovering: Bool { isSelected }

    init(
        item: LitheContextMenuItem,
        isSelected: Bool,
        showsIcons: Bool,
        action: @escaping () -> Void,
        onHover: ((Bool) -> Void)? = nil
    ) {
        self.item = item
        self.isSelected = isSelected
        self.showsIcons = showsIcons
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
                if showsIcons {
                    Group {
                        if let iconKind = item.iconKind {
                            LitheIcon(kind: iconKind, size: 16)
                        } else if let systemImage = item.systemImage {
                            Image(systemName: systemImage)
                                .font(LitheTheme.uiFont(size: 13, weight: .regular))
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 16, height: 16)
                    .foregroundStyle(isHovering ? LitheTheme.settingsSelectionText : LitheTheme.secondaryText)
                }

                Text(LocalizedStringKey(item.title))
                    .font(LitheTheme.uiFont(size: LitheDropdownMetrics.fontSize))
                    .foregroundStyle(isHovering
                                     ? LitheTheme.settingsSelectionText
                                     : LitheTheme.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 14)

                if submenuItems != nil {
                    Image(systemName: "chevron.right")
                        .font(LitheTheme.uiFont(size: 9, weight: .semibold))
                        .foregroundStyle(isHovering ? LitheTheme.settingsSelectionText : LitheTheme.secondaryText)
                } else if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(Font(LitheDropdownMetrics.shortcutFont))
                        .foregroundStyle(isHovering ? LitheTheme.settingsSelectionText.opacity(0.78) : LitheTheme.tertiaryText)
                }
            }
        }
        .buttonStyle(LitheDropdownRowStyle(isSelected: isSelected))
        .padding(.horizontal, LitheDropdownMetrics.popupPadding)
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

/// Keep searchable dropdowns sized when their SwiftUI content opens a flyout.
@MainActor
final class LitheDropdownHostingController: NSHostingController<AnyView> {
    var sizeChanged: (() -> Void)?
    override var preferredContentSize: NSSize {
        didSet { if preferredContentSize != oldValue { sizeChanged?() } }
    }
}

@MainActor
final class LitheContextMenuPresenter: NSObject, NSWindowDelegate {
    static let shared = LitheContextMenuPresenter()

    private var panel: LitheContextMenuPanel?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var visibleFrame: NSRect = .zero
    private var contentDismissed: (() -> Void)?
    private var contentAnchor: NSPoint?

    func show(
        items: [LitheContextMenuItem],
        at screenPoint: NSPoint,
        appearance: NSAppearance?,
        locale: Locale,
        opensUpward: Bool = false
    ) {
        dismiss()
        guard !items.isEmpty else { return }

        let menuWidth = Self.menuWidth(for: items)
        let visibleFrame = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        self.visibleFrame = visibleFrame.insetBy(dx: 6, dy: 6)
        let maximumHeight = max(1, visibleFrame.height - 12)
        let menuHeight = min(Self.menuHeight(for: items), maximumHeight)
        let submenuWidths = items.compactMap { item -> CGFloat? in
            guard case .submenu(let submenuItems) = item.kind else { return nil }
            return Self.menuWidth(for: submenuItems)
        }
        let submenuHeights = items.compactMap { item -> CGFloat? in
            guard case .submenu(let submenuItems) = item.kind else { return nil }
            return Self.menuHeight(for: submenuItems)
        }
        let submenuWidth = submenuWidths.max() ?? 0
        let submenuHeight = min(submenuHeights.max() ?? 0, maximumHeight)
        let preferredOrigin = NSPoint(
            x: screenPoint.x - 6,
            y: opensUpward ? screenPoint.y + 6 : screenPoint.y - menuHeight + 6
        )
        let origin = NSPoint(
            x: min(max(preferredOrigin.x, visibleFrame.minX + 6), visibleFrame.maxX - menuWidth - 6),
            y: min(max(preferredOrigin.y, visibleFrame.minY + 6), visibleFrame.maxY - menuHeight - 6)
        )
        let submenuOnLeft = submenuWidth > 0
            && origin.x + menuWidth + submenuWidth + LitheDropdownMetrics.submenuSpacing > visibleFrame.maxX - 6
            && origin.x - submenuWidth - LitheDropdownMetrics.submenuSpacing >= visibleFrame.minX + 6
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

        let panel = makePanel(contentController: NSHostingController(rootView: content), appearance: appearance)
        panel.handleKey = { selection.handle($0) }

        // Installing the hosting controller can reset the initial content size.
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: menuWidth, height: menuHeight)), display: true)

        self.panel = panel
        installEventMonitors()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func makePanel(contentController: NSViewController, appearance: NSAppearance?) -> LitheContextMenuPanel {
        let panel = LitheContextMenuPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentViewController = contentController
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
        return panel
    }

    /// Searchable filters share the action-menu window and dismissal lifecycle.
    func show(contentController: NSViewController, at screenPoint: NSPoint,
              appearance: NSAppearance?, onDismiss: @escaping () -> Void) {
        dismiss()
        let panel = makePanel(contentController: contentController, appearance: appearance)
        panel.handleKey = { [weak self] event in
            guard event.keyCode == 53 else { return false }
            self?.dismiss()
            return true
        }
        self.panel = panel
        if let hosting = contentController as? LitheDropdownHostingController {
            hosting.sizingOptions = [.preferredContentSize]
            hosting.sizeChanged = { [weak self, weak hosting] in
                guard let hosting else { return }
                self?.resize(contentController: hosting)
            }
        }
        contentDismissed = onDismiss
        contentAnchor = screenPoint
        resize(contentController: contentController)
        installEventMonitors()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func resize(contentController: NSViewController) {
        guard let panel, panel.contentViewController === contentController,
              let point = contentAnchor else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let bounds = (screen?.visibleFrame ?? panel.frame).insetBy(dx: 6, dy: 6)
        contentController.view.layoutSubtreeIfNeeded()
        let preferred = contentController.preferredContentSize
        let fitting = preferred.width > 0 && preferred.height > 0
            ? preferred : contentController.view.fittingSize
        let size = NSSize(width: min(fitting.width, bounds.width),
                          height: min(fitting.height, bounds.height))
        let origin = NSPoint(x: min(max(point.x, bounds.minX), bounds.maxX - size.width),
                             y: min(max(point.y - size.height, bounds.minY), bounds.maxY - size.height))
        let frame = NSRect(origin: origin, size: size)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    func dismiss(contentController: NSViewController) {
        guard panel?.contentViewController === contentController else { return }
        dismiss()
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
                ? submenuWidth + LitheDropdownMetrics.submenuSpacing
                : 0
        )
        let height = max(rootHeight, isSubmenuVisible ? submenuHeight : 0)
        var frame = panel.frame
        let wasSubmenuVisible = frame.width > rootWidth
        if submenuOnLeft, isSubmenuVisible != wasSubmenuVisible {
            frame.origin.x += isSubmenuVisible
                ? -(submenuWidth + LitheDropdownMetrics.submenuSpacing)
                : submenuWidth + LitheDropdownMetrics.submenuSpacing
        }
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: width, height: height)
        frame.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height)
        frame.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
        panel.setFrame(frame, display: true)
    }

    fileprivate static func menuWidth(
        for items: [LitheContextMenuItem]
    ) -> CGFloat {
        let widestItem = items.reduce(CGFloat.zero) { width, item in
            guard case .action = item.kind else {
                guard case .submenu = item.kind else { return width }
                return max(width, menuItemWidth(item))
            }
            return max(width, menuItemWidth(item))
        }
        let showsIcons = items.contains { $0.systemImage != nil || $0.iconKind != nil }
        let chromeWidth = 2 * (LitheDropdownMetrics.itemHorizontalPadding + LitheDropdownMetrics.popupPadding)
            + 14 + 9 + (showsIcons ? 16 + 9 : 0)
        let contentWidth = ceil(widestItem + chromeWidth)
        return min(
            max(contentWidth, LitheDropdownMetrics.minimumRootWidth),
            LitheDropdownMetrics.maximumWidth
        )
    }

    fileprivate static func menuHeight(for items: [LitheContextMenuItem]) -> CGFloat {
        items.reduce(LitheDropdownMetrics.verticalPadding) { height, item in
            switch item.kind {
            case .separator:
                height + LitheDropdownMetrics.separatorHeight
            case .action, .submenu:
                height + LitheDropdownMetrics.rowHeight
            }
        }
    }

    private static func menuItemWidth(_ item: LitheContextMenuItem) -> CGFloat {
        let titleWidth = (item.title as NSString).size(
            withAttributes: [.font: LitheDropdownMetrics.itemFont]
        ).width
        let shortcutWidth = item.shortcut.map {
            ($0 as NSString).size(
                withAttributes: [.font: LitheDropdownMetrics.shortcutFont]
            ).width
        } ?? 0
        let trailingWidth: CGFloat
        if case .submenu = item.kind { trailingWidth = 16 + 9 }
        else { trailingWidth = item.shortcut == nil ? 0 : shortcutWidth + 9 }
        return titleWidth + trailingWidth
    }

    func dismiss() {
        removeEventMonitors()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        contentAnchor = nil
        let dismissed = contentDismissed
        contentDismissed = nil
        dismissed?()
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

private struct LitheContextMenuModifier: ViewModifier {
    @Environment(\.isLithePaneResizing) private var isResizing
    let items: () -> [LitheContextMenuItem]
    let onRightClick: () -> Void

    func body(content: Content) -> some View {
        content.overlay {
            if !isResizing {
                LitheContextMenuTrigger(items: items, onRightClick: onRightClick)
            }
        }
    }
}

extension View {
    func litheContextMenu(
        items: @escaping () -> [LitheContextMenuItem],
        onRightClick: @escaping () -> Void = {}
    ) -> some View {
        modifier(LitheContextMenuModifier(items: items, onRightClick: onRightClick))
    }
}
