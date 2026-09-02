import AppKit
import SwiftUI

private enum LitheContextMenuMetrics {
    static let minimumRootWidth: CGFloat = 272
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
    let shortcut: String?
    let role: Role
    let isEnabled: Bool
    let action: () -> Void

    static func action(
        _ title: String,
        systemImage: String? = nil,
        shortcut: String? = nil,
        role: Role = .standard,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> Self {
        Self(
            kind: .action,
            title: title,
            systemImage: systemImage,
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
            shortcut: nil,
            role: .standard,
            isEnabled: true,
            action: {}
        )
    }
}

private struct LitheContextMenuContent: View {
    let items: [LitheContextMenuItem]
    let width: CGFloat
    let dismiss: () -> Void
    let submenuWidth: CGFloat
    let submenuHeight: CGFloat
    let submenuOnLeft: Bool
    let onSubmenuVisibilityChanged: (Bool) -> Void
    @State private var openSubmenuID: UUID?

    private var openSubmenuItems: [LitheContextMenuItem]? {
        guard let openSubmenuID else { return nil }
        guard case .submenu(let items) = self.items.first(where: { $0.id == openSubmenuID })?.kind else {
            return nil
        }
        return items
    }

    private var submenuTopOffset: CGFloat {
        guard let openSubmenuID, openSubmenuItems != nil else { return 0 }
        let itemTop = items
            .prefix { $0.id != openSubmenuID }
            .reduce(LitheContextMenuMetrics.verticalPadding / 2) { offset, item in
                offset + {
                    switch item.kind {
                    case .separator:
                        LitheContextMenuMetrics.separatorHeight
                    case .action, .submenu:
                        LitheContextMenuMetrics.rowHeight
                    }
                }()
            }
        return min(
            itemTop,
            max(0, Self.menuHeight(for: items) - submenuHeight)
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            menuColumn(
                items,
                width: width,
                onSubmenuHover: { item, hovering in
                    guard hovering else { return }
                    if case .submenu = item.kind {
                        openSubmenuID = item.id
                    } else {
                        openSubmenuID = nil
                    }
                }
            )
            .offset(
                x: submenuOnLeft && openSubmenuItems != nil
                    ? submenuWidth + LitheContextMenuMetrics.submenuSpacing
                    : 0
            )

            if let openSubmenuItems {
                menuColumn(openSubmenuItems, width: submenuWidth)
                    .offset(
                        x: submenuOnLeft
                            ? 0
                            : width + LitheContextMenuMetrics.submenuSpacing,
                        y: submenuTopOffset
                    )
                    .zIndex(1)
            }
        }
        .frame(
            width: width + (openSubmenuItems == nil ? 0 : submenuWidth + LitheContextMenuMetrics.submenuSpacing),
            height: max(
                Self.menuHeight(for: items),
                openSubmenuItems == nil ? 0 : submenuHeight
            ),
            alignment: .topLeading
        )
        .contentShape(Rectangle())
        .onHover { isHovering in
            if !isHovering {
                openSubmenuID = nil
            }
        }
        .onChange(of: openSubmenuID) { submenuID in
            onSubmenuVisibilityChanged(submenuID != nil)
        }
    }

    @ViewBuilder
    private func menuColumn(
        _ items: [LitheContextMenuItem],
        width: CGFloat,
        onSubmenuHover: ((LitheContextMenuItem, Bool) -> Void)? = nil
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                switch item.kind {
                case .action:
                    LitheContextMenuRow(
                        item: item,
                        action: {
                            dismiss()
                            item.action()
                        },
                        onHover: { hovering in
                            onSubmenuHover?(item, hovering)
                        }
                    )
                case .separator:
                    Rectangle()
                        .fill(LitheTheme.divider)
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                case .submenu:
                    LitheContextMenuRow(item: item) { hovering in
                        onSubmenuHover?(item, hovering)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: width)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LitheTheme.contextMenuBackground)
        }
    }

    private static func menuHeight(for items: [LitheContextMenuItem]) -> CGFloat {
        items.reduce(LitheContextMenuMetrics.verticalPadding) { height, item in
            switch item.kind {
            case .separator:
                height + LitheContextMenuMetrics.separatorHeight
            case .action, .submenu:
                height + LitheContextMenuMetrics.rowHeight
            }
        }
    }
}

private struct LitheContextMenuRow: View {
    let item: LitheContextMenuItem
    let action: (() -> Void)?
    let onSubmenuHover: ((Bool) -> Void)?
    @State private var isHovering = false

    init(
        item: LitheContextMenuItem,
        action: @escaping () -> Void,
        onHover: ((Bool) -> Void)? = nil
    ) {
        self.item = item
        self.action = action
        self.onSubmenuHover = onHover
    }

    init(item: LitheContextMenuItem, onSubmenuHover: @escaping (Bool) -> Void) {
        self.item = item
        self.action = nil
        self.onSubmenuHover = onSubmenuHover
    }

    private var submenuItems: [LitheContextMenuItem]? {
        guard case .submenu(let items) = item.kind else { return nil }
        return items
    }

    var body: some View {
        Button {
            guard submenuItems == nil else { return }
            action?()
        } label: {
            HStack(spacing: 9) {
                Group {
                    if let systemImage = item.systemImage {
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
            isHovering = hovering
            onSubmenuHover?(hovering)
        }
    }
}

@MainActor
private final class LitheContextMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class LitheContextMenuPresenter: NSObject, NSWindowDelegate {
    static let shared = LitheContextMenuPresenter()

    private var panel: LitheContextMenuPanel?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

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
        let menuHeight = Self.menuHeight(for: items)
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
        let submenuHeight = submenuHeights.max() ?? 0
        let visibleFrame = NSScreen.screens
            .first(where: { $0.frame.contains(screenPoint) })?
            .visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let preferredOrigin = NSPoint(x: screenPoint.x - 6, y: screenPoint.y - menuHeight + 6)
        let origin = NSPoint(
            x: min(max(preferredOrigin.x, visibleFrame.minX + 6), visibleFrame.maxX - menuWidth - 6),
            y: min(max(preferredOrigin.y, visibleFrame.minY + 6), visibleFrame.maxY - menuHeight - 6)
        )
        let submenuOnLeft = submenuWidth > 0
            && origin.x + menuWidth + submenuWidth + LitheContextMenuMetrics.submenuSpacing > visibleFrame.maxX - 6
            && origin.x - submenuWidth - LitheContextMenuMetrics.submenuSpacing >= visibleFrame.minX + 6
        let content = LitheContextMenuContent(
            items: items,
            width: menuWidth,
            dismiss: { [weak self] in self?.dismiss() },
            submenuWidth: submenuWidth,
            submenuHeight: submenuHeight,
            submenuOnLeft: submenuOnLeft,
            onSubmenuVisibilityChanged: { [weak self] isVisible in
                self?.resizeMenu(
                    isSubmenuVisible: isVisible,
                    rootWidth: menuWidth,
                    rootHeight: menuHeight,
                    submenuWidth: submenuWidth,
                    submenuHeight: submenuHeight,
                    submenuOnLeft: submenuOnLeft
                )
            }
        )
        .environment(\.locale, locale)

        let panel = LitheContextMenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: menuWidth, height: menuHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
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
            if event.type == .keyDown, event.keyCode == 53 {
                self.dismiss()
                return nil
            }
            if event.type != .keyDown, event.window !== self.panel {
                self.dismiss()
                return nil
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
        guard NSApp.currentEvent?.type == .rightMouseDown else { return nil }
        return super.hitTest(point)
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
