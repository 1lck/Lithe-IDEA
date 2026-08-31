import AppKit
import SwiftUI

struct LitheContextMenuItem: Identifiable {
    enum Kind {
        case action
        case separator
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
}

private struct LitheContextMenuContent: View {
    let items: [LitheContextMenuItem]
    let width: CGFloat
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                switch item.kind {
                case .action:
                    LitheContextMenuRow(item: item) {
                        dismiss()
                        item.action()
                    }
                case .separator:
                    Rectangle()
                        .fill(LitheTheme.divider)
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
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
}

private struct LitheContextMenuRow: View {
    let item: LitheContextMenuItem
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
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
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(isHovering ? LitheTheme.toolWindowSelectedText : LitheTheme.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 14)

                if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(isHovering ? LitheTheme.toolWindowSelectedText.opacity(0.78) : LitheTheme.tertiaryText)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
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
        .onHover { isHovering = $0 }
    }
}

@MainActor
private final class LitheContextMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class LitheContextMenuPresenter: NSObject, NSWindowDelegate {
    static let shared = LitheContextMenuPresenter()

    private let menuWidth: CGFloat = 252
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

        let menuHeight = items.reduce(CGFloat(12)) { height, item in
            height + (item.kind == .separator ? 11 : 26)
        }
        let content = LitheContextMenuContent(
            items: items,
            width: menuWidth,
            dismiss: { [weak self] in self?.dismiss() }
        )
        .environment(\.locale, locale)
        .frame(width: menuWidth, height: menuHeight)

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

        let visibleFrame = NSScreen.screens
            .first(where: { $0.frame.contains(screenPoint) })?
            .visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let preferredOrigin = NSPoint(x: screenPoint.x - 6, y: screenPoint.y - menuHeight + 6)
        let origin = NSPoint(
            x: min(max(preferredOrigin.x, visibleFrame.minX + 6), visibleFrame.maxX - menuWidth - 6),
            y: min(max(preferredOrigin.y, visibleFrame.minY + 6), visibleFrame.maxY - menuHeight - 6)
        )
        panel.setFrameOrigin(origin)

        self.panel = panel
        installEventMonitors()
        panel.orderFrontRegardless()
        panel.makeKey()
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
