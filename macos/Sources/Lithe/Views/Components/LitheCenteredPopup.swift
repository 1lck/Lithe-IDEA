import AppKit
import SwiftUI

extension View {
    /// IDEA NewItemSimplePopupPanel: a borderless name row on the popup surface.
    func lithePopupNameField() -> some View {
        textFieldStyle(.plain)
            .font(LitheTheme.uiFont(size: 13))
            .padding(.horizontal, 13)
            .frame(height: 32)
            .foregroundStyle(LitheTheme.primaryText)
    }
}

/// Uses the New File/New Directory panel lifecycle for centered product forms.
struct LitheCenteredPopup<PopupContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @Environment(\.self) private var environment
    var allowsDismiss = true
    var dialogTitle: String? = nil
    @ViewBuilder var content: () -> PopupContent

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // Read state and content during SwiftUI's update so their dependencies are tracked.
        let popupContent = isPresented ? AnyView(content().environment(\.self, environment)) : nil
        let coordinator = context.coordinator
        coordinator.revision += 1
        let revision = coordinator.revision
        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator, coordinator.revision == revision else { return }
            coordinator.presenter.allowsDismiss = allowsDismiss
            guard let popupContent, let parent = view.window else {
                coordinator.presenter.close()
                coordinator.host = nil
                return
            }
            if let host = coordinator.host {
                host.rootView = popupContent
                if let dialogTitle { host.view.window?.title = dialogTitle }
            } else {
                let host = NSHostingController(rootView: popupContent)
                coordinator.host = host
                coordinator.presenter.show(contentController: host, parent: parent, dialogTitle: dialogTitle) { [weak coordinator] in
                    coordinator?.revision += 1
                    coordinator?.host = nil
                    isPresented = false
                }
            }
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.revision += 1
        coordinator.presenter.close()
        coordinator.host = nil
    }

    @MainActor
    final class Coordinator {
        let presenter = LitheCenteredPopupPresenter()
        var host: NSHostingController<AnyView>?
        var revision = 0
    }
}

private final class LitheCenteredPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class LitheCenteredPopupPresenter: NSObject, NSWindowDelegate {
    var allowsDismiss = true
    private var panel: NSPanel?
    private var parentObservers: [NSObjectProtocol] = []
    private var onDismiss: (() -> Void)?
    private var parentEventMonitor: Any?

    func show(contentController: NSViewController, parent: NSWindow, dialogTitle: String? = nil, onDismiss: @escaping () -> Void) {
        close()
        self.onDismiss = onDismiss
        let size = contentController.view.fittingSize
        let panel = LitheCenteredPopupPanel(contentRect: NSRect(origin: .zero, size: size),
                                           styleMask: dialogTitle == nil ? [.borderless] : [.titled, .closable],
                                           backing: .buffered, defer: false)
        self.panel = panel
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.appearance = parent.effectiveAppearance
        panel.animationBehavior = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        if let dialogTitle {
            panel.title = dialogTitle
            panel.titlebarAppearsTransparent = true
            panel.backgroundColor = LitheCommitDialogStyle.backgroundNSColor
            panel.isOpaque = true
        }
        // Keep native titled-window chrome intact; disabling the shadow also changes its visible frame.
        panel.hasShadow = true
        panel.delegate = self
        panel.contentViewController = contentController
        parent.addChildWindow(panel, ordered: .above)
        center()
        for notification in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            parentObservers.append(NotificationCenter.default.addObserver(
                forName: notification, object: parent, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.center() }
            })
        }
        parentObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: parent, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(force: true) }
        })
        if dialogTitle != nil {
            // A child panel alone does not stop clicks/shortcuts reaching its owner.
            // Filter only the owner: native file panels and nested selectors stay interactive.
            parentEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp, .keyDown, .keyUp, .scrollWheel
            ]) { [weak self, weak parent] event in
                guard let self, let parent, event.window === parent, let panel = self.panel else { return event }
                panel.makeKeyAndOrderFront(nil)
                return nil
            }
        }
        panel.makeKeyAndOrderFront(nil)
        center()
    }

    private func center() {
        guard let panel, let parent = panel.parent else { return }
        panel.setFrameOrigin(NSPoint(x: parent.frame.midX - panel.frame.width / 2,
                                     y: parent.frame.midY - panel.frame.height / 2))
    }

    func close() {
        if let parentEventMonitor { NSEvent.removeMonitor(parentEventMonitor) }
        parentEventMonitor = nil
        parentObservers.forEach(NotificationCenter.default.removeObserver)
        parentObservers.removeAll()
        let previousPanel = panel
        panel = nil
        onDismiss = nil
        previousPanel?.delegate = nil
        if let previousPanel {
            previousPanel.parent?.removeChildWindow(previousPanel)
            previousPanel.close()
        }
    }

    private func dismiss(force: Bool = false) {
        guard allowsDismiss || force else { return }
        let callback = onDismiss
        close()
        callback?()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel?.styleMask.contains(.titled) != true else { return }
        // A value selector inside a form owns a child panel; keep the form alive.
        guard panel?.childWindows?.contains(where: { $0.isVisible }) != true else { return }
        dismiss()
    }

    func windowDidResize(_ notification: Notification) { center() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }
}
