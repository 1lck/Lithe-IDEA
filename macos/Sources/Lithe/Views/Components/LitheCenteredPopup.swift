import AppKit
import SwiftUI

struct LithePopupDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            (window?.delegate as? LitheCenteredPopupPresenter)?.preservePosition()
            window?.performDrag(with: event)
        }
    }
}

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
    var topInset: CGFloat? = nil
    var focusFirstTextField = false
    var resizesToContent = false
    var contentUpdateKey: AnyHashable? = nil
    @ViewBuilder var content: () -> PopupContent

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = LitheDropdownAnchorView()
        view.onAttach = { [weak coordinator = context.coordinator] _, _ in coordinator?.onAttach?() }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // Read state and content during SwiftUI's update so their dependencies are tracked.
        let coordinator = context.coordinator
        let popupContent = isPresented ? AnyView(LithePopupEnvironmentContent(
            content: content(), parentEnvironment: environment, presenter: coordinator.presenter)) : nil
        coordinator.revision += 1
        let revision = coordinator.revision
        let present = { [weak view, weak coordinator] in
            guard let view, let coordinator, coordinator.revision == revision else { return }
            coordinator.presenter.allowsDismiss = allowsDismiss
            coordinator.presenter.topInset = topInset
            coordinator.presenter.resizesToContent = resizesToContent
            guard let popupContent, let parent = view.window else {
                coordinator.presenter.close()
                coordinator.host = nil
                return
            }
            if let host = coordinator.host {
                if contentUpdateKey == nil || coordinator.contentUpdateKey != contentUpdateKey {
                    host.rootView = popupContent
                    coordinator.contentUpdateKey = contentUpdateKey
                }
                if let dialogTitle { host.view.window?.title = dialogTitle }
                if topInset != nil || resizesToContent { coordinator.presenter.center() }
            } else {
                let host = LitheDropdownHostingController(rootView: popupContent)
                if contentUpdateKey != nil || resizesToContent {
                    host.sizingOptions = [.preferredContentSize]
                    host.sizeChanged = { [weak coordinator] in coordinator?.presenter.center() }
                }
                coordinator.host = host
                coordinator.contentUpdateKey = contentUpdateKey
                coordinator.presenter.show(contentController: host, parent: parent, dialogTitle: dialogTitle,
                                           focusFirstTextField: focusFirstTextField) { [weak coordinator] in
                    coordinator?.revision += 1
                    coordinator?.host = nil
                    isPresented = false
                }
            }
        }
        // The first SwiftUI update can precede attachment to an NSWindow.
        coordinator.onAttach = { DispatchQueue.main.async(execute: present) }
        DispatchQueue.main.async(execute: present)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        (view as? LitheDropdownAnchorView)?.onAttach = nil
        coordinator.onAttach = nil
        coordinator.revision += 1
        coordinator.presenter.close()
        coordinator.host = nil
    }

    @MainActor
    final class Coordinator {
        let presenter = LitheCenteredPopupPresenter()
        var host: NSHostingController<AnyView>?
        var revision = 0
        var onAttach: (() -> Void)?
        var contentUpdateKey: AnyHashable?
    }
}

/// Inherit product settings without copying the owner's now-inactive window state.
private struct LithePopupEnvironmentContent<Content: View>: View {
    let content: Content
    let parentEnvironment: EnvironmentValues
    @ObservedObject var presenter: LitheCenteredPopupPresenter

    var body: some View {
        content.environment(\.controlActiveState, presenter.controlActiveState)
            .environment(\.self, parentEnvironment)
    }
}

private final class LitheCenteredPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class LitheCenteredPopupPresenter: NSObject, NSWindowDelegate, ObservableObject {
    @Published private(set) var controlActiveState: ControlActiveState = .inactive
    var allowsDismiss = true
    var topInset: CGFloat?
    var resizesToContent = false
    private var panel: NSPanel?
    private var parentObservers: [NSObjectProtocol] = []
    private var onDismiss: (() -> Void)?
    private var parentEventMonitor: Any?
    private var isManuallyPositioned = false

    func show(contentController: NSViewController, parent: NSWindow, dialogTitle: String? = nil,
              focusFirstTextField: Bool = false, onDismiss: @escaping () -> Void) {
        close()
        controlActiveState = .inactive
        self.onDismiss = onDismiss
        let size = contentController.view.fittingSize
        let panel = LitheCenteredPopupPanel(contentRect: NSRect(origin: .zero, size: size),
                                           styleMask: dialogTitle == nil ? [.borderless] : [.titled, .closable],
                                           backing: .buffered, defer: false)
        self.panel = panel
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.appearance = parent.effectiveAppearance
        // JBR AWTWindow uses an sRGB backing store for color-matched popup surfaces.
        panel.colorSpace = .sRGB
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
        if focusFirstTextField {
            // Request native focus after the hosting view has joined the key panel.
            contentController.view.layoutSubtreeIfNeeded()
            func firstField(in view: NSView) -> NSView? {
                if let field = view as? NSTextField, field.isEditable, field.isEnabled { return field }
                if let editor = view as? NSTextView, editor.isEditable, !editor.isFieldEditor { return editor }
                return view.subviews.lazy.compactMap { firstField(in: $0) }.first
            }
            if let field = firstField(in: contentController.view) {
                panel.initialFirstResponder = field
                panel.makeFirstResponder(field)
                (field as? NSTextField)?.selectText(nil)
            }
        }
    }

    func center() {
        guard let panel, let parent = panel.parent else { return }
        if let topInset, let content = panel.contentViewController?.view {
            let size = content.fittingSize
            let owner = parent.contentRect(forFrameRect: parent.frame)
            let frame = NSRect(x: isManuallyPositioned ? panel.frame.minX : owner.midX - size.width / 2,
                                  y: (isManuallyPositioned ? panel.frame.maxY : owner.maxY - topInset) - size.height,
                                  width: size.width, height: size.height)
            if frame != panel.frame { panel.setFrame(frame, display: true) }
            return
        }
        if resizesToContent, let content = panel.contentViewController?.view {
            let size = content.fittingSize
            if size.width > 0, size.height > 0, size != panel.contentLayoutRect.size {
                panel.setContentSize(size)
            }
        }
        panel.setFrameOrigin(NSPoint(x: parent.frame.midX - panel.frame.width / 2,
                                     y: parent.frame.midY - panel.frame.height / 2))
    }

    func preservePosition() {
        // Native dragging is asynchronous; subsequent layout must keep the user's top-left anchor.
        isManuallyPositioned = true
    }

    func close() {
        isManuallyPositioned = false
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

    func windowDidBecomeKey(_ notification: Notification) {
        controlActiveState = .key
    }

    func windowDidResignKey(_ notification: Notification) {
        controlActiveState = .inactive
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
