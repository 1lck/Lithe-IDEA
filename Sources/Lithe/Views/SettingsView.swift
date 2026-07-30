import SwiftUI

struct SettingsView: View {
    enum Category: String, CaseIterable, Identifiable {
        case general = "General"
        case editor = "Editor"
        case terminal = "Terminal"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .editor: "textformat"
            case .terminal: "terminal"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @ObservedObject var settings: AppSettings
    @State private var selection: Category = .general

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack(spacing: 0) {
                categories
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                content
            }
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            footer
        }
        .frame(width: 760, height: 520)
        .background(LitheTheme.window)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "gearshape.fill")
                .foregroundStyle(LitheTheme.secondaryText)
            Text("Settings")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .litheIconButton()
            .help("Close Settings")
        }
        .foregroundStyle(LitheTheme.primaryText)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(LitheTheme.toolHeader)
    }

    private var categories: some View {
        VStack(spacing: 3) {
            ForEach(Category.allCases) { category in
                Button {
                    selection = category
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: category.icon).frame(width: 18)
                        Text(category.rawValue)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(selection == category ? LitheTheme.selection : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == category ? Color.white : LitheTheme.primaryText)
            }
            Spacer()
        }
        .font(.system(size: 12.5))
        .padding(8)
        .frame(width: 190)
        .background(LitheTheme.sidebar)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(selection.rawValue)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)

                switch selection {
                case .general: generalSettings
                case .editor: editorSettings
                case .terminal: terminalSettings
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var generalSettings: some View {
        group("Files") {
            Toggle("Save changed files automatically", isOn: $settings.autoSave)
            if settings.autoSave {
                row("Save after") {
                    Picker("", selection: $settings.autoSaveDelay) {
                        Text("0.5 seconds").tag(0.5)
                        Text("1.5 seconds").tag(1.5)
                        Text("3 seconds").tag(3.0)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }
        }
    }

    private var editorSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Display") {
                row("Font size") {
                    Stepper(value: $settings.editorFontSize, in: 10...22, step: 1) {
                        Text("\(Int(settings.editorFontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                Toggle("Show usages and Git author", isOn: $settings.showCodeVision)
            }
            group("Indentation") {
                row("Tab width") {
                    Picker("", selection: $settings.tabWidth) {
                        Text("2 spaces").tag(2)
                        Text("4 spaces").tag(4)
                        Text("8 spaces").tag(8)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }
        }
    }

    private var terminalSettings: some View {
        group("Shell") {
            row("Default shell") {
                Picker("", selection: $settings.terminalShell) {
                    ForEach(TerminalShell.allCases) { shell in
                        Text(shell.title).tag(shell)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                .onChange(of: settings.terminalShell) {
                    guard model.terminalSession.isRunning else { return }
                    let path = settings.terminalShellPath
                        ?? ProcessInfo.processInfo.environment["SHELL"]
                        ?? "/bin/zsh"
                    model.terminalSession.restart(using: path)
                }
            }
            Text("Used for new terminal sessions.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            content()
        }
        .font(.system(size: 12.5))
        .foregroundStyle(LitheTheme.primaryText)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.sidebar)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.divider, lineWidth: 1) }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
            Spacer()
            content()
        }
        .frame(minHeight: 28)
    }

    private var footer: some View {
        HStack {
            Button("Restore Defaults") { settings.restoreDefaults() }
                .buttonStyle(.borderless)
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(LitheTheme.toolHeader)
    }
}
