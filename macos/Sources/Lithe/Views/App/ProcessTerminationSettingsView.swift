import SwiftUI

// Note: 统一子进程生命周期见 .agents/notes/proposed/architecture/2026-10-16-unified-child-process-lifecycle.md

/// Settings › Appearance & Behavior › Process Termination Policy.
///
/// Every choice has an ⓘ explanation because the terms (busy terminal, Agent
/// task, background service) are not obvious. Decisions are made by Rust Core
/// from these values; this view only edits them.
struct ProcessTerminationSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose what happens to programs started in Lithe when you quit or close a terminal. Programs started outside Lithe are never shown or stopped.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            LitheSettingsSection("When quitting Lithe") {
                row(
                    "Terminals with running programs",
                    info: "A terminal is busy when a program other than the shell still runs in it, such as a Spring Boot app, npm run dev or a job you sent to the background. Idle terminals always close without asking. Ending a terminal ends every program started in it."
                ) {
                    select(\.terminalOnQuit, options: TerminalQuitPolicy.allCases, label: "Terminals with running programs") {
                        switch $0 {
                        case .confirmEach: "Ask for each terminal"
                        case .terminate: "End without asking"
                        }
                    }
                }

                row(
                    "Agent tasks",
                    info: "Commands an AI Agent started that are still running, for example a deployment, a database migration or a dev server. Each one is asked about separately because ending one halfway can leave data or services inconsistent. What the Agent needs for itself, such as its MCP servers, always ends with the Agent."
                ) {
                    select(\.agentTasks, options: AgentTaskTerminationPolicy.allCases, label: "Agent tasks") {
                        switch $0 {
                        case .confirmEach: "Ask for each task"
                        case .keep: "Keep running"
                        case .terminate: "End without asking"
                        }
                    }
                }
                if settings.processTermination.agentTasks == .terminate {
                    warning("Agent tasks will be ended without asking. A deployment or migration that is still running will be interrupted.")
                }

                row(
                    "Background services",
                    info: "Programs started in Lithe that left their terminal or tool to keep running on their own, like daemons or background dev servers. They are listed together when you quit, and you choose which ones to end. Only programs started in this Lithe are listed; containers and services started outside Lithe are never touched."
                ) {
                    select(\.backgroundResources, options: BackgroundResourcePolicy.allCases, label: "Background services") {
                        switch $0 {
                        case .ask: "Ask in one list"
                        case .terminate: "End all"
                        case .keep: "Keep running"
                        }
                    }
                }
            }

            LitheSettingsSection("Closing a terminal tab") {
                HStack(spacing: 6) {
                    LitheSettingsCheckbox(
                        isOn: binding(\.confirmTerminalTabClose),
                        title: "Ask before closing a tab with running programs"
                    )
                    LitheInfoTip("Closing a tab ends every program started in it, including jobs sent to the background. Turn this off to close tabs immediately. Background services that left the terminal are not ended here; they are asked about when you quit.")
                }
            }

            LitheSettingsSection("After Lithe closes unexpectedly") {
                row(
                    "Programs left running",
                    info: "If Lithe crashes or is force quit, a small helper immediately ends its terminals and tools. Agent tasks and background services are kept until the next launch, so nothing important is ended without you. Agent tasks are always asked about, whatever you choose here."
                ) {
                    select(\.startupSweep, options: StartupSweepPolicy.allCases, label: "Programs left running") {
                        switch $0 {
                        case .ask: "Ask on next launch"
                        case .terminate: "End on next launch"
                        }
                    }
                }
            }

            LitheSettingsSection("Stopping programs") {
                row(
                    "Time to exit",
                    info: "Lithe first asks each program to stop, giving it this long to save its work and exit. Programs still running afterwards are force-stopped."
                ) {
                    LitheSettingsStepper(
                        value: binding(\.gracefulStopSeconds),
                        in: ProcessTerminationSettings.gracefulStopSecondsRange,
                        step: 1,
                        width: 126,
                        accessibilityLabel: "Time to exit",
                        title: { String(format: String(localized: "%lld s"), $0) }
                    )
                }
            }

            LitheSettingsSection("Remembered choices") {
                let remembered = settings.processTermination.rememberedChoices.sorted { $0.key < $1.key }
                if remembered.isEmpty {
                    Text("No remembered choices. Check “Remember my choice” in the quit dialog to skip the question for a kind of service next time.")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(remembered, id: \.key) { recognizer, choice in
                        HStack(spacing: 8) {
                            Text(recognizer).font(LitheTheme.uiFont(size: 12, design: .monospaced))
                            Text(choice == .terminate ? "Always end" : "Always keep")
                                .foregroundStyle(LitheTheme.secondaryText)
                            Spacer(minLength: 0)
                            Button("Forget") {
                                settings.processTermination.rememberedChoices[recognizer] = nil
                            }
                            .buttonStyle(LitheSecondaryButtonStyle())
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func row<Content: View>(
        _ title: String,
        info: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            LitheSettingsLabel(LocalizedStringKey(title), info: info)
                .frame(minWidth: 230, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
    }

    private func warning(_ text: LocalizedStringKey) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(LitheTheme.smallFont)
            .foregroundStyle(LitheTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ProcessTerminationSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings.processTermination[keyPath: keyPath] },
            set: { settings.processTermination[keyPath: keyPath] = $0 }
        )
    }

    private func select<Value: Hashable>(
        _ keyPath: WritableKeyPath<ProcessTerminationSettings, Value>,
        options: [Value],
        label: String,
        title: @escaping (Value) -> String
    ) -> some View {
        LitheSettingsSelect(
            selection: binding(keyPath),
            options: options,
            width: 200,
            accessibilityLabel: label,
            title: title
        )
    }
}
