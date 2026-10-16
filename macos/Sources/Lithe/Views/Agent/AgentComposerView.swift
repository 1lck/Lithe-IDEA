import SwiftUI
import UniformTypeIdentifiers
import LitheAgentConversationModule

/// Context strip, flexible writing area, and a compact bottom command bar.
struct AgentComposerView: View {
    @Environment(\.locale) private var locale
    let agents: [AgentOption]
    let selectedAgent: AgentOption?
    let isResponding: Bool
    let isBlocked: Bool
    let onSend: (String, [AgentFileReference]) throws -> Void
    let onCancel: () -> Void
    let onSelectAgent: (String) -> Void
    let onOpenSettings: () -> Void
    let onError: (String?) -> Void
    var fallbackAgentName: String? = nil
    var configOptions: [AgentSessionConfigOption] = []
    var sessionID: String?
    var isPreparingSession = false
    var isConfiguring = false
    var isCancelling = false
    var canSteer = false
    var isSendingSupplement = false
    var hasPendingContinuation = false
    var contextUsage: AgentContextUsage?
    var sessionStatistics: AgentSessionStatistics?
    var showsSubscriptionQuota = false
    var subscriptionQuota: AgentSubscriptionQuota?
    var subscriptionAccount: String?
    var quotaFailure: String?
    var onSetConfig: (String, String) -> Void = { _, _ in }
    var commands: [AgentCommand] = []
    var showsToolbar = true
    var draftText: Binding<String>? = nil
    var draftFiles: Binding<[AgentFileReference]>? = nil
    var detailsContent: (() -> AnyView)? = nil
    @State private var completion = AgentCommandCompletion()
    @State private var files: [AgentFileReference] = []
    @State private var isDropTargeted = false
    @State private var showsFilePicker = false
    @State private var showsDetails = false
    @State private var showsContext = false
    @FocusState private var isFocused: Bool

    private var attachments: [AgentFileReference] {
        get { draftFiles?.wrappedValue ?? files }
        nonmutating set {
            if let draftFiles { draftFiles.wrappedValue = newValue }
            else { files = newValue }
        }
    }
    private var textBinding: Binding<String> {
        Binding(get: { draftText?.wrappedValue ?? completion.draft }, set: {
            completion.draft = $0
            draftText?.wrappedValue = $0
        })
    }
    private var currentDraft: String { draftText?.wrappedValue ?? completion.draft }
    private var hasContent: Bool { !currentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }
    private var displayAgentName: String? { selectedAgent?.name ?? fallbackAgentName }
    private var commandSuggestions: [AgentCommand]? {
        completion.suggestions(in: commands)
    }

    var body: some View {
        composerContent
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
            if newSessionID != nil { attachments.removeAll() }
            showsDetails = false
            showsContext = false
        }
        .onAppear { if let draftText { completion.draft = draftText.wrappedValue } }
        .onChange(of: draftText?.wrappedValue) { value in
            if let value, value != completion.draft { completion.draft = value }
        }
        .padding(.horizontal, AgentComposerMetrics.horizontalInset)
        .padding(.bottom, AgentComposerMetrics.bottomInset)
        .onExitCommand { _ = handleCommandKey(.escape) }
    }

    private var composerContent: some View {
        AgentComposerContent(files: attachments, commands: commandSuggestions,
                             highlightedIndex: completion.highlightedIndex,
                             onSelect: complete, onRemoveFile: { id in attachments.removeAll { $0.id == id } },
                             onFocus: { isFocused = true }, isFocused: isFocused || isDropTargeted) {
            if showsToolbar { contextBar }
            else { Color.clear.frame(height: AgentComposerMetrics.contextHeight - 1).accessibilityHidden(true) }
        } editor: {
            LitheSearchTextField("Type your task or / for commands", text: textBinding, axis: .vertical)
                .lineLimit(1...)
                .focused($isFocused)
                .onSubmit { _ = handleCommandKey(.submit) }
                .modifier(AgentCommandKeyNavigation(onKey: handleCommandKey))
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        } toolbar: {
            if showsToolbar { toolbar }
        }
    }

    private var contextBar: some View {
        HStack(spacing: 6) {
            Button { showsFilePicker = true } label: {
                LitheIDEAIcon(resourcePath: "expui/general/add.svg", size: LitheTheme.Metrics.toolbarIconSize,
                              fallbackSystemImage: "plus", preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .accessibilityLabel(isDropTargeted ? "Drop files here" : "Attach files")
            .help("Drag files here or click to choose files")
            Spacer(minLength: 0)
            if showsSubscriptionQuota {
                AgentSubscriptionQuotaView(quota: subscriptionQuota, account: subscriptionAccount, failure: quotaFailure)
                    .id(sessionID ?? selectedAgent?.id)
            }
            Button { showsContext = false; showsDetails.toggle() } label: {
                LitheIDEAIcon(resourcePath: "expui/status/info.svg", size: LitheTheme.Metrics.toolbarIconSize,
                              fallbackSystemImage: "info.circle", preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .help("Show Session Details")
            .accessibilityLabel("Session statistics")
            .accessibilityIdentifier("agent-session-details")
            .litheDropdown(isPresented: $showsDetails, opensUpward: true) {
                Group {
                    if let detailsContent { detailsContent() }
                    else {
                        AgentEditorDetailsPanel(statistics: sessionStatistics, contextUsage: contextUsage,
                            fileChanges: [], workspace: { EmptyView() })
                            .frame(height: AgentEditorConversationMetrics.detailsPopupHeight)
                    }
                }
            }
        }
        .font(LitheTheme.uiFont(size: 11))
        .foregroundStyle(AgentPanelStyle.secondary)
        .padding(.horizontal, AgentComposerMetrics.toolbarHorizontalInset)
        .frame(height: AgentComposerMetrics.contextHeight - 2)
        .background(AgentPanelStyle.context)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            agentMenu
            if isPreparingSession {
                Label("Loading session settings…", systemImage: "hourglass")
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(AgentPanelStyle.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("agent-session-settings-loading")
            } else if !configOptions.isEmpty {
                AgentSessionSelectors(options: configOptions, agentName: selectedAgent?.name,
                    isDisabled: isBlocked || isConfiguring, appliesToNextTurn: isResponding, onSelect: onSetConfig)
                    .id(sessionID ?? selectedAgent?.id)
                if isConfiguring { ProgressView().controlSize(.mini) }
            } else if let model = selectedAgent?.modelName, !model.isEmpty {
                Text(model).font(LitheTheme.uiFont(size: 11)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(AgentPanelStyle.secondary).help(model)
            }
            Spacer(minLength: 0)
            contextButton
            if isResponding || hasPendingContinuation {
                Button(action: onCancel) {
                    LitheIDEAIcon(resourcePath: "expui/run/stop.svg", size: LitheTheme.Metrics.toolbarIconSize,
                                  fallbackSystemImage: "stop.fill", preservesOriginalColors: true)
                }
                .litheToolbarIconButton()
                .disabled(isCancelling)
                .help(isCancelling ? "Stopping…" : "Stop")
                .accessibilityLabel("Stop")
            }
            Button(action: send) {
                LitheIDEAIcon(resourcePath: "collaboration/sendOutline.svg", size: LitheTheme.Metrics.toolbarIconSize,
                              fallbackSystemImage: "paperplane", preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .disabled(isCancelling || isSendingSupplement || hasPendingContinuation || !hasContent || isBlocked || isPreparingSession || isConfiguring || (isResponding && !canSteer))
            .help(isSendingSupplement ? "Sending…" : "Send")
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, AgentComposerMetrics.toolbarHorizontalInset)
        .frame(height: AgentComposerMetrics.toolbarHeight - 2)
    }

    private var contextButton: some View {
        Button { showsDetails = false; showsContext.toggle() } label: {
            AgentContextUsageView(usage: contextUsage, showsPercentage: false, showsHoverCard: false)
        }
        .buttonStyle(.litheNoPress)
        .workbenchHoverCard(placement: .above, maximumWidth: LitheDropdownMetrics.maximumWidth) {
            WorkbenchHoverTooltipLabel(title: Text(verbatim:
                AgentContextUsagePresentation.details(contextUsage, locale: locale)))
        }
        .litheDropdown(isPresented: $showsContext, opensUpward: true) {
            AgentContextPanel(usage: contextUsage, composition: sessionStatistics?.modelCalls?.latestContext,
                              onClose: { showsContext = false })
            .padding(14)
            .frame(width: AgentContextPanel.popoverWidth)
        }
    }

    private var agentMenu: some View {
        LitheMenu(opensUpward: true) {
            LitheContextMenuItem.heading("Agents")
            if agents.isEmpty { LitheContextMenuItem.heading("No Agent is set up yet") }
            for agent in agents {
                LitheContextMenuItem.action(
                    agent.name,
                    icon: AnyView(AgentBrandIcon(name: agent.name, size: 16, style: .brand)),
                    checked: agent.id == selectedAgent?.id || (selectedAgent == nil && agent.name == fallbackAgentName)
                ) {
                    onSelectAgent(agent.id)
                }
            }
            LitheContextMenuItem.separator
            LitheContextMenuItem.action("Agent Settings…", action: onOpenSettings)
        } label: {
            AgentBrandIcon(name: displayAgentName, size: LitheTheme.Metrics.toolbarIconSize, style: .brand)
                .foregroundStyle(AgentPanelStyle.secondary)
        }
        .litheToolbarIconButton()
        .help(displayAgentName ?? AgentLocalization.string("Choose an Agent", locale: locale))
        .accessibilityLabel("Switch Agent")
        .accessibilityIdentifier("agent-composer-agent-selector")
    }

    private func addFiles(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        do {
            attachments = try AgentFileReference.adding(urls, to: attachments)
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
        draftText?.wrappedValue = completion.draft
        isFocused = true
    }

    private func handleCommandKey(_ key: AgentCommandCompletion.Key) -> AgentCommandCompletion.Result {
        if let draftText { completion.draft = draftText.wrappedValue }
        defer { draftText?.wrappedValue = completion.draft }
        let result = completion.handle(key, commands: commands, isResponding: isResponding || hasPendingContinuation)
        switch result {
        case .send: send()
        case .cancel: onCancel()
        case .handled: isFocused = true
        case .ignored: break
        }
        return result
    }

    private func send() {
        guard hasContent, !isCancelling, !isSendingSupplement, !hasPendingContinuation, !isResponding || canSteer else { return }
        if isBlocked || isPreparingSession {
            onError("The conversation is still being prepared. Try again in a moment.")
            return
        }
        do {
            try onSend(currentDraft, attachments)
            completion.draft = ""
            draftText?.wrappedValue = ""
            attachments.removeAll()
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
    @Environment(\.locale) private var locale
    @ViewBuilder let transcript: Transcript
    @ViewBuilder let composer: Composer
    @State private var composerMinimumHeight = AgentComposerMetrics.minimumHeight(hasFiles: false)

    var body: some View {
        GeometryReader { geometry in
            let fixedHeight = composerMinimumHeight - AgentComposerMetrics.writingLineHeight
            let writingLimit = max(AgentComposerMetrics.writingLineHeight,
                min(AgentComposerMetrics.maximumWritingHeight, geometry.size.height * 0.6 - fixedHeight))
            VStack(spacing: 0) {
                transcript.frame(maxWidth: .infinity, maxHeight: .infinity)
                composer
                    .padding(.top, AgentComposerMetrics.splitTopInset)
                    .environment(\.agentComposerMaximumWritingHeight, writingLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onPreferenceChange(AgentComposerMinimumHeightKey.self) { composerMinimumHeight = $0 }
        .agentCommandSuggestionScope()
    }
}
