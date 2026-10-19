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
    @Published public private(set) var selectedSessionID: String? {
        didSet { selectionRevision &+= 1 }
    }
    /// Counts selection changes so a slow navigation can tell it was superseded.
    private var selectionRevision = 0
    @Published public private(set) var conversations: [String: AgentConversation] = [:]
    /// Sessions shown as tabs, in the order they were opened in this panel.
    @Published public private(set) var openSessionIDs: [String] = []
    /// Prompt of a new conversation while its session is being created.
    @Published public private(set) var pendingNewConversationPrompt: String?
    @Published public private(set) var canLoadSessions = false
    @Published public private(set) var canSteer = false
    @Published public private(set) var isRefreshingSessions = false
    @Published public private(set) var historyError: String?
    /// The Agent's own archived conversations for this workspace, kept apart from
    /// `sessions`: listing them is read-only and opening one needs consent.
    @Published private var listedArchivedSessions: [AgentSessionSummary] = []
    /// Only upstream listing evidence wins over an archive result. Locally loaded
    /// conversations are retained for their tabs, not evidence of active history.
    private var upstreamActiveSessionIDs: Set<String> = []
    public var archivedSessions: [AgentSessionSummary] {
        listedArchivedSessions.filter { !upstreamActiveSessionIDs.contains($0.id) }
    }
    /// False when the Host stopped at its page bound, so the list is partial.
    @Published public private(set) var isArchivedHistoryComplete = true
    @Published public private(set) var canListArchivedSessions = false
    @Published public private(set) var isRefreshingArchivedSessions = false
    @Published public private(set) var archivedHistoryError: String?
    @Published public private(set) var unarchivingSessionID: String?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var fileReviewSessionID: String?
    @Published public private(set) var fileReviewError: String?
    @Published public private(set) var fileReviewErrorSessionID: String?
    // Drafts belong to each session, independent of its presentation or Agent process.
    @Published public var draftText = ""
    @Published public var draftFiles: [AgentFileReference] = []
    @Published public private(set) var composerFocusRequest: UInt = 0
    private struct Draft {
        var text = ""
        var files: [AgentFileReference] = []
        var isEmpty: Bool { text.isEmpty && files.isEmpty }
    }
    private var sessionDrafts: [String: Draft] = [:]
    private var unassignedDraft = Draft()
    private var fileReviewTask: Task<Void, Never>?

    /// Called when any conversation starts or stops waiting for a permission
    /// decision, so a background project can signal it.
    public var onAttentionChanged: ((Bool) -> Void)?
    /// Persisted session totals; `nil` keeps statistics per connection only.
    var statisticsStore: AgentSessionStatisticsStore?

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
    private struct Supplement {
        let token: String
        let prompt: AgentPrompt
        let messageID: String
        var isCancelled = false
    }
    private var supplements: [String: Supplement] = [:]
    private var continuations: [String: Supplement] = [:]
    private var loadTokens: [String: String] = [:]
    /// Streamed text not yet shown, per session. One buffer holds one role so
    /// interleaved reasoning and reply chunks become separate messages.
    private var pendingText: [String: (role: AgentConversationMessage.Role, text: String, subagentSessionID: String?)] = [:]
    /// Child associations are rebuilt with the owning conversation's history snapshot.
    private var subagentOwners: [String: String] = [:]
    private var flushTask: Task<Void, Never>?
    private var needsAttention = false
    @Published private var createToken: String?
    private var loadBackups: [String: AgentConversation] = [:]
    /// Locally prepared sessions without a submitted prompt or upstream history evidence.
    /// Codex does not persist their rollout until the first prompt, so they cannot be resumed.
    private var unpromptedSessionIDs: Set<String> = []
    private var historyContinuations: [String: CheckedContinuation<[AgentConversationMessage], Error>] = [:]
    private var historyRefreshToken: String?
    private var archivedRefreshToken: String?
    /// List requests made obsolete by an unarchive. The host still answers them,
    /// so their terminal events must be consumed here rather than treated as new.
    private var supersededListTokens: Set<String> = []
    private var unarchiveRequest: (token: String, summary: AgentSessionSummary, continuation: CheckedContinuation<Void, Error>)?
    private var isClaudeConnection = false

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
    /// Unconsumed input can still be revoked while the next-turn configuration is pending.
    public var hasPendingContinuation: Bool {
        selectedSessionID.map { continuations[$0] != nil } ?? false
    }
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
        isClaudeConnection = configuration.agentID == "claude-acp"
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
        let old = detachConnection(failure: "ChatGPT sign-in was cancelled.")
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
        refreshArchivedSessions()
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

    private func refreshArchivedSessions() {
        guard canListArchivedSessions, connectionState == .ready, !isRefreshingArchivedSessions else { return }
        let token = makeToken()
        archivedRefreshToken = token
        isRefreshingArchivedSessions = true
        archivedHistoryError = nil
        if !sendCommand(["kind": "listArchivedSessions", "token": token]) {
            archivedHistoryError = errorMessage
            isRefreshingArchivedSessions = false
            archivedRefreshToken = nil
        }
    }

    /// Moves an archived conversation back into the Agent's active history so
    /// it can be loaded. Call only after the user confirmed: this changes the
    /// Agent's own records, unlike every other history action.
    ///
    /// - Returns: `false` when the selection changed while the Agent was
    ///   restoring; the restore stands, but the caller must not navigate over
    ///   the user's later choice.
    @discardableResult
    public func unarchiveSession(_ sessionID: String) async throws -> Bool {
        guard connectionState == .ready, unarchiveRequest == nil,
              let summary = archivedSessions.first(where: { $0.id == sessionID }) else {
            throw AgentConversationError.cannotResume
        }
        let revision = selectionRevision
        let token = makeToken()
        archivedHistoryError = nil
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            unarchiveRequest = (token, summary, continuation)
            unarchivingSessionID = sessionID
            if !sendCommand(["kind": "unarchiveSession", "token": token, "sessionId": sessionID]) {
                finishUnarchive(token: token, result: .failure(AgentConversationError.sendFailed(errorMessage ?? "The Agent request failed.")))
            }
        }
        return revision == selectionRevision
    }

    private func finishUnarchive(token: String, result: Result<Void, Error>) {
        guard let request = unarchiveRequest, request.token == token else { return }
        unarchiveRequest = nil
        unarchivingSessionID = nil
        switch result {
        case .success:
            // The mutation supersedes both list snapshots, including events already
            // buffered before this continuation resumes. Refresh from the new state.
            if let token = historyRefreshToken { supersededListTokens.insert(token) }
            if let token = archivedRefreshToken { supersededListTokens.insert(token) }
            historyRefreshToken = nil
            archivedRefreshToken = nil
            isRefreshingSessions = false
            isRefreshingArchivedSessions = false
            let summary = request.summary
            listedArchivedSessions.removeAll { $0.id == summary.id }
            upstreamActiveSessionIDs.insert(summary.id)
            if !sessions.contains(where: { $0.id == summary.id }) { sessions.insert(summary, at: 0) }
            refreshSessions()
        case .failure(let error):
            archivedHistoryError = error.localizedDescription
        }
        request.continuation.resume(with: result)
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
        saveDraft()
        discardUnpersistedEmptySessions()
        draftText = ""
        draftFiles = []
        unassignedDraft = Draft()
        selectedSessionID = nil
        errorMessage = nil
        prepareConversation()
    }

    /// Prepare an empty session so upstream settings are available before sending.
    public func prepareConversation() {
        guard connectionState == .ready else { return }
        if let sessionID = selectedSessionID {
            if unpromptedSessionIDs.contains(sessionID), conversations[sessionID]?.isAttached != true {
                // An empty Codex session has no persisted rollout to load after
                // reconnect. Keep its draft while replacing only the stale ID.
                guard createToken == nil else { return }
                conversations[sessionID] = nil
                sessions.removeAll { $0.id == sessionID }
                openSessionIDs.removeAll { $0 == sessionID }
                sessionDrafts[sessionID] = nil
                unpromptedSessionIDs.remove(sessionID)
                selectedSessionID = nil
            } else {
                if conversations[sessionID]?.isAttached != true { selectSession(sessionID) }
                return
            }
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
        if selectedSessionID != sessionID {
            saveDraft()
            restoreDraft(sessionDrafts[sessionID] ?? Draft())
        }
        selectedSessionID = sessionID
        errorMessage = nil
        openTab(sessionID)
        let conversation = conversations[sessionID]
        if unpromptedSessionIDs.contains(sessionID), conversation?.isAttached != true {
            prepareConversation()
            return
        }
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
        rebuildSubagentOwners()
        unpromptedSessionIDs.remove(sessionID)
        pendingText[sessionID] = nil
        queuedPrompts[sessionID] = nil
        if selectedSessionID == sessionID {
            if let next = openSessionIDs.last { selectSession(next) }
            else {
                selectedSessionID = nil
                restoreDraft(Draft())
                unassignedDraft = Draft()
            }
            // Closing the final tab does not change connectionState or make
            // the view appear again, so start its replacement settings here.
            if selectedSessionID == nil { prepareConversation() }
        }
        sessionDrafts[sessionID] = nil
    }

    /// Attach to a draft without prompting, cancelling a running turn, or waiting
    /// for settings/history. Validate the entire batch before changing selection.
    public func attachFiles(_ urls: [URL], to destination: AgentFileAttachmentDestination) throws {
        let targetFiles: [AgentFileReference]
        switch destination {
        case .current:
            targetFiles = draftFiles
        case .session(let id):
            guard sessions.contains(where: { $0.id == id }) else { throw AgentFileAttachmentError.sessionUnavailable }
            targetFiles = id == selectedSessionID ? draftFiles : sessionDrafts[id]?.files ?? []
        case .newConversation:
            targetFiles = selectedSessionID == nil ? draftFiles : unassignedDraft.files
        }
        let files = try AgentFileReference.adding(urls, to: targetFiles)
        switch destination {
        case .current: break
        case .session(let id): selectSession(id)
        case .newConversation:
            if selectedSessionID == nil { prepareConversation() }
            else if isCreatingSession || !unassignedDraft.isEmpty {
                saveDraft()
                restoreDraft(unassignedDraft)
                selectedSessionID = nil
                prepareConversation()
            } else { startNewConversation() }
        }
        draftFiles = files
        composerFocusRequest &+= 1
    }

    private func saveDraft() {
        let draft = Draft(text: draftText, files: draftFiles)
        if let selectedSessionID { sessionDrafts[selectedSessionID] = draft }
        else { unassignedDraft = draft }
    }

    private func restoreDraft(_ draft: Draft) {
        draftText = draft.text
        draftFiles = draft.files
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
        guard conversation.pendingSteeringToken == nil, continuations[sessionID] == nil else {
            throw AgentConversationError.sessionBusy
        }
        if conversation.isResponding {
            guard canSteer, !conversation.isCancelling, conversation.pendingSteeringToken == nil else {
                throw AgentConversationError.sessionBusy
            }
            let token = makeToken()
            var command: [String: Any] = ["kind": "steer", "token": token, "sessionId": sessionID, "text": prompt.text]
            if !prompt.files.isEmpty { command["files"] = prompt.files.map(\.commandValue) }
            guard sendCommand(command) else {
                throw AgentConversationError.sendFailed(errorMessage ?? AgentConversationError.notConnected.localizedDescription)
            }
            flushPendingText()
            var message = AgentConversationMessage(role: .user, text: prompt.displayText)
            message.delivery = .sending
            conversations[sessionID]?.messages.append(message)
            conversations[sessionID]?.pendingSteeringToken = token
            supplements[sessionID] = Supplement(token: token, prompt: prompt, messageID: message.id)
            return
        }
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
              conversations[sessionID]?.isResponding == true || hasPendingContinuation,
              conversations[sessionID]?.isCancelling != true else { return }
        let isResponding = conversations[sessionID]?.isResponding == true
        if isResponding { conversations[sessionID]?.isCancelling = true }
        cancelContinuation(in: sessionID)
        // A queued continuation has no native turn to cancel. Configuration
        // acknowledgements can continue, but must not send the revoked input.
        guard isResponding else { return }
        conversations[sessionID]?.pendingPermissions.removeAll()
        conversations[sessionID]?.refreshTurnClock(at: now())
        updateAttention()
        if !sendCommand(["kind": "cancel", "sessionId": sessionID]) {
            conversations[sessionID]?.isCancelling = false
        }
    }

    /// Dismiss the advisory for this quiet interval without resending the prompt.
    public func continueWaiting() {
        guard let sessionID = selectedSessionID else { return }
        conversations[sessionID]?.isQuiet = false
    }

    public func dismissNotice(_ id: String, in sessionID: String) {
        guard conversations[sessionID]?.notice?.id == id else { return }
        conversations[sessionID]?.notice = nil
    }

    public func answerPermission(optionID: String?) {
        guard let sessionID = selectedSessionID,
              let permission = conversations[sessionID]?.permission else { return }
        conversations[sessionID]?.pendingPermissions.removeFirst()
        conversations[sessionID]?.refreshTurnClock(at: now())
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
            canListArchivedSessions = event["canListArchivedSessions"] as? Bool ?? false
            canSteer = event["canSteer"] as? Bool ?? false
            refreshSessions()
        case "steeringResult":
            guard let sessionID, let token, let supplement = supplements[sessionID], supplement.token == token else { return }
            supplements[sessionID] = nil
            conversations[sessionID]?.pendingSteeringToken = nil
            switch event["outcome"] as? String {
            case "injected":
                setDelivery(.received, messageID: supplement.messageID, in: sessionID)
            case "promptRequired":
                if supplement.isCancelled {
                    setDelivery(.failed("Supplementary message cancelled."), messageID: supplement.messageID, in: sessionID)
                } else {
                    continuations[sessionID] = supplement
                    resumeContinuation(in: sessionID)
                }
            default:
                setDelivery(.failed(event["message"] as? String ?? "The Agent did not accept the supplementary message."),
                            messageID: supplement.messageID, in: sessionID)
            }
        case "sessions":
            if let token, supersededListTokens.remove(token) != nil { return }
            guard isRefreshingSessions, token == historyRefreshToken else { return }
            mergeSessions(event["sessions"] as? [[String: Any]] ?? [])
            historyRefreshToken = nil
            isRefreshingSessions = false
            reconcileArchivedSessions()
        case "archivedSessions":
            if let token, supersededListTokens.remove(token) != nil { return }
            guard isRefreshingArchivedSessions, token == archivedRefreshToken else { return }
            listedArchivedSessions = (event["sessions"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let id = entry["sessionId"] as? String else { return nil }
                return AgentSessionSummary(id: id, title: entry["title"] as? String, updatedAt: entry["updatedAt"] as? String)
            }
            isArchivedHistoryComplete = event["complete"] as? Bool ?? false
            archivedRefreshToken = nil
            isRefreshingArchivedSessions = false
            reconcileArchivedSessions()
        case "sessionUnarchived":
            guard let token else { return }
            finishUnarchive(token: token, result: .success(()))
        case "sessionCreated":
            guard let sessionID, let token, token == createToken else { return }
            applyConfiguration(event["configOptions"], to: sessionID)
            sessionCreated(sessionID, token: token)
        case "sessionLoaded":
            guard let sessionID, let token, loadTokens.removeValue(forKey: token) != nil else { return }
            unpromptedSessionIDs.remove(sessionID)
            flushPendingText()
            conversations[sessionID, default: AgentConversation()].isLoading = false
            conversations[sessionID]?.isAttached = true
            conversations[sessionID]?.hasCompleteHistory = true
            // The final catalog describes any usage just replayed during this
            // load. Reconcile notices without discarding that native report.
            applyConfiguration(event["configOptions"], to: sessionID, invalidatesContextUsage: false)
            restoreContextUsage(in: sessionID)
            loadBackups[sessionID] = nil
            persistStatistics(sessionID)
            historyContinuations.removeValue(forKey: sessionID)?.resume(returning: conversations[sessionID]?.messages ?? [])
            if let prompt = queuedPrompts.removeValue(forKey: sessionID) {
                startPrompt(prompt, in: sessionID)
            }
        case "sessionConfigured":
            guard let sessionID, let token, conversations[sessionID]?.pendingConfigToken == token else { return }
            applyConfiguration(event["configOptions"], to: sessionID)
            conversations[sessionID]?.pendingConfigToken = nil
            applyPendingModeNotice(in: sessionID)
            if let id = conversations[sessionID]?.pendingQueuedConfigID {
                let requested = conversations[sessionID]?.queuedConfigValues[id]
                let confirmed = conversations[sessionID]?.configOptions.first { $0.id == id }?.currentValue
                conversations[sessionID]?.pendingQueuedConfigID = nil
                guard requested == confirmed else {
                    failQueuedConfiguration(in: sessionID, message: "The Agent did not confirm the selected session setting.")
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
                  let attempt = event["attempt"] as? Int, attempt > 1 else { return }
            let maximum = event["maxAttempts"] as? Int
            if event["maxAttempts"] != nil {
                guard let maximum, maximum > 1, attempt <= maximum else { return }
            }
            flushPendingText()
            conversations[sessionID]?.retryTurnID = turnID
            conversations[sessionID]?.retryAttempt = attempt
            conversations[sessionID]?.retryMaxAttempts = maximum
            conversations[sessionID]?.responsePhase = .retrying
        case "turnActivity":
            guard let sessionID, conversations[sessionID]?.isResponding == true,
                  conversations[sessionID]?.isCancelling != true,
                  let quiet = event["quiet"] as? Bool,
                  conversations[sessionID]?.isQuiet != quiet else { return }
            conversations[sessionID]?.isQuiet = quiet
        case "turnCancelling":
            guard let sessionID else { return }
            conversations[sessionID]?.isCancelling = true
            cancelContinuation(in: sessionID)
            // Host-initiated cancellation has already rejected these requests.
            conversations[sessionID]?.pendingPermissions.removeAll()
            conversations[sessionID]?.refreshTurnClock(at: now())
            updateAttention()
        case "update":
            guard let sessionID, let update = event["update"] as? [String: Any] else { return }
            if applySubagentLifecycle(update, parentSessionID: sessionID) { return }
            if let owner = subagentOwners[sessionID] {
                guard conversations[owner]?.subagents.contains(where: { $0.id == sessionID && $0.state == .running }) == true,
                      ["agent_message_chunk", "agent_thought_chunk", "user_message_chunk", "tool_call", "tool_call_update"].contains(update["sessionUpdate"] as? String ?? "") else { return }
                apply(update, to: owner, subagentSessionID: sessionID)
            } else { apply(update, to: sessionID) }
        case "permission":
            guard let sessionID,
                  conversations[sessionID]?.isCancelling != true,
                  let requestID = event["requestId"] as? String,
                  let request = event["request"] as? [String: Any] else { return }
            if let source = request["sessionId"] as? String, let owner = subagentOwners[source] {
                guard owner == sessionID,
                      conversations[sessionID]?.subagents.contains(where: { $0.id == source && $0.state == .running }) == true else { return }
            }
            let prompt = permissionPrompt(requestID, request, sessionID: sessionID)
            markResponseProgress(.waiting, in: sessionID)
            conversations[sessionID, default: AgentConversation()].enqueuePermission(prompt)
            conversations[sessionID]?.refreshTurnClock(at: now())
            updateAttention()
        case "modelCall":
            // Unattributed calls cannot be assigned to a session without guessing.
            guard let sessionID, conversations[sessionID] != nil,
                  let call = AgentModelCall.parse(event["call"]) else { return }
            // A stream that outlived its turn must not count toward the next one.
            let afterTurn = event["afterTurnFinished"] as? Bool == true
            conversations[sessionID]?.recordModelCall(call, countsForActiveTurn: !afterTurn)
            // Calls inside a turn are saved with it; a late one has no turn left to wait for.
            if afterTurn || conversations[sessionID]?.activeTurn == nil { persistStatistics(sessionID) }
        case "turnFinished":
            refreshQuota()
            guard let sessionID else { return }
            if event["stopReason"] as? String == "cancelled" { cancelContinuation(in: sessionID) }
            flushPendingText()
            conversations[sessionID]?.finishTurn(at: now(), usage: AgentTurnUsage.parse(event["usage"]))
            persistStatistics(sessionID)
            conversations[sessionID]?.isResponding = false
            conversations[sessionID]?.isCancelling = false
            conversations[sessionID]?.interruptPendingTools()
            conversations[sessionID]?.pendingPermissions.removeAll()
            conversations[sessionID]?.errorMessage = stopReasonMessage(event["stopReason"] as? String)
            updateAttention()
            applyQueuedConfiguration(in: sessionID)
            resumeContinuation(in: sessionID)
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
        else { sessionDrafts[sessionID] = unassignedDraft }
        unassignedDraft = Draft()
        if let prompt { startPrompt(prompt, in: sessionID) }
        if let selectedSessionID, selectedSessionID != sessionID,
           unpromptedSessionIDs.contains(selectedSessionID), conversations[selectedSessionID]?.isAttached != true {
            prepareConversation()
        }
    }

    private func requestFailed(token: String?, sessionID: String?, message: String) {
        if let token, supersededListTokens.remove(token) != nil {
            return
        } else if let token, token == archivedRefreshToken {
            archivedRefreshToken = nil
            isRefreshingArchivedSessions = false
            archivedHistoryError = message
        } else if let token, token == unarchiveRequest?.token {
            finishUnarchive(token: token, result: .failure(AgentConversationError.sendFailed(message)))
        } else if let token, token == historyRefreshToken {
            historyRefreshToken = nil
            isRefreshingSessions = false
            historyError = message
        } else if let sessionID, let token, conversations[sessionID]?.pendingConfigToken == token {
            conversations[sessionID]?.pendingConfigToken = nil
            applyPendingModeNotice(in: sessionID)
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
            rebuildSubagentOwners()
            conversations[loading]?.isLoading = false
            conversations[loading]?.errorMessage = message
            historyContinuations.removeValue(forKey: loading)?.resume(throwing: AgentConversationError.sendFailed(message))
        } else if token != nil {
            errorMessage = message
        } else if let sessionID, conversations[sessionID] != nil {
            flushPendingText()
            conversations[sessionID]?.finishTurn(at: now())
            persistStatistics(sessionID)
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

    /// Keep the raw archive response so an older active listing cannot discard it.
    private func reconcileArchivedSessions() {
        let archived = Set(archivedSessions.map(\.id))
        sessions.removeAll { archived.contains($0.id) }
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
        upstreamActiveSessionIDs = listedIDs
        // A listed session is owned by upstream history even if the local transcript is empty.
        unpromptedSessionIDs.subtract(listedIDs)
        // Sessions created in this run may not be persisted by the agent yet.
        sessions = sessions.filter { !listedIDs.contains($0.id) && conversations[$0.id] != nil } + listed
    }

    private func apply(_ update: [String: Any], to sessionID: String, subagentSessionID: String? = nil) {
        switch update["sessionUpdate"] as? String {
        case "notice":
            guard connectionState == .ready, let notice = AgentSessionNotice.parse(update) else { return }
            if isClaudeConnection, notice.isClaudeAutoModeFallback,
               conversations[sessionID]?.pendingConfigToken != nil {
                conversations[sessionID]?.pendingModeNotice = notice
            } else { applyNotice(notice, to: sessionID) }
        case "usage_update":
            guard connectionState == .ready else { return }
            conversations[sessionID, default: AgentConversation()].contextUsage = AgentContextUsage.parse(update)
            let meta = update["_meta"] as? [String: Any]
            let source = (meta?["lithe"] as? [String: Any])?["contextUsageSource"] as? String
            conversations[sessionID]?.contextUsageIsHistorical = source == "history" && conversations[sessionID]?.contextUsage != nil
            conversations[sessionID]?.hasReportedContextUsage = true
            if conversations[sessionID]?.isResponding == false { persistStatistics(sessionID) }
        case "config_option_update":
            applyConfiguration(update["configOptions"], to: sessionID)
        case "agent_message_chunk":
            guard let text = Self.text(of: update) else { return }
            if !text.isEmpty, subagentSessionID == nil { markResponseProgress(.responding, in: sessionID) }
            buffer(text, role: .agent, in: sessionID, subagentSessionID: subagentSessionID)
        case "agent_thought_chunk":
            guard let text = Self.text(of: update) else { return }
            if !text.isEmpty, subagentSessionID == nil { markResponseProgress(.thinking, in: sessionID) }
            buffer(text, role: .thought, in: sessionID, subagentSessionID: subagentSessionID)
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
            let previousMode = conversations[sessionID]?.configOptions[index].currentValue
            if isClaudeConnection, previousMode != modeID {
                conversations[sessionID]?.autoFallbackTransition = previousMode == AgentSessionNotice.claudeAutoMode
                    && modeID == AgentSessionNotice.claudeAutoFallbackMode
                    ? AgentAutoFallbackTransition(precedingNoticeID: conversations[sessionID]?.notice?.id) : nil
            }
            conversations[sessionID]?.configOptions[index].currentValue = modeID
            reconcileModeNotice(in: sessionID)
        case "user_message_chunk":
            // Live input is already shown locally, including pending steering.
            // Replay still rebuilds the upstream-owned transcript while loading.
            guard conversations[sessionID]?.isResponding != true else { return }
            guard let text = Self.text(of: update) else { return }
            flushPendingText()
            append(text, role: .user, to: sessionID, subagentSessionID: subagentSessionID)
        case "tool_call", "tool_call_update":
            guard let toolCallID = update["toolCallId"] as? String else { return }
            flushPendingText()
            upsertTool(toolCallID, update: update, in: sessionID, subagentSessionID: subagentSessionID)
            conversations[sessionID]?.refreshTurnClock(at: now())
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

    private func applyConfiguration(_ value: Any?, to sessionID: String, invalidatesContextUsage: Bool = true) {
        let options = AgentSessionConfigOption.parse(value)
        let oldModels = conversations[sessionID]?.contextModelValues ?? [:]
        let newModels = options.filter { $0.category == "model" }.reduce(into: [String: String]()) { $0[$1.id] = $1.currentValue }
        let transition = conversations[sessionID]?.autoFallbackTransition
        conversations[sessionID]?.autoFallbackTransition = nil
        if oldModels != newModels {
            if invalidatesContextUsage {
                conversations[sessionID]?.contextUsage = nil
                conversations[sessionID]?.contextUsageIsHistorical = false
                // Invalidating a report must not prematurely persist an unfinished turn.
                if conversations[sessionID]?.isLoading == false { statisticsStore?.invalidateContextUsage(for: sessionID) }
            }
            if !oldModels.isEmpty, isClaudeConnection, let notice = conversations[sessionID]?.notice,
               notice.isClaudeAutoModeFallback {
                // Claude's native model switch emits mode -> notice -> catalog.
                // Preserve only the warning produced during that transition;
                // a later model switch must still invalidate this same notice.
                let isNewFallback = transition.map { $0.precedingNoticeID != notice.id } ?? false
                if !isNewFallback { conversations[sessionID]?.notice = nil }
            }
        }
        conversations[sessionID, default: AgentConversation()].configOptions = options
        reconcileModeNotice(in: sessionID)
    }

    private func reconcileModeNotice(in sessionID: String) {
        guard isClaudeConnection, conversations[sessionID]?.notice?.isClaudeAutoModeFallback == true,
              let mode = conversations[sessionID]?.configOptions.first(where: { $0.category == "mode" }) else { return }
        // The adapter defers its initial fallback advisory until the first prompt,
        // even if the user has already switched to Plan in the meantime.
        if mode.currentValue != AgentSessionNotice.claudeAutoFallbackMode {
            conversations[sessionID]?.notice = nil
        }
    }

    private func applyNotice(_ notice: AgentSessionNotice, to sessionID: String) {
        if isClaudeConnection, notice.isClaudeAutoModeFallback,
           let mode = conversations[sessionID]?.configOptions.first(where: { $0.category == "mode" }),
           mode.currentValue != AgentSessionNotice.claudeAutoFallbackMode { return }
        // A newer applicable notice supersedes a fallback waiting on configuration.
        conversations[sessionID]?.pendingModeNotice = nil
        conversations[sessionID, default: AgentConversation()].notice = notice
    }

    private func applyPendingModeNotice(in sessionID: String) {
        guard let notice = conversations[sessionID]?.pendingModeNotice else { return }
        conversations[sessionID]?.pendingModeNotice = nil
        applyNotice(notice, to: sessionID)
    }

    /// Submit next-turn choices only after the Host has released this session's prompt.
    private func applyQueuedConfiguration(in sessionID: String) {
        guard let conversation = conversations[sessionID], conversation.isAttached,
              !conversation.isResponding, !conversation.isLoading,
              conversation.pendingConfigToken == nil else { return }
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
                failQueuedConfiguration(in: sessionID, message: "The Agent no longer supports the selected session setting.")
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
            failQueuedConfiguration(in: sessionID, message: "The Agent no longer supports the selected session setting.")
        }
        resumeContinuation(in: sessionID)
    }

    private func failQueuedConfiguration(in sessionID: String, message: String) {
        conversations[sessionID]?.queuedConfigValues.removeAll()
        conversations[sessionID]?.pendingQueuedConfigID = nil
        conversations[sessionID]?.configurationError = message
        resumeContinuation(in: sessionID)
    }

    /// Consume only the pinned adapters' explicit native child lifecycle events.
    private func applySubagentLifecycle(_ update: [String: Any], parentSessionID: String) -> Bool {
        let kind = update["sessionUpdate"] as? String
        guard kind == "subagent_spawned" || kind == "subagent_state_update" else { return false }
        let root = subagentOwners[parentSessionID] ?? parentSessionID
        guard var conversation = conversations[root],
              let child = update["subagentSessionId"] as? String, !child.isEmpty,
              child != root, child != parentSessionID, conversations[child] == nil else { return true }
        if kind == "subagent_spawned" {
            guard let name = update["name"] as? String, let task = update["task"] as? String,
                  subagentOwners[child] == nil || subagentOwners[child] == root else { return true }
            if let index = conversation.subagents.firstIndex(where: { $0.id == child }) {
                guard conversation.subagents[index].parentSessionID == parentSessionID else { return true }
                conversation.subagents[index].name = name
                conversation.subagents[index].task = task
            } else {
                let parent = conversation.subagents.first { $0.id == parentSessionID }
                guard parentSessionID == root || parent?.state == .running else { return true }
                conversation.subagents.append(AgentSubagent(id: child, parentSessionID: parentSessionID,
                    name: name, task: task, depth: parent.map { $0.depth + 1 } ?? 0))
            }
            subagentOwners[child] = root
        } else {
            guard let state = (update["state"] as? String).flatMap(AgentSubagent.State.init(rawValue:)),
                  let index = conversation.subagents.firstIndex(where: { $0.id == child && $0.parentSessionID == parentSessionID }),
                  conversation.subagents[index].state == .running || conversation.subagents[index].state == .disconnected else { return true }
            flushPendingText()
            // Flushing may have appended the child's last output to this snapshot.
            conversation.messages = conversations[root]?.messages ?? conversation.messages
            conversation.subagents[index].state = state
            var ended = Set<String>()
            if state != .running {
                ended.insert(child)
                // A terminal parent cannot continue owning live descendants.
                // Their outcome is unknown unless they reported it themselves.
                for _ in conversation.subagents.indices {
                    for descendant in conversation.subagents.indices where ended.contains(conversation.subagents[descendant].parentSessionID) {
                        ended.insert(conversation.subagents[descendant].id)
                        if conversation.subagents[descendant].state == .running {
                            conversation.subagents[descendant].state = .disconnected
                        }
                    }
                }
            }
            for message in conversation.messages.indices where conversation.messages[message].subagentSessionID.map(ended.contains) == true {
                if conversation.messages[message].toolStatus == .pending || conversation.messages[message].toolStatus == .inProgress {
                    conversation.messages[message].toolStatus = .interrupted
                }
            }
            conversation.pendingPermissions.removeAll { $0.subagentSessionID.map(ended.contains) == true }
            conversation.refreshTurnClock(at: now())
        }
        conversations[root] = conversation
        updateAttention()
        return true
    }

    private func rebuildSubagentOwners() {
        subagentOwners.removeAll()
        for (root, conversation) in conversations {
            for child in conversation.subagents { subagentOwners[child.id] = root }
        }
    }

    private static func toolMessageID(_ toolCallID: String, subagentSessionID: String?) -> String {
        guard let child = subagentSessionID else { return "tool:\(toolCallID)" }
        return "subagent-tool:\(child.utf8.count):\(child):\(toolCallID)"
    }

    private func append(_ text: String, role: AgentConversationMessage.Role, to sessionID: String, subagentSessionID: String? = nil) {
        var conversation = conversations[sessionID] ?? AgentConversation()
        if let last = conversation.messages.indices.last, conversation.messages[last].role == role,
           conversation.messages[last].subagentSessionID == subagentSessionID {
            conversation.messages[last].text += text
        } else {
            conversation.messages.append(AgentConversationMessage(role: role, text: text))
            conversation.messages[conversation.messages.count - 1].subagentSessionID = subagentSessionID
        }
        conversations[sessionID] = conversation
    }

    private func upsertTool(_ toolCallID: String, update: [String: Any], in sessionID: String, subagentSessionID: String? = nil) {
        var conversation = conversations[sessionID] ?? AgentConversation()
        let id = Self.toolMessageID(toolCallID, subagentSessionID: subagentSessionID)
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
                text: title ?? "Tool call",
                toolStatus: status ?? .pending
            ))
            conversation.messages[conversation.messages.count - 1].toolDetails.merge(update)
            conversation.messages[conversation.messages.count - 1].subagentSessionID = subagentSessionID
        }
        conversations[sessionID] = conversation
    }

    private func permissionPrompt(_ requestID: String, _ request: [String: Any], sessionID: String) -> AgentPermissionPrompt {
        let child = (request["sessionId"] as? String).flatMap { subagentOwners[$0] == sessionID ? $0 : nil }
        let tool = request["toolCall"] as? [String: Any]
        let options = (request["options"] as? [[String: Any]] ?? []).compactMap { option -> AgentPermissionChoice? in
            guard let id = option["optionId"] as? String, let label = option["name"] as? String else { return nil }
            return AgentPermissionChoice(id: id, label: label, kind: option["kind"] as? String)
        }
        let toolTitle = tool?["title"] as? String ?? "Allow the Agent to continue?"
        let name = child.flatMap { id in conversations[sessionID]?.subagents.first(where: { $0.id == id })?.name }
        var prompt = AgentPermissionPrompt(
            id: requestID,
            title: name.map { "\($0): \(toolTitle)" } ?? toolTitle,
            choices: options
        )
        prompt.subagentSessionID = child
        if let tool {
            if let id = tool["toolCallId"] as? String,
               let known = conversations[sessionID]?.messages.first(where: { $0.id == Self.toolMessageID(id, subagentSessionID: child) }) {
                prompt.details = known.toolDetails
            }
            prompt.details.merge(tool)
        }
        return prompt
    }

    // MARK: Helpers

    @discardableResult
    private func startPrompt(_ prompt: AgentPrompt, in sessionID: String, messageID: String? = nil) -> Bool {
        var command: [String: Any] = ["kind": "prompt", "sessionId": sessionID, "text": prompt.text]
        if !prompt.files.isEmpty { command["files"] = prompt.files.map(\.commandValue) }
        guard sendCommand(command) else { return false }
        unpromptedSessionIDs.remove(sessionID)
        var conversation = conversations[sessionID] ?? AgentConversation()
        let message = AgentConversationMessage(id: messageID ?? UUID().uuidString, role: .user, text: prompt.displayText)
        if messageID == nil { conversation.messages.append(message) }
        else if let index = conversation.messages.firstIndex(where: { $0.id == messageID }) {
            conversation.messages[index].delivery = .received
        }
        conversation.activeTurn = AgentTurnStatistics(id: message.id, startedAt: prompt.submittedAt)
        conversation.isResponding = true
        conversation.isQuiet = false
        conversation.responsePhase = .waiting
        conversation.retryTurnID = nil
        conversation.retryAttempt = nil
        conversation.retryMaxAttempts = nil
        conversation.errorMessage = nil
        conversation.notice = nil
        conversation.autoFallbackTransition = nil
        conversations[sessionID] = conversation
        return true
    }

    private func setDelivery(_ delivery: AgentConversationMessage.Delivery, messageID: String, in sessionID: String) {
        guard let index = conversations[sessionID]?.messages.firstIndex(where: { $0.id == messageID }) else { return }
        conversations[sessionID]?.messages[index].delivery = delivery
    }

    private func cancelContinuation(in sessionID: String) {
        supplements[sessionID]?.isCancelled = true
        if let supplement = continuations.removeValue(forKey: sessionID) {
            setDelivery(.failed("Supplementary message cancelled."), messageID: supplement.messageID, in: sessionID)
        }
    }

    /// Explicitly unconsumed input (including deferred commands) can become a
    /// normal prompt after this turn; ambiguous delivery failures never replay.
    private func resumeContinuation(in sessionID: String) {
        guard let supplement = continuations[sessionID], let conversation = conversations[sessionID],
              !conversation.isResponding, !conversation.isCancelling, conversation.pendingConfigToken == nil,
              conversation.queuedConfigValues.isEmpty else { return }
        continuations[sessionID] = nil
        if conversation.configurationError != nil || !startPrompt(supplement.prompt, in: sessionID, messageID: supplement.messageID) {
            setDelivery(.failed(conversation.configurationError ?? errorMessage ?? AgentConversationError.notConnected.localizedDescription),
                        messageID: supplement.messageID, in: sessionID)
        }
    }

    private func persistStatistics(_ sessionID: String) {
        guard let statisticsStore, let conversation = conversations[sessionID],
              conversation.isAttached, !conversation.isLoading else { return }
        statisticsStore.save(conversation, sessionID: sessionID)
    }

    private func restoreContextUsage(in sessionID: String) {
        guard let conversation = conversations[sessionID], !conversation.hasReportedContextUsage else { return }
        let snapshot = conversation.statisticsBaseline ?? loadBackups[sessionID]?.statisticsRecord(at: .distantPast)
        guard let usage = snapshot?.contextUsage, let models = snapshot?.contextModels,
              !models.isEmpty, models == conversation.contextModelValues else { return }
        conversations[sessionID]?.contextUsage = usage
        conversations[sessionID]?.contextUsageIsHistorical = true
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
        // Replay carries no timing or usage; earlier connections' totals do.
        conversation.statisticsBaseline = statisticsStore?.record(for: sessionID)
        conversations[sessionID] = conversation
        rebuildSubagentOwners()
        if !sendCommand(["kind": "loadSession", "token": token, "sessionId": sessionID]) {
            requestFailed(token: token, sessionID: sessionID, message: errorMessage ?? "The Agent request failed.")
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
        canSteer = false
        for (sessionID, supplement) in supplements.merging(continuations, uniquingKeysWith: { first, _ in first }) {
            setDelivery(.failed(failure ?? AgentConversationError.notConnected.localizedDescription), messageID: supplement.messageID, in: sessionID)
        }
        supplements.removeAll()
        continuations.removeAll()
        isRefreshingSessions = false
        historyRefreshToken = nil
        // Archived rows belong to this connection's Agent and workspace; never
        // let them outlive it into another Agent's history.
        canListArchivedSessions = false
        listedArchivedSessions = []
        upstreamActiveSessionIDs = []
        isArchivedHistoryComplete = true
        isRefreshingArchivedSessions = false
        archivedRefreshToken = nil
        supersededListTokens.removeAll()
        if let request = unarchiveRequest { finishUnarchive(token: request.token, result: .failure(AgentConversationError.notConnected)) }
        archivedHistoryError = nil
        for continuation in historyContinuations.values {
            continuation.resume(throwing: AgentConversationError.notConnected)
        }
        historyContinuations.removeAll()
        queuedPrompts.removeAll()
        loadTokens.removeAll()
        for (id, backup) in loadBackups { conversations[id] = backup }
        rebuildSubagentOwners()
        loadBackups.removeAll()
        discardUnpersistedEmptySessions()
        createToken = nil
        pendingNewConversationPrompt = nil
        for id in conversations.keys {
            conversations[id]?.finishTurn(at: now())
            persistStatistics(id)
            conversations[id]?.contextUsage = nil
            conversations[id]?.contextUsageIsHistorical = false
            conversations[id]?.hasReportedContextUsage = false
            conversations[id]?.notice = nil
            conversations[id]?.pendingModeNotice = nil
            conversations[id]?.autoFallbackTransition = nil
            conversations[id]?.availableCommands = []
            conversations[id]?.isResponding = false
            conversations[id]?.interruptPendingTools()
            conversations[id]?.isCancelling = false
            conversations[id]?.pendingSteeringToken = nil
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
        let discarded = unpromptedSessionIDs.filter {
            let draft = $0 == selectedSessionID ? Draft(text: draftText, files: draftFiles) : sessionDrafts[$0] ?? Draft()
            return conversations[$0]?.messages.isEmpty == true && draft.isEmpty
        }
        unpromptedSessionIDs.subtract(discarded)
        // Never infer this from an empty transcript alone: unloaded history must survive.
        for id in discarded { conversations[id] = nil; sessionDrafts[id] = nil }
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

    private func buffer(_ text: String, role: AgentConversationMessage.Role, in sessionID: String, subagentSessionID: String? = nil) {
        if let pending = pendingText[sessionID], pending.role != role || pending.subagentSessionID != subagentSessionID { flushPendingText() }
        pendingText[sessionID, default: (role, "", subagentSessionID)].text += text
        scheduleFlush()
    }

    private func flushPendingText() {
        let pending = pendingText
        pendingText.removeAll()
        for (sessionID, chunk) in pending where !chunk.text.isEmpty {
            append(chunk.text, role: chunk.role, to: sessionID, subagentSessionID: chunk.subagentSessionID)
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
    case configurationPending
    case sessionBusy
    case fileReviewInProgress
    case fileReviewChanged
    case sendFailed(String)

    /// Canonical product message keys; the native view selects the interface language.
    public var errorDescription: String? {
        switch self {
        case .featureDisabled: "Agent conversation is turned off. Turn it on in the panel settings to send messages."
        case .noAgentConfigured: "No Agent is ready yet. Open the panel settings to install an Agent and choose a local or custom provider."
        case .moduleStarting: "The Agent module is still starting. Try again in a moment."
        case .missingCommand: "Set the custom Agent's executable in the panel settings."
        case .missingProvider: "Choose a local or custom provider in the Agent panel settings."
        case .missingAPIKey: "This Agent's provider has no API key. Update its local configuration or edit the custom provider in the panel settings."
        case .notConnected: "The Agent is not running. Connect to start a conversation."
        case .sessionStopping: "The previous Agent is still stopping. Try again shortly."
        case .cannotResume: "This Agent cannot reopen earlier conversations. Start a new conversation."
        case .sessionBusy: "The Agent is still responding in this conversation."
        case .fileReviewInProgress: "Wait for the Agent file rollback to finish."
        case .fileReviewChanged: "The reported file changes have been updated. Review them again before rolling back."
        case .sendFailed(let message): message
        case .configurationPending: "Wait for the Agent configuration to finish updating."
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
