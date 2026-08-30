import AppKit
import SwiftUI

/// “Go to Line:Column”dialog: a small floating window with a single
/// `[Line] [:column]:` input that accepts a 1-based line or line:column,
/// prefilled with the current caret position and fully selected. Return or
/// OK jumps, Esc or Cancel dismisses without side effects. Presentation is
/// a view-layer capability: visibility state lives in `EditorChromeModel`
/// and the jump itself goes through the existing `AppModel` navigation path.
@MainActor
enum GoToLineDialog {
    private static let okResponse = NSApplication.ModalResponse(rawValue: 1)
    private static let cancelResponse = NSApplication.ModalResponse(rawValue: 0)
    /// Both the workbench and the standalone editor window host a presenter
    /// observing the same chrome flag; this keeps only one modal alive.
    private static var isPresented = false

    /// Present the dialog modally over the editor window; on OK, parse the
    /// input and jump. Invalid input keeps Return from jumping.
    static func present(model: AppModel) {
        guard !isPresented, model.activeDocument != nil else { return }
        isPresented = true
        defer { isPresented = false }
        model.showGoToLine()

        let coordinator = DialogCoordinator()
        coordinator.onConfirm = { NSApp.stopModal(withCode: okResponse) }
        coordinator.onCancel = { NSApp.stopModal(withCode: cancelResponse) }
        let panel = makePanel(
            coordinator: coordinator,
            appearance: model.settings.themePreference.windowAppearance
        )
        configureContent(panel: panel, coordinator: coordinator, initialValue: initialValue(for: model))
        center(panel: panel)
        panel.makeKeyAndOrderFront(nil)
        if let field = coordinator.field {
            panel.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)

        model.hideGoToLine()
        if response == okResponse, let input = coordinator.confirmedText {
            model.goToLine(input)
        }
    }

    /// Prefill mirrors the status bar's 1-based line:column display.
    private static func initialValue(for model: AppModel) -> String {
        let caret = model.editorChrome.caret
        return "\(max(caret?.line ?? 0, 0) + 1):\(max(caret?.utf16Column ?? 0, 0) + 1)"
    }

    private static func makePanel(coordinator: DialogCoordinator, appearance: NSAppearance?) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 96),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Go to Line:Column"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.delegate = coordinator
        // Follow the same theme preference as the workbench windows; without
        // this the panel falls back to the system appearance and renders
        // light inside a dark-themed editor.
        panel.appearance = appearance
        return panel
    }

    private static func configureContent(
        panel: NSPanel,
        coordinator: DialogCoordinator,
        initialValue: String
    ) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 96))

        let label = NSTextField(labelWithString: "[Line] [:column]:")
        label.font = .systemFont(ofSize: 13)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 16, y: 50)
        content.addSubview(label)

        let field = NSTextField(frame: NSRect(
            x: label.frame.maxX + 8,
            y: 48,
            width: 340 - label.frame.width - 16 - 8 - 16,
            height: 24
        ))
        field.stringValue = initialValue
        field.font = .systemFont(ofSize: 13)
        field.delegate = coordinator
        field.target = coordinator
        field.action = #selector(DialogCoordinator.confirmFromField)
        coordinator.field = field
        content.addSubview(field)

        let cancelButton = NSButton(
            title: "Cancel",
            target: coordinator,
            action: #selector(DialogCoordinator.cancelFromButton)
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 340 - 16 - 78 - 10 - 78, y: 12, width: 78, height: 30)
        content.addSubview(cancelButton)

        let okButton = NSButton(
            title: "OK",
            target: coordinator,
            action: #selector(DialogCoordinator.confirmFromButton)
        )
        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"
        okButton.frame = NSRect(x: 340 - 16 - 78, y: 12, width: 78, height: 30)
        okButton.isEnabled = GoToLineInput.parse(initialValue) != nil
        coordinator.okButton = okButton
        content.addSubview(okButton)

        panel.contentView = content
    }

    /// Prefer centering over the editor window so the jump origin stays visible.
    private static func center(panel: NSPanel) {
        let size = panel.frame.size
        if let keyWindow = NSApp.keyWindow, keyWindow !== panel {
            panel.setFrameOrigin(
                NSPoint(
                    x: keyWindow.frame.midX - size.width / 2,
                    y: keyWindow.frame.midY - size.height / 2
                )
            )
        } else {
            panel.center()
        }
    }
}

@MainActor
private final class DialogCoordinator: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    weak var field: NSTextField?
    weak var okButton: NSButton?
    private(set) var confirmedText: String?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel()
        return true
    }

    /// Gray out OK while the input is not a valid line or line:column.
    func controlTextDidChange(_ notification: Notification) {
        guard let field else { return }
        okButton?.isEnabled = GoToLineInput.parse(field.stringValue) != nil
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            confirmFromField()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    @objc func confirmFromField() {
        confirm()
    }

    @objc func confirmFromButton() {
        confirm()
    }

    @objc func cancelFromButton() {
        cancel()
    }

    private func confirm() {
        guard let field,
              GoToLineInput.parse(field.stringValue) != nil else { return }
        confirmedText = field.stringValue
        onConfirm?()
    }

    private func cancel() {
        onCancel?()
    }
}

/// Presents the dialog when the chrome flag flips on, so every entry point
/// (menu, context menu, status bar, Cmd+L) funnels through the same state.
/// The presentation is deferred one runloop hop so it never runs inside a
/// SwiftUI view update.
struct GoToLineDialogPresenter: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var chrome: EditorChromeModel
    @State private var isPresenting = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: chrome.isGoToLineVisible) { isVisible in
                guard isVisible, !isPresenting else { return }
                isPresenting = true
                DispatchQueue.main.async { [model] in
                    defer { isPresenting = false }
                    GoToLineDialog.present(model: model)
                }
            }
    }
}
