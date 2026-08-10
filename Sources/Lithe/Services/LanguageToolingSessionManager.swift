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

/// Owns only active language-tooling processes. The catalog is metadata and
/// providers are created lazily on first use, so opening a workspace does not
/// start five LSPs or Debug Adapters just because they are supported.
@MainActor
final class LanguageToolingSessionManager: ObservableObject {
    @Published private(set) var diagnostics: [URL: [LanguageServerDiagnostic]] = [:]
    @Published private(set) var languageServerFeatures: [String: LanguageServerFeatureSet] = [:]
    @Published private(set) var debugStates: [String: DebugAdapterState] = [:]
    @Published private(set) var lastDebugEvents: [String: DebugAdapterEvent] = [:]
    @Published private(set) var verifiedBreakpoints: [String: [DebugBreakpoint]] = [:]
    var onDebugStateChange: ((String, DebugAdapterState) -> Void)?
    var onDebugEvent: ((String, DebugAdapterEvent) -> Void)?
    private let catalog: LanguageProviderCatalog
    private var runtimesByID: [String: any LanguageProviderRuntime]
    private var languageServers: [String: any LanguageServerSession] = [:]
    private var languageServerRoots: [String: URL] = [:]
    private var debugAdapters: [String: any DebugAdapterSession] = [:]
    private var debugAdapterRoots: [String: URL] = [:]
    private var requestedBreakpoints: [String: [URL: [DebugSourceBreakpoint]]] = [:]

    init(
        catalog: LanguageProviderCatalog = .standard,
        runtimes: [any LanguageProviderRuntime] = []
    ) {
        self.catalog = catalog
        runtimesByID = Dictionary(uniqueKeysWithValues: runtimes.map { ($0.descriptor.id, $0) })
    }

    convenience init(registry: LanguagePackRegistry) {
        self.init(catalog: registry.catalog, runtimes: registry.toolingRuntimes)
    }

    var activeLanguageServerIDs: Set<String> { Set(languageServers.keys) }
    var activeDebugAdapterIDs: Set<String> { Set(debugAdapters.keys) }

    func provider(for fileURL: URL) -> LanguageProviderDescriptor? {
        catalog.provider(for: fileURL)
    }

    func supportsGenericEditing(for fileURL: URL) -> Bool {
        guard let descriptor = catalog.provider(for: fileURL),
              descriptor.capabilities.contains(.languageServer) else { return false }
        guard runtimesByID[descriptor.id]?.supportsEditingSession == true else { return false }
        return !features(for: fileURL).isEmpty
    }

    func supportsGenericDebugging(for fileURL: URL) -> Bool {
        guard let descriptor = catalog.provider(for: fileURL) else { return false }
        return runtimesByID[descriptor.id]?.supportsDebugAdapterSession == true
    }

    func features(for fileURL: URL) -> LanguageServerFeatureSet {
        guard let descriptor = catalog.provider(for: fileURL) else { return [] }
        return languageServerFeatures[descriptor.id]
            ?? runtimesByID[descriptor.id]?.declaredLanguageServerFeatures
            ?? []
    }

    @discardableResult
    func activateLanguageServer(for fileURL: URL, rootURL: URL) throws -> any LanguageServerSession {
        guard let descriptor = catalog.provider(for: fileURL) else {
            throw LanguageToolingSessionError.noProvider(fileExtension: fileURL.pathExtension.lowercased())
        }
        guard descriptor.capabilities.contains(.languageServer) else {
            throw LanguageToolingSessionError.capabilityUnavailable(
                provider: descriptor.displayName,
                capability: "language server"
            )
        }
        let normalizedRoot = rootURL.standardizedFileURL
        if let active = languageServers[descriptor.id] {
            if active.isRunning, languageServerRoots[descriptor.id] == normalizedRoot {
                return active
            }
            active.stop()
            languageServers[descriptor.id] = nil
            languageServerRoots[descriptor.id] = nil
        }
        guard let runtime = runtimesByID[descriptor.id] else {
            throw LanguageToolingSessionError.providerNotInstalled(descriptor.displayName)
        }
        guard let session = runtime.makeLanguageServerSession() else {
            throw LanguageToolingSessionError.toolingUnavailable(
                runtime.unavailableToolingMessage ?? descriptor.displayName
            )
        }
        languageServerFeatures[descriptor.id] = runtime.declaredLanguageServerFeatures
        if let reporting = session as? any LanguageServerFeatureReportingSession {
            reporting.onSupportedFeaturesChange = { [weak self] features in
                self?.languageServerFeatures[descriptor.id] = features
            }
        }
        do {
            try session.start(rootURL: normalizedRoot)
        } catch {
            languageServerFeatures[descriptor.id] = nil
            throw error
        }
        languageServers[descriptor.id] = session
        languageServerRoots[descriptor.id] = normalizedRoot
        return session
    }

    @discardableResult
    func activateDebugAdapter(for fileURL: URL, rootURL: URL) throws -> any DebugAdapterSession {
        guard let descriptor = catalog.provider(for: fileURL) else {
            throw LanguageToolingSessionError.noProvider(fileExtension: fileURL.pathExtension.lowercased())
        }
        guard descriptor.capabilities.contains(.debugAdapter)
                || runtimesByID[descriptor.id]?.supportsDebugAdapterSession == true else {
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

    func stopLanguageServer(providerID: String) {
        languageServers.removeValue(forKey: providerID)?.stop()
        languageServerRoots[providerID] = nil
        languageServerFeatures[providerID] = nil
    }

    func stopDebugAdapter(providerID: String) {
        debugAdapters.removeValue(forKey: providerID)?.stop()
        debugAdapterRoots[providerID] = nil
        debugStates[providerID] = .idle
    }

    func stopAll() {
        for session in languageServers.values { session.stop() }
        for session in debugAdapters.values { session.stop() }
        languageServers.removeAll()
        languageServerRoots.removeAll()
        languageServerFeatures = [:]
        debugAdapters.removeAll()
        debugAdapterRoots.removeAll()
        debugStates = [:]
        lastDebugEvents = [:]
        verifiedBreakpoints = [:]
        requestedBreakpoints = [:]
        diagnostics = [:]
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
        guard descriptor.capabilities.contains(.debugAdapter)
                || runtimesByID[descriptor.id]?.supportsDebugAdapterSession == true else {
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

    func synchronizeLanguageServer(
        for fileURL: URL,
        text: String,
        rootURL: URL
    ) throws {
        guard let descriptor = catalog.provider(for: fileURL) else {
            throw LanguageToolingSessionError.noProvider(
                fileExtension: fileURL.pathExtension.lowercased()
            )
        }
        let session = try activateLanguageServer(for: fileURL, rootURL: rootURL)
        guard let documentSession = session as? any LanguageServerDocumentSession else { return }
        documentSession.onDiagnostics = { [weak self] url, diagnostics in
            self?.diagnostics[url.standardizedFileURL] = diagnostics
        }
        documentSession.synchronizeDocument(
            url: fileURL,
            languageIdentifier: descriptor.languageIdentifier(for: fileURL),
            text: text
        )
    }

    func closeDocument(_ fileURL: URL) {
        guard let descriptor = catalog.provider(for: fileURL),
              let session = languageServers[descriptor.id] as? any LanguageServerDocumentSession
        else { return }
        session.closeDocument(url: fileURL)
        diagnostics[fileURL.standardizedFileURL] = nil
    }

    func navigate(
        method: String,
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        rootURL: URL,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        guard let descriptor = catalog.provider(for: fileURL) else {
            throw LanguageToolingSessionError.noProvider(
                fileExtension: fileURL.pathExtension.lowercased()
            )
        }
        let feature: LanguageServerFeatureSet
        let capability: String
        switch method {
        case "textDocument/definition":
            feature = .definition
            capability = "go to definition"
        case "textDocument/references":
            feature = .references
            capability = "find references"
        case "textDocument/implementation":
            feature = .implementation
            capability = "go to implementation"
        default:
            throw LanguageToolingSessionError.capabilityUnavailable(
                provider: descriptor.displayName,
                capability: method
            )
        }
        let session = try activateLanguageServer(for: fileURL, rootURL: rootURL)
        try requireFeature(feature, descriptor: descriptor, capability: capability)
        guard let navigation = session as? any LanguageServerNavigationSession else {
            throw LanguageToolingSessionError.capabilityUnavailable(
                provider: descriptor.displayName,
                capability: "definition and reference navigation"
            )
        }
        navigation.onDiagnostics = { [weak self] url, diagnostics in
            self?.diagnostics[url.standardizedFileURL] = diagnostics
        }
        navigation.synchronizeDocument(
            url: fileURL,
            languageIdentifier: descriptor.languageIdentifier(for: fileURL),
            text: text
        )
        navigation.locations(
            method: method,
            documentURL: fileURL,
            position: position,
            completion: completion
        )
    }

    func hover(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        rootURL: URL,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws {
        let session = try codeIntelligenceSession(
            fileURL: fileURL,
            text: text,
            rootURL: rootURL,
            requiredFeature: .hover,
            capability: "hover"
        )
        session.hover(documentURL: fileURL, position: position, completion: completion)
    }

    func completions(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        rootURL: URL,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        let session = try codeIntelligenceSession(
            fileURL: fileURL,
            text: text,
            rootURL: rootURL,
            requiredFeature: .completion,
            capability: "completion"
        )
        session.completions(documentURL: fileURL, position: position, completion: completion)
    }

    func rename(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        newName: String,
        rootURL: URL,
        completion: @escaping (Result<LanguageServerWorkspaceEdit, Error>) -> Void
    ) throws {
        let session = try editingSession(
            fileURL: fileURL,
            text: text,
            rootURL: rootURL,
            requiredFeature: .rename,
            capability: "rename"
        )
        session.rename(
            documentURL: fileURL,
            position: position,
            newName: newName,
            completion: completion
        )
    }

    func format(
        fileURL: URL,
        text: String,
        rootURL: URL,
        options: [String: Any] = [
            "tabSize": 4,
            "insertSpaces": true,
            "trimTrailingWhitespace": true,
            "insertFinalNewline": true,
            "trimFinalNewlines": true
        ],
        completion: @escaping (Result<[LanguageServerTextEdit], Error>) -> Void
    ) throws {
        let session = try editingSession(
            fileURL: fileURL,
            text: text,
            rootURL: rootURL,
            requiredFeature: .formatting,
            capability: "document formatting"
        )
        session.formatting(documentURL: fileURL, options: options, completion: completion)
    }

    func codeActions(
        fileURL: URL,
        text: String,
        range: LanguageServerRange,
        diagnostics: [LanguageServerDiagnostic],
        rootURL: URL,
        completion: @escaping (Result<[LanguageServerCodeAction], Error>) -> Void
    ) throws {
        let session = try editingSession(
            fileURL: fileURL,
            text: text,
            rootURL: rootURL,
            requiredFeature: .codeActions,
            capability: "code actions"
        )
        session.codeActions(
            documentURL: fileURL,
            range: range,
            diagnostics: diagnostics,
            completion: completion
        )
    }

    func execute(
        _ command: LanguageServerCommand,
        fileURL: URL,
        text: String,
        rootURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) throws {
        let session = try editingSession(
            fileURL: fileURL,
            text: text,
            rootURL: rootURL,
            requiredFeature: .executeCommand,
            capability: "execute command"
        )
        session.execute(command: command, completion: completion)
    }

    func resolveCompletion(
        _ item: LanguageServerCompletionItem,
        fileURL: URL,
        text: String,
        rootURL: URL,
        completion: @escaping (Result<LanguageServerCompletionItem, Error>) -> Void
    ) throws {
        let session = try editingSession(
            fileURL: fileURL,
            text: text,
            rootURL: rootURL,
            requiredFeature: .completionResolve,
            capability: "completion item resolve"
        )
        session.resolveCompletion(item, completion: completion)
    }

    func resolveCodeAction(
        _ action: LanguageServerCodeAction,
        fileURL: URL,
        text: String,
        rootURL: URL,
        completion: @escaping (Result<LanguageServerCodeAction, Error>) -> Void
    ) throws {
        let session = try editingSession(
            fileURL: fileURL,
            text: text,
            rootURL: rootURL,
            requiredFeature: .codeActionResolve,
            capability: "code action resolve"
        )
        session.resolveCodeAction(action, completion: completion)
    }

    private func codeIntelligenceSession(
        fileURL: URL,
        text: String,
        rootURL: URL,
        requiredFeature: LanguageServerFeatureSet,
        capability: String
    ) throws -> any LanguageServerCodeIntelligenceSession {
        guard let descriptor = catalog.provider(for: fileURL) else {
            throw LanguageToolingSessionError.noProvider(
                fileExtension: fileURL.pathExtension.lowercased()
            )
        }
        let session = try activateLanguageServer(for: fileURL, rootURL: rootURL)
        try requireFeature(requiredFeature, descriptor: descriptor, capability: capability)
        guard let intelligence = session as? any LanguageServerCodeIntelligenceSession else {
            throw LanguageToolingSessionError.capabilityUnavailable(
                provider: descriptor.displayName,
                capability: "hover and completion"
            )
        }
        intelligence.onDiagnostics = { [weak self] url, diagnostics in
            self?.diagnostics[url.standardizedFileURL] = diagnostics
        }
        intelligence.synchronizeDocument(
            url: fileURL,
            languageIdentifier: descriptor.languageIdentifier(for: fileURL),
            text: text
        )
        return intelligence
    }

    private func editingSession(
        fileURL: URL,
        text: String,
        rootURL: URL,
        requiredFeature: LanguageServerFeatureSet,
        capability: String
    ) throws -> any LanguageServerEditingSession {
        guard let descriptor = catalog.provider(for: fileURL) else {
            throw LanguageToolingSessionError.noProvider(
                fileExtension: fileURL.pathExtension.lowercased()
            )
        }
        let session = try activateLanguageServer(for: fileURL, rootURL: rootURL)
        try requireFeature(requiredFeature, descriptor: descriptor, capability: capability)
        guard let editing = session as? any LanguageServerEditingSession else {
            throw LanguageToolingSessionError.capabilityUnavailable(
                provider: descriptor.displayName,
                capability: "rename, formatting and code actions"
            )
        }
        editing.onDiagnostics = { [weak self] url, diagnostics in
            self?.diagnostics[url.standardizedFileURL] = diagnostics
        }
        editing.synchronizeDocument(
            url: fileURL,
            languageIdentifier: descriptor.languageIdentifier(for: fileURL),
            text: text
        )
        return editing
    }

    private func requireFeature(
        _ feature: LanguageServerFeatureSet,
        descriptor: LanguageProviderDescriptor,
        capability: String
    ) throws {
        guard (languageServerFeatures[descriptor.id]
            ?? runtimesByID[descriptor.id]?.declaredLanguageServerFeatures
            ?? []).contains(feature) else {
            throw LanguageToolingSessionError.capabilityUnavailable(
                provider: descriptor.displayName,
                capability: capability
            )
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
