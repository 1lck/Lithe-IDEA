import SwiftUI
import LitheAgentConversationModule

/// Bordered input box with the agent and model pickers below the text, and a
/// send button that turns into stop while the Agent is responding.
struct AgentComposerView: View {
    let agents: [AgentOption]
    let selectedAgent: AgentOption?
    let isResponding: Bool
    /// Sending waits for a session to be created or loaded.
    let isBlocked: Bool
    let onSend: (String) throws -> Void
    let onCancel: () -> Void
    let onSelectAgent: (String) -> Void
    let onOpenSettings: () -> Void
    let onError: (String?) -> Void
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                composerChip(systemImage: "paperclip", title: String(localized: "Attach file"))
                    .help("Attachments are not supported yet")
                    .opacity(0.6)
                composerChip(systemImage: "doc.text", title: String(localized: "File context"))
                    .help("File context is not supported yet")
                    .opacity(0.6)
                Spacer()
            }
            TextField("Ask the Agent, Enter to send, Shift-Enter for a new line", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...8)
                .focused($isFocused)
                .onSubmit(send)
                .padding(.horizontal, 4)
                .padding(.top, 4)
            HStack(spacing: 6) {
                agentMenu
                if let model = selectedAgent?.modelName, !model.isEmpty {
                    composerChip(systemImage: "cpu", title: model)
                }
                Spacer()
                if isResponding {
                    Button(action: onCancel) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(LitheTheme.error.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .lithePointer()
                    .help("Stop")
                    .keyboardShortcut(.escape, modifiers: [])
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(
                                hasText ? LitheTheme.accent : LitheTheme.badgeBackground,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .foregroundStyle(hasText ? Color.white : LitheTheme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .lithePointer()
                    .disabled(!hasText)
                    .help("Send")
                }
            }
        }
        .padding(8)
        .background(LitheTheme.inputBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isFocused ? LitheTheme.inputFocusBorder : LitheTheme.inputBorder, lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(LitheTheme.editor)
        .onAppear { isFocused = true }
    }

    private var agentMenu: some View {
        Menu {
            if agents.isEmpty {
                Text("No Agent is set up yet")
            }
            ForEach(agents) { agent in
                Button {
                    onSelectAgent(agent.id)
                } label: {
                    if agent.id == selectedAgent?.id {
                        Label(agent.name, systemImage: "checkmark")
                    } else {
                        Text(agent.name)
                    }
                }
            }
            Divider()
            Button("Agent Settings…", action: onOpenSettings)
        } label: {
            composerChip(
                systemImage: "sparkles",
                title: selectedAgent?.name ?? String(localized: "Choose an Agent"),
                showsChevron: true
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Agent")
    }

    private func composerChip(systemImage: String, title: String, showsChevron: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 10))
            Text(title).lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(LitheTheme.badgeBackground, in: Capsule())
    }

    private func send() {
        guard hasText, !isResponding else { return }
        if isBlocked {
            onError(String(localized: "The conversation is still being prepared. Try again in a moment."))
            return
        }
        do {
            try onSend(draft)
            draft = ""
            onError(nil)
        } catch {
            onError(error.localizedDescription)
        }
    }
}
