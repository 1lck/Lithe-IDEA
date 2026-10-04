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
    var isPreparingSession = false
    var isConfiguring = false
    var isCancelling = false
    var contextUsage: AgentContextUsage?
    var showsSubscriptionQuota = false
    var subscriptionQuota: AgentSubscriptionQuota?
    var subscriptionAccount: String?
    var quotaFailure: String?
    var onSetConfig: (String, String) -> Void = { _, _ in }
    var commands: [AgentCommand] = []
    @State private var completion = AgentCommandCompletion()
    @State private var files: [AgentFileReference] = []
    @State private var isDropTargeted = false
    @State private var showsFilePicker = false
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var hasContent: Bool { !completion.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty }
    private var commandSuggestions: [AgentCommand]? {
        completion.suggestions(in: commands)
    }

    var body: some View {
        AgentComposerContent(files: files, commands: commandSuggestions,
                             highlightedIndex: completion.highlightedIndex,
                             onSelect: complete, onRemoveFile: { id in files.removeAll { $0.id == id } },
                             onFocus: { isFocused = true }) {
            contextBar
        } editor: {
            TextField("Message the Agent", text: $completion.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(LitheTheme.uiFont(size: 13))
                .foregroundStyle(AgentPanelStyle.text)
                .lineLimit(1...)
                .focused($isFocused)
                .onSubmit { _ = handleCommandKey(.submit) }
                .modifier(AgentCommandKeyNavigation(onKey: handleCommandKey))
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        } toolbar: {
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
        .onHover { isHovering = $0 }
        .padding(.horizontal, 8)
        .padding(.bottom, AgentComposerMetrics.bottomInset)
        .onAppear { isFocused = true }
        .onExitCommand { _ = handleCommandKey(.escape) }
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
        .font(LitheTheme.uiFont(size: 11))
        .foregroundStyle(AgentPanelStyle.secondary)
        .padding(.horizontal, 10)
        .frame(height: AgentComposerMetrics.contextHeight - 2)
        .background(AgentPanelStyle.context, in: RoundedRectangle(cornerRadius: 7))
        .padding(1)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button(action: onOpenSettings) { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(AgentToolbarButtonStyle())
                .help("Agent Settings")
            agentMenu
            if isPreparingSession {
                Label("Loading session settings…", systemImage: "hourglass")
                    .font(.system(size: 11))
                    .foregroundStyle(AgentPanelStyle.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("agent-session-settings-loading")
            } else if !configOptions.isEmpty {
                AgentSessionSelectors(
                    options: configOptions,
                    agentName: selectedAgent?.name,
                    isDisabled: isBlocked || isResponding || isConfiguring,
                    onSelect: onSetConfig
                )
                .id(sessionID ?? selectedAgent?.id)
                if isConfiguring { ProgressView().controlSize(.mini) }
            } else if let model = selectedAgent?.modelName, !model.isEmpty {
                HStack(spacing: 5) {
                    AgentBrandIcon(name: selectedAgent?.name, size: 12, style: .brand)
                    Text(model).lineLimit(1).truncationMode(.middle)
                }
                .font(LitheTheme.uiFont(size: 11))
                .foregroundStyle(AgentPanelStyle.secondary)
                .padding(.horizontal, 4)
                .help(model)
            }
            Spacer(minLength: 0)
            Button(action: isResponding ? onCancel : send) {
                Image(systemName: isResponding ? "stop.fill" : "paperplane")
                    .font(LitheTheme.uiFont(size: 13))
                    .foregroundStyle(isResponding ? LitheTheme.error : (hasContent ? AgentPanelStyle.text : AgentPanelStyle.muted))
                    .frame(width: 26, height: 26)
                    .background(AgentPanelStyle.context, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.litheNoPress)
            .lithePointer()
            .disabled(isCancelling || (!isResponding && (!hasContent || isBlocked || isPreparingSession || isConfiguring)))
            .help(isCancelling ? "Stopping…" : (isResponding ? "Stop" : "Send"))
        }
        .padding(.horizontal, 5)
        .frame(height: AgentComposerMetrics.toolbarHeight - 2)
        .background(AgentPanelStyle.toolbar, in: RoundedRectangle(cornerRadius: 7))
        .padding(1)
    }

    private var agentMenu: some View {
        LitheMenu {
            if agents.isEmpty { LitheContextMenuItem.heading("No Agent is set up yet") }
            for agent in agents {
                LitheContextMenuItem.action(agent.name, checked: agent.id == selectedAgent?.id) {
                    onSelectAgent(agent.id)
                }
            }
            LitheContextMenuItem.separator
            LitheContextMenuItem.action("Agent Settings…", action: onOpenSettings)
        } label: {
            AgentBrandIcon(name: selectedAgent?.name, size: 18, style: .brand)
                .foregroundStyle(AgentPanelStyle.secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.litheNoPress)
        .fixedSize()
        .help(selectedAgent?.name ?? String(localized: "Choose an Agent"))
        .accessibilityLabel("Switch Agent")
        .accessibilityIdentifier("agent-composer-agent-selector")
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

    private func complete(_ command: AgentCommand) {
        completion.complete(command)
        isFocused = true
    }

    private func handleCommandKey(_ key: AgentCommandCompletion.Key) -> AgentCommandCompletion.Result {
        let result = completion.handle(key, commands: commands, isResponding: isResponding)
        switch result {
        case .send: send()
        case .cancel: onCancel()
        case .handled: isFocused = true
        case .ignored: break
        }
        return result
    }

    private func send() {
        guard hasContent, !isResponding else { return }
        if isBlocked || isPreparingSession {
            onError(String(localized: "The conversation is still being prepared. Try again in a moment."))
            return
        }
        do {
            try onSend(completion.draft, files)
            completion.draft = ""
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
    let onKey: (AgentCommandCompletion.Key) -> AgentCommandCompletion.Result

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .onKeyPress(.upArrow) { handle(.up) }
                .onKeyPress(.downArrow) { handle(.down) }
                .onKeyPress(.tab) { handle(.tab) }
        } else {
            content
        }
    }

    @available(macOS 14.0, *)
    private func handle(_ key: AgentCommandCompletion.Key) -> KeyPress.Result {
        onKey(key) == .ignored ? .ignored : .handled
    }
}

/// The shared split container keeps resize updates outside the conversation model.
struct AgentConversationLayout<Transcript: View, Composer: View>: View {
    @ViewBuilder let transcript: Transcript
    @ViewBuilder let composer: Composer
    @State private var composerMinimumHeight = AgentComposerMetrics.minimumHeight(hasFiles: false)

    var body: some View {
        GeometryReader { geometry in
            let minimum = min(composerMinimumHeight, max(0, geometry.size.height - SplitHandleView.hitThickness))
            LitheSplitPaneView(
                axis: .vertical,
                placement: .trailing,
                defaultSize: min(210, geometry.size.height * 0.3),
                minimum: minimum,
                maximum: max(minimum, geometry.size.height * 0.6),
                showsIdleDivider: false
            ) {
                composer
                    .padding(.top, AgentComposerMetrics.splitTopInset)
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
        .onPreferenceChange(AgentComposerMinimumHeightKey.self) { composerMinimumHeight = $0 }
        .agentCommandSuggestionScope()
    }
}
