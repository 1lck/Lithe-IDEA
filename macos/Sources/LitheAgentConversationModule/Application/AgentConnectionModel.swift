import Combine
import Foundation
import LitheCoreContracts

/// One entry of the agent-owned conversation history for the workspace.
public struct AgentSessionSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String?
    public var updatedAt: String?

    public init(id: String, title: String? = nil, updatedAt: String? = nil) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

public struct AgentConversationMessage: Identifiable, Equatable, Sendable {
    public enum Role: Equatable, Sendable { case user, agent, tool }
    /// ACP tool call status; absent means `pending`.
    public enum ToolStatus: String, Equatable, Sendable {
        case pending
        case inProgress = "in_progress"
        case completed
        case failed
    }

    public let id: String
    public let role: Role
    public var text: String
    public var toolStatus: ToolStatus?

    public init(id: String = UUID().uuidString, role: Role, text: String, toolStatus: ToolStatus? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.toolStatus = toolStatus
    }
}

public struct AgentPermissionChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
}

public struct AgentPermissionPrompt: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let choices: [AgentPermissionChoice]
}

/// Display state of one conversation session.
public struct AgentConversation: Equatable, Sendable {
    public var messages: [AgentConversationMessage] = []
    public var isResponding = false
    public var isLoading = false
    /// Whether the current connection knows this session (created or loaded on
    /// it). A new agent process must load a session before prompting it again.
    public var isAttached = false
    public var permission: AgentPermissionPrompt?
    public var errorMessage: String?

    public init() {}
}

/// Owns one agent's connection and conversations within a project, and
/// batches streaming text before UI updates.
@MainActor
public final class AgentConnectionModel: ObservableObject {
    public enum ConnectionState: Equatable, Sendable {
        case idle
        case connecting
        case ready
        case failed(String)
    }

    @Published public private(set) var connectionState: ConnectionState = .idle
    /// Name and version the agent reported on `ready`, for the panel header.
    @Published public private(set) var agentName: String?
    @Published public private(set) var agentVersion: String?
    @Published public private(set) var sessions: [AgentSessionSummary] = []
    /// `nil` selects a new, not yet created conversation.
    @Published public private(set) var selectedSessionID: String?
    @Published public private(set) var conversations: [String: AgentConversation] = [:]
    /// Sessions shown as tabs, in the order they were opened in this panel.
    @Published public private(set) var openSessionIDs: [String] = []
    /// Prompt of a new conversation while its session is being created.
    @Published public private(set) var pendingNewConversationPrompt: String?
    @Published public private(set) var canLoadSessions = false
    @Published public private(set) var errorMessage: String?

    /// Called when any conversation starts or stops waiting for a permission
    /// decision, so a background project can signal it.
    public var onAttentionChanged: ((Bool) -> Void)?

    private let transport: any AgentConversationTransport
    private var connection: (any AgentConnection)?
    private var eventTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<String>.Continuation?
    private var closeTask: Task<Void, Never>?
    private var canListSessions = false
    private var nextToken = 0
    /// Prompts waiting for a session: keyed by new-session token or by the
    /// session ID being loaded.
    private var queuedPrompts: [String: String] = [:]
    private var loadTokens: [String: String] = [:]
    private var pendingText: [String: String] = [:]
    private var flushTask: Task<Void, Never>?
    private var needsAttention = false

    public init(transport: any AgentConversationTransport) {
        self.transport = transport
    }

    public var hasActiveConnection: Bool { connection != nil }
    public var isCreatingSession: Bool { pendingNewConversationPrompt != nil }
    public var hasPendingPermission: Bool { conversations.values.contains { $0.permission != nil } }
    public var selectedConversation: AgentConversation? {
        selectedSessionID.flatMap { conversations[$0] }
    }

    // MARK: Connection

    /// Start the agent for this project. Does nothing while already connected.
    public func connect(configuration: AgentLaunchConfiguration) throws {
        guard connection == nil else { return }
        guard closeTask == nil else { throw AgentConversationError.sessionStopping }
        let (events, continuation) = AsyncStream<String>.makeStream()
        errorMessage = nil
        connectionState = .connecting
        do {
            connection = try transport.open(configuration: configuration) { event in
                continuation.yield(event)
            }
        } catch {
            continuation.finish()
            connectionState = .failed(error.localizedDescription)
            throw error
        }
        eventContinuation = continuation
        // One consumer keeps events in the order the connection produced them.
        eventTask = Task { [weak self] in
            for await event in events {
                self?.receive(event)
            }
        }
    }

    /// Show why the agent could not start, e.g. incomplete settings.
    public func reportConnectionFailure(_ message: String) {
        guard connection == nil else { return }
        connectionState = .failed(message)
    }

    /// Stop the agent and wait for its process tree to exit.
    public func stop() async {
        let old = detachConnection(failure: nil)
        await old?.close()
        if let closeTask { await closeTask.value }
    }

    public func refreshSessions() {
        guard canListSessions else { return }
        sendCommand(["kind": "listSessions", "token": makeToken()])
    }

    // MARK: Conversations

    public func startNewConversation() {
        selectedSessionID = nil
        errorMessage = nil
    }

    public func selectSession(_ sessionID: String) {
        selectedSessionID = sessionID
        errorMessage = nil
        openTab(sessionID)
        let conversation = conversations[sessionID]
        if conversation?.isAttached != true, conversation?.isLoading != true,
           connection != nil, canLoadSessions {
            beginLoad(sessionID)
        }
    }

    /// Close a tab. A conversation that is still responding or waiting for a
    /// permission decision stays open so its outcome is not lost.
    public func closeConversation(_ sessionID: String) {
        guard let conversation = conversations[sessionID],
              !conversation.isResponding, conversation.permission == nil else { return }
        openSessionIDs.removeAll { $0 == sessionID }
        conversations[sessionID] = nil
        pendingText[sessionID] = nil
        queuedPrompts[sessionID] = nil
        if selectedSessionID == sessionID {
            selectedSessionID = openSessionIDs.last
        }
    }

    public func send(_ text: String) throws {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard connection != nil else { throw AgentConversationError.notConnected }
        guard let sessionID = selectedSessionID else {
            guard !isCreatingSession else { return }
            let token = makeToken()
            queuedPrompts[token] = prompt
            pendingNewConversationPrompt = prompt
            errorMessage = nil
            sendCommand(["kind": "newSession", "token": token])
            return
        }
        let conversation = conversations[sessionID] ?? AgentConversation()
        guard !conversation.isResponding else { return }
        if conversation.isLoading {
            queuedPrompts[sessionID] = prompt
        } else if conversation.isAttached {
            startPrompt(prompt, in: sessionID)
        } else if canLoadSessions {
            queuedPrompts[sessionID] = prompt
            beginLoad(sessionID)
        } else {
            throw AgentConversationError.cannotResume
        }
    }

    public func cancel() {
        guard let sessionID = selectedSessionID,
              conversations[sessionID]?.isResponding == true else { return }
        // The host answers pending permissions with `cancelled` and reports
        // the turn as cancelled without waiting for the agent.
        conversations[sessionID]?.permission = nil
        updateAttention()
        if !sendCommand(["kind": "cancel", "sessionId": sessionID]) {
            conversations[sessionID]?.isResponding = false
        }
    }

    public func answerPermission(optionID: String?) {
        guard let sessionID = selectedSessionID,
              let permission = conversations[sessionID]?.permission else { return }
        conversations[sessionID]?.permission = nil
        updateAttention()
        sendCommand([
            "kind": "permission",
            "requestId": permission.id,
            "optionId": optionID.map { $0 as Any } ?? NSNull()
        ])
    }

    // MARK: Events

    func receive(_ json: String) {
        guard let data = json.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = event["kind"] as? String else { return }
        let sessionID = event["sessionId"] as? String
        let token = event["token"] as? String
        switch kind {
        case "ready":
            connectionState = .ready
            agentName = event["agentName"] as? String
            agentVersion = event["agentVersion"] as? String
            canLoadSessions = event["canLoadSessions"] as? Bool ?? false
            canListSessions = event["canListSessions"] as? Bool ?? false
            refreshSessions()
        case "sessions":
            mergeSessions(event["sessions"] as? [[String: Any]] ?? [])
        case "sessionCreated":
            guard let sessionID, let token else { return }
            sessionCreated(sessionID, token: token)
        case "sessionLoaded":
            guard let sessionID, let token, loadTokens.removeValue(forKey: token) != nil else { return }
            flushPendingText()
            conversations[sessionID, default: AgentConversation()].isLoading = false
            conversations[sessionID]?.isAttached = true
            if let prompt = queuedPrompts.removeValue(forKey: sessionID) {
                startPrompt(prompt, in: sessionID)
            }
        case "update":
            guard let sessionID, let update = event["update"] as? [String: Any] else { return }
            apply(update, to: sessionID)
        case "permission":
            guard let sessionID,
                  let requestID = event["requestId"] as? String,
                  let request = event["request"] as? [String: Any] else { return }
            conversations[sessionID, default: AgentConversation()].permission = permissionPrompt(requestID, request)
            updateAttention()
        case "turnFinished":
            guard let sessionID else { return }
            flushPendingText()
            conversations[sessionID]?.isResponding = false
            conversations[sessionID]?.permission = nil
            conversations[sessionID]?.errorMessage = stopReasonMessage(event["stopReason"] as? String)
            updateAttention()
        case "requestFailed":
            requestFailed(token: token, sessionID: sessionID, message: event["message"] as? String ?? "The Agent request failed.")
        case "stopped":
            let old = detachConnection(failure: event["message"] as? String)
            if let old {
                closeTask = Task { [weak self] in
                    await old.close()
                    self?.closeTask = nil
                }
            }
        default:
            break
        }
    }

    private func sessionCreated(_ sessionID: String, token: String) {
        let prompt = queuedPrompts.removeValue(forKey: token)
        if !sessions.contains(where: { $0.id == sessionID }) {
            sessions.insert(AgentSessionSummary(id: sessionID, title: prompt.map(Self.provisionalTitle)), at: 0)
        }
        var conversation = conversations[sessionID] ?? AgentConversation()
        conversation.isAttached = true
        conversations[sessionID] = conversation
        openTab(sessionID)
        guard let prompt else { return }
        pendingNewConversationPrompt = nil
        selectedSessionID = sessionID
        startPrompt(prompt, in: sessionID)
    }

    private func requestFailed(token: String?, sessionID: String?, message: String) {
        if let token, queuedPrompts.removeValue(forKey: token) != nil {
            pendingNewConversationPrompt = nil
            errorMessage = message
        } else if let token, let loading = loadTokens.removeValue(forKey: token) {
            queuedPrompts.removeValue(forKey: loading)
            conversations[loading]?.isLoading = false
            conversations[loading]?.errorMessage = message
        } else if let sessionID, conversations[sessionID] != nil {
            flushPendingText()
            conversations[sessionID]?.isResponding = false
            conversations[sessionID]?.errorMessage = message
        } else {
            errorMessage = message
        }
    }

    private func mergeSessions(_ entries: [[String: Any]]) {
        let listed = entries.compactMap { entry -> AgentSessionSummary? in
            guard let id = entry["sessionId"] as? String else { return nil }
            let local = sessions.first { $0.id == id }
            return AgentSessionSummary(
                id: id,
                title: entry["title"] as? String ?? local?.title,
                updatedAt: entry["updatedAt"] as? String
            )
        }
        let listedIDs = Set(listed.map(\.id))
        // Sessions created in this run may not be persisted by the agent yet.
        sessions = sessions.filter { !listedIDs.contains($0.id) && conversations[$0.id] != nil } + listed
    }

    private func apply(_ update: [String: Any], to sessionID: String) {
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            guard let text = Self.text(of: update) else { return }
            pendingText[sessionID, default: ""] += text
            scheduleFlush()
        case "user_message_chunk":
            guard let text = Self.text(of: update) else { return }
            flushPendingText()
            append(text, role: .user, to: sessionID)
        case "tool_call", "tool_call_update":
            guard let toolCallID = update["toolCallId"] as? String else { return }
            flushPendingText()
            upsertTool(toolCallID, update: update, in: sessionID)
        case "session_info_update":
            guard let title = update["title"] as? String, !title.isEmpty else { return }
            if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
                sessions[index].title = title
            } else {
                sessions.insert(AgentSessionSummary(id: sessionID, title: title), at: 0)
            }
        default:
            break
        }
    }

    private func append(_ text: String, role: AgentConversationMessage.Role, to sessionID: String) {
        var conversation = conversations[sessionID] ?? AgentConversation()
        if let last = conversation.messages.indices.last, conversation.messages[last].role == role {
            conversation.messages[last].text += text
        } else {
            conversation.messages.append(AgentConversationMessage(role: role, text: text))
        }
        conversations[sessionID] = conversation
    }

    private func upsertTool(_ toolCallID: String, update: [String: Any], in sessionID: String) {
        var conversation = conversations[sessionID] ?? AgentConversation()
        let id = "tool:\(toolCallID)"
        let status = (update["status"] as? String).flatMap(AgentConversationMessage.ToolStatus.init(rawValue:))
        let title = (update["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let index = conversation.messages.firstIndex(where: { $0.id == id }) {
            if let title { conversation.messages[index].text = title }
            if let status { conversation.messages[index].toolStatus = status }
        } else {
            conversation.messages.append(AgentConversationMessage(
                id: id,
                role: .tool,
                text: title ?? "Tool call",
                toolStatus: status ?? .pending
            ))
        }
        conversations[sessionID] = conversation
    }

    private func permissionPrompt(_ requestID: String, _ request: [String: Any]) -> AgentPermissionPrompt {
        let tool = request["toolCall"] as? [String: Any]
        let options = (request["options"] as? [[String: Any]] ?? []).compactMap { option -> AgentPermissionChoice? in
            guard let id = option["optionId"] as? String, let label = option["name"] as? String else { return nil }
            return AgentPermissionChoice(id: id, label: label)
        }
        return AgentPermissionPrompt(
            id: requestID,
            title: tool?["title"] as? String ?? "Allow the Agent to continue?",
            choices: options
        )
    }

    // MARK: Helpers

    private func startPrompt(_ prompt: String, in sessionID: String) {
        var conversation = conversations[sessionID] ?? AgentConversation()
        conversation.messages.append(AgentConversationMessage(role: .user, text: prompt))
        conversation.isResponding = true
        conversation.errorMessage = nil
        conversations[sessionID] = conversation
        if !sendCommand(["kind": "prompt", "sessionId": sessionID, "text": prompt]) {
            conversations[sessionID]?.isResponding = false
        }
    }

    private func beginLoad(_ sessionID: String) {
        let token = makeToken()
        loadTokens[token] = sessionID
        pendingText[sessionID] = nil
        // The agent replays the whole history, so rebuild it from scratch.
        var conversation = AgentConversation()
        conversation.isLoading = true
        conversations[sessionID] = conversation
        sendCommand(["kind": "loadSession", "token": token, "sessionId": sessionID])
    }

    /// Returns false and records the error when the command could not be queued.
    @discardableResult
    private func sendCommand(_ command: [String: Any]) -> Bool {
        guard let connection else {
            errorMessage = AgentConversationError.notConnected.localizedDescription
            return false
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: command)
            try connection.send(commandJSON: String(decoding: data, as: UTF8.self))
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Clears connection state; returns the connection that still has to be closed.
    private func detachConnection(failure: String?) -> (any AgentConnection)? {
        flushPendingText()
        flushTask?.cancel()
        flushTask = nil
        // Events still buffered for the old connection must not be applied.
        eventContinuation?.finish()
        eventContinuation = nil
        eventTask?.cancel()
        eventTask = nil
        let old = connection
        connection = nil
        connectionState = failure.map(ConnectionState.failed) ?? .idle
        canListSessions = false
        queuedPrompts.removeAll()
        loadTokens.removeAll()
        pendingNewConversationPrompt = nil
        for id in conversations.keys {
            conversations[id]?.isResponding = false
            conversations[id]?.isLoading = false
            conversations[id]?.isAttached = false
            conversations[id]?.permission = nil
        }
        updateAttention()
        return old
    }

    private func openTab(_ sessionID: String) {
        guard !openSessionIDs.contains(sessionID) else { return }
        openSessionIDs.append(sessionID)
    }

    private func makeToken() -> String {
        nextToken += 1
        return "lithe-\(nextToken)"
    }

    private func updateAttention() {
        let attention = hasPendingPermission
        guard attention != needsAttention else { return }
        needsAttention = attention
        onAttentionChanged?(attention)
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flushPendingText()
        }
    }

    private func flushPendingText() {
        let pending = pendingText
        pendingText.removeAll()
        for (sessionID, text) in pending where !text.isEmpty {
            append(text, role: .agent, to: sessionID)
        }
    }

    private func stopReasonMessage(_ reason: String?) -> String? {
        switch reason {
        case "max_tokens": "The response stopped at the model's token limit."
        case "max_turn_requests": "The Agent stopped after reaching its request limit for this turn."
        case "refusal": "The Agent declined to continue."
        default: nil
        }
    }

    private static func text(of update: [String: Any]) -> String? {
        guard let content = update["content"] as? [String: Any],
              content["type"] as? String == "text" else { return nil }
        return content["text"] as? String
    }

    private static func provisionalTitle(_ prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }
}

public enum AgentConversationError: LocalizedError, Equatable {
    case featureDisabled
    case noAgentConfigured
    case moduleStarting
    case missingCommand
    case missingProvider
    case missingAPIKey
    case notConnected
    case sessionStopping
    case cannotResume

    public var errorDescription: String? {
        switch self {
        case .featureDisabled: String(localized: "Agent conversation is turned off. Turn it on in the panel settings to send messages.")
        case .noAgentConfigured: String(localized: "No Agent is ready yet. Open the panel settings to install an Agent and fetch its local configuration.")
        case .moduleStarting: String(localized: "The Agent module is still starting. Try again in a moment.")
        case .missingCommand: String(localized: "Set the custom Agent's executable in the panel settings.")
        case .missingProvider: String(localized: "Fetch this Agent's local configuration in the panel settings.")
        case .missingAPIKey: String(localized: "Your local configuration has no API key for this Agent. Add one, then fetch the configuration again.")
        case .notConnected: String(localized: "The Agent is not running. Connect to start a conversation.")
        case .sessionStopping: String(localized: "The previous Agent is still stopping. Try again shortly.")
        case .cannotResume: String(localized: "This Agent cannot reopen earlier conversations. Start a new conversation.")
        }
    }
}
