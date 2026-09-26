import AppKit
import SwiftUI
import LitheAgentConversationModule

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
    @State private var showsAgentPicker = false

    var body: some View {
        let conversation = feature.selectedConversation
        let messages = conversation?.messages ?? []
        VStack(spacing: 0) {
            if conversation?.isLoading != true && messages.isEmpty && feature.pendingNewConversationPrompt == nil {
                AgentHeroView(agentName: agentName, agentVersion: agentVersion) {
                    showsAgentPicker = true
                }
                .popover(isPresented: $showsAgentPicker, arrowEdge: .bottom) {
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
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .litheRowHover()
                        }
                    }
                    .padding(6)
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
                            if !searchText.isEmpty && !messages.contains(where: { $0.text.localizedStandardContains(searchText) }) {
                                Text("No matching messages")
                                    .foregroundStyle(AgentPanelStyle.secondary)
                            }
                            ForEach(messages.filter { searchText.isEmpty || $0.text.localizedStandardContains(searchText) }) { message in
                                AgentMessageRow(message: message, onOpenFile: onOpenFile).id(message.id)
                            }
                            if feature.selectedSessionID == nil, let prompt = feature.pendingNewConversationPrompt {
                                AgentMessageRow(message: AgentConversationMessage(id: "pending", role: .user, text: prompt))
                                    .id("pending")
                            }
                            if conversation?.isResponding == true || feature.isCreatingSession {
                                AgentThinkingRow(isCancelling: conversation?.isCancelling == true).id("responding")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: messages.last?.text) { _ in
                        if searchText.isEmpty, let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .onChange(of: messages.count) { _ in
                        if searchText.isEmpty, let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            if let permission = conversation?.permission {
                AgentPermissionCard(permission: permission, answer: { feature.answerPermission(optionID: $0) }, onOpenFile: onOpenFile)
            }
            AgentActivitySummaryBar(messages: messages)
        }
    }
}

private struct AgentThinkingRow: View {
    var isCancelling = false
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(isCancelling ? "Stopping…" : "Thinking…")
                .font(.system(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .padding(.leading, 2)
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
            .buttonStyle(.plain)
            .lithePointer()
            .accessibilityLabel("Switch Agent")
            .onHover { isHovering = $0 }
            .overlay(alignment: .topLeading) {
                if let agentVersion, !agentVersion.isEmpty {
                    Text("v\(agentVersion)")
                        .font(.system(size: 10, weight: .medium))
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
                .font(.system(size: 14))
                .foregroundStyle(AgentPanelStyle.logo)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help("Switch Agent")
    }
}

/// Three segments below the transcript: tool tasks, running, edits. Kept
/// visible even when empty so the layout does not jump when the first tool
/// call arrives. Edits count tool calls the agent titled as file changes.
struct AgentActivitySummaryBar: View {
    let messages: [AgentConversationMessage]

    private var tools: [AgentConversationMessage] { messages.filter { $0.role == .tool } }
    private var running: Int { tools.filter { $0.toolStatus == .inProgress || $0.toolStatus == .pending }.count }
    private var failed: Int { tools.filter { $0.toolStatus == .failed }.count }
    private var edits: Int {
        tools.filter { message in
            message.toolDetails.kind == "edit" || message.toolDetails.kind == "delete"
        }.count
    }

    var body: some View {
        HStack(spacing: 0) {
            segment(systemImage: "checklist", title: "Tasks", value: tools.count, tint: failed > 0 ? LitheTheme.error : nil)
            Divider().frame(height: 14).overlay(LitheTheme.divider)
            segment(systemImage: "arrow.triangle.2.circlepath", title: "Running", value: running, tint: running > 0 ? LitheTheme.accent : nil)
            Divider().frame(height: 14).overlay(LitheTheme.divider)
            segment(systemImage: "pencil", title: "Edits", value: edits, tint: nil)
        }
        .font(.system(size: 11))
        .foregroundStyle(AgentPanelStyle.muted)
        .frame(height: 32)
        .background(AgentPanelStyle.header, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(AgentPanelStyle.border, lineWidth: 1))
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }

    private func segment(systemImage: String, title: LocalizedStringKey, value: Int, tint: Color?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 10))
            Text(title)
            if value > 0 {
                Text("\(value)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint ?? LitheTheme.primaryText)
            }
        }
        .frame(maxWidth: .infinity)
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
                    .font(.system(size: 12.5, weight: .semibold))
            }
            Text(permission.title)
                .font(.system(size: 12, design: .monospaced))
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
    var onOpenFile: (AgentToolDetails.Location) -> Void = { _ in }

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(LitheTheme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }
        case .agent:
            AgentMarkdownMessage(text: message.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            AgentToolCallRow(message: message, onOpenFile: onOpenFile)
        }
    }
}

private struct AgentToolCallRow: View {
    let message: AgentConversationMessage
    let onOpenFile: (AgentToolDetails.Location) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                header
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide tool details" : "Show tool details")
            if expanded && !message.toolDetails.isEmpty {
                AgentToolEvidenceView(details: message.toolDetails, onOpenFile: onOpenFile)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .background(LitheTheme.raised, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.panelBorder, lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if message.toolStatus == .inProgress || message.toolStatus == .pending {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 14, height: 14)
            Text(message.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var icon: String {
        switch message.toolStatus {
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .interrupted: "pause.circle"
        default: "circle.dotted"
        }
    }

    private var tint: Color {
        switch message.toolStatus {
        case .completed: LitheTheme.success
        case .failed: LitheTheme.error
        default: LitheTheme.tertiaryText
        }
    }
}

private struct AgentToolEvidenceView: View {
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
                    .buttonStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
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
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(LitheTheme.secondaryText)
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
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
                        .font(.system(size: 13))
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
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LitheTheme.tertiaryText)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    didCopy = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); didCopy = false }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
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
