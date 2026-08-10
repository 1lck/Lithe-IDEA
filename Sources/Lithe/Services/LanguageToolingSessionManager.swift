import Foundation

enum LanguageToolingSessionError: LocalizedError, Equatable, Sendable {
    case noProvider(fileExtension: String)
    case providerNotInstalled(String)
    case toolingUnavailable(String)
    case capabilityUnavailable(provider: String, capability: String)

    var errorDescription: String? {
        switch self {
        case .noProvider(let fileExtension):
            return "No language provider handles .\(fileExtension) files."
        case .providerNotInstalled(let provider):
            return "The \(provider) language provider is not installed."
        case .toolingUnavailable(let message):
            return message
        case .capabilityUnavailable(let provider, let capability):
            return "The \(provider) provider does not support \(capability)."
        }
    }
}

/// UI-facing façade for language tooling. LSP behavior is intentionally not
/// implemented in Swift; these entry points are stable while the Rust LSP host
/// is wired underneath them.
@MainActor
final class LanguageToolingSessionManager: ObservableObject {
    @Published private(set) var diagnostics: [URL: [LanguageServerDiagnostic]] = [:]
    @Published private(set) var languageServerFeatures: [String: LanguageServerFeatureSet] = [:]
    @Published private(set) var debugStates: [String: DebugAdapterState] = [:]
    @Published private(set) var lastDebugEvents: [String: DebugAdapterEvent] = [:]
    @Published private(set) var verifiedBreakpoints: [String: [DebugBreakpoint]] = [:]

    var onDebugStateChange: ((String, DebugAdapterState) -> Void)?
    var onDebugEvent: ((String, DebugAdapterEvent) -> Void)?

    private var catalog: LanguageProviderCatalog
    private let core: RustCoreBridge
    private var runtimesByID: [String: any LanguageProviderRuntime]
    private var languageServers: [String: any LanguageServerSession] = [:]
    private var languageServerRoots: [String: URL] = [:]
    private var debugAdapters: [String: any DebugAdapterSession] = [:]
    private var debugAdapterRoots: [String: URL] = [:]
    private var requestedBreakpoints: [String: [URL: [DebugSourceBreakpoint]]] = [:]

    init(
        catalog: LanguageProviderCatalog = .standard,
        runtimes: [any LanguageProviderRuntime] = [],
        core: RustCoreBridge = RustCoreBridge()
    ) {
        self.catalog = catalog
        self.core = core
        runtimesByID = Dictionary(uniqueKeysWithValues: runtimes.map { ($0.descriptor.id, $0) })
    }

    convenience init(registry: LanguagePackRegistry) {
        self.init(catalog: registry.catalog, runtimes: registry.toolingRuntimes)
    }

    var activeLanguageServerIDs: Set<String> { Set(languageServers.keys) }
    var activeDebugAdapterIDs: Set<String> { Set(debugAdapters.keys) }

    func updateCatalog(_ catalog: LanguageProviderCatalog) {
        self.catalog = catalog
        let validProviderIDs = Set(catalog.descriptors.map(\.id))
        languageServerFeatures = languageServerFeatures.filter { validProviderIDs.contains($0.key) }
        diagnostics = diagnostics.filter { catalog.provider(for: $0.key) != nil }
        for providerID in Array(languageServers.keys) where !validProviderIDs.contains(providerID) {
            stopLanguageServer(providerID: providerID)
        }
    }

    func provider(for fileURL: URL) -> LanguageProviderDescriptor? {
        catalog.provider(for: fileURL)
    }

    func supportsGenericEditing(for fileURL: URL) -> Bool {
        guard catalog.provider(for: fileURL)?.capabilities.contains(.languageServer) == true else {
            return false
        }
        return !features(for: fileURL).isEmpty
    }

    func supportsGenericDebugging(for fileURL: URL) -> Bool {
        guard let descriptor = catalog.provider(for: fileURL),
              descriptor.capabilities.contains(.debugAdapter) else { return false }
        return runtimesByID[descriptor.id]?.supportsDebugAdapterSession == true
    }

    func features(for fileURL: URL) -> LanguageServerFeatureSet {
        guard let descriptor = catalog.provider(for: fileURL) else { return [] }
        if let features = languageServerFeatures[descriptor.id] { return features }
        guard descriptor.capabilities.contains(.languageServer), core.isAvailable else { return [] }
        return [.definition, .references, .implementation, .hover, .completion]
    }

    func synchronizeLanguageServer(
        for fileURL: URL,
        text: String,
        rootURL: URL
    ) throws {
        guard let descriptor = catalog.provider(for: fileURL) else {
            throw LanguageToolingSessionError.noProvider(fileExtension: fileURL.pathExtension.lowercased())
        }
        guard descriptor.capabilities.contains(.languageServer) else { return }
        guard let runtime = runtimesByID[descriptor.id],
              runtime.supportsLanguageServerSession else {
            return
        }
        let normalizedRoot = rootURL.standardizedFileURL
        let session: any LanguageServerSession
        if let active = languageServers[descriptor.id],
           active.isRunning,
           languageServerRoots[descriptor.id] == normalizedRoot {
            session = active
        } else {
            languageServers[descriptor.id]?.stop()
            guard let created = runtime.makeLanguageServerSession() else {
                throw LanguageToolingSessionError.toolingUnavailable(
                    runtime.unavailableToolingMessage ?? descriptor.displayName
                )
            }
            configureLanguageServerCallbacks(created, providerID: descriptor.id)
            try created.start(rootURL: normalizedRoot)
            languageServers[descriptor.id] = created
            languageServerRoots[descriptor.id] = normalizedRoot
            session = created
        }
        try session.synchronize(
            fileURL: fileURL,
            text: text,
            languageID: descriptor.languageIdentifier(for: fileURL)
        )
    }

    func closeDocument(_ fileURL: URL) {
        diagnostics[fileURL.standardizedFileURL] = nil
    }

    func clearDiagnostics() {
        diagnostics = [:]
    }

    func stopLanguageServer(providerID: String) {
        languageServers.removeValue(forKey: providerID)?.stop()
        languageServerRoots[providerID] = nil
        languageServerFeatures[providerID] = nil
    }

    func stopAllLanguageServers() {
        for session in languageServers.values { session.stop() }
        diagnostics = [:]
        languageServerFeatures = [:]
        languageServers.removeAll()
        languageServerRoots.removeAll()
    }

    func navigate(
        method: String,
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        rootURL _: URL,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        if let session = languageServerSession(for: fileURL),
           session.isRunning {
            do {
                try session.navigate(
                    method: method,
                    fileURL: fileURL,
                    position: position,
                    completion: completion
                )
                return
            } catch {}
        }
        guard supportsBuiltinLanguageServer(for: fileURL) else {
            throw unavailableLanguageServerError(for: fileURL)
        }
        completion(.success(core.builtinLanguageNavigation(
            method: method,
            fileURL: fileURL,
            text: text,
            position: position
        ) ?? []))
    }

    func hover(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        rootURL _: URL,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws {
        if let session = languageServerSession(for: fileURL),
           session.isRunning {
            do {
                try session.hover(fileURL: fileURL, position: position, completion: completion)
                return
            } catch {}
        }
        guard supportsBuiltinLanguageServer(for: fileURL) else {
            throw unavailableLanguageServerError(for: fileURL)
        }
        completion(.success(core.builtinLanguageHover(
            fileURL: fileURL,
            text: text,
            position: position
        )))
    }

    func completions(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        rootURL _: URL,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        if let session = languageServerSession(for: fileURL),
           session.isRunning {
            do {
                try session.completions(fileURL: fileURL, position: position, completion: completion)
                return
            } catch {}
        }
        guard supportsBuiltinLanguageServer(for: fileURL) else {
            throw unavailableLanguageServerError(for: fileURL)
        }
        completion(.success(core.builtinLanguageCompletions(
            fileURL: fileURL,
            text: text,
            position: position
        ) ?? []))
    }

    func rename(
        fileURL: URL,
        text _: String,
        position: LanguageServerPosition,
        newName: String,
        rootURL _: URL,
        completion: @escaping (Result<LanguageServerWorkspaceEdit, Error>) -> Void
    ) throws {
        if let session = languageServerSession(for: fileURL),
           session.isRunning {
            do {
                try session.rename(
                    fileURL: fileURL,
                    position: position,
                    newName: newName,
                    completion: completion
                )
                return
            } catch {}
        }
        throw unavailableLanguageServerError(for: fileURL)
    }

    func format(
        fileURL: URL,
        text _: String,
        rootURL _: URL,
        options _: [String: Any] = [
            "tabSize": 4,
            "insertSpaces": true,
            "trimTrailingWhitespace": true,
            "insertFinalNewline": true,
            "trimFinalNewlines": true
        ],
        completion: @escaping (Result<[LanguageServerTextEdit], Error>) -> Void
    ) throws {
        if let session = languageServerSession(for: fileURL),
           session.isRunning {
            do {
                try session.format(fileURL: fileURL, completion: completion)
                return
            } catch {}
        }
        throw unavailableLanguageServerError(for: fileURL)
    }

    func codeActions(
        fileURL: URL,
        text _: String,
        range: LanguageServerRange,
        diagnostics: [LanguageServerDiagnostic],
        rootURL _: URL,
        completion: @escaping (Result<[LanguageServerCodeAction], Error>) -> Void
    ) throws {
        if let session = languageServerSession(for: fileURL),
           session.isRunning {
            do {
                try session.codeActions(
                    fileURL: fileURL,
                    range: range,
                    diagnostics: diagnostics,
                    completion: completion
                )
                return
            } catch {}
        }
        throw unavailableLanguageServerError(for: fileURL)
    }

    func execute(
        _ command: LanguageServerCommand,
        fileURL: URL,
        text _: String,
        rootURL _: URL,
        completion _: @escaping (Result<Void, Error>) -> Void
    ) throws {
        guard command.command.isEmpty == false else {
            throw LanguageToolingSessionError.capabilityUnavailable(
                provider: catalog.provider(for: fileURL)?.displayName ?? fileURL.pathExtension,
                capability: "execute command"
            )
        }
        throw unavailableLanguageServerError(for: fileURL)
    }

    func resolveCompletion(
        _ item: LanguageServerCompletionItem,
        fileURL: URL,
        text _: String,
        rootURL _: URL,
        completion: @escaping (Result<LanguageServerCompletionItem, Error>) -> Void
    ) throws {
        guard item.label.isEmpty == false else {
            throw LanguageToolingSessionError.capabilityUnavailable(
                provider: catalog.provider(for: fileURL)?.displayName ?? fileURL.pathExtension,
                capability: "completion item resolve"
            )
        }
        if let session = languageServerSession(for: fileURL),
           session.isRunning {
            do {
                try session.resolveCompletion(item, fileURL: fileURL, completion: completion)
                return
            } catch {}
        }
        throw unavailableLanguageServerError(for: fileURL)
    }

    func resolveCodeAction(
        _ action: LanguageServerCodeAction,
        fileURL: URL,
        text _: String,
        rootURL _: URL,
        completion: @escaping (Result<LanguageServerCodeAction, Error>) -> Void
    ) throws {
        guard action.title.isEmpty == false else {
            throw LanguageToolingSessionError.capabilityUnavailable(
                provider: catalog.provider(for: fileURL)?.displayName ?? fileURL.pathExtension,
                capability: "code action resolve"
            )
        }
        if let session = languageServerSession(for: fileURL),
           session.isRunning {
            do {
                try session.resolveCodeAction(action, fileURL: fileURL, completion: completion)
                return
            } catch {}
        }
        throw unavailableLanguageServerError(for: fileURL)
    }

    @discardableResult
    func activateDebugAdapter(for fileURL: URL, rootURL: URL) throws -> any DebugAdapterSession {
        guard let descriptor = catalog.provider(for: fileURL) else {
            throw LanguageToolingSessionError.noProvider(fileExtension: fileURL.pathExtension.lowercased())
        }
        guard descriptor.capabilities.contains(.debugAdapter) else {
            throw LanguageToolingSessionError.capabilityUnavailable(
                provider: descriptor.displayName,
                capability: "debug adapter"
            )
        }
        let normalizedRoot = rootURL.standardizedFileURL
        if let active = debugAdapters[descriptor.id] {
            if active.isRunning, debugAdapterRoots[descriptor.id] == normalizedRoot {
                return active
            }
            active.stop()
            debugAdapters[descriptor.id] = nil
            debugAdapterRoots[descriptor.id] = nil
        }
        guard let runtime = runtimesByID[descriptor.id] else {
            throw LanguageToolingSessionError.providerNotInstalled(descriptor.displayName)
        }
        guard let session = runtime.makeDebugAdapterSession(rootURL: normalizedRoot) else {
            throw LanguageToolingSessionError.toolingUnavailable(
                runtime.unavailableToolingMessage ?? descriptor.displayName
            )
        }
        configureDebugCallbacks(session, providerID: descriptor.id)
        try session.start(rootURL: normalizedRoot)
        debugAdapters[descriptor.id] = session
        debugAdapterRoots[descriptor.id] = normalizedRoot
        debugStates[descriptor.id] = session.state
        if let controlling = session as? any DebugAdapterControllingSession {
            for (source, breakpoints) in requestedBreakpoints[descriptor.id] ?? [:] {
                controlling.setBreakpoints(breakpoints, in: source)
            }
        }
        return session
    }

    func stopDebugAdapter(providerID: String) {
        debugAdapters.removeValue(forKey: providerID)?.stop()
        debugAdapterRoots[providerID] = nil
        debugStates[providerID] = .idle
    }

    func stopAll() {
        for session in languageServers.values { session.stop() }
        for session in debugAdapters.values { session.stop() }
        diagnostics = [:]
        languageServerFeatures = [:]
        languageServers.removeAll()
        languageServerRoots.removeAll()
        debugAdapters.removeAll()
        debugAdapterRoots.removeAll()
        debugStates = [:]
        lastDebugEvents = [:]
        verifiedBreakpoints = [:]
        requestedBreakpoints = [:]
    }

    @discardableResult
    func launchDebugAdapter(
        for fileURL: URL,
        rootURL: URL,
        configuration: DebugLaunchConfiguration
    ) throws -> any DebugAdapterControllingSession {
        let session = try activateDebugAdapter(for: fileURL, rootURL: rootURL)
        guard let controlling = session as? any DebugAdapterControllingSession else {
            let descriptor = catalog.provider(for: fileURL)
            throw LanguageToolingSessionError.capabilityUnavailable(
                provider: descriptor?.displayName ?? fileURL.pathExtension,
                capability: "DAP launch control"
            )
        }
        try controlling.launch(configuration)
        return controlling
    }

    func setDebugBreakpoints(
        _ breakpoints: [DebugSourceBreakpoint],
        in fileURL: URL
    ) throws {
        guard let descriptor = catalog.provider(for: fileURL) else {
            throw LanguageToolingSessionError.noProvider(
                fileExtension: fileURL.pathExtension.lowercased()
            )
        }
        guard descriptor.capabilities.contains(.debugAdapter) else {
            throw LanguageToolingSessionError.capabilityUnavailable(
                provider: descriptor.displayName,
                capability: "debug adapter breakpoints"
            )
        }
        var providerBreakpoints = requestedBreakpoints[descriptor.id] ?? [:]
        providerBreakpoints[fileURL.standardizedFileURL] = breakpoints
        requestedBreakpoints[descriptor.id] = providerBreakpoints
        (debugAdapters[descriptor.id] as? any DebugAdapterControllingSession)?
            .setBreakpoints(breakpoints, in: fileURL)
    }

    func debugSession(providerID: String) -> (any DebugAdapterControllingSession)? {
        debugAdapters[providerID] as? any DebugAdapterControllingSession
    }

    private func unavailableLanguageServerError(for fileURL: URL) -> LanguageToolingSessionError {
        let provider = catalog.provider(for: fileURL)?.displayName ?? fileURL.pathExtension
        return .toolingUnavailable(
            "\(provider) language server is waiting for the Rust LSP host integration."
        )
    }

    private func supportsBuiltinLanguageServer(for fileURL: URL) -> Bool {
        catalog.provider(for: fileURL)?.capabilities.contains(.languageServer) == true
            && core.isAvailable
    }

    private func languageServerSession(for fileURL: URL) -> (any LanguageServerSession)? {
        guard let descriptor = catalog.provider(for: fileURL) else { return nil }
        return languageServers[descriptor.id]
    }

    private func configureLanguageServerCallbacks(
        _ session: any LanguageServerSession,
        providerID _: String
    ) {
        session.onDiagnostics = { [weak self] fileURL, diagnostics in
            self?.diagnostics[fileURL.standardizedFileURL] = diagnostics
        }
    }

    private func configureDebugCallbacks(
        _ session: any DebugAdapterSession,
        providerID: String
    ) {
        guard let controlling = session as? any DebugAdapterControllingSession else { return }
        controlling.onStateChange = { [weak self] state in
            self?.debugStates[providerID] = state
            self?.onDebugStateChange?(providerID, state)
        }
        controlling.onEvent = { [weak self] event in
            guard let self else { return }
            self.lastDebugEvents[providerID] = event
            self.onDebugEvent?(providerID, event)
            if case .breakpoint(let breakpoint) = event {
                var values = self.verifiedBreakpoints[providerID] ?? []
                if let index = values.firstIndex(where: { $0.id == breakpoint.id }) {
                    values[index] = breakpoint
                } else {
                    values.append(breakpoint)
                }
                self.verifiedBreakpoints[providerID] = values.sorted {
                    ($0.sourceURL?.path ?? "", $0.line ?? 0) < ($1.sourceURL?.path ?? "", $1.line ?? 0)
                }
            }
        }
    }
}
