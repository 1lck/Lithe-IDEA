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
    /// The session whose adapter asked for this one; nil for a root session.
    public let parentID: DebugSessionID?

    public var isRunning: Bool {
        ![.idle, .terminated, .failed].contains(state)
    }

    public init(
        id: DebugSessionID,
        providerID: String,
        providerDisplayName: String,
        rootURL: URL,
        state: DebugAdapterState,
        targetTitle: String? = nil,
        parentID: DebugSessionID? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.providerDisplayName = providerDisplayName
        self.rootURL = rootURL
        self.state = state
        self.targetTitle = targetTitle
        self.parentID = parentID
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
                configureRunInTerminalHandler(managed.session, sessionID: managed.id)
            }
        }
    }
    /// Session-aware reverse request routing used by hosts that own one
    /// integrated terminal per debugger session.
    public var onSessionRunInTerminalRequest: ((
        DebugSessionID,
        DebugRunInTerminalRequest,
        @escaping DebugRunInTerminalCompletion
    ) -> Void)? {
        didSet {
            for managed in sessions.values {
                configureRunInTerminalHandler(managed.session, sessionID: managed.id)
            }
        }
    }

    /// Builds the adapter session for a `startDebugging` child of a running session.
    /// A provider that understands its adapter's child configuration (for example a
    /// `connect` endpoint) may override it; by default the child is a new session
    /// from `makeSession`, so the host always advertises `startDebugging` support.
    public var makeChildSession: (@MainActor (
        DebugProviderDescriptor,
        DebugStartDebuggingRequest,
        URL
    ) -> (any DebugAdapterSession)?)? {
        didSet {
            for managed in sessions.values {
                configureStartDebuggingHandler(managed.session, sessionID: managed.id)
            }
        }
    }

    /// Read at every lookup: a host that registers debug adapters while it
    /// runs hands back the current set instead of the one it started with.
    private let providersSource: @MainActor () -> [DebugProviderDescriptor]
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
        let parentID: DebugSessionID?
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

    public convenience init(
        providers: [DebugProviderDescriptor],
        makeSession: @escaping @MainActor (
            DebugProviderDescriptor,
            URL
        ) -> (any DebugAdapterSession)?
    ) {
        self.init(providersSource: { providers }, makeSession: makeSession)
    }

    public init(
        providersSource: @escaping @MainActor () -> [DebugProviderDescriptor],
        makeSession: @escaping @MainActor (
            DebugProviderDescriptor,
            URL
        ) -> (any DebugAdapterSession)?
    ) {
        self.providersSource = providersSource
        self.makeSession = makeSession
    }

    /// Provider IDs with a currently selected compatibility session.
    public var activeAdapterIDs: Set<String> { Set(activeSessionIDsByProvider.keys) }

    /// IDs for every session still registered with the manager.
    public var activeSessionIDs: Set<DebugSessionID> { Set(sessions.keys) }

    public func provider(for fileURL: URL) -> DebugProviderDescriptor? {
        providersSource().first { $0.selectsByFile && $0.matches(fileURL) }
    }

    /// Reads current registrations even when an older session is still alive.
    public func provider(id: String) -> DebugProviderDescriptor? {
        providersSource().first { $0.id == id }
    }

    @discardableResult
    public func activate(for fileURL: URL, rootURL: URL, adapterProviderID: String? = nil) throws -> any DebugAdapterSession {
        let descriptor = try descriptor(for: fileURL, adapterProviderID: adapterProviderID)
        return try activate(descriptor: descriptor, rootURL: rootURL)
    }

    private func activate(descriptor: DebugProviderDescriptor, rootURL: URL) throws -> any DebugAdapterSession {
        let providerID = descriptor.id
        if let sessionID = activeSessionIDsByProvider[providerID],
           let managed = sessions[sessionID],
           managed.session.isRunning,
           managed.rootURL == rootURL.standardizedFileURL {
            return managed.session
        }
        if activeSessionIDsByProvider[providerID] != nil {
            stop(providerID: providerID)
        }
        return try activateNew(descriptor: descriptor, rootURL: rootURL).session
    }

    /// Creates a new independent session without replacing another session for
    /// the same provider. Existing provider-level APIs continue to use the
    /// latest session as their compatibility target.
    @discardableResult
    public func activateNew(for fileURL: URL, rootURL: URL, adapterProviderID: String? = nil) throws -> DebugSessionHandle {
        try activateNew(descriptor: descriptor(for: fileURL, adapterProviderID: adapterProviderID), rootURL: rootURL)
    }

    private func activateNew(descriptor: DebugProviderDescriptor, rootURL: URL) throws -> DebugSessionHandle {
        let normalizedRoot = rootURL.standardizedFileURL
        guard let session = makeSession(descriptor, normalizedRoot) else {
            throw DebugProviderError.adapterUnavailable(descriptor.displayName)
        }
        let (sessionID, activationToken) = register(
            session, descriptor: descriptor, rootURL: normalizedRoot, parentID: nil
        )
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
            replayBreakpoints(to: controlling, providerID: descriptor.id)
        }
        return DebugSessionHandle(id: sessionID, session: session)
    }

    @discardableResult
    public func launch(
        for fileURL: URL,
        rootURL: URL,
        configuration: DebugLaunchConfiguration
    ) throws -> any DebugAdapterControllingSession {
        let descriptor = try launchDescriptor(for: fileURL, configuration: configuration)
        let session = try activate(descriptor: descriptor, rootURL: rootURL)
        let sessionID = activeSessionIDsByProvider[descriptor.id]
        guard let controlling = session as? any DebugAdapterControllingSession else {
            if let sessionID { stop(sessionID: sessionID) }
            throw DebugProviderError.capabilityUnavailable(
                provider: descriptor.displayName,
                capability: "DAP launch control"
            )
        }
        do {
            try controlling.launch(configuration)
        } catch {
            if let sessionID { stop(sessionID: sessionID) }
            throw error
        }
        return controlling
    }

    /// Starts a new independent adapter session and returns its identity.
    @discardableResult
    public func launchNew(
        for fileURL: URL,
        rootURL: URL,
        configuration: DebugLaunchConfiguration
    ) throws -> (id: DebugSessionID, session: any DebugAdapterControllingSession) {
        let descriptor = try launchDescriptor(for: fileURL, configuration: configuration)
        let handle = try activateNew(descriptor: descriptor, rootURL: rootURL)
        guard let controlling = handle.session as? any DebugAdapterControllingSession else {
            stop(sessionID: handle.id)
            throw DebugProviderError.capabilityUnavailable(
                provider: descriptor.displayName,
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
        // Two explicit adapters can debug the same language concurrently. Each
        // receives source breakpoints, including those recorded before launch.
        let matching = providersSource().filter { $0.matches(fileURL) }
        guard !matching.isEmpty else {
            throw DebugProviderError.noProvider(
                fileExtension: fileURL.pathExtension.lowercased()
            )
        }
        for descriptor in matching {
            var values = requestedBreakpoints[descriptor.id] ?? [:]
            values[fileURL.standardizedFileURL] = breakpoints
            requestedBreakpoints[descriptor.id] = values
        }
        let providerIDs = Set(matching.map(\.id))
        sessions.values
            .filter { providerIDs.contains($0.descriptor.id) }
            .compactMap { $0.session as? any DebugAdapterControllingSession }
            .forEach { $0.setBreakpoints(breakpoints, in: fileURL) }
    }

    public func setExceptionBreakpoints(
        _ breakpoints: [DebugExceptionBreakpoint],
        for fileURL: URL,
        adapterProviderID: String? = nil
    ) throws {
        let descriptor = try descriptor(for: fileURL, adapterProviderID: adapterProviderID)
        requestedExceptionBreakpoints[descriptor.id] = breakpoints
        sessions.values
            .filter { $0.descriptor.id == descriptor.id }
            .compactMap { $0.session as? any DebugAdapterControllingSession }
            .forEach { $0.setExceptionBreakpoints(breakpoints) }
    }

    public func setFunctionBreakpoints(
        _ breakpoints: [DebugFunctionBreakpoint],
        for fileURL: URL,
        adapterProviderID: String? = nil
    ) throws {
        let descriptor = try descriptor(for: fileURL, adapterProviderID: adapterProviderID)
        requestedFunctionBreakpoints[descriptor.id] = breakpoints
        sessions.values
            .filter { $0.descriptor.id == descriptor.id }
            .compactMap { $0.session as? any DebugAdapterControllingSession }
            .forEach { $0.setFunctionBreakpoints(breakpoints) }
    }

    public func setDataBreakpoints(
        _ breakpoints: [DebugDataBreakpoint],
        for fileURL: URL,
        adapterProviderID: String? = nil
    ) throws {
        let descriptor = try descriptor(for: fileURL, adapterProviderID: adapterProviderID)
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

    /// Stops a session together with its whole child tree, children first, so no
    /// child outlives the parent whose adapter requested it.
    public func stop(sessionID: DebugSessionID) {
        for childID in childSessionIDs(of: sessionID).reversed() { stopOne(childID) }
        stopOne(sessionID)
    }

    /// Stops every session `isOwned` accepts, each with its child tree. A host
    /// that knows which registration a session was built from uses this to end
    /// exactly the sessions of a registration that went away, not every session
    /// that happens to debug the same language.
    public func stopSessions(where isOwned: (any DebugAdapterSession) -> Bool) {
        for sessionID in sessionOrder {
            guard let managed = sessions[sessionID], isOwned(managed.session) else { continue }
            stop(sessionID: sessionID)
        }
    }

    /// IDs of every descendant of `sessionID`, parents before their children.
    public func childSessionIDs(of sessionID: DebugSessionID) -> [DebugSessionID] {
        var result: [DebugSessionID] = []
        var pending = [sessionID]
        while !pending.isEmpty {
            let parent = pending.removeFirst()
            let children = sessionOrder.filter { sessions[$0]?.parentID == parent }
            result.append(contentsOf: children)
            pending.append(contentsOf: children)
        }
        return result
    }

    private func stopOne(_ sessionID: DebugSessionID) {
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
        configureRunInTerminalHandler(session, sessionID: sessionID)
        configureStartDebuggingHandler(session, sessionID: sessionID)
        guard let controlling = session as? any DebugAdapterControllingSession else { return }
        controlling.onStateChange = { [weak self] state in
            guard let self,
                  self.sessions[sessionID]?.activationToken == activationToken else { return }
            self.updateSessionState(sessionID, state: state)
            self.onSessionStateChange?(sessionID, providerID, state)
            if state == .terminated || state == .failed {
                // Core asks children to stop when their parent ends; the host owns the
                // transports, so it closes them here.
                for childID in self.childSessionIDs(of: sessionID).reversed() {
                    self.stopOne(childID)
                }
            }
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

    private func descriptor(for fileURL: URL, adapterProviderID: String? = nil) throws -> DebugProviderDescriptor {
        if let adapterProviderID {
            guard let descriptor = provider(id: adapterProviderID) else {
                throw DebugProviderError.adapterUnavailable(adapterProviderID)
            }
            return descriptor
        }
        guard let descriptor = provider(for: fileURL) else {
            throw DebugProviderError.noProvider(
                fileExtension: fileURL.pathExtension.lowercased()
            )
        }
        return descriptor
    }

    private func launchDescriptor(for fileURL: URL, configuration: DebugLaunchConfiguration) throws -> DebugProviderDescriptor {
        let descriptor = try descriptor(for: fileURL, adapterProviderID: configuration.adapterProviderID)
        guard descriptor.requests.contains(configuration.request) else {
            throw DebugProviderError.capabilityUnavailable(
                provider: descriptor.displayName, capability: configuration.request.rawValue
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
            targetTitle: existing.targetTitle,
            parentID: existing.parentID
        )
    }

    private func promoteLatestSession(for providerID: String) {
        // Child sessions never become the provider's selected session; they are only
        // promoted when no root session of the provider is left.
        let candidates = sessionOrder.reversed().filter { sessions[$0]?.descriptor.id == providerID }
        guard let replacementID = candidates.first(where: { sessions[$0]?.parentID == nil })
                ?? candidates.first,
              let replacement = sessions[replacementID] else {
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
            targetTitle: managed.targetTitle,
            parentID: managed.parentID
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

    private func register(
        _ session: any DebugAdapterSession,
        descriptor: DebugProviderDescriptor,
        rootURL: URL,
        parentID: DebugSessionID?
    ) -> (DebugSessionID, UUID) {
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
            rootURL: rootURL,
            session: session,
            activationToken: activationToken,
            parentID: parentID,
            targetTitle: nil
        )
        sessionOrder.append(sessionID)
        return (sessionID, activationToken)
    }

    private func configureStartDebuggingHandler(
        _ session: any DebugAdapterSession,
        sessionID: DebugSessionID
    ) {
        guard let session = session as? any DebugAdapterStartDebuggingSession else { return }
        session.onStartDebuggingRequest = { [weak self] request, completion in
            guard let self else {
                completion(.failure(DebugAdapterProtocolError.stopped))
                return
            }
            completion(self.openChildSession(of: sessionID, request: request))
        }
    }

    /// Opens the session an adapter asked for. The child joins the parent's Core
    /// session tree and never replaces the provider's selected session; the UI decides
    /// when to bring it forward.
    private func openChildSession(
        of parentID: DebugSessionID,
        request: DebugStartDebuggingRequest
    ) -> Result<Void, Error> {
        guard let parent = sessions[parentID],
              parent.session.state != .terminated, parent.session.state != .failed,
              let session = (makeChildSession ?? { descriptor, _, root in self.makeSession(descriptor, root) })(
                  parent.descriptor, request, parent.rootURL
              ),
              let controlling = session as? any DebugAdapterControllingSession,
              let childLink = session as? any DebugAdapterChildSessionLinking,
              let parentLink = parent.session as? any DebugAdapterChildSessionLinking else {
            return .failure(DebugAdapterCapabilityError.unsupported("child debug sessions"))
        }
        childLink.parentCoreSessionID = parentLink.coreSessionID
        let (childID, _) = register(
            session, descriptor: parent.descriptor, rootURL: parent.rootURL, parentID: parentID
        )
        updateSessionSummary(childID)
        do {
            try session.start(rootURL: parent.rootURL)
            replayBreakpoints(to: controlling, providerID: parent.descriptor.id)
            try controlling.launch(DebugLaunchConfiguration(
                name: request.configurationName ?? parent.targetTitle ?? "",
                request: request.request,
                arguments: request.configuration
            ))
        } catch {
            stopOne(childID)
            return .failure(error)
        }
        updateSessionTargetTitle(
            childID,
            title: request.configurationName ?? parent.targetTitle
        )
        return .success(())
    }

    /// Sends the provider's saved source, exception, function and data breakpoints to a
    /// newly started session so it stops where the user already asked it to.
    private func replayBreakpoints(
        to controlling: any DebugAdapterControllingSession,
        providerID: String
    ) {
        for (source, breakpoints) in requestedBreakpoints[providerID] ?? [:] {
            controlling.setBreakpoints(breakpoints, in: source)
        }
        if let breakpoints = requestedExceptionBreakpoints[providerID] {
            controlling.setExceptionBreakpoints(breakpoints)
        }
        if let breakpoints = requestedFunctionBreakpoints[providerID] {
            controlling.setFunctionBreakpoints(breakpoints)
        }
        if let breakpoints = requestedDataBreakpoints[providerID] {
            controlling.setDataBreakpoints(breakpoints)
        }
    }

    private func configureRunInTerminalHandler(
        _ session: any DebugAdapterSession,
        sessionID: DebugSessionID
    ) {
        guard let session = session as? any DebugAdapterRunInTerminalSession else { return }
        session.onRunInTerminalRequest = { [weak self] request, completion in
            guard let self else {
                completion(.failure(DebugAdapterProtocolError.stopped))
                return
            }
            if let onSessionRunInTerminalRequest {
                onSessionRunInTerminalRequest(sessionID, request, completion)
            } else {
                onRunInTerminalRequest?(request, completion)
            }
        }
    }
}

private extension DebugStartDebuggingRequest {
    var configurationName: String? {
        guard case .string(let name)? = configuration["name"], !name.isEmpty else { return nil }
        return name
    }
}
