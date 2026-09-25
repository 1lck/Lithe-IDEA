import Combine
import Foundation
import LitheCoreContracts

public struct AgentConversationMessage: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable { case user, agent, activity }
    public let id: UUID
    public let role: Role
    public var text: String

    public init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

public struct AgentPermissionChoice: Identifiable, Sendable {
    public let id: String
    public let label: String
}

public struct AgentPermissionPrompt: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let choices: [AgentPermissionChoice]
}

/// Owns one workspace conversation and batches streaming text before UI updates.
@MainActor
public final class AgentConversationFeatureModel: ObservableObject {
    @Published public private(set) var messages: [AgentConversationMessage] = []
    @Published public private(set) var isConnecting = false
    @Published public private(set) var isResponding = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var permission: AgentPermissionPrompt?

    private let transport: any AgentConversationTransport
    private var session: (any AgentConversationSession)?
    private var sessionGeneration = UUID()
    private var workspaceURL: URL?
    private var pendingText = ""
    private var flushTask: Task<Void, Never>?

    public var hasActiveSession: Bool { session != nil }

    public init(transport: any AgentConversationTransport) {
        self.transport = transport
    }

    public func send(_ prompt: String, configuration: AgentLaunchConfiguration) throws {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard !isResponding else { return }
        guard !configuration.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentConversationError.missingCommand
        }
        if workspaceURL != nil && workspaceURL != configuration.workspaceURL {
            throw AgentConversationError.workspaceChanged
        }
        if session == nil {
            let generation = UUID()
            sessionGeneration = generation
            isConnecting = true
            do {
                session = try transport.open(configuration: configuration) { [weak self] event in
                    Task { @MainActor [weak self] in
                        guard let self, self.sessionGeneration == generation else { return }
                        self.receive(event)
                    }
                }
            } catch {
                isConnecting = false
                throw error
            }
            workspaceURL = configuration.workspaceURL
        }
        messages.append(AgentConversationMessage(role: .user, text: prompt))
        messages.append(AgentConversationMessage(role: .agent, text: ""))
        errorMessage = nil
        isResponding = true
        do {
            try session?.send(prompt)
        } catch {
            isResponding = false
            errorMessage = error.localizedDescription
            throw error
        }
    }

    public func cancel() {
        session?.cancel()
    }

    public func answerPermission(optionID: String?) {
        guard let permission else { return }
        session?.answerPermission(requestID: permission.id, optionID: optionID)
        self.permission = nil
    }

    public func stop() async {
        sessionGeneration = UUID()
        flushPendingText()
        flushTask?.cancel()
        flushTask = nil
        answerPermission(optionID: nil)
        let oldSession = session
        session = nil
        workspaceURL = nil
        isConnecting = false
        isResponding = false
        await oldSession?.stop()
    }

    public func startNewConversation() async {
        await stop()
        messages.removeAll()
        errorMessage = nil
    }

    private func receive(_ json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String else { return }
        switch kind {
        case "ready": isConnecting = false
        case "update":
            guard let update = object["update"] as? [String: Any],
                  let updateKind = update["sessionUpdate"] as? String else { return }
            switch updateKind {
            case "agent_message_chunk":
                if let content = update["content"] as? [String: Any],
                   let text = content["text"] as? String {
                    pendingText += text
                    scheduleFlush()
                }
            case "tool_call", "tool_call_update":
                flushPendingText()
                let title = update["title"] as? String ?? "Agent tool call"
                messages.append(AgentConversationMessage(role: .activity, text: title))
            default: break
            }
        case "permission":
            guard let id = object["requestId"] as? String,
                  let request = object["request"] as? [String: Any] else { return }
            let tool = request["toolCall"] as? [String: Any]
            let title = tool?["title"] as? String ?? "Allow Agent action?"
            let options = (request["options"] as? [[String: Any]] ?? []).compactMap { option -> AgentPermissionChoice? in
                guard let id = option["optionId"] as? String,
                      let label = option["name"] as? String else { return nil }
                return AgentPermissionChoice(id: id, label: label)
            }
            permission = AgentPermissionPrompt(id: id, title: title, choices: options)
        case "turnFinished":
            flushPendingText()
            isResponding = false
        case "error":
            flushPendingText()
            isConnecting = false
            isResponding = false
            errorMessage = object["message"] as? String ?? "The Agent failed."
            Task { await stop() }
        case "stopped":
            flushPendingText()
            isConnecting = false
            isResponding = false
            if errorMessage == nil { errorMessage = "The Agent session ended." }
            Task { await stop() }
        default: break
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard let self, !Task.isCancelled else { return }
            self.flushPendingText()
            self.flushTask = nil
        }
    }

    private func flushPendingText() {
        guard !pendingText.isEmpty else { return }
        if let index = messages.indices.last, messages[index].role == .agent {
            messages[index].text += pendingText
        } else {
            messages.append(AgentConversationMessage(role: .agent, text: pendingText))
        }
        pendingText = ""
    }
}

public enum AgentConversationError: LocalizedError {
    case missingCommand
    case workspaceChanged

    public var errorDescription: String? {
        switch self {
        case .missingCommand: "Set an ACP Agent command before sending a message."
        case .workspaceChanged: "Close this conversation before switching workspaces."
        }
    }
}
