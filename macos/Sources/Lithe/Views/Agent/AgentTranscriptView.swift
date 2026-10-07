import AppKit
import SwiftUI
import LitheAgentConversationModule

/// Groups adjacent ACP tool calls without changing the stored transcript.
/// Prose and user messages end a group, preserving the order of the conversation.
enum AgentTranscriptItem: Identifiable {
    case message(AgentConversationMessage)
    case toolGroup([AgentConversationMessage])
    case turnSummary(AgentTurnStatistics)

    var id: String {
        switch self {
        case .message(let message): message.id
        case .toolGroup(let tools): "tools:\(tools[0].id)"
        case .turnSummary(let turn): "turn:\(turn.id)"
        }
    }

    func matches(_ searchText: String) -> Bool {
        guard !searchText.isEmpty else { return true }
        switch self {
        case .message(let message): return message.text.localizedStandardContains(searchText)
        case .toolGroup(let tools): return tools.contains { Self.toolMatches($0, searchText) }
        case .turnSummary: return false
        }
    }

    static func toolMatches(_ message: AgentConversationMessage, _ searchText: String) -> Bool {
        message.text.localizedStandardContains(searchText)
            || message.toolDetails.input?.localizedStandardContains(searchText) == true
            || message.toolDetails.output?.localizedStandardContains(searchText) == true
            || message.toolDetails.content.contains {
                $0.title.localizedStandardContains(searchText) || $0.text.localizedStandardContains(searchText)
            } == true
            || message.toolDetails.locations.contains { $0.path.localizedStandardContains(searchText) } == true
    }

    static func grouped(_ messages: [AgentConversationMessage], turns: [AgentTurnStatistics] = []) -> [Self] {
        var items: [Self] = []
        var tools: [AgentConversationMessage] = []
        let summaries = turns.reduce(into: [String: AgentTurnStatistics]()) { result, turn in
            if let ending = turn.endingMessageID { result[ending] = turn }
        }
        for message in messages {
            if message.role == .tool {
                tools.append(message)
            } else {
                if !tools.isEmpty {
                    items.append(.toolGroup(tools))
                    tools.removeAll(keepingCapacity: true)
                }
                items.append(.message(message))
            }
            if let summary = summaries[message.id] {
                if !tools.isEmpty {
                    items.append(.toolGroup(tools))
                    tools.removeAll(keepingCapacity: true)
                }
                items.append(.turnSummary(summary))
            }
        }
        if !tools.isEmpty { items.append(.toolGroup(tools)) }
        return items
    }
}

/// Message list of the selected conversation, followed by the pending
/// permission request and a summary of this turn's tool activity.
struct AgentTranscriptView: View {
    @ObservedObject var feature: AgentConnectionModel
    let agentName: String?
    let agentVersion: String?
    let agents: [AgentOption]
    let onSelectAgent: (String) -> Void
    var searchText = ""
    var onOpenFile: (AgentToolDetails.Location) -> Void = { _ in }
    var onRestoreFile: (AgentFileChange) async throws -> Void = { _ in throw AgentEditRestoreError.unavailable }
    @State private var showsAgentPicker = false
    // A filtered-out row can be destroyed. Keep its preference in the owning
    // transcript view, isolated by session and message, until the actual data goes away.
    @State private var thoughtExpansions: [String: [String: AgentThoughtExpansion]] = [:]

    var body: some View {
        let conversation = feature.selectedConversation
        let sessionID = feature.selectedSessionID
        let messages = conversation?.messages ?? []
        let transcript = AgentTranscriptItem.grouped(messages, turns: conversation?.completedTurns ?? [])
            .filter { $0.matches(searchText) }
        // Only reasoning that is still streaming opens by default.
        let liveThoughtID = conversation?.responseStatus == .thinking && messages.last?.role == .thought
            ? messages.last?.id : nil
        VStack(spacing: 0) {
            if conversation?.isLoading != true && messages.isEmpty && feature.pendingNewConversationPrompt == nil {
                AgentHeroView(agentName: agentName, agentVersion: agentVersion) {
                    showsAgentPicker = true
                }
                .litheDropdown(isPresented: $showsAgentPicker) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(agents) { agent in
                            Button {
                                showsAgentPicker = false
                                onSelectAgent(agent.id)
                            } label: {
                                HStack {
                                    Text(agent.name)
                                    Spacer()
                                    if agent.name == agentName { Image(systemName: "checkmark") }
                                }
                                .frame(minHeight: LitheDropdownMetrics.rowHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(LitheDropdownRowStyle(isSelected: agent.name == agentName))
                        }
                    }
                    .padding(LitheDropdownMetrics.popupPadding)
                    .frame(width: 180)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if conversation?.isLoading == true {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading conversation…").foregroundStyle(LitheTheme.secondaryText)
                                }
                            }
                            if !searchText.isEmpty && transcript.isEmpty {
                                Text("No matching messages")
                                    .foregroundStyle(AgentPanelStyle.secondary)
                            }
                            ForEach(transcript) { item in
                                Group {
                                    switch item {
                                    case .message(let message):
                                        AgentMessageRow(
                                            message: message,
                                            isStreamingThought: liveThoughtID == message.id,
                                            isSearching: !searchText.isEmpty,
                                            thoughtExpansion: thoughtExpansion(for: message.id),
                                            onOpenFile: onOpenFile
                                        )
                                    case .toolGroup(let tools):
                                        AgentToolGroupView(messages: tools, searchText: searchText, onOpenFile: onOpenFile)
                                    case .turnSummary(let turn):
                                        AgentTurnStatisticsView(statistics: turn)
                                    }
                                }
                                .id(item.id)
                            }
                            if feature.selectedSessionID == nil, let prompt = feature.pendingNewConversationPrompt {
                                AgentMessageRow(message: AgentConversationMessage(id: "pending", role: .user, text: prompt))
                                    .id("pending")
                            }
                            if conversation?.isResponding == true || feature.isCreatingSession {
                                AgentResponseStatusRow(
                                    responseStatus: conversation?.responseStatus ?? .preparing,
                                    startedAt: conversation?.activeTurn?.startedAt ?? feature.pendingNewConversationStartedAt,
                                    hasStreamingThought: liveThoughtID != nil,
                                    retryAttempt: conversation?.retryAttempt,
                                    retryMaxAttempts: conversation?.retryMaxAttempts
                                ).id("responding")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: messages.last?.text) { _ in
                        if searchText.isEmpty, let last = transcript.last {
                            proxy.scrollTo(conversation?.isResponding == true ? "responding" : last.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: messages.count) { _ in
                        if searchText.isEmpty, let last = transcript.last {
                            proxy.scrollTo(conversation?.isResponding == true ? "responding" : last.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: conversation?.completedTurns.count) { _ in
                        if searchText.isEmpty, let last = transcript.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            if let permission = conversation?.permission {
                AgentPermissionCard(permission: permission, answer: { feature.answerPermission(optionID: $0) }, onOpenFile: onOpenFile)
            }
            AgentActivitySummaryBar(
                messages: messages, plan: conversation?.plan,
                reviewed: conversation?.reviewedFileChanges ?? [:],
                isResponding: conversation?.isResponding == true,
                isReviewing: feature.fileReviewSessionID != nil,
                reviewError: feature.fileReviewErrorSessionID == sessionID ? feature.fileReviewError : nil,
                onOpenFile: onOpenFile,
                onKeep: { changes in
                    if let sessionID { feature.keepFileChanges(changes, in: sessionID) }
                },
                onRestore: { changes in
                    if let sessionID {
                        await feature.restoreFileChanges(changes, in: sessionID, restore: onRestoreFile)
                    }
                }
            )
            .id(feature.selectedSessionID)
        }
        .onChange(of: feature.openSessionIDs) { sessionIDs in
            thoughtExpansions = thoughtExpansions.filter { sessionIDs.contains($0.key) }
        }
        .onChange(of: messages.map(\.id)) { messageIDs in
            // Use unfiltered messages: changing the search must never discard preferences.
            guard let sessionID = feature.selectedSessionID, let preferences = thoughtExpansions[sessionID] else { return }
            let retainedIDs = Set(messageIDs)
            thoughtExpansions[sessionID] = preferences.filter { retainedIDs.contains($0.key) }
        }
    }

    private func thoughtExpansion(for messageID: String) -> Binding<AgentThoughtExpansion> {
        guard let sessionID = feature.selectedSessionID else { return .constant(AgentThoughtExpansion()) }
        return Binding(
            get: { thoughtExpansions[sessionID]?[messageID] ?? AgentThoughtExpansion() },
            set: { thoughtExpansions[sessionID, default: [:]][messageID] = $0 }
        )
    }
}

/// Centered agent mark with its version; tapping it switches agents.
struct AgentHeroView: View {
    let agentName: String?
    let agentVersion: String?
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 16) {
            Button(action: onTap) {
                AgentBrandIcon(name: agentName, size: 60)
                    .foregroundStyle(isHovering ? AgentPanelStyle.secondary : AgentPanelStyle.logo)
            }
            .buttonStyle(.litheNoPress)
            .lithePointer()
            .accessibilityLabel("Switch Agent")
            .onHover { isHovering = $0 }
            .overlay(alignment: .topLeading) {
                if let agentVersion, !agentVersion.isEmpty {
                    Text("v\(agentVersion)")
                        .font(LitheTheme.uiFont(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .foregroundStyle(AgentPanelStyle.versionText)
                        .background(AgentPanelStyle.versionAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(AgentPanelStyle.versionAccent.opacity(0.4)))
                        .fixedSize()
                        .offset(x: 70, y: -2)
                }
            }
            Text(agentName.map { String(format: String(localized: "Send a message to %@"), $0) }
                 ?? String(localized: "Choose an Agent to start"))
                .font(LitheTheme.uiFont(size: 14))
                .foregroundStyle(AgentPanelStyle.logo)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help("Switch Agent")
    }
}

private struct AgentPermissionCard: View {
    let permission: AgentPermissionPrompt
    let answer: (String?) -> Void
    let onOpenFile: (AgentToolDetails.Location) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(LitheTheme.warning)
                Text("Permission required")
                    .font(LitheTheme.uiFont(size: 12.5, weight: .semibold))
            }
            Text(permission.title)
                .font(LitheTheme.uiFont(size: 12, design: .monospaced))
                .foregroundStyle(LitheTheme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !permission.details.isEmpty {
                ScrollView {
                    AgentToolEvidenceView(details: permission.details, onOpenFile: onOpenFile)
                }
                .frame(maxHeight: 180)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(permission.choices) { choice in
                    Button(choice.label) { answer(choice.id) }
                        .buttonStyle(.bordered)
                        .tint(choice.kind?.hasPrefix("reject") == true ? LitheTheme.error : LitheTheme.accent)
                }
                if !permission.choices.contains(where: { $0.kind?.hasPrefix("reject") == true }) {
                    Button("Deny") { answer(nil) }
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(LitheTheme.warning.opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

private struct AgentMessageRow: View {
    let message: AgentConversationMessage
    var isStreamingThought = false
    var isSearching = false
    var thoughtExpansion: Binding<AgentThoughtExpansion> = .constant(AgentThoughtExpansion())
    var onOpenFile: (AgentToolDetails.Location) -> Void = { _ in }

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(LitheTheme.uiFont(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(LitheTheme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }
        case .agent:
            AgentMarkdownMessage(text: message.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thought:
            AgentThoughtRow(text: message.text, isStreaming: isStreamingThought, isSearching: isSearching,
                            expansion: thoughtExpansion)
        case .tool:
            AgentToolGroupView(messages: [message], searchText: "", onOpenFile: onOpenFile)
        }
    }
}

struct AgentToolEvidenceView: View {
    let details: AgentToolDetails
    let onOpenFile: (AgentToolDetails.Location) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(details.locations.enumerated()), id: \.offset) { _, location in
                Button { onOpenFile(location) } label: {
                    Label(location.path + (location.line.map { ":\($0)" } ?? ""), systemImage: "doc")
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                    .buttonStyle(.litheNoPress)
                    .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                    .help(location.path)
            }
            if let input = details.input { evidence("Input", text: input) }
            ForEach(Array(details.content.enumerated()), id: \.offset) { _, content in
                evidence(content.title, text: content.text)
            }
            if let output = details.output { evidence("Result", text: output) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func evidence(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(LitheTheme.uiFont(size: 11, weight: .medium)).foregroundStyle(LitheTheme.secondaryText)
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        }
    }
}

/// Splits the reply into prose and fenced code blocks. Prose uses inline
/// Markdown; code blocks get a monospaced box with a copy button.
private struct AgentMarkdownMessage: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.segments(of: text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let prose):
                    Text(Self.markdown(prose))
                        .font(LitheTheme.uiFont(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let language, let code):
                    AgentCodeBlock(language: language, code: code)
                }
            }
        }
    }

    enum Segment: Equatable {
        case prose(String)
        case code(language: String, code: String)
    }

    /// Fences that have not been closed yet (still streaming) are treated as code.
    static func segments(of text: String) -> [Segment] {
        var segments: [Segment] = []
        var prose = ""
        var code = ""
        var language = ""
        var inCode = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                if inCode {
                    segments.append(.code(language: language, code: code.trimmingCharacters(in: .newlines)))
                    code = ""
                    inCode = false
                } else {
                    if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        segments.append(.prose(prose.trimmingCharacters(in: .newlines)))
                    }
                    prose = ""
                    language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
                continue
            }
            if inCode { code += line + "\n" } else { prose += line + "\n" }
        }
        if inCode {
            segments.append(.code(language: language, code: code.trimmingCharacters(in: .newlines)))
        } else if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(.prose(prose.trimmingCharacters(in: .newlines)))
        }
        return segments
    }

    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct AgentCodeBlock: View {
    let language: String
    let code: String
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? String(localized: "code") : language)
                    .font(LitheTheme.uiFont(size: 10.5, weight: .medium))
                    .foregroundStyle(LitheTheme.tertiaryText)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    didCopy = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); didCopy = false }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(LitheTheme.uiFont(size: 10.5))
                }
                .buttonStyle(.litheNoPress)
                .lithePointer()
                .foregroundStyle(didCopy ? LitheTheme.success : LitheTheme.tertiaryText)
                .help("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(LitheTheme.toolHeaderInactive)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(LitheTheme.codeFont)
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(LitheTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.panelBorder, lineWidth: 1))
    }
}
