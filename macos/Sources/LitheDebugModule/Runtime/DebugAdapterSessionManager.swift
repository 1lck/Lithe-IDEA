import Foundation
import LitheCoreContracts

/// Identifies one independently managed debug adapter session.
public struct DebugSessionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

/// A stable, UI-safe projection of one debug session.
public struct DebugSessionSummary: Identifiable, Equatable, Sendable {
    public let id: DebugSessionID
    public let providerID: String
    public let providerDisplayName: String
    public let rootURL: URL
    public let state: DebugAdapterState
    public let targetTitle: String?

    public var isRunning: Bool {
        ![.idle, .terminated, .failed].contains(state)
    }

    public init(
        id: DebugSessionID,
        providerID: String,
        providerDisplayName: String,
        rootURL: URL,
        state: DebugAdapterState,
        targetTitle: String? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.providerDisplayName = providerDisplayName
        self.rootURL = rootURL
        self.state = state
        self.targetTitle = targetTitle
    }
}

/// The adapter and its public identity returned when a new session is created.
public struct DebugSessionHandle {
    public let id: DebugSessionID
    public let session: any DebugAdapterSession

    public init(id: DebugSessionID, session: any DebugAdapterSession) {
        self.id = id
        self.session = session
    }
}

/// Owns every DAP session, breakpoint projection, and debug callback.
///
/// This is deliberately separate from `LanguageToolingSessionManager`: an LSP
/// module can now sleep without stopping a debugger, and the Debug module can
/// release every adapter without retaining a language-server service graph.
@MainActor
public final class DebugAdapterSessionManager: ObservableObject {
    @Published public private(set) var states: [String: DebugAdapterState] = [:]
    @Published public private(set) var lastEvents: [String: DebugAdapterEvent] = [:]
    @Published public private(set) var verifiedBreakpoints: [String: [DebugBreakpoint]] = [:]
    @Published public private(set) var sessionSummaries: [DebugSessionSummary] = []

    public var onStateChange: ((String, DebugAdapterState) -> Void)?
    public var onEvent: ((String, DebugAdapterEvent) -> Void)?
    public var onSessionStateChange: ((DebugSessionID, String, DebugAdapterState) -> Void)?
    public var onSessionEvent: ((DebugSessionID, String, DebugAdapterEvent) -> Void)?
    public var onRunInTerminalRequest: DebugRunInTerminalRequestHandler? {
        didSet {
            for managed in sessions.values {
                configureRunInTerminalHandler(managed.session)
            }
        }
    }

    private let providers: [DebugProviderDescriptor]
    private let makeSession: @MainActor (
        DebugProviderDescriptor,
        URL
    ) -> (any DebugAdapterSession)?
    private struct ManagedSession {
        let id: DebugSessionID
        let descriptor: DebugProviderDescriptor
        let rootURL: URL
        let session: any DebugAdapterSession
        let activationToken: UUID
        var targetTitle: String?
    }

    private var sessions: [DebugSessionID: ManagedSession] = [:]
    private var sessionOrder: [DebugSessionID] = []
    private var activeSessionIDsByProvider: [String: DebugSessionID] = [:]
    private var roots: [String: URL] = [:]
    private var activationTokens: [String: UUID] = [:]
    private var requestedBreakpoints: [String: [URL: [DebugSourceBreakpoint]]] = [:]
    private var requestedExceptionBreakpoints: [String: [DebugExceptionBreakpoint]] = [:]
    private var requestedFunctionBreakpoints: [String: [DebugFunctionBreakpoint]] = [:]
    private var requestedDataBreakpoints: [String: [DebugDataBreakpoint]] = [:]

    public init(
        providers: [DebugProviderDescriptor],
        makeSession: @escaping @MainActor (
            DebugProviderDescriptor,
            URL
        ) -> (any DebugAdapterSession)?
    ) {
        self.providers = providers
        self.makeSession = makeSession
    }

    /// Provider IDs with a currently selected compatibility session.
    public var activeAdapterIDs: Set<String> { Set(activeSessionIDsByProvider.keys) }

    /// IDs for every session still registered with the manager.
    public var activeSessionIDs: Set<DebugSessionID> { Set(sessions.keys) }

    public func provider(for fileURL: URL) -> DebugProviderDescriptor? {
        providers.first { $0.matches(fileURL) }
    }

    @discardableResult
    public func activate(for fileURL: URL, rootURL: URL) throws -> any DebugAdapterSession {
        let providerID = try descriptor(for: fileURL).id
        if let sessionID = activeSessionIDsByProvider[providerID],
           let managed = sessions[sessionID],
           managed.session.isRunning,
           managed.rootURL == rootURL.standardizedFileURL {
            return managed.session
        }
        if activeSessionIDsByProvider[providerID] != nil {
            stop(providerID: providerID)
        }
        return try activateNew(for: fileURL, rootURL: rootURL).session
    }

    /// Creates a new independent session without replacing another session for
    /// the same provider. Existing provider-level APIs continue to use the
    /// latest session as their compatibility target.
    @discardableResult
    public func activateNew(for fileURL: URL, rootURL: URL) throws -> DebugSessionHandle {
        let descriptor = try descriptor(for: fileURL)
        let normalizedRoot = rootURL.standardizedFileURL
        guard let session = makeSession(descriptor, normalizedRoot) else {
            throw DebugProviderError.adapterUnavailable(descriptor.displayName)
        }
        let sessionID = DebugSessionID()
        let activationToken = UUID()
        configureCallbacks(
            session,
            sessionID: sessionID,
            providerID: descriptor.id,
            activationToken: activationToken
        )
        sessions[sessionID] = ManagedSession(
            id: sessionID,
            descriptor: descriptor,
            rootURL: normalizedRoot,
            session: session,
            activationToken: activationToken,
            targetTitle: nil
        )
        sessionOrder.append(sessionID)
        activeSessionIDsByProvider[descriptor.id] = sessionID
        roots[descriptor.id] = normalizedRoot
        states[descriptor.id] = session.state
        activationTokens[descriptor.id] = activationToken
        updateSessionSummary(sessionID)
        do {
            try session.start(rootURL: normalizedRoot)
        } catch {
            session.stop()
            sessions.removeValue(forKey: sessionID)
            sessionOrder.removeAll { $0 == sessionID }
            if activeSessionIDsByProvider[descriptor.id] == sessionID {
                promoteLatestSession(for: descriptor.id)
            }
            throw error
        }
        if activeSessionIDsByProvider[descriptor.id] == sessionID {
            states[descriptor.id] = session.state
        }
        updateSessionSummary(sessionID)
        if let controlling = session as? any DebugAdapterControllingSession {
            for (source, breakpoints) in requestedBreakpoints[descriptor.id] ?? [:] {
                controlling.setBreakpoints(breakpoints, in: source)
            }
            if let breakpoints = requestedExceptionBreakpoints[descriptor.id] {
                controlling.setExceptionBreakpoints(breakpoints)
            }
            if let breakpoints = requestedFunctionBreakpoints[descriptor.id] {
                controlling.setFunctionBreakpoints(breakpoints)
            }
            if let breakpoints = requestedDataBreakpoints[descriptor.id] {
                controlling.setDataBreakpoints(breakpoints)
            }
        }
        return DebugSessionHandle(id: sessionID, session: session)
    }

    @discardableResult
    public func launch(
        for fileURL: URL,
        rootURL: URL,
        configuration: DebugLaunchConfiguration
    ) throws -> any DebugAdapterControllingSession {
        let session = try activate(for: fileURL, rootURL: rootURL)
        guard let controlling = session as? any DebugAdapterControllingSession else {
            throw DebugProviderError.capabilityUnavailable(
                provider: provider(for: fileURL)?.displayName ?? fileURL.pathExtension,
                capability: "DAP launch control"
            )
        }
        try controlling.launch(configuration)
        return controlling
    }

    /// Starts a new independent adapter session and returns its identity.
    @discardableResult
    public func launchNew(
        for fileURL: URL,
        rootURL: URL,
        configuration: DebugLaunchConfiguration
    ) throws -> (id: DebugSessionID, session: any DebugAdapterControllingSession) {
        let handle = try activateNew(for: fileURL, rootURL: rootURL)
        guard let controlling = handle.session as? any DebugAdapterControllingSession else {
            stop(sessionID: handle.id)
            throw DebugProviderError.capabilityUnavailable(
                provider: provider(for: fileURL)?.displayName ?? fileURL.pathExtension,
                capability: "DAP launch control"
            )
        }
        do {
            try controlling.launch(configuration)
        } catch {
            stop(sessionID: handle.id)
            throw error
        }
        updateSessionTargetTitle(handle.id, title: configuration.name)
        return (handle.id, controlling)
    }

    public func setBreakpoints(_ breakpoints: [DebugSourceBreakpoint], in fileURL: URL) throws {
        guard let descriptor = provider(for: fileURL) else {
            throw DebugProviderError.noProvider(
                fileExtension: fileURL.pathExtension.lowercased()
            )
        }
        var values = requestedBreakpoints[descriptor.id] ?? [:]
        values[fileURL.standardizedFileURL] = breakpoints
        requestedBreakpoints[descriptor.id] = values
        sessions.values
            .filter { $0.descriptor.id == descriptor.id }
            .compactMap { $0.session as? any DebugAdapterControllingSession }
            .forEach { $0.setBreakpoints(breakpoints, in: fileURL) }
    }

    public func setExceptionBreakpoints(
        _ breakpoints: [DebugExceptionBreakpoint],
        for fileURL: URL
    ) throws {
        guard let descriptor = provider(for: fileURL) else {
            throw DebugProviderError.noProvider(
                fileExtension: fileURL.pathExtension.lowercased()
            )
        }
        requestedExceptionBreakpoints[descriptor.id] = breakpoints
        sessions.values
            .filter { $0.descriptor.id == descriptor.id }
            .compactMap { $0.session as? any DebugAdapterControllingSession }
            .forEach { $0.setExceptionBreakpoints(breakpoints) }
    }

    public func setFunctionBreakpoints(
        _ breakpoints: [DebugFunctionBreakpoint],
        for fileURL: URL
    ) throws {
        guard let descriptor = provider(for: fileURL) else {
            throw DebugProviderError.noProvider(
                fileExtension: fileURL.pathExtension.lowercased()
            )
        }
        requestedFunctionBreakpoints[descriptor.id] = breakpoints
        sessions.values
            .filter { $0.descriptor.id == descriptor.id }
            .compactMap { $0.session as? any DebugAdapterControllingSession }
            .forEach { $0.setFunctionBreakpoints(breakpoints) }
    }

    public func setDataBreakpoints(
        _ breakpoints: [DebugDataBreakpoint],
        for fileURL: URL
    ) throws {
        guard let descriptor = provider(for: fileURL) else {
            throw DebugProviderError.noProvider(
                fileExtension: fileURL.pathExtension.lowercased()
            )
        }
        requestedDataBreakpoints[descriptor.id] = breakpoints
        sessions.values
            .filter { $0.descriptor.id == descriptor.id }
            .compactMap { $0.session as? any DebugAdapterControllingSession }
            .forEach { $0.setDataBreakpoints(breakpoints) }
    }

    public func session(providerID: String) -> (any DebugAdapterControllingSession)? {
        guard let sessionID = activeSessionIDsByProvider[providerID] else { return nil }
        return sessions[sessionID]?.session as? any DebugAdapterControllingSession
    }

    public func session(id: DebugSessionID) -> (any DebugAdapterControllingSession)? {
        sessions[id]?.session as? any DebugAdapterControllingSession
    }

    /// Selects which session is addressed by the compatibility provider-level
    /// APIs and callbacks. Selection does not start or stop a session.
    @discardableResult
    public func select(sessionID: DebugSessionID) -> Bool {
        guard let managed = sessions[sessionID] else { return false }
        let providerID = managed.descriptor.id
        activeSessionIDsByProvider[providerID] = sessionID
        roots[providerID] = managed.rootURL
        activationTokens[providerID] = managed.activationToken
        states[providerID] = managed.session.state
        return true
    }

    public func selectedSessionID(providerID: String) -> DebugSessionID? {
        activeSessionIDsByProvider[providerID]
    }

    public func stop(providerID: String) {
        guard let sessionID = activeSessionIDsByProvider[providerID] else {
            states[providerID] = .idle
            return
        }
        stop(sessionID: sessionID)
    }

    public func stop(sessionID: DebugSessionID) {
        guard let managed = sessions.removeValue(forKey: sessionID) else { return }
        managed.session.stop()
        sessionOrder.removeAll { $0 == sessionID }
        if activeSessionIDsByProvider[managed.descriptor.id] == sessionID {
            promoteLatestSession(for: managed.descriptor.id)
        }
        sessionSummaries.removeAll { $0.id == sessionID }
        onSessionStateChange?(sessionID, managed.descriptor.id, .idle)
    }

    public func stopAll() {
        for session in sessions.values { session.session.stop() }
        sessions.removeAll()
        sessionOrder.removeAll()
        activeSessionIDsByProvider.removeAll()
        roots.removeAll()
        activationTokens.removeAll()
        states.removeAll()
        lastEvents.removeAll()
        verifiedBreakpoints.removeAll()
        sessionSummaries.removeAll()
        requestedBreakpoints.removeAll()
        requestedExceptionBreakpoints.removeAll()
        requestedFunctionBreakpoints.removeAll()
        requestedDataBreakpoints.removeAll()
    }

    private func configureCallbacks(
        _ session: any DebugAdapterSession,
        sessionID: DebugSessionID,
        providerID: String,
        activationToken: UUID
    ) {
        configureRunInTerminalHandler(session)
        guard let controlling = session as? any DebugAdapterControllingSession else { return }
        controlling.onStateChange = { [weak self] state in
            guard let self,
                  self.sessions[sessionID]?.activationToken == activationToken else { return }
            self.updateSessionState(sessionID, state: state)
            self.onSessionStateChange?(sessionID, providerID, state)
            guard self.activeSessionIDsByProvider[providerID] == sessionID else { return }
            self.states[providerID] = state
            self.onStateChange?(providerID, state)
        }
        controlling.onEvent = { [weak self] event in
            guard let self,
                  self.sessions[sessionID]?.activationToken == activationToken else { return }
            self.onSessionEvent?(sessionID, providerID, event)
            guard self.activeSessionIDsByProvider[providerID] == sessionID else { return }
            lastEvents[providerID] = event
            onEvent?(providerID, event)
            if case .breakpoint(let breakpoint) = event {
                var values = verifiedBreakpoints[providerID] ?? []
                if let index = values.firstIndex(where: { $0.id == breakpoint.id }) {
                    values[index] = breakpoint
                } else {
                    values.append(breakpoint)
                }
                verifiedBreakpoints[providerID] = values.sorted {
                    ($0.sourceURL?.path ?? "", $0.line ?? 0)
                        < ($1.sourceURL?.path ?? "", $1.line ?? 0)
                }
            }
        }
    }

    private func descriptor(for fileURL: URL) throws -> DebugProviderDescriptor {
        guard let descriptor = provider(for: fileURL) else {
            throw DebugProviderError.noProvider(
                fileExtension: fileURL.pathExtension.lowercased()
            )
        }
        return descriptor
    }

    private func updateSessionState(_ sessionID: DebugSessionID, state: DebugAdapterState) {
        guard let index = sessionSummaries.firstIndex(where: { $0.id == sessionID }),
              let existing = sessions[sessionID] else { return }
        sessionSummaries[index] = DebugSessionSummary(
            id: sessionID,
            providerID: existing.descriptor.id,
            providerDisplayName: existing.descriptor.displayName,
            rootURL: existing.rootURL,
            state: state,
            targetTitle: existing.targetTitle
        )
    }

    private func promoteLatestSession(for providerID: String) {
        guard let replacementID = sessionOrder.reversed().first(where: {
            sessions[$0]?.descriptor.id == providerID
        }), let replacement = sessions[replacementID] else {
            activeSessionIDsByProvider[providerID] = nil
            roots[providerID] = nil
            activationTokens[providerID] = nil
            states[providerID] = .idle
            lastEvents[providerID] = nil
            verifiedBreakpoints[providerID] = nil
            return
        }
        activeSessionIDsByProvider[providerID] = replacementID
        roots[providerID] = replacement.rootURL
        activationTokens[providerID] = replacement.activationToken
        states[providerID] = replacement.session.state
        lastEvents[providerID] = nil
        verifiedBreakpoints[providerID] = nil
    }

    private func updateSessionSummary(_ sessionID: DebugSessionID) {
        guard let managed = sessions[sessionID] else { return }
        let summary = DebugSessionSummary(
            id: sessionID,
            providerID: managed.descriptor.id,
            providerDisplayName: managed.descriptor.displayName,
            rootURL: managed.rootURL,
            state: managed.session.state,
            targetTitle: managed.targetTitle
        )
        if let index = sessionSummaries.firstIndex(where: { $0.id == sessionID }) {
            sessionSummaries[index] = summary
        } else {
            sessionSummaries.append(summary)
        }
        sessionSummaries.sort { left, right in
            guard let leftIndex = sessionOrder.firstIndex(of: left.id),
                  let rightIndex = sessionOrder.firstIndex(of: right.id) else {
                return left.id.description < right.id.description
            }
            return leftIndex < rightIndex
        }
    }

    private func updateSessionTargetTitle(_ sessionID: DebugSessionID, title: String?) {
        guard var managed = sessions[sessionID] else { return }
        managed.targetTitle = title
        sessions[sessionID] = managed
        updateSessionSummary(sessionID)
    }

    private func configureRunInTerminalHandler(_ session: any DebugAdapterSession) {
        guard let session = session as? any DebugAdapterRunInTerminalSession else { return }
        session.onRunInTerminalRequest = onRunInTerminalRequest
    }
}
