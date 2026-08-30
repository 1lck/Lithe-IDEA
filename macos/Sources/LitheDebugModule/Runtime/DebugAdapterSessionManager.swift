import Foundation
import LitheCoreContracts

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

    public var onStateChange: ((String, DebugAdapterState) -> Void)?
    public var onEvent: ((String, DebugAdapterEvent) -> Void)?
    public var onRunInTerminalRequest: DebugRunInTerminalRequestHandler? {
        didSet {
            for session in sessions.values {
                configureRunInTerminalHandler(session)
            }
        }
    }

    private let providers: [DebugProviderDescriptor]
    private let makeSession: @MainActor (
        DebugProviderDescriptor,
        URL
    ) -> (any DebugAdapterSession)?
    private var sessions: [String: any DebugAdapterSession] = [:]
    private var roots: [String: URL] = [:]
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

    public var activeAdapterIDs: Set<String> { Set(sessions.keys) }

    public func provider(for fileURL: URL) -> DebugProviderDescriptor? {
        providers.first { $0.matches(fileURL) }
    }

    @discardableResult
    public func activate(for fileURL: URL, rootURL: URL) throws -> any DebugAdapterSession {
        guard let descriptor = provider(for: fileURL) else {
            throw DebugProviderError.noProvider(
                fileExtension: fileURL.pathExtension.lowercased()
            )
        }

        let normalizedRoot = rootURL.standardizedFileURL
        if let active = sessions[descriptor.id] {
            if active.isRunning, roots[descriptor.id] == normalizedRoot {
                return active
            }
            active.stop()
            sessions[descriptor.id] = nil
            roots[descriptor.id] = nil
        }

        guard let session = makeSession(descriptor, normalizedRoot) else {
            throw DebugProviderError.adapterUnavailable(descriptor.displayName)
        }
        configureCallbacks(session, providerID: descriptor.id)
        try session.start(rootURL: normalizedRoot)
        sessions[descriptor.id] = session
        roots[descriptor.id] = normalizedRoot
        states[descriptor.id] = session.state
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
        return session
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

    public func setBreakpoints(_ breakpoints: [DebugSourceBreakpoint], in fileURL: URL) throws {
        guard let descriptor = provider(for: fileURL) else {
            throw DebugProviderError.noProvider(
                fileExtension: fileURL.pathExtension.lowercased()
            )
        }
        var values = requestedBreakpoints[descriptor.id] ?? [:]
        values[fileURL.standardizedFileURL] = breakpoints
        requestedBreakpoints[descriptor.id] = values
        session(providerID: descriptor.id)?.setBreakpoints(breakpoints, in: fileURL)
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
        session(providerID: descriptor.id)?.setExceptionBreakpoints(breakpoints)
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
        session(providerID: descriptor.id)?.setFunctionBreakpoints(breakpoints)
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
        session(providerID: descriptor.id)?.setDataBreakpoints(breakpoints)
    }

    public func session(providerID: String) -> (any DebugAdapterControllingSession)? {
        sessions[providerID] as? any DebugAdapterControllingSession
    }

    public func stop(providerID: String) {
        sessions.removeValue(forKey: providerID)?.stop()
        roots[providerID] = nil
        states[providerID] = .idle
    }

    public func stopAll() {
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        roots.removeAll()
        states.removeAll()
        lastEvents.removeAll()
        verifiedBreakpoints.removeAll()
        requestedBreakpoints.removeAll()
        requestedExceptionBreakpoints.removeAll()
        requestedFunctionBreakpoints.removeAll()
        requestedDataBreakpoints.removeAll()
    }

    private func configureCallbacks(
        _ session: any DebugAdapterSession,
        providerID: String
    ) {
        configureRunInTerminalHandler(session)
        guard let controlling = session as? any DebugAdapterControllingSession else { return }
        controlling.onStateChange = { [weak self] state in
            self?.states[providerID] = state
            self?.onStateChange?(providerID, state)
        }
        controlling.onEvent = { [weak self] event in
            guard let self else { return }
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

    private func configureRunInTerminalHandler(_ session: any DebugAdapterSession) {
        guard let session = session as? any DebugAdapterRunInTerminalSession else { return }
        session.onRunInTerminalRequest = onRunInTerminalRequest
    }
}
