import SwiftUI
import LitheAgentConversationModule

/// Context strip, flexible writing area, and a compact bottom command bar.
struct AgentComposerView: View {
    let agents: [AgentOption]
    let selectedAgent: AgentOption?
    let isResponding: Bool
    let isBlocked: Bool
    let onSend: (String) throws -> Void
    let onCancel: () -> Void
    let onSelectAgent: (String) -> Void
    let onOpenSettings: () -> Void
    let onError: (String?) -> Void
    var configOptions: [AgentSessionConfigOption] = []
    var sessionID: String?
    var isConfiguring = false
    var isCancelling = false
    var onSetConfig: (String, String) -> Void = { _, _ in }
    @State private var draft = ""
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            contextBar
            ScrollView {
                TextField("Message the Agent", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(AgentPanelStyle.text)
                    .lineLimit(1...)
                    .focused($isFocused)
                    .onSubmit(send)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
            toolbar
        }
        .background(AgentPanelStyle.canvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused || isHovering ? AgentPanelStyle.focus : AgentPanelStyle.secondary.opacity(0.45), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onHover { isHovering = $0 }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .onAppear { isFocused = true }
        .onExitCommand { if isResponding { onCancel() } }
    }

    private var contextBar: some View {
        HStack(spacing: 8) {
            Label("Project files", systemImage: "folder")
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(AgentPanelStyle.secondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(AgentPanelStyle.context, in: RoundedRectangle(cornerRadius: 7))
        .padding(1)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button(action: onOpenSettings) { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(AgentToolbarButtonStyle())
                .help("Agent Settings")
            agentMenu
            if !configOptions.isEmpty {
                AgentSessionSelectors(
                    options: configOptions,
                    agentName: selectedAgent?.name,
                    isDisabled: isBlocked || isResponding || isConfiguring,
                    onSelect: onSetConfig
                )
                .id(sessionID ?? selectedAgent?.id)
                if isConfiguring { ProgressView().controlSize(.mini) }
            }
            if configOptions.isEmpty, let model = selectedAgent?.modelName, !model.isEmpty {
                HStack(spacing: 5) {
                    AgentBrandIcon(name: selectedAgent?.name, size: 12)
                    Text(model).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 11))
                .foregroundStyle(AgentPanelStyle.secondary)
                .padding(.horizontal, 4)
                .help(model)
            }
            Spacer(minLength: 0)
            Button(action: isResponding ? onCancel : send) {
                Image(systemName: isResponding ? "stop.fill" : "paperplane")
                    .font(.system(size: 13))
                    .foregroundStyle(isResponding ? LitheTheme.error : (hasText ? AgentPanelStyle.text : AgentPanelStyle.muted))
                    .frame(width: 26, height: 26)
                    .background(AgentPanelStyle.context, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .lithePointer()
            .disabled(isCancelling || (!isResponding && (!hasText || isBlocked || isConfiguring)))
            .help(isCancelling ? "Stopping…" : (isResponding ? "Stop" : "Send"))
        }
        .padding(.horizontal, 5)
        .frame(height: 36)
        .background(AgentPanelStyle.toolbar, in: RoundedRectangle(cornerRadius: 7))
        .padding(1)
    }

    private var agentMenu: some View {
        Menu {
            if agents.isEmpty { Text("No Agent is set up yet") }
            ForEach(agents) { agent in
                Button { onSelectAgent(agent.id) } label: {
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
            AgentBrandIcon(name: selectedAgent?.name, size: 16)
                .foregroundStyle(AgentPanelStyle.secondary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(selectedAgent?.name ?? String(localized: "Choose an Agent"))
        .accessibilityLabel("Switch Agent")
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

/// The shared split container keeps resize updates outside the conversation model.
struct AgentConversationLayout<Transcript: View, Composer: View>: View {
    @ViewBuilder let transcript: Transcript
    @ViewBuilder let composer: Composer

    var body: some View {
        GeometryReader { geometry in
            LitheSplitPaneView(
                axis: .vertical,
                placement: .trailing,
                defaultSize: min(210, geometry.size.height * 0.3),
                minimum: min(120, geometry.size.height * 0.4),
                maximum: max(0, geometry.size.height * 0.6),
                showsIdleDivider: false
            ) {
                composer
                    .padding(.top, 10)
                    .overlay(alignment: .top) {
                        Capsule().fill(AgentPanelStyle.muted.opacity(0.55))
                            .frame(width: 54, height: 3)
                            .offset(y: -4)
                            .allowsHitTesting(false)
                    }
            } flexible: {
                transcript
            }
        }
    }
}
