import AppKit
import SwiftUI

// Note: 统一子进程生命周期见 .agents/notes/proposed/architecture/2026-10-16-unified-child-process-lifecycle.md

/// Formats how long a process has been running, for exit confirmations.
enum ProcessRunningTimeFormatter {
    static func string(from start: Date, to end: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(0, end.timeIntervalSince(start))) ?? ""
    }
}

/// The confirmation shown for each command an Agent started that is still
/// running. The platform presenter owns the window, the pasteboard and the
/// mapping of the answer back to the exit flow.
struct AgentTaskExitConfirmationView: View {
    static let width: CGFloat = 640
    /// The command box grows with its content up to this height, then scrolls.
    static let maximumCommandHeight: CGFloat = 240

    let task: AgentTaskCandidate
    let position: Int
    let count: Int
    let purpose: ProcessConfirmationPurpose
    /// The running time is measured up to this moment.
    let presentedAt: Date
    let onCopyCommand: () -> Void
    let onAnswer: (AgentTaskExitAnswer) -> Void

    private let command: CommandLineDisplay
    @State private var commandHeight: CGFloat = 0
    @State private var didCopy = false

    init(
        task: AgentTaskCandidate,
        position: Int,
        count: Int,
        purpose: ProcessConfirmationPurpose,
        presentedAt: Date,
        onCopyCommand: @escaping () -> Void,
        onAnswer: @escaping (AgentTaskExitAnswer) -> Void
    ) {
        self.task = task
        self.position = position
        self.count = count
        self.purpose = purpose
        self.presentedAt = presentedAt
        self.onCopyCommand = onCopyCommand
        self.onAnswer = onAnswer
        command = CommandLineDisplayFormatter.format(task.commandLine)
    }

    var title: String {
        purpose == .startupSweep
            ? String(format: String(localized: "A task %@ started before Lithe last closed unexpectedly is still running"), task.agentName)
            : String(format: String(localized: "%@ started a task that is still running"), task.agentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            facts
            commandSection
            LitheBanner(status: .warning) {
                Text(String(localized: "Agents may run deployments, migrations or long builds. Ending one halfway can leave data or services inconsistent. Keep it if you are not sure what it does."))
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(20)
        .frame(width: Self.width)
        .background(LitheTheme.popupBackground.ignoresSafeArea())
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            LitheIDEAIcon(resourcePath: "expui/status/warning.svg", size: 36, preservesOriginalColors: true)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(LitheTheme.uiFont(size: 16, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(String(format: String(localized: "%lld of %lld"), position, count))
                    .font(LitheTheme.uiFont(size: 13))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
        }
    }

    private var facts: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                FactCard(
                    iconPath: "expui/run/run.svg",
                    tint: LitheTheme.success,
                    label: String(localized: "Status"),
                    value: statusText,
                    valueColor: LitheTheme.success
                )
                .fixedSize(horizontal: true, vertical: false)
                if !task.workspace.isEmpty {
                    FactCard(
                        iconPath: "expui/nodes/folder.svg",
                        tint: LitheTheme.accent,
                        label: String(localized: "Workspace"),
                        value: task.workspace,
                        truncatesMiddle: true
                    )
                }
                if let startedAt = task.startedAt {
                    FactCard(
                        iconPath: "expui/general/history.svg",
                        tint: LitheTheme.secondaryText,
                        label: String(localized: "Running Time"),
                        value: ProcessRunningTimeFormatter.string(from: startedAt, to: presentedAt),
                        tintsIcon: true
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if let directory = task.workingDirectory, directory != task.workspace {
                FactCard(
                    iconPath: "expui/nodes/folder.svg",
                    tint: LitheTheme.accent,
                    label: String(localized: "Directory"),
                    value: directory,
                    truncatesMiddle: true
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusText: String {
        let running = String(localized: "Running")
        guard task.processCount > 1 else { return running }
        return running + " · " + String(format: String(localized: "%lld processes"), task.processCount)
    }

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LitheIDEAIcon(resourcePath: "terminal/terminal@20x20.svg", size: 16, preservesOriginalColors: true)
                    .accessibilityHidden(true)
                Text(String(localized: "Command"))
                    .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer(minLength: 0)
                Button {
                    onCopyCommand()
                    didCopy = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        didCopy = false
                    }
                } label: {
                    LitheIDEAIcon(
                        resourcePath: didCopy ? "expui/general/greenCheckmark.svg" : "expui/general/copy.svg",
                        size: LitheTheme.Metrics.toolbarIconSize,
                        preservesOriginalColors: true
                    )
                }
                .buttonStyle(LitheIconButtonStyle(size: 24))
                .lithePointer()
                .help(String(localized: "Copy Original Command"))
                .accessibilityLabel(String(localized: "Copy Original Command"))
            }
            ScrollView(.vertical) {
                Text(Self.styled(command))
                    .font(LitheTheme.uiFont(size: 12, design: .monospaced))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: CommandHeightKey.self, value: proxy.size.height)
                    })
            }
            .frame(height: min(commandHeight, Self.maximumCommandHeight))
            .onPreferenceChange(CommandHeightKey.self) { commandHeight = $0 }
            .litheScrollViewChrome(hideHorizontal: true)
            .background(LitheTheme.editor)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(LitheTheme.divider, lineWidth: 1))
            .accessibilityLabel(String(localized: "Command"))
            .accessibilityValue(task.commandLine)
        }
        .padding(12)
        .factSurface()
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if purpose == .quit {
                Button(String(localized: "Cancel Quit")) { onAnswer(.cancel) }
                    .buttonStyle(LitheActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            Spacer(minLength: 0)
            Button(String(localized: "End This Task")) { onAnswer(.terminate) }
                .buttonStyle(LitheActionButtonStyle())
            Button(String(localized: "Keep Running")) { onAnswer(.keep) }
                .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
        }
    }

    static func styled(_ display: CommandLineDisplay) -> AttributedString {
        var result = AttributedString()
        for (index, line) in display.lines.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            for run in line {
                var styled = AttributedString(run.text)
                styled.foregroundColor = CommandSyntaxColors.color(for: run.role)
                result.append(styled)
            }
        }
        return result
    }
}

private struct CommandHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reuses the editor's JSON syntax colors rather than UI status colors.
private enum CommandSyntaxColors {
    private static func syntaxColor(_ keyPath: KeyPath<SyntaxHighlightingPalette, NSColor>) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let base = CodeEditorPalette(isDark: dark, theme: LitheTheme.activeTheme)
            return SyntaxHighlightingColorConfiguration.bundled.palette(formatID: "json", base: base)[keyPath: keyPath]
        })
    }

    private static let text = syntaxColor(\.text)
    private static let option = syntaxColor(\.keyword)
    private static let key = syntaxColor(\.property)
    private static let string = syntaxColor(\.string)
    private static let number = syntaxColor(\.number)
    private static let literal = syntaxColor(\.boolean)
    private static let punctuation = syntaxColor(\.punctuation)

    static func color(for role: CommandLineDisplay.Role) -> Color {
        switch role {
        case .text: text
        case .option: option
        case .jsonKey: key
        case .jsonString: string
        case .jsonNumber: number
        case .jsonLiteral: literal
        case .jsonPunctuation: punctuation
        }
    }
}

private struct FactCard: View {
    let iconPath: String
    let tint: Color
    let label: String
    let value: String
    var valueColor: Color = LitheTheme.primaryText
    var truncatesMiddle = false
    /// Monochrome icons take the tint; colored IDEA icons keep their colors.
    var tintsIcon = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.14))
                if tintsIcon {
                    LitheIDEAIcon(resourcePath: iconPath, size: 16).foregroundStyle(tint)
                } else {
                    LitheIDEAIcon(resourcePath: iconPath, size: 16, preservesOriginalColors: true)
                }
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                Text(value)
                    .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .truncationMode(truncatesMiddle ? .middle : .tail)
                    .help(value)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .factSurface()
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    func factSurface() -> some View {
        background(LitheTheme.raised)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LitheTheme.divider, lineWidth: 1))
    }
}
