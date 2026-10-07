import Combine
import Foundation
import LitheCoreContracts

/// Owns one agent's connection and conversations within a project, and
/// batches streaming text before UI updates.
@MainActor
public final class AgentConnectionModel: ObservableObject {
    public enum ConnectionState: Equatable, Sendable {
        case idle
        case connecting
        case authenticationRequired
        case authenticating
        case ready
        case failed(String)
    }

    @Published public private(set) var connectionState: ConnectionState = .idle
    @Published public private(set) var usesSubscription = false
    @Published public private(set) var subscriptionEmail: String?
    @Published public private(set) var subscriptionPlan: String?
    @Published public private(set) var subscriptionQuota: AgentSubscriptionQuota?
    @Published public private(set) var quotaFailure: String?

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
    @Published public private(set) var isRefreshingSessions = false
    @Published public private(set) var historyError: String?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var fileReviewSessionID: String?
    @Published public private(set) var fileReviewError: String?
    @Published public private(set) var fileReviewErrorSessionID: String?
    private var fileReviewTask: Task<Void, Never>?

    /// Called when any conversation starts or stops waiting for a permission
    /// decision, so a background project can signal it.
    public var onAttentionChanged: ((Bool) -> Void)?

    private let transport: any AgentConversationTransport
    private let now: () -> ContinuousClock.Instant
    private var connection: (any AgentConnection)?
    private var eventTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<String>.Continuation?
    private var closeTask: Task<Void, Never>?
    private var canListSessions = false
    private var nextToken = 0
    /// Prompts waiting for a session: keyed by new-session token or by the
    /// session ID being loaded.
    private var queuedPrompts: [String: AgentPrompt] = [:]
    private var loadTokens: [String: String] = [:]
    /// Streamed text not yet shown, per session. One buffer holds one role so
    /// interleaved reasoning and reply chunks become separate messages.
    private var pendingText: [String: (role: AgentConversationMessage.Role, text: String)] = [:]
    private var flushTask: Task<Void, Never>?
    private var needsAttention = false
    @Published private var createToken: String?
    private var loadBackups: [String: AgentConversation] = [:]
    /// Locally prepared sessions without a submitted prompt or upstream history evidence.
    /// Codex does not persist their rollout until the first prompt, so they cannot be resumed.
    private var unpromptedSessionIDs: Set<String> = []
    private var historyContinuations: [String: CheckedContinuation<[AgentConversationMessage], Error>] = [:]
    private var historyRefreshToken: String?

    public init(transport: any AgentConversationTransport, now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.transport = transport
        self.now = now
    }

    public var hasActiveConnection: Bool { connection != nil }
    public var isCreatingSession: Bool { createToken != nil }
    public var pendingNewConversationStartedAt: ContinuousClock.Instant? {
        createToken.flatMap { queuedPrompts[$0]?.submittedAt }
    }
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
        usesSubscription = configuration.authentication == .codexSubscription
        subscriptionEmail = nil
        subscriptionPlan = nil
        subscriptionQuota = nil
        quotaFailure = nil
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
                guard !Task.isCancelled else { break }
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
        fileReviewTask?.cancel()
        if let fileReviewTask { await fileReviewTask.value }
        let old = detachConnection(failure: nil)
        await old?.close()
        if let closeTask { await closeTask.value }
    }

    public func authenticate() {
        guard usesSubscription, connectionState == .authenticationRequired else { return }
        if sendCommand(["kind": "authenticate"]) { connectionState = .authenticating }
    }

    /// Keep a cancelled login out of the idle view, which auto-connects on appear.
    public func cancelAuthentication() async {
        guard connectionState == .authenticating else { return }
        let old = detachConnection(failure: String(localized: "ChatGPT sign-in was cancelled."))
        if let old {
            let closing = Task { await old.close() }
            closeTask = closing
            await closing.value
            closeTask = nil
        }
    }

    /// The visible panel owns the polling task; the native host coalesces requests.
    public func refreshQuota() {
        guard usesSubscription, connectionState == .ready else { return }
        sendCommand(["kind": "refreshQuota"])
    }

    public var canRefreshSessions: Bool { canListSessions && connectionState == .ready }

    public func refreshSessions() {
        guard canRefreshSessions, !isRefreshingSessions else { return }
        let token = makeToken()
        historyRefreshToken = token
        isRefreshingSessions = true
        historyError = nil
        if !sendCommand(["kind": "listSessions", "token": token]) {
            historyError = errorMessage
            isRefreshingSessions = false
            historyRefreshToken = nil
        }
    }

    public func canExportTranscript(_ sessionID: String) -> Bool {
        let conversation = conversations[sessionID]
        guard conversation?.isResponding != true, conversation?.isLoading != true,
              conversation?.pendingConfigToken == nil else { return false }
        return conversation?.hasCompleteHistory == true
            || (canLoadSessions && connectionState == .ready)
    }

    /// Replays an unopened transcript through the existing bounded ACP request.
    /// Cancellation releases the waiter; the Agent may finish its replay normally.
    public func historyTranscript(_ sessionID: String) async throws -> [AgentConversationMessage] {
        try Task.checkCancellation()
        guard canExportTranscript(sessionID) else { throw AgentConversationError.cannotResume }
        if let conversation = conversations[sessionID], conversation.hasCompleteHistory {
            return conversation.messages
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                historyContinuations[sessionID] = continuation
                beginLoad(sessionID)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.historyContinuations.removeValue(forKey: sessionID)?.resume(throwing: CancellationError())
            }
        }
    }

    // MARK: Conversations

    public func startNewConversation() {
        guard !isCreatingSession else { return }
        selectedSessionID = nil
        errorMessage = nil
        prepareConversation()
    }

    /// Prepare an empty session so upstream settings are available before sending.
    public func prepareConversation() {
        guard connectionState == .ready else { return }
        if let sessionID = selectedSessionID {
            if conversations[sessionID]?.isAttached != true { selectSession(sessionID) }
            return
        }
        guard createToken == nil else { return }
        let token = makeToken()
        createToken = token
        if !sendCommand(["kind": "newSession", "token": token]) { createToken = nil }
    }

    public func setConfigOption(_ id: String, value: String) {
        guard let sessionID = selectedSessionID, let conversation = conversations[sessionID],
              conversation.isAttached, !conversation.isLoading,
              conversation.pendingConfigToken == nil,
              let option = conversation.configOptions.first(where: { $0.id == id }),
              option.choices.contains(where: { $0.id == value }) else { return }
        if conversation.isResponding {
            // Do not change the running turn's model or its outstanding tool permissions.
            conversations[sessionID]?.queuedConfigValues[id] = option.currentValue == value ? nil : value
            conversations[sessionID]?.configurationError = nil
            return
        }
        guard option.currentValue != value else { return }
        let token = makeToken()
        conversations[sessionID]?.pendingConfigToken = token
        conversations[sessionID]?.configurationError = nil
        if !sendCommand(["kind": "setConfigOption", "token": token, "sessionId": sessionID, "configId": id, "value": value]) {
            conversations[sessionID]?.pendingConfigToken = nil
        }
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
              !conversation.isResponding, !conversation.isLoading,
              conversation.pendingConfigToken == nil, conversation.permission == nil else { return }
        openSessionIDs.removeAll { $0 == sessionID }
        conversations[sessionID] = nil
        unpromptedSessionIDs.remove(sessionID)
        pendingText[sessionID] = nil
        queuedPrompts[sessionID] = nil
        if selectedSessionID == sessionID {
            selectedSessionID = openSessionIDs.last
            // Closing the final tab does not change connectionState or make
            // the view appear again, so start its replacement settings here.
            if selectedSessionID == nil { prepareConversation() }
        }
    }

    public func send(_ text: String, files: [AgentFileReference] = []) throws {
        guard fileReviewSessionID == nil else { throw AgentConversationError.fileReviewInProgress }
        let prompt = AgentPrompt(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            files: try AgentFileReference.adding(files.map(\.url), to: []),
            submittedAt: now()
        )
        guard !prompt.isEmpty else { return }
        guard connection != nil else { throw AgentConversationError.notConnected }
        guard let sessionID = selectedSessionID else {
            if createToken == nil { prepareConversation() }
            guard let token = createToken else { throw AgentConversationError.notConnected }
            queuedPrompts[token] = prompt
            pendingNewConversationPrompt = prompt.displayText
            errorMessage = nil
            return
        }
        let conversation = conversations[sessionID] ?? AgentConversation()
        guard !conversation.isResponding else { throw AgentConversationError.sessionBusy }
        guard conversation.pendingConfigToken == nil, conversation.queuedConfigValues.isEmpty else {
            throw AgentConversationError.configurationPending
        }
        if conversation.isLoading {
            queuedPrompts[sessionID] = prompt
        } else if conversation.isAttached {
            guard startPrompt(prompt, in: sessionID) else {
                throw AgentConversationError.sendFailed(errorMessage ?? AgentConversationError.notConnected.localizedDescription)
            }
        } else if canLoadSessions {
            queuedPrompts[sessionID] = prompt
            beginLoad(sessionID)
        } else {
            throw AgentConversationError.cannotResume
        }
    }

    public func cancel() {
        guard let sessionID = selectedSessionID,
              conversations[sessionID]?.isResponding == true,
              conversations[sessionID]?.isCancelling != true else { return }
        conversations[sessionID]?.isCancelling = true
        conversations[sessionID]?.pendingPermissions.removeAll()
        updateAttention()
        if !sendCommand(["kind": "cancel", "sessionId": sessionID]) {
            conversations[sessionID]?.isCancelling = false
        }
    }

    public func answerPermission(optionID: String?) {
        guard let sessionID = selectedSessionID,
              let permission = conversations[sessionID]?.permission else { return }
        conversations[sessionID]?.pendingPermissions.removeFirst()
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
        case "authenticationRequired":
            guard usesSubscription else { return }
            connectionState = .authenticationRequired
        case "authenticating":
            guard usesSubscription else { return }
            connectionState = .authenticating
        case "account":
            guard usesSubscription, let account = event["account"] as? [String: Any] else { return }
            subscriptionEmail = account["email"] as? String
            subscriptionPlan = account["plan"] as? String
        case "quota":
            guard usesSubscription, connectionState == .ready else { return }
            if let snapshot = AgentSubscriptionQuota.parse(event["snapshot"]) {
                subscriptionQuota = snapshot
                quotaFailure = nil
            } else { quotaFailure = "unparsable" }
        case "quotaFailed":
            guard usesSubscription, connectionState == .ready else { return }
            quotaFailure = event["code"] as? String ?? "unavailable"
            if quotaFailure == "accountChanged" || quotaFailure == "unauthorized" { subscriptionQuota = nil }
        case "ready":
            connectionState = .ready
            agentName = event["agentName"] as? String
            agentVersion = event["agentVersion"] as? String
            canLoadSessions = event["canLoadSessions"] as? Bool ?? false
            canListSessions = event["canListSessions"] as? Bool ?? false
            refreshSessions()
        case "sessions":
            guard isRefreshingSessions, token == historyRefreshToken else { return }
            mergeSessions(event["sessions"] as? [[String: Any]] ?? [])
            historyRefreshToken = nil
            isRefreshingSessions = false
        case "sessionCreated":
            guard let sessionID, let token, token == createToken else { return }
            conversations[sessionID, default: AgentConversation()].configOptions = AgentSessionConfigOption.parse(event["configOptions"])
            sessionCreated(sessionID, token: token)
        case "sessionLoaded":
            guard let sessionID, let token, loadTokens.removeValue(forKey: token) != nil else { return }
            unpromptedSessionIDs.remove(sessionID)
            flushPendingText()
            conversations[sessionID, default: AgentConversation()].isLoading = false
            conversations[sessionID]?.isAttached = true
            conversations[sessionID]?.hasCompleteHistory = true
            loadBackups[sessionID] = nil
            conversations[sessionID]?.configOptions = AgentSessionConfigOption.parse(event["configOptions"])
            historyContinuations.removeValue(forKey: sessionID)?.resume(returning: conversations[sessionID]?.messages ?? [])
            if let prompt = queuedPrompts.removeValue(forKey: sessionID) {
                startPrompt(prompt, in: sessionID)
            }
        case "sessionConfigured":
            guard let sessionID, let token, conversations[sessionID]?.pendingConfigToken == token else { return }
            applyConfiguration(event["configOptions"], to: sessionID)
            conversations[sessionID]?.pendingConfigToken = nil
            if let id = conversations[sessionID]?.pendingQueuedConfigID {
                let requested = conversations[sessionID]?.queuedConfigValues[id]
                let confirmed = conversations[sessionID]?.configOptions.first { $0.id == id }?.currentValue
                conversations[sessionID]?.pendingQueuedConfigID = nil
                guard requested == confirmed else {
                    failQueuedConfiguration(in: sessionID, message: String(localized: "The Agent did not confirm the selected session setting."))
                    return
                }
                conversations[sessionID]?.queuedConfigValues[id] = nil
                applyQueuedConfiguration(in: sessionID)
            }
        case "turnRetrying":
            guard let sessionID,
                  conversations[sessionID]?.isResponding == true,
                  conversations[sessionID]?.isCancelling != true,
                  let turnID = event["turnId"] as? String, !turnID.isEmpty,
                  turnID != conversations[sessionID]?.previousRetryTurnID,
                  let attempt = event["attempt"] as? Int,
                  let maximum = event["maxAttempts"] as? Int,
                  maximum > 1, attempt > 1, attempt <= maximum else { return }
            flushPendingText()
            conversations[sessionID]?.retryTurnID = turnID
            conversations[sessionID]?.retryAttempt = attempt
            conversations[sessionID]?.retryMaxAttempts = maximum
            conversations[sessionID]?.responsePhase = .retrying
        case "turnCancelling":
            guard let sessionID else { return }
            conversations[sessionID]?.isCancelling = true
            // Host-initiated cancellation has already rejected these requests.
            conversations[sessionID]?.pendingPermissions.removeAll()
            updateAttention()
        case "update":
            guard let sessionID, let update = event["update"] as? [String: Any] else { return }
            apply(update, to: sessionID)
        case "permission":
            guard let sessionID,
                  conversations[sessionID]?.isCancelling != true,
                  let requestID = event["requestId"] as? String,
                  let request = event["request"] as? [String: Any] else { return }
            let prompt = permissionPrompt(requestID, request, sessionID: sessionID)
            markResponseProgress(.waiting, in: sessionID)
            conversations[sessionID, default: AgentConversation()].enqueuePermission(prompt)
            updateAttention()
        case "turnFinished":
            refreshQuota()
            guard let sessionID else { return }
            flushPendingText()
            conversations[sessionID]?.finishTurn(at: now(), usage: AgentTurnUsage.parse(event["usage"]))
            conversations[sessionID]?.isResponding = false
            conversations[sessionID]?.isCancelling = false
            conversations[sessionID]?.interruptPendingTools()
            conversations[sessionID]?.pendingPermissions.removeAll()
            conversations[sessionID]?.errorMessage = stopReasonMessage(event["stopReason"] as? String)
            updateAttention()
            applyQueuedConfiguration(in: sessionID)
        case "requestFailed":
            requestFailed(token: token, sessionID: sessionID, message: event["message"] as? String ?? String(localized: "The Agent request failed."))
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
        guard token == createToken else { return }
        createToken = nil
        let prompt = queuedPrompts.removeValue(forKey: token)
        if !sessions.contains(where: { $0.id == sessionID }) {
            sessions.insert(AgentSessionSummary(id: sessionID, title: prompt.map { Self.provisionalTitle($0.displayText) }), at: 0)
        }
        var conversation = conversations[sessionID] ?? AgentConversation()
        conversation.isAttached = true
        conversation.hasCompleteHistory = true
        conversations[sessionID] = conversation
        unpromptedSessionIDs.insert(sessionID)
        openTab(sessionID)
        pendingNewConversationPrompt = nil
        if selectedSessionID == nil { selectedSessionID = sessionID }
        if let prompt { startPrompt(prompt, in: sessionID) }
    }

    private func requestFailed(token: String?, sessionID: String?, message: String) {
        if let token, token == historyRefreshToken {
            historyRefreshToken = nil
            isRefreshingSessions = false
            historyError = message
        } else if let sessionID, let token, conversations[sessionID]?.pendingConfigToken == token {
            conversations[sessionID]?.pendingConfigToken = nil
            failQueuedConfiguration(in: sessionID, message: message)
        } else if let token, token == createToken {
            queuedPrompts.removeValue(forKey: token)
            createToken = nil
            pendingNewConversationPrompt = nil
            errorMessage = message
        } else if let token, let loading = loadTokens.removeValue(forKey: token) {
            queuedPrompts.removeValue(forKey: loading)
            pendingText[loading] = nil
            if let backup = loadBackups.removeValue(forKey: loading) { conversations[loading] = backup }
            conversations[loading]?.isLoading = false
            conversations[loading]?.errorMessage = message
            historyContinuations.removeValue(forKey: loading)?.resume(throwing: AgentConversationError.sendFailed(message))
        } else if token != nil {
            errorMessage = message
        } else if let sessionID, conversations[sessionID] != nil {
            flushPendingText()
            conversations[sessionID]?.finishTurn(at: now())
            conversations[sessionID]?.isResponding = false
            conversations[sessionID]?.isCancelling = false
            conversations[sessionID]?.interruptPendingTools()
            conversations[sessionID]?.pendingPermissions.removeAll()
            conversations[sessionID]?.errorMessage = message
            updateAttention()
            applyQueuedConfiguration(in: sessionID)
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
        // A listed session is owned by upstream history even if the local transcript is empty.
        unpromptedSessionIDs.subtract(listedIDs)
        // Sessions created in this run may not be persisted by the agent yet.
        sessions = sessions.filter { !listedIDs.contains($0.id) && conversations[$0.id] != nil } + listed
    }

    private func apply(_ update: [String: Any], to sessionID: String) {
        switch update["sessionUpdate"] as? String {
        case "usage_update":
            guard connectionState == .ready else { return }
            conversations[sessionID, default: AgentConversation()].contextUsage = AgentContextUsage.parse(update)
        case "config_option_update":
            applyConfiguration(update["configOptions"], to: sessionID)
        case "agent_message_chunk":
            guard let text = Self.text(of: update) else { return }
            if !text.isEmpty { markResponseProgress(.responding, in: sessionID) }
            buffer(text, role: .agent, in: sessionID)
        case "agent_thought_chunk":
            guard let text = Self.text(of: update) else { return }
            if !text.isEmpty { markResponseProgress(.thinking, in: sessionID) }
            buffer(text, role: .thought, in: sessionID)
        case "plan":
            guard let plan = AgentPlan.parse(update) else { return }
            conversations[sessionID, default: AgentConversation()].plan = plan.entries.isEmpty ? nil : plan
            // A valid plan proves recovery without implying streamed reasoning.
            if conversations[sessionID]?.responsePhase == .retrying {
                markResponseProgress(.waiting, in: sessionID)
            }
        case "available_commands_update":
            guard let commands = AgentCommand.parse(update) else { return }
            conversations[sessionID, default: AgentConversation()].availableCommands = commands
        case "current_mode_update":
            // Agents that expose modes as a config option may switch on their own,
            // e.g. leaving plan mode; keep the selector on the reported mode.
            guard let modeID = update["currentModeId"] as? String,
                  let index = conversations[sessionID]?.configOptions.firstIndex(where: {
                      $0.category == "mode" && $0.choices.contains { $0.id == modeID }
                  }) else { return }
            conversations[sessionID]?.configOptions[index].currentValue = modeID
        case "user_message_chunk":
            guard let text = Self.text(of: update) else { return }
            flushPendingText()
            append(text, role: .user, to: sessionID)
        case "tool_call", "tool_call_update":
            guard let toolCallID = update["toolCallId"] as? String else { return }
            flushPendingText()
            upsertTool(toolCallID, update: update, in: sessionID)
            markResponseProgress(.waiting, in: sessionID)
        case "session_info_update":
            // codex-acp 1.13.1 forwards retries in metadata without a title.
            // Consume the explicit flag, never infer retries from a silent timer
            // or show raw provider errors that may contain private routing data.
            if conversations[sessionID]?.isResponding == true,
               conversations[sessionID]?.isCancelling != true,
               let metadata = update["_meta"] as? [String: Any],
               let codex = metadata["codex"] as? [String: Any],
               let error = codex["error"] as? [String: Any], error["willRetry"] as? Bool == true,
               let turnID = error["turnId"] as? String, !turnID.isEmpty,
               turnID != conversations[sessionID]?.previousRetryTurnID {
                conversations[sessionID]?.retryTurnID = turnID
                conversations[sessionID]?.retryAttempt = nil
                conversations[sessionID]?.retryMaxAttempts = nil
                conversations[sessionID]?.responsePhase = .retrying
            }
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

    private func markResponseProgress(_ status: AgentResponseStatus, in sessionID: String) {
        guard conversations[sessionID]?.isResponding == true,
              conversations[sessionID]?.isCancelling != true,
              conversations[sessionID]?.responsePhase != status else { return }
        // Keep text-chunk publication coalesced; only phase transitions publish.
        guard var conversation = conversations[sessionID] else { return }
        conversation.responsePhase = status
        conversation.retryAttempt = nil
        conversation.retryMaxAttempts = nil
        conversations[sessionID] = conversation
    }

    private func applyConfiguration(_ value: Any?, to sessionID: String) {
        let options = AgentSessionConfigOption.parse(value)
        let oldModels = conversations[sessionID]?.configOptions.filter { $0.category == "model" } ?? []
        let newModels = options.filter { $0.category == "model" }
        if oldModels.map(\.currentValue) != newModels.map(\.currentValue) {
            conversations[sessionID]?.contextUsage = nil
        }
        conversations[sessionID, default: AgentConversation()].configOptions = options
    }

    /// Submit next-turn choices only after the Host has released this session's prompt.
    private func applyQueuedConfiguration(in sessionID: String) {
        guard let conversation = conversations[sessionID], conversation.isAttached,
              !conversation.isResponding, !conversation.isLoading,
              conversation.pendingConfigToken == nil, !conversation.queuedConfigValues.isEmpty else { return }
        // A model acknowledgement can replace the available reasoning/speed choices.
        // Revalidate each remaining choice against that latest complete option list.
        let ordered = conversation.configOptions.filter { $0.category == "model" }
            + conversation.configOptions.filter { $0.category != "model" }
        for option in ordered {
            guard let value = conversations[sessionID]?.queuedConfigValues[option.id] else { continue }
            if option.currentValue == value {
                conversations[sessionID]?.queuedConfigValues[option.id] = nil
                continue
            }
            guard option.choices.contains(where: { $0.id == value }) else {
                failQueuedConfiguration(in: sessionID, message: String(localized: "The Agent no longer supports the selected session setting."))
                return
            }
            let token = makeToken()
            conversations[sessionID]?.pendingConfigToken = token
            conversations[sessionID]?.pendingQueuedConfigID = option.id
            if !sendCommand(["kind": "setConfigOption", "token": token, "sessionId": sessionID,
                             "configId": option.id, "value": value]) {
                conversations[sessionID]?.pendingConfigToken = nil
                failQueuedConfiguration(in: sessionID, message: errorMessage ?? AgentConversationError.notConnected.localizedDescription)
            }
            return
        }
        if conversations[sessionID]?.queuedConfigValues.isEmpty == false {
            failQueuedConfiguration(in: sessionID, message: String(localized: "The Agent no longer supports the selected session setting."))
        }
    }

    private func failQueuedConfiguration(in sessionID: String, message: String) {
        conversations[sessionID]?.queuedConfigValues.removeAll()
        conversations[sessionID]?.pendingQueuedConfigID = nil
        conversations[sessionID]?.configurationError = message
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
            conversation.messages[index].toolDetails.merge(update)
        } else {
            conversation.messages.append(AgentConversationMessage(
                id: id,
                role: .tool,
                text: title ?? String(localized: "Tool call"),
                toolStatus: status ?? .pending
            ))
            conversation.messages[conversation.messages.count - 1].toolDetails.merge(update)
        }
        conversations[sessionID] = conversation
    }

    private func permissionPrompt(_ requestID: String, _ request: [String: Any], sessionID: String) -> AgentPermissionPrompt {
        let tool = request["toolCall"] as? [String: Any]
        let options = (request["options"] as? [[String: Any]] ?? []).compactMap { option -> AgentPermissionChoice? in
            guard let id = option["optionId"] as? String, let label = option["name"] as? String else { return nil }
            return AgentPermissionChoice(id: id, label: label, kind: option["kind"] as? String)
        }
        var prompt = AgentPermissionPrompt(
            id: requestID,
            title: tool?["title"] as? String ?? String(localized: "Allow the Agent to continue?"),
            choices: options
        )
        if let tool {
            if let id = tool["toolCallId"] as? String,
               let known = conversations[sessionID]?.messages.first(where: { $0.id == "tool:\(id)" }) {
                prompt.details = known.toolDetails
            }
            prompt.details.merge(tool)
        }
        return prompt
    }

    // MARK: Helpers

    @discardableResult
    private func startPrompt(_ prompt: AgentPrompt, in sessionID: String) -> Bool {
        var command: [String: Any] = ["kind": "prompt", "sessionId": sessionID, "text": prompt.text]
        if !prompt.files.isEmpty { command["files"] = prompt.files.map(\.commandValue) }
        guard sendCommand(command) else { return false }
        unpromptedSessionIDs.remove(sessionID)
        var conversation = conversations[sessionID] ?? AgentConversation()
        let message = AgentConversationMessage(role: .user, text: prompt.displayText)
        conversation.messages.append(message)
        conversation.activeTurn = AgentTurnStatistics(id: message.id, startedAt: prompt.submittedAt)
        conversation.isResponding = true
        conversation.responsePhase = .waiting
        conversation.retryTurnID = nil
        conversation.retryAttempt = nil
        conversation.retryMaxAttempts = nil
        conversation.errorMessage = nil
        conversations[sessionID] = conversation
        return true
    }

    private func beginLoad(_ sessionID: String) {
        let token = makeToken()
        loadTokens[token] = sessionID
        loadBackups[sessionID] = conversations[sessionID]
        pendingText[sessionID] = nil
        // The agent replays the whole history, so rebuild it from scratch.
        var conversation = AgentConversation()
        // Review decisions belong to the open tab, not the connection. Replayed
        // evidence still has to match the acknowledged version or exact prefix.
        conversation.reviewedFileChanges = loadBackups[sessionID]?.reviewedFileChanges ?? [:]
        conversation.isLoading = true
        conversations[sessionID] = conversation
        if !sendCommand(["kind": "loadSession", "token": token, "sessionId": sessionID]) {
            requestFailed(token: token, sessionID: sessionID, message: errorMessage ?? String(localized: "The Agent request failed."))
        }
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
        subscriptionQuota = nil
        subscriptionEmail = nil
        subscriptionPlan = nil
        quotaFailure = nil
        connectionState = failure.map(ConnectionState.failed) ?? .idle
        canListSessions = false
        canLoadSessions = false
        isRefreshingSessions = false
        historyRefreshToken = nil
        for continuation in historyContinuations.values {
            continuation.resume(throwing: AgentConversationError.notConnected)
        }
        historyContinuations.removeAll()
        queuedPrompts.removeAll()
        loadTokens.removeAll()
        for (id, backup) in loadBackups { conversations[id] = backup }
        loadBackups.removeAll()
        discardUnpersistedEmptySessions()
        createToken = nil
        pendingNewConversationPrompt = nil
        for id in conversations.keys {
            conversations[id]?.finishTurn(at: now())
            conversations[id]?.contextUsage = nil
            conversations[id]?.availableCommands = []
            conversations[id]?.isResponding = false
            conversations[id]?.interruptPendingTools()
            conversations[id]?.isCancelling = false
            conversations[id]?.pendingConfigToken = nil
            conversations[id]?.queuedConfigValues.removeAll()
            conversations[id]?.pendingQueuedConfigID = nil
            conversations[id]?.isLoading = false
            conversations[id]?.isAttached = false
            conversations[id]?.pendingPermissions.removeAll()
        }
        updateAttention()
        return old
    }

    private func discardUnpersistedEmptySessions() {
        let discarded = unpromptedSessionIDs.filter { conversations[$0]?.messages.isEmpty == true }
        unpromptedSessionIDs.removeAll()
        // Never infer this from an empty transcript alone: unloaded history must survive.
        for id in discarded { conversations[id] = nil }
        sessions.removeAll { discarded.contains($0.id) }
        openSessionIDs.removeAll { discarded.contains($0) }
        if let selectedSessionID, discarded.contains(selectedSessionID) {
            self.selectedSessionID = nil
        }
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

    private func buffer(_ text: String, role: AgentConversationMessage.Role, in sessionID: String) {
        if let pending = pendingText[sessionID], pending.role != role { flushPendingText() }
        pendingText[sessionID, default: (role, "")].text += text
        scheduleFlush()
    }

    private func flushPendingText() {
        let pending = pendingText
        pendingText.removeAll()
        for (sessionID, chunk) in pending where !chunk.text.isEmpty {
            append(chunk.text, role: chunk.role, to: sessionID)
        }
    }

    private func stopReasonMessage(_ reason: String?) -> String? {
        switch reason {
        case "max_tokens": String(localized: "The response stopped at the model's token limit.")
        case "max_turn_requests": String(localized: "The Agent stopped after reaching its request limit for this turn.")
        case "refusal": String(localized: "The Agent declined to continue.")
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
    case configurationPending
    case sessionBusy
    case fileReviewInProgress
    case fileReviewChanged
    case sendFailed(String)

    public var errorDescription: String? {
        switch self {
        case .featureDisabled: String(localized: "Agent conversation is turned off. Turn it on in the panel settings to send messages.")
        case .noAgentConfigured: String(localized: "No Agent is ready yet. Open the panel settings to install an Agent and choose a local or custom provider.")
        case .moduleStarting: String(localized: "The Agent module is still starting. Try again in a moment.")
        case .missingCommand: String(localized: "Set the custom Agent's executable in the panel settings.")
        case .missingProvider: String(localized: "Choose a local or custom provider in the Agent panel settings.")
        case .missingAPIKey: String(localized: "This Agent's provider has no API key. Update its local configuration or edit the custom provider in the panel settings.")
        case .notConnected: String(localized: "The Agent is not running. Connect to start a conversation.")
        case .sessionStopping: String(localized: "The previous Agent is still stopping. Try again shortly.")
        case .cannotResume: String(localized: "This Agent cannot reopen earlier conversations. Start a new conversation.")
        case .sessionBusy: String(localized: "The Agent is still responding in this conversation.")
        case .fileReviewInProgress: String(localized: "Wait for the Agent file rollback to finish.")
        case .fileReviewChanged: String(localized: "The reported file changes have been updated. Review them again before rolling back.")
        case .sendFailed(let message): message
        case .configurationPending: String(localized: "Wait for the Agent configuration to finish updating.")
        }
    }
}

extension AgentConnectionModel {
    /// Files have already been saved by the Agent. Keeping an exact version
    /// acknowledges its review without changing the transcript or editor buffers.
    public func keepFileChanges(_ changes: [AgentFileChange], in sessionID: String) {
        guard fileReviewSessionID == nil, let conversation = conversations[sessionID], !conversation.isResponding else { return }
        let current = AgentActivity(messages: conversation.messages, reviewed: conversation.reviewedFileChanges).files
        let complete = AgentActivity(messages: conversation.messages).files
        for change in changes where !change.isPending && current.contains(change) {
            conversations[sessionID]?.reviewedFileChanges[change.path] = complete.first { $0.path == change.path }
        }
    }

    /// The connection owns the native restoration job and awaits it at shutdown.
    /// A batch acknowledges each success; failed and newer versions stay visible.
    public func restoreFileChanges(
        _ changes: [AgentFileChange], in sessionID: String,
        restore: @escaping @MainActor (AgentFileChange) async throws -> Void
    ) async {
        guard fileReviewSessionID == nil else { return }
        fileReviewSessionID = sessionID
        fileReviewError = nil
        fileReviewErrorSessionID = sessionID
        let job = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for change in changes {
                    try Task.checkCancellation()
                    guard let conversation = self.conversations[sessionID], !conversation.isResponding,
                          change.canRevert, AgentActivity(messages: conversation.messages, reviewed: conversation.reviewedFileChanges).files.contains(change) else {
                        throw AgentConversationError.fileReviewChanged
                    }
                    let snapshot = AgentActivity(messages: conversation.messages).files.first { $0.path == change.path }
                    try await restore(change)
                    self.conversations[sessionID]?.reviewedFileChanges[change.path] = snapshot
                }
            } catch is CancellationError { }
            catch { self.fileReviewError = error.localizedDescription }
        }
        fileReviewTask = job
        await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
        fileReviewTask = nil
        fileReviewSessionID = nil
    }
}
