import SwiftUI
import LitheAgentConversationModule
import LitheCoreContracts

struct AgentConversationView: View {
    @ObservedObject var feature: AgentConversationFeatureModel
    @ObservedObject var settings: AppSettings
    let workspaceURL: URL?
    @State private var draft = ""
    @State private var localError: String?

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(title: "Agent") {
                Button("New conversation") {
                    Task { await feature.startNewConversation() }
                }
                .disabled(!feature.hasActiveSession && feature.messages.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if feature.messages.isEmpty {
                            Text("Ask an ACP Agent about this workspace.")
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                        ForEach(feature.messages) { message in
                            if !message.text.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(message.role == .user ? "You" : message.role == .agent ? "Agent" : "Activity")
                                        .font(.caption.bold())
                                    Text(message.text)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(message.id)
                            }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: feature.messages.count) { _ in
                    if let last = feature.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: feature.messages.last?.text) { _ in
                    if let last = feature.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if let permission = feature.permission {
                VStack(alignment: .leading, spacing: 8) {
                    Text(permission.title)
                    HStack {
                        ForEach(permission.choices) { choice in
                            Button(choice.label) { feature.answerPermission(optionID: choice.id) }
                        }
                        Button("Deny") { feature.answerPermission(optionID: nil) }
                    }
                }
                .padding(12)
            }
            if let error = localError ?? feature.errorMessage {
                Text(error).foregroundStyle(LitheTheme.warning).padding(.horizontal, 12)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Agent", text: $draft, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.roundedBorder)
                if feature.isResponding {
                    Button("Cancel") { feature.cancel() }
                } else {
                    Button("Send", action: send)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspaceURL == nil)
                }
            }
            .padding(12)
        }
    }

    private func send() {
        guard let workspaceURL else { return }
        let prompt = draft
        let arguments = settings.agentArguments
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        do {
            try feature.send(prompt, configuration: AgentLaunchConfiguration(
                command: settings.agentCommand,
                arguments: arguments,
                workspaceURL: workspaceURL
            ))
            draft = ""
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }
}
