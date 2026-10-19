import SwiftUI
import UniformTypeIdentifiers
import LitheAgentConversationModule

/// Two-line writing area that grows with the draft above a single bottom command bar.
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
    /// Workspace files matching an `@` query; nil where no workspace is open.
    var findFiles: ((String) async -> [AgentFileMention])? = nil
    /// Refresh a bare @ when the workspace's initial scan or file inventory changes.
    var fileMentionRevision: UUID? = nil
    /// Saves a pasted image to platform storage and returns the file to attach.
    var savePastedImage: ((Data) throws -> URL)? = nil
    var showsToolbar = true
    var draftText: Binding<String>? = nil
    var draftFiles: Binding<[AgentFileReference]>? = nil
    var focusRequest: UInt = 0
    @State private var completion = AgentCommandCompletion()
    @State private var files: [AgentFileReference] = []
    @State private var isDropTargeted = false
    @State private var showsFilePicker = false
    @State private var mentionURLs: [String: URL] = [:]
    @State private var showsDetails = false
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
    private var showsStopAction: Bool {
        hasPendingContinuation || (isResponding && (!hasContent || isCancelling))
    }
    private var displayAgentName: String? { selectedAgent?.name ?? fallbackAgentName }
    private var commandSuggestions: [AgentCommand]? {
        completion.suggestions(in: commands)
    }
    private struct FileMentionRequest: Equatable {
        let query: String?
        let inventoryRevision: UUID?
    }
    private var fileMentionRequest: FileMentionRequest {
        let query = AgentCommand.mentionQuery(in: currentDraft)
        return FileMentionRequest(query: query, inventoryRevision: query == "" ? fileMentionRevision : nil)
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
            // Bound drafts are owned by the connection's session lifecycle.
            if draftFiles == nil, newSessionID != nil { attachments.removeAll() }
            showsDetails = false
        }
        .onAppear {
            if let draftText { completion.draft = draftText.wrappedValue }
            if focusRequest > 0 { isFocused = true }
        }
        .onChange(of: focusRequest) { _ in isFocused = true }
        .onChange(of: draftText?.wrappedValue) { value in
            if let value, value != completion.draft { completion.draft = value }
        }
        .task(id: fileMentionRequest) {
            await loadFileMentions(for: fileMentionRequest.query)
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
            LitheSearchTextField(findFiles == nil ? "Type your task or / for commands" : "Type your task, / for commands or @ for files", text: textBinding, axis: .vertical)
                .lineLimit(AgentComposerMetrics.minimumWritingLines...)
                .focused($isFocused)
                .background(AgentPasteAttachments(isActive: isFocused, onPaste: attachPasted))
                .onSubmit { _ = handleCommandKey(.submit) }
                .modifier(AgentCommandKeyNavigation(onKey: handleCommandKey))
                .padding(.horizontal, 8)
                .padding(.vertical, AgentComposerMetrics.writingVerticalInset)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        } toolbar: {
            if showsToolbar { toolbar }
        }
    }

    private var attachButton: some View {
        Button { showsFilePicker = true } label: {
            LitheIDEAIcon(resourcePath: "expui/general/add.svg", size: LitheTheme.Metrics.toolbarIconSize,
                          fallbackSystemImage: "plus", preservesOriginalColors: true)
        }
        .litheToolbarIconButton()
        .accessibilityLabel(isDropTargeted ? "Drop files here" : "Attach files")
        .accessibilityIdentifier("agent-composer-attach-files")
        .help("Drag files here or click to choose files")
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            attachButton
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
            if showsSubscriptionQuota {
                AgentSubscriptionQuotaView(quota: subscriptionQuota, account: subscriptionAccount, failure: quotaFailure)
                    .id(sessionID ?? selectedAgent?.id)
            }
            detailsButton
            Button(action: showsStopAction ? onCancel : send) {
                LitheIDEAIcon(resourcePath: showsStopAction ? "expui/run/stop.svg" : "collaboration/sendOutline.svg",
                              size: LitheTheme.Metrics.toolbarIconSize,
                              fallbackSystemImage: showsStopAction ? "stop.fill" : "paperplane", preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .disabled(showsStopAction ? isCancelling : (isCancelling || isSendingSupplement || hasPendingContinuation || !hasContent || isBlocked || isPreparingSession || isConfiguring || (isResponding && !canSteer)))
            .help(showsStopAction ? (isCancelling ? "Stopping…" : "Stop") : (isSendingSupplement ? "Sending…" : "Send"))
            .accessibilityLabel(showsStopAction ? "Stop" : "Send")
            .accessibilityIdentifier("agent-composer-primary-action")
        }
        .padding(.horizontal, AgentComposerMetrics.toolbarHorizontalInset)
        .frame(height: AgentComposerMetrics.toolbarHeight - 2)
    }

    private var detailsButton: some View {
        Button { showsDetails.toggle() } label: {
            if contextUsage != nil {
                AgentContextUsageView(usage: contextUsage, showsPercentage: false, showsHoverCard: false)
            } else {
                LitheIDEAIcon(resourcePath: "expui/status/info.svg", size: LitheTheme.Metrics.toolbarIconSize,
                              fallbackSystemImage: "info.circle", preservesOriginalColors: true)
                    .frame(width: LitheTheme.Metrics.toolbarIconButtonSize,
                           height: LitheTheme.Metrics.toolbarIconButtonSize)
            }
        }
        .buttonStyle(.litheNoPress)
        .accessibilityLabel("Show Session Details")
        .accessibilityValue(AgentContextUsagePresentation.details(contextUsage, locale: locale))
        .accessibilityIdentifier("agent-session-details")
        .workbenchHoverCard(placement: .above, maximumWidth: LitheDropdownMetrics.maximumWidth) {
            WorkbenchHoverTooltipLabel(title: Text(verbatim:
                AgentContextUsagePresentation.details(contextUsage, locale: locale)))
        }
        .litheDropdown(isPresented: $showsDetails, opensUpward: true) {
            AgentEditorDetailsPanel(statistics: sessionStatistics, contextUsage: contextUsage,
                                    onClose: { showsDetails = false })
                .frame(height: AgentEditorConversationMetrics.detailsPopupHeight)
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

    private func attachPasted(_ attachment: AgentPasteboardAttachment) -> Bool {
        switch attachment {
        case .files(let urls):
            return addFiles(urls)
        case .image(let png):
            guard let savePastedImage else { return false }
            do {
                return addFiles([try savePastedImage(png)])
            } catch {
                onError(error.localizedDescription)
                return true
            }
        }
    }

    private func complete(_ command: AgentCommand) {
        completion.complete(command)
        draftText?.wrappedValue = completion.draft
        if command.isFileMention { attachMention(command) }
        isFocused = true
    }

    private func attachMention(_ command: AgentCommand) {
        guard let url = mentionURLs[command.id] else { return }
        _ = addFiles([url])
    }

    /// Debounced so a fast typist searches once per pause, not per keystroke.
    private func loadFileMentions(for query: String?) async {
        guard let query, let findFiles else {
            completion.setFileMentions([], for: nil)
            return
        }
        // A bare @ lists the loaded workspace immediately; only searches debounce.
        if !query.isEmpty {
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
        }
        guard !Task.isCancelled else { return }
        let files = await findFiles(query)
        guard !Task.isCancelled else { return }
        mentionURLs = Dictionary(files.map { ("@" + $0.path, $0.url) }, uniquingKeysWith: { first, _ in first })
        completion.setFileMentions(files.map(AgentCommand.fileMention), for: query)
    }

    private func handleCommandKey(_ key: AgentCommandCompletion.Key) -> AgentCommandCompletion.Result {
        if let draftText { completion.draft = draftText.wrappedValue }
        defer { draftText?.wrappedValue = completion.draft }
        let result = completion.handle(key, commands: commands, isResponding: isResponding || hasPendingContinuation)
        switch result {
        case .send: send()
        case .cancel: onCancel()
        case .handled: isFocused = true
        case .attach(let command):
            draftText?.wrappedValue = completion.draft
            attachMention(command)
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
            let fixedHeight = composerMinimumHeight - AgentComposerMetrics.minimumWritingHeight
            let writingLimit = max(AgentComposerMetrics.minimumWritingHeight,
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
