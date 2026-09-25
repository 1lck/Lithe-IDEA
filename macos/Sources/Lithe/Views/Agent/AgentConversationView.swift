import SwiftUI
import LitheAgentConversationModule

struct AgentConversationView: View {
    @ObservedObject var feature: AgentConversationFeatureModel
    let onConnect: () -> Void
    @State private var draft = ""
    @State private var localError: String?

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(title: "Agent") {
                sessionMenu
                Button {
                    feature.startNewConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(LitheIconButtonStyle())
                .help("New conversation")
                .disabled(feature.selectedSessionID == nil)
            }
            switch feature.connectionState {
            case .idle, .connecting:
                statusView {
                    ProgressView().controlSize(.small)
                    Text("Starting the Agent…").foregroundStyle(LitheTheme.secondaryText)
                }
                .onAppear {
                    if feature.connectionState == .idle { onConnect() }
                }
            case .failed(let message):
                statusView {
                    Text(message)
                        .foregroundStyle(LitheTheme.warning)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Retry", action: onConnect)
                }
            case .ready:
                conversationView
            }
        }
    }

    private var sessionMenu: some View {
        Menu {
            Button("New conversation") { feature.startNewConversation() }
            if !feature.sessions.isEmpty {
                Divider()
                ForEach(feature.sessions) { session in
                    Button {
                        feature.selectSession(session.id)
                    } label: {
                        if session.id == feature.selectedSessionID {
                            Label(Self.title(of: session), systemImage: "checkmark")
                        } else {
                            Text(Self.title(of: session))
                        }
                    }
                }
            }
            Divider()
            Button("Refresh history") { feature.refreshSessions() }
        } label: {
            Text(selectedTitle)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Conversation history")
    }

    private var selectedTitle: String {
        guard let id = feature.selectedSessionID else { return "New conversation" }
        return feature.sessions.first { $0.id == id }.map(Self.title(of:)) ?? "Conversation"
    }

    private var conversationView: some View {
        let conversation = feature.selectedConversation
        let messages = conversation?.messages ?? []
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if conversation?.isLoading == true {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Loading conversation…").foregroundStyle(LitheTheme.secondaryText)
                            }
                        } else if messages.isEmpty && feature.pendingNewConversationPrompt == nil {
                            Text("Ask the Agent about this workspace.")
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                        ForEach(messages) { message in
                            AgentMessageRow(message: message).id(message.id)
                        }
                        if feature.selectedSessionID == nil, let prompt = feature.pendingNewConversationPrompt {
                            AgentMessageRow(message: AgentConversationMessage(id: "pending", role: .user, text: prompt))
                                .id("pending")
                        }
                        if conversation?.isResponding == true || feature.isCreatingSession {
                            ProgressView().controlSize(.small).id("responding")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.last?.text) { _ in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if let permission = conversation?.permission {
                permissionBar(permission)
            }
            if let error = localError ?? conversation?.errorMessage ?? feature.errorMessage {
                Text(error)
                    .foregroundStyle(LitheTheme.warning)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
            composer(isResponding: conversation?.isResponding == true)
        }
    }

    private func permissionBar(_ permission: AgentPermissionPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(permission.title, systemImage: "hand.raised")
                .font(.body.weight(.medium))
            HStack {
                ForEach(permission.choices) { choice in
                    Button(choice.label) { feature.answerPermission(optionID: choice.id) }
                }
                Button("Deny") { feature.answerPermission(optionID: nil) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(LitheTheme.hoverBackground)
    }

    private func composer(isResponding: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message the Agent", text: $draft, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
            if isResponding {
                Button("Cancel") { feature.cancel() }
            } else {
                Button("Send", action: send)
                    .disabled(
                        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || feature.isCreatingSession
                            || feature.selectedConversation?.isLoading == true
                    )
            }
        }
        .padding(12)
    }

    private func statusView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    private func send() {
        do {
            try feature.send(draft)
            draft = ""
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private static func title(of session: AgentSessionSummary) -> String {
        guard let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "Untitled conversation"
        }
        return title
    }
}

private struct AgentMessageRow: View {
    let message: AgentConversationMessage

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .leading, spacing: 4) {
                Text("You").font(.caption.bold()).foregroundStyle(LitheTheme.secondaryText)
                Text(message.text).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(LitheTheme.hoverBackground, in: RoundedRectangle(cornerRadius: 6))
        case .agent:
            Text(Self.markdown(message.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Label {
                Text(message.text).lineLimit(2)
            } icon: {
                Image(systemName: Self.icon(for: message.toolStatus))
            }
            .font(.callout)
            .foregroundStyle(LitheTheme.secondaryText)
        }
    }

    /// Inline Markdown keeps line breaks and renders emphasis, code and links;
    /// text that fails to parse is shown as typed.
    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private static func icon(for status: AgentConversationMessage.ToolStatus?) -> String {
        switch status {
        case .completed: "checkmark.circle"
        case .failed: "xmark.circle"
        case .inProgress: "arrow.triangle.2.circlepath"
        case .pending, nil: "circle.dotted"
        }
    }
}
