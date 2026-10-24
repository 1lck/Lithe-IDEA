import AppKit
import SwiftUI

/// Owns field labels and spacing. Disable editing, never the explanatory tip.
struct LitheFormField<Content: View>: View {
    let title: Text?
    var info: String? = nil
    var isEnabled = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: LitheInfoTip.labelSpacing) {
            if let title {
                LitheSettingsLabel(title, info: info).font(LitheTheme.settingsFont)
            }
            content().disabled(!isEnabled)
        }
    }
}

/// Complete single-line editor, including secure input, focus, cursor and chrome.
struct LitheTextField: View {
    private let placeholder: Text
    @Binding private var text: String
    private let secure: Bool
    private let axis: Axis
    private let focus: FocusState<Bool>.Binding?
    private let label: Text?
    private let info: String?
    private let isEnabled: Bool

    init(_ placeholder: LocalizedStringKey, text: Binding<String>, secure: Bool = false, axis: Axis = .horizontal,
         focus: FocusState<Bool>.Binding? = nil) {
        self.placeholder = Text(placeholder)
        _text = text
        self.secure = secure
        self.axis = axis
        self.focus = focus
        label = nil; info = nil; isEnabled = true
    }

    init(verbatim placeholder: String, text: Binding<String>, label: String? = nil, info: String? = nil,
         isEnabled: Bool = true, focus: FocusState<Bool>.Binding? = nil) {
        self.placeholder = Text(verbatim: placeholder)
        _text = text
        self.secure = false
        self.axis = .horizontal
        self.focus = focus
        self.label = label.map { Text(verbatim: $0) }
        self.info = info
        self.isEnabled = isEnabled
    }

    var body: some View {
        LitheFormField(title: label, info: info, isEnabled: isEnabled) {
            Group {
                if secure {
                    SecureField(text: $text, prompt: placeholder) { label ?? placeholder }
                } else {
                    TextField(text: $text, prompt: placeholder, axis: axis) { label ?? placeholder }
                }
            }
            .modifier(LitheSettingsTextFieldModifier(externalFocus: focus, multiline: axis == .vertical))
            .accessibilityLabel(label ?? placeholder)
        }
    }
}

/// Complete multiline editor. Return inserts a newline; callers choose submission actions.
struct LitheTextEditor: View {
    @Binding var text: String
    private let height: CGFloat
    private let font: Font?
    private let focus: FocusState<Bool>.Binding?
    private let label: Text?
    private let info: String?
    private let isEnabled: Bool

    init(text: Binding<String>, height: CGFloat, focus: FocusState<Bool>.Binding? = nil, font: Font? = nil) {
        _text = text; self.height = height; self.focus = focus; self.font = font
        label = nil; info = nil; isEnabled = true
    }

    init(text: Binding<String>, rows: Int, label: String, info: String? = nil, isEnabled: Bool = true) {
        _text = text
        height = ceil(NSLayoutManager().defaultLineHeight(for: LitheTheme.editorFont(size: 12))) * CGFloat(rows)
        focus = nil; font = nil
        self.label = Text(verbatim: label); self.info = info; self.isEnabled = isEnabled
    }

    var body: some View {
        LitheFormField(title: label, info: info, isEnabled: isEnabled) {
            TextEditor(text: $text)
                .modifier(LitheSettingsTextEditorModifier(height: height, font: font, externalFocus: focus))
                .accessibilityLabel(label ?? Text("Text editor"))
        }
    }
}
private struct LitheSettingsTextFieldModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    var externalFocus: FocusState<Bool>.Binding? = nil
    var multiline = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(LitheTheme.settingsFont)
            .focused(externalFocus ?? $isFocused)
            .padding(.horizontal, 9)
            .padding(.vertical, multiline ? 6 : 0)
            .frame(minHeight: SettingsSelectMetrics.controlHeight, maxHeight: multiline ? nil : SettingsSelectMetrics.controlHeight)
            .litheSettingsControlChrome(
                background: LitheTheme.settingsTextFieldBackground,
                border: (externalFocus?.wrappedValue ?? isFocused) ? LitheTheme.settingsControlAccent : LitheTheme.settingsControlBorder
            )
            .litheTextEditingCursor()
            .opacity(isEnabled ? 1 : 0.55)
    }
}

private struct LitheSettingsTextEditorModifier: ViewModifier {
    @FocusState private var isFocused: Bool
    let height: CGFloat
    var font: Font? = nil
    var externalFocus: FocusState<Bool>.Binding? = nil

    private var hasFocus: Bool { externalFocus?.wrappedValue ?? isFocused }

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .font(font ?? LitheTheme.uiFont(size: 12, design: .monospaced))
            .focused(externalFocus ?? $isFocused)
            .frame(height: height)
            .padding(5)
            .litheSettingsControlChrome(
                background: LitheTheme.settingsTextFieldBackground,
                border: hasFocus ? LitheTheme.settingsControlAccent : LitheTheme.settingsControlBorder,
                lineWidth: hasFocus ? 2 : 1,
                borderOutset: hasFocus ? 1 : 0
            )
    }
}
