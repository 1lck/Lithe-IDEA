import SwiftUI
import UniformTypeIdentifiers
import LitheAgentConversationModule

/// Context strip, flexible writing area, and a compact bottom command bar.
struct AgentComposerView: View {
    let agents: [AgentOption]
    let selectedAgent: AgentOption?
    let isResponding: Bool
    let isBlocked: Bool
    let onSend: (String, [AgentFileReference]) throws -> Void
    let onCancel: () -> Void
    let onSelectAgent: (String) -> Void
    let onOpenSettings: () -> Void
    let onError: (String?) -> Void
    var configOptions: [AgentSessionConfigOption] = []
    var sessionID: String?
    var isConfiguring = false
    var isCancelling = false
    var contextUsage: AgentContextUsage?
    var showsSubscriptionQuota = false
    var subscriptionQuota: AgentSubscriptionQuota?
    var subscriptionAccount: String?
    var quotaFailure: String?
    var onSetConfig: (String, String) -> Void = { _, _ in }
    var commands: [AgentCommand] = []
    @State private var draft = ""
    @State private var highlightedCommand = 0
    /// Esc hides suggestions for this exact draft; editing shows them again.
    @State private var dismissedCommandDraft: String?
    @State private var files: [AgentFileReference] = []
    @State private var isDropTargeted = false
    @State private var showsFilePicker = false
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var hasContent: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty }
    private var commandSuggestions: [AgentCommand]? {
        dismissedCommandDraft == draft ? nil : AgentCommand.suggestions(for: draft, in: commands)
    }

    var body: some View {
        VStack(spacing: 0) {
            contextBar
            if !files.isEmpty {
                AgentFileReferenceList(files: files) { id in files.removeAll { $0.id == id } }
            }
            AgentComposerDraftArea(
                commands: commandSuggestions,
                highlightedIndex: highlightedCommand,
                onSelect: complete
            ) {
                ScrollView {
                    TextField("Message the Agent", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(AgentPanelStyle.text)
                        .lineLimit(1...)
                        .focused($isFocused)
                        .onSubmit(submit)
                        .modifier(AgentCommandKeyNavigation(
                            isActive: commandSuggestions?.isEmpty == false,
                            onMove: moveCommandHighlight,
                            onComplete: { completeHighlighted() }
                        ))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture { isFocused = true }
            }
            toolbar
        }
        .background(AgentPanelStyle.canvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused || isHovering || isDropTargeted ? AgentPanelStyle.focus : AgentPanelStyle.secondary.opacity(0.45), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .dropDestination(for: URL.self) { urls, _ in
            addFiles(urls)
        } isTargeted: { isDropTargeted = $0 }
        .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): _ = addFiles(urls)
            case .failure(let error): onError(error.localizedDescription)
            }
        }
        .onChange(of: sessionID) { newSessionID in
            if newSessionID != nil { files.removeAll() }
        }
        .onChange(of: draft) { _ in highlightedCommand = 0 }
        .onHover { isHovering = $0 }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .onAppear { isFocused = true }
        .onExitCommand {
            if commandSuggestions != nil {
                dismissedCommandDraft = draft
            } else if isResponding {
                onCancel()
            }
        }
    }

    private var contextBar: some View {
        HStack(spacing: 8) {
            AgentContextUsageView(usage: contextUsage)
            Rectangle().fill(AgentPanelStyle.border).frame(width: 1, height: 12)
            Button { showsFilePicker = true } label: {
                Label(isDropTargeted ? "Drop files here" : "Attach files", systemImage: "paperclip")
            }
            .buttonStyle(.litheNoPress)
            .help("Drag files here or click to choose files")
            Spacer(minLength: 0)
            if showsSubscriptionQuota {
                AgentSubscriptionQuotaView(quota: subscriptionQuota, account: subscriptionAccount, failure: quotaFailure)
            }
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
                    .foregroundStyle(isResponding ? LitheTheme.error : (hasContent ? AgentPanelStyle.text : AgentPanelStyle.muted))
                    .frame(width: 26, height: 26)
                    .background(AgentPanelStyle.context, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.litheNoPress)
            .lithePointer()
            .disabled(isCancelling || (!isResponding && (!hasContent || isBlocked || isConfiguring)))
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

    private func addFiles(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        do {
            files = try AgentFileReference.adding(urls, to: files)
            onError(nil)
            isFocused = true
            return true
        } catch {
            onError(error.localizedDescription)
            return false
        }
    }

    /// Return completes a partially typed command; a fully typed one is sent.
    private func submit() {
        if let suggestions = commandSuggestions, !suggestions.isEmpty,
           !suggestions.contains(where: { $0.invocation == draft }) {
            completeHighlighted()
            return
        }
        send()
    }

    private func completeHighlighted() {
        guard let suggestions = commandSuggestions, !suggestions.isEmpty else { return }
        complete(suggestions[min(highlightedCommand, suggestions.count - 1)])
    }

    private func complete(_ command: AgentCommand) {
        draft = command.invocation + " "
        dismissedCommandDraft = nil
        isFocused = true
    }

    private func moveCommandHighlight(_ offset: Int) {
        guard let count = commandSuggestions?.count, count > 0 else { return }
        highlightedCommand = (min(highlightedCommand, count - 1) + offset + count) % count
    }

    private func send() {
        guard hasContent, !isResponding else { return }
        if isBlocked {
            onError(String(localized: "The conversation is still being prepared. Try again in a moment."))
            return
        }
        do {
            try onSend(draft, files)
            draft = ""
            files.removeAll()
            onError(nil)
        } catch {
            onError(error.localizedDescription)
        }
    }

}

/// Arrow keys and Tab drive the command list while it is open. Key handling on a
/// focused text field needs macOS 14; macOS 13 keeps mouse selection and Return.
private struct AgentCommandKeyNavigation: ViewModifier {
    let isActive: Bool
    let onMove: (Int) -> Void
    let onComplete: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .onKeyPress(.upArrow) { handle { onMove(-1) } }
                .onKeyPress(.downArrow) { handle { onMove(1) } }
                .onKeyPress(.tab) { handle(onComplete) }
        } else {
            content
        }
    }

    @available(macOS 14.0, *)
    private func handle(_ action: () -> Void) -> KeyPress.Result {
        guard isActive else { return .ignored }
        action()
        return .handled
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
        .agentCommandSuggestionScope()
    }
}
