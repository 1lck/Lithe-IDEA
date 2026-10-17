import LitheCoreContracts
import SwiftUI

// Note: 声明式插件设置的归属与取值规则见 .agents/notes/implemented/feature/2026-10-14-declarative-plugin-settings.md

/// The options a declarative plugin lets the user change. Every control writes
/// the value as soon as it is valid, since the language server reads it at its
/// next start; the section then offers the restart instead of doing it, so
/// editing a number never restarts a server mid-keystroke.
struct PluginSettingsSection: View {
    let settings: [PluginSettingState]
    let onChange: (_ settingID: String, _ value: ToolingJSONValue?) -> Void
    let onRestartLanguageServers: () -> Void
    @State private var hasUnappliedChange = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LocalizedStringKey("Settings"))
                .font(LitheTheme.uiFont(size: 15, weight: .semibold))
                .padding(.horizontal, 24)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(settings) { setting in
                    PluginSettingRow(setting: setting) { value in
                        onChange(setting.id, value)
                        hasUnappliedChange = true
                    }
                }
                if hasUnappliedChange {
                    HStack(spacing: 10) {
                        Label(
                            LocalizedStringKey("Applies the next time the language server starts."),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                        Button(LocalizedStringKey("Restart Language Servers")) {
                            onRestartLanguageServers()
                            hasUnappliedChange = false
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(24)
        }
    }
}

private struct PluginSettingRow: View {
    let setting: PluginSettingState
    let onChange: (ToolingJSONValue?) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 4) {
                Text(LocalizedStringKey(setting.declaration.title))
                    .foregroundStyle(LitheTheme.primaryText)
                if let summary = setting.declaration.summary {
                    LitheInfoTip(LocalizedStringKey(summary))
                }
            }
            Spacer(minLength: 12)
            control
            Button(LocalizedStringKey("Reset to Default")) { onChange(nil) }
                .buttonStyle(.borderless)
                .font(LitheTheme.smallFont)
                .opacity(setting.isDefault ? 0 : 1)
                .disabled(setting.isDefault)
        }
    }

    @ViewBuilder private var control: some View {
        switch setting.declaration.kind {
        case .integer(let minimum, let maximum, let unit):
            PluginIntegerSettingField(
                value: setting.value,
                range: minimum...maximum,
                unit: unit,
                accessibilityLabel: setting.declaration.title,
                onChange: onChange
            )
        case .choice(let options):
            LitheSettingsSelect(
                selection: Binding(
                    get: { selectedOption(in: options) },
                    set: { onChange(.string($0)) }
                ),
                options: options.map(\.value),
                width: 180,
                accessibilityLabel: setting.declaration.title,
                title: { value in options.first { $0.value == value }?.title ?? value }
            )
        case .toggle:
            LitheSettingsCheckbox(
                isOn: Binding(
                    get: { setting.value == .bool(true) },
                    set: { onChange(.bool($0)) }
                ),
                accessibilityLabel: LocalizedStringKey(setting.declaration.title)
            )
        }
    }

    private func selectedOption(in options: [DeclarativePluginSetting.Option]) -> String {
        if case .string(let value) = setting.value { return value }
        return options.first?.value ?? ""
    }
}

/// A whole-number field with its unit. A value outside the allowed range is
/// never stored; the field says so and keeps the last stored value.
private struct PluginIntegerSettingField: View {
    let value: ToolingJSONValue
    let range: ClosedRange<Int>
    let unit: String?
    let accessibilityLabel: String
    let onChange: (ToolingJSONValue?) -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var storedNumber: Int? {
        if case .integer(let number) = value { number } else { nil }
    }

    private var isAcceptable: Bool {
        Int(text.trimmingCharacters(in: .whitespaces)).map(range.contains) ?? false
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $text)
                .litheSettingsTextField()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 90)
                .focused($isFocused)
                .accessibilityLabel(Text(verbatim: accessibilityLabel))
                .onSubmit(commit)
                .onChange(of: text) { _ in commitWhileTyping() }
                .onChange(of: isFocused) { focused in
                    // Leaving the field with a value that was never accepted
                    // shows the stored one again.
                    if !focused { text = storedNumber.map(String.init) ?? text }
                }
            if let unit {
                Text(verbatim: unit)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            if !isAcceptable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LitheTheme.warning)
                    .help(Text(verbatim: String(format: NSLocalizedString(
                        "Enter a whole number from %d to %d.",
                        comment: "Plugin integer setting range hint"
                    ), range.lowerBound, range.upperBound)))
            }
        }
        .onAppear { text = storedNumber.map(String.init) ?? "" }
        // A reset or another change of the stored value refreshes the field
        // unless the user is typing in it.
        .onChange(of: value) { _ in
            if !isFocused { text = storedNumber.map(String.init) ?? text }
        }
    }

    private func commitWhileTyping() {
        guard isFocused, isAcceptable, let number = Int(text.trimmingCharacters(in: .whitespaces)),
              number != storedNumber else { return }
        onChange(.integer(number))
    }

    private func commit() {
        if isAcceptable, let number = Int(text.trimmingCharacters(in: .whitespaces)) {
            if number != storedNumber { onChange(.integer(number)) }
        } else {
            text = storedNumber.map(String.init) ?? text
        }
    }
}
