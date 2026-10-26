import AppKit
import LitheDebugModule
import LitheModuleAPI
import SwiftUI

/// The Debug Console with a prompt row under the output. The row is where debugger
/// commands are typed; Tab (or typing) lists what the adapter and its plugin offer in a
/// popup above the row. Program standard input stays on the output's own inline line.
struct DebugConsolePane<Output: View>: View {
    @ObservedObject var feature: GenericDebugFeatureModel
    let fontSize: CGFloat
    /// Called when Enter could not run the line, so the owner can say why.
    let onSubmitRejected: () -> Void
    @ViewBuilder let output: () -> Output

    @Environment(\.colorScheme) private var colorScheme
    @State private var controller = DebugConsoleInputController()
    @State private var isFocused = false
    /// A click on a popup row moves focus on some macOS versions; keep the popup open then.
    @State private var isPointerOverPopup = false

    static var barHeight: CGFloat { 40 }

    var body: some View {
        VStack(spacing: 0) {
            output()
            promptBar
        }
        .overlay(alignment: .bottomLeading) {
            DebugConsoleSuggestionPopup(prompt: feature.consolePrompt) { index in
                controller.accept(index, using: feature.consolePrompt)
            }
            .onHover { isPointerOverPopup = $0 }
            .padding(.leading, 8)
            .padding(.bottom, Self.barHeight + 2)
        }
    }

    private var isEditable: Bool { feature.isSessionActive }

    private var placeholder: String {
        if !feature.isSessionActive { return L10n.string("Start a debug session to run debugger commands") }
        if feature.state != .paused { return L10n.string("Pause the program to run debugger commands") }
        return L10n.string("Enter a debugger command (Tab to complete)")
    }

    private var promptBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isEditable ? LitheTheme.accent : LitheTheme.tertiaryText)
                .frame(width: 12)
                .accessibilityHidden(true)
            DebugConsoleInputField(
                placeholder: placeholder,
                isEnabled: isEditable,
                fontSize: fontSize,
                isDark: colorScheme == .dark,
                accessibilityLabel: L10n.string("Debugger command input"),
                actions: actions,
                controller: controller,
                isFocused: $isFocused,
                onBlur: { if !isPointerOverPopup { feature.consolePrompt.dismiss() } }
            )
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(LitheTheme.inputBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isFocused ? LitheTheme.accent : LitheTheme.settingsControlBorder, lineWidth: 1)
        }
        .opacity(isEditable ? 1 : 0.7)
        .padding(.horizontal, 8)
        .frame(height: Self.barHeight)
        .frame(maxWidth: .infinity)
        .background(LitheTheme.editor)
        .overlay(alignment: .top) {
            Rectangle().fill(LitheTheme.panelBorder).frame(height: 1)
        }
    }

    private var actions: DebugConsoleInputActions {
        DebugConsoleInputActions(
            prompt: feature.consolePrompt,
            submit: { line in
                let accepted = feature.submitConsoleInput(line)
                if !accepted { onSubmitRejected() }
                return accepted
            },
            previousHistory: { feature.previousConsoleExpression(current: $0) },
            nextHistory: { feature.nextConsoleExpression() }
        )
    }
}

/// The popup above the prompt row, in the shape of the terminal completion list:
/// name and description per row, and a footer naming the keys.
struct DebugConsoleSuggestionPopup: View {
    @ObservedObject var prompt: DebugConsolePromptModel
    let onSelect: (Int) -> Void

    private static let rowHeight: CGFloat = 24
    private static let maximumVisibleRows = 8
    private static let listInset: CGFloat = 4
    private static let width: CGFloat = 520

    var body: some View {
        if prompt.isPopupOpen {
            VStack(spacing: 0) {
                list
                Rectangle().fill(LitheTheme.panelBorder).frame(height: 1)
                Text("↑↓ Select · Tab Fill · Enter Run · Esc Close")
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(LitheTheme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
            }
            .frame(width: Self.width)
            .lithePopupChrome(cornerRadius: 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Debugger command suggestions")
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(prompt.suggestions.enumerated()), id: \.offset) { index, suggestion in
                        row(suggestion, index: index)
                            .id(index)
                    }
                }
                .padding(Self.listInset)
            }
            .frame(height: CGFloat(min(prompt.suggestions.count, Self.maximumVisibleRows)) * Self.rowHeight
                + 2 * Self.listInset)
            .onChange(of: prompt.selectedIndex) { index in
                proxy.scrollTo(index)
            }
        }
    }

    private func row(_ suggestion: DebugConsolePromptModel.Suggestion, index: Int) -> some View {
        Button { onSelect(index) } label: {
            HStack(spacing: 10) {
                Text(verbatim: suggestion.name)
                    .font(LitheTheme.uiFont(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let detail = suggestion.detail {
                    Text(verbatim: detail)
                        .font(LitheTheme.uiFont(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .frame(height: Self.rowHeight)
        }
        .buttonStyle(LitheDropdownRowStyle(isSelected: index == prompt.selectedIndex))
    }
}

/// What the AppKit field asks of its owner. Keeps the field free of feature types.
struct DebugConsoleInputActions {
    let prompt: DebugConsolePromptModel
    /// Runs the line; false leaves it in the field.
    let submit: (String) -> Bool
    let previousHistory: (String) -> String?
    let nextHistory: () -> String?
}

/// Reaches the field from SwiftUI, for filling it when a popup row is clicked.
@MainActor
final class DebugConsoleInputController {
    weak var field: DebugConsoleTextField?

    /// The line as typed, including text the field editor has not handed back yet.
    func line() -> String {
        (field?.currentEditor() as? NSTextView)?.string ?? field?.stringValue ?? ""
    }

    /// Replaces the whole line and puts the caret at `caret` (UTF-16). Does not report
    /// an edit: the prompt model already decided what the popup shows next.
    func fill(_ text: String, caret: Int) {
        guard let field else { return }
        if field.currentEditor() == nil { field.window?.makeFirstResponder(field) }
        guard let editor = field.currentEditor() as? NSTextView else {
            field.stringValue = text
            return
        }
        editor.string = text
        editor.setSelectedRange(NSRange(location: min(max(caret, 0), text.utf16.count), length: 0))
    }

    /// A click on popup row `index`: fill it in and leave the caret ready to go on typing.
    func accept(_ index: Int, using prompt: DebugConsolePromptModel) {
        prompt.select(at: index)
        guard let filled = prompt.acceptSelected(into: line()) else { return }
        fill(filled.text, caret: filled.caret)
    }
}

/// Reports gaining and losing keyboard focus so the row can show a focus border.
final class DebugConsoleTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

struct DebugConsoleInputField: NSViewRepresentable {
    let placeholder: String
    let isEnabled: Bool
    let fontSize: CGFloat
    let isDark: Bool
    let accessibilityLabel: String
    let actions: DebugConsoleInputActions
    let controller: DebugConsoleInputController
    @Binding var isFocused: Bool
    let onBlur: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: actions, controller: controller)
    }

    func makeNSView(context: Context) -> DebugConsoleTextField {
        let field = DebugConsoleTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("debug-console-input")
        controller.field = field
        return field
    }

    func updateNSView(_ field: DebugConsoleTextField, context: Context) {
        context.coordinator.actions = actions
        field.isEnabled = isEnabled
        let font = LitheTheme.editorFont(size: fontSize)
        field.font = font
        field.textColor = LitheTheme.nsColor(.primaryText, isDark: isDark)
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: font,
                .foregroundColor: LitheTheme.nsColor(.secondaryText, isDark: isDark)
            ]
        )
        field.setAccessibilityLabel(accessibilityLabel)
        let focus = $isFocused
        let blurred = onBlur
        field.onFocusChange = { focused in
            if focus.wrappedValue != focused { focus.wrappedValue = focused }
            if !focused { blurred() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var actions: DebugConsoleInputActions
        private let controller: DebugConsoleInputController

        init(actions: DebugConsoleInputActions, controller: DebugConsoleInputController) {
            self.actions = actions
            self.controller = controller
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let editor = (notification.object as? NSTextField)?.currentEditor() as? NSTextView else { return }
            actions.prompt.textDidChange(editor.string, caret: editor.selectedRange().location)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let prompt = actions.prompt
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                let result = prompt.tab(text: textView.string, caret: textView.selectedRange().location)
                if case .replace(let text, let caret) = result { controller.fill(text, caret: caret) }
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                prompt.moveSelection(by: -1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                if prompt.moveSelection(by: 1) { return true }
                if let next = actions.nextHistory() { controller.fill(next, caret: next.utf16.count) }
                return true
            case #selector(NSResponder.moveUp(_:)):
                if prompt.moveSelection(by: -1) { return true }
                if let previous = actions.previousHistory(textView.string) {
                    controller.fill(previous, caret: previous.utf16.count)
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard prompt.isPopupOpen else { return false }
                prompt.dismiss()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                let typed = textView.string
                let line = prompt.acceptChosen(into: typed)?.text ?? typed
                prompt.dismiss()
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
                if actions.submit(line) {
                    controller.fill("", caret: 0)
                } else {
                    controller.fill(line, caret: line.utf16.count)
                }
                return true
            default:
                return false
            }
        }
    }
}
