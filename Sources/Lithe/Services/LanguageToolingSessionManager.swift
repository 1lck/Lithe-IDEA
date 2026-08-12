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

/// UI-facing façade that routes language features across active LSP sessions
/// and lightweight local providers without exposing either implementation.
@MainActor
final class LanguageToolingSessionManager: ObservableObject {
    @Published private(set) var diagnostics: [URL: [LanguageServerDiagnostic]] = [:]
    @Published private(set) var languageServerFeatures: [String: LanguageServerFeatureSet] = [:]
    @Published private(set) var languageServerLogs: [LanguageServerLogEntry] = []
    @Published private(set) var languageServerStates: [String: LanguageServerSessionState] = [:]
    @Published private(set) var languageServerInfos: [String: LanguageServerInfo] = [:]
    @Published private(set) var debugStates: [String: DebugAdapterState] = [:]
    @Published private(set) var lastDebugEvents: [String: DebugAdapterEvent] = [:]
    @Published private(set) var verifiedBreakpoints: [String: [DebugBreakpoint]] = [:]

    var onDebugStateChange: ((String, DebugAdapterState) -> Void)?
    var onDebugEvent: ((String, DebugAdapterEvent) -> Void)?

    private var catalog: LanguageProviderCatalog
    private var runtimesByID: [String: any LanguageProviderRuntime]
    private let runtimeFactory: (any LanguageProviderRuntimeFactory)?
    private var languageServers: [String: any LanguageServerSession] = [:]
    private var languageServerRoots: [String: URL] = [:]
    private var languageServerSessionIdentities: [String: ObjectIdentifier] = [:]
    private var diagnosticsByProviderID: [String: [URL: [LanguageServerDiagnostic]]] = [:]
    private var languageFeatureProviders: [any LanguageFeatureProvider]
    private var languageServerFeatureProviders: [String: LanguageServerFeatureProvider] = [:]
    private var debugAdapters: [String: any DebugAdapterSession] = [:]
    private var debugAdapterRoots: [String: URL] = [:]
    private var requestedBreakpoints: [String: [URL: [DebugSourceBreakpoint]]] = [:]

    init(
        catalog: LanguageProviderCatalog = .standard,
        runtimes: [any LanguageProviderRuntime] = [],
        runtimeFactory: (any LanguageProviderRuntimeFactory)? = nil,
        core: RustCoreBridge = RustCoreBridge(),
        languageFeatureProviders: [any LanguageFeatureProvider] = []
    ) {
        self.catalog = catalog
        self.runtimeFactory = runtimeFactory
        self.languageFeatureProviders = languageFeatureProviders + [
            BuiltinLanguageFeatureProvider(core: core)
        ]
        runtimesByID = Dictionary(uniqueKeysWithValues: runtimes.map { ($0.descriptor.id, $0) })
    }

    convenience init(registry: LanguagePackRegistry) {
        self.init(catalog: registry.catalog, runtimes: registry.toolingRuntimes)
    }

    var activeLanguageServerIDs: Set<String> {
        Set(languageServers.compactMap { providerID, session in
            guard session.isRunning,
                  languageServerStates[providerID] == .ready else { return nil }
            return providerID
        })
    }
    var activeDebugAdapterIDs: Set<String> { Set(debugAdapters.keys) }

    func updateCatalog(_ catalog: LanguageProviderCatalog) {
        let previousDescriptors = Dictionary(
            uniqueKeysWithValues: self.catalog.descriptors.map { ($0.id, $0) }
        )
        let updatedDescriptors = Dictionary(
            uniqueKeysWithValues: catalog.descriptors.map { ($0.id, $0) }
        )
        let changedProviderIDs = Set(previousDescriptors.keys)
            .union(updatedDescriptors.keys)
            .filter { previousDescriptors[$0] != updatedDescriptors[$0] }

        self.catalog = catalog
        let validProviderIDs = Set(catalog.descriptors.map(\.id))
        languageServerFeatures = languageServerFeatures.filter { validProviderIDs.contains($0.key) }
        languageServerStates = languageServerStates.filter { validProviderIDs.contains($0.key) }
        languageServerInfos = languageServerInfos.filter { validProviderIDs.contains($0.key) }
        diagnosticsByProviderID = diagnosticsByProviderID.filter {
            validProviderIDs.contains($0.key)
        }
        rebuildDiagnostics()
        languageServerLogs = languageServerLogs.filter { validProviderIDs.contains($0.providerID) }
        for providerID in changedProviderIDs {
            stopLanguageServer(providerID: providerID)
            stopDebugAdapter(providerID: providerID)
            if updatedDescriptors[providerID] == nil {
                languageServerStates[providerID] = nil
            }
            if runtimeFactory != nil {
                runtimesByID[providerID] = nil
            }
        }
    }

    func provider(for fileURL: URL) -> LanguageProviderDescriptor? {
        catalog.provider(for: fileURL)
    }

    func supportsGenericEditing(for fileURL: URL) -> Bool {
        return !features(for: fileURL).isEmpty
    }

    func supportsGenericDebugging(for fileURL: URL) -> Bool {
        guard let descriptor = catalog.provider(for: fileURL),
              descriptor.capabilities.contains(.debugAdapter) else { return false }
        return runtime(for: descriptor)?.supportsDebugAdapterSession == true
    }

    func features(for fileURL: URL) -> LanguageServerFeatureSet {
        let context = featureContext(
            fileURL: fileURL,
            text: "",
            position: LanguageServerPosition(line: 0, utf16Column: 0),
            rootURL: nil
        )
        var result = catalog.provider(for: fileURL).flatMap {
            languageServerFeatures[$0.id]
        } ?? []
        for provider in languageFeatureProviders {
            if provider.supports(.completion, in: context) { result.insert(.completion) }
            if provider.supports(.hover, in: context) { result.insert(.hover) }
            if provider.supports(.navigation(method: "textDocument/definition"), in: context) {
                result.insert(.definition)
            }
            if provider.supports(.navigation(method: "textDocument/references"), in: context) {
                result.insert(.references)
            }
            if provider.supports(.navigation(method: "textDocument/implementation"), in: context) {
                result.insert(.implementation)
            }
        }
        return result
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
        guard let runtime = runtime(for: descriptor),
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
            // Retire every projection of the previous root before resolving a
            // replacement. If executable resolution or construction fails,
            // the UI must not retain a stale ready session from the old root.
            stopLanguageServer(providerID: descriptor.id)
            recordLanguageServerLog(
                providerID: descriptor.id,
                level: .info,
                message: "Resolving language server",
                detail: descriptor.languageServerLaunch?.executableNames.joined(separator: ", ")
            )
            guard let created = runtime.makeLanguageServerSession() else {
                let message = runtime.unavailableToolingMessage ?? descriptor.displayName
                languageServerStates[descriptor.id] = .failed(
                    exitCode: nil,
                    message: message
                )
                recordLanguageServerLog(
                    providerID: descriptor.id,
                    level: .error,
                    message: "Language server executable was not found",
                    detail: message
                )
                throw LanguageToolingSessionError.toolingUnavailable(message)
            }
            let featureProvider = LanguageServerFeatureProvider(
                providerID: descriptor.id,
                session: created,
                features: created.features
            )
            let sessionIdentity = ObjectIdentifier(created)
            languageServerSessionIdentities[descriptor.id] = sessionIdentity
            languageServerStates[descriptor.id] = .startingProcess
            languageServerFeatures[descriptor.id] = nil
            languageServerInfos[descriptor.id] = nil
            languageServerFeatureProviders[descriptor.id] = featureProvider
            configureLanguageServerCallbacks(
                created,
                providerID: descriptor.id,
                sessionIdentity: sessionIdentity
            )
            do {
                try created.start(rootURL: normalizedRoot)
            } catch {
                clearDiagnostics(providerID: descriptor.id)
                languageServerSessionIdentities[descriptor.id] = nil
                languageServerStates[descriptor.id] = .failed(
                    exitCode: nil,
                    message: error.localizedDescription
                )
                languageServerFeatures[descriptor.id] = nil
                languageServerInfos[descriptor.id] = nil
                languageServerFeatureProviders[descriptor.id] = nil
                recordLanguageServerLog(
                    providerID: descriptor.id,
                    level: .error,
                    message: "Language server failed to start",
                    detail: error.localizedDescription
                )
                throw error
            }
            languageServers[descriptor.id] = created
            languageServerRoots[descriptor.id] = normalizedRoot
            recordLanguageServerLog(
                providerID: descriptor.id,
                level: .info,
                message: "Language server session registered",
                detail: normalizedRoot.path
            )
            session = created
        }
        try session.synchronize(
            fileURL: fileURL,
            text: text,
            languageID: descriptor.languageIdentifier(for: fileURL)
        )
    }

    func closeDocument(_ fileURL: URL) {
        let standardizedURL = fileURL.standardizedFileURL
        clearDiagnostics(for: standardizedURL)
        languageServerSession(for: standardizedURL)?.closeDocument(standardizedURL)
    }

    func clearDiagnostics() {
        diagnosticsByProviderID = [:]
        diagnostics = [:]
    }

    func diagnostics(for providerID: String) -> [URL: [LanguageServerDiagnostic]] {
        diagnosticsByProviderID[providerID] ?? [:]
    }

    func clearDiagnostics(providerID: String) {
        guard diagnosticsByProviderID.removeValue(forKey: providerID) != nil else { return }
        rebuildDiagnostics()
    }

    func clearLanguageServerLogs() {
        languageServerLogs = []
    }

    func recordLanguageServerLog(
        providerID: String,
        level: LanguageServerLogLevel,
        message: String,
        detail: String? = nil
    ) {
        languageServerLogs.insert(LanguageServerLogEntry(
            providerID: providerID,
            level: level,
            message: message,
            detail: detail
        ), at: 0)
        if languageServerLogs.count > 100 {
            languageServerLogs.removeLast(languageServerLogs.count - 100)
        }
    }

    func stopLanguageServer(providerID: String) {
        if languageServers[providerID] != nil {
            recordLanguageServerLog(
                providerID: providerID,
                level: .info,
                message: "Stopping language server",
                detail: nil
            )
        }
        clearDiagnostics(providerID: providerID)
        languageServerSessionIdentities[providerID] = nil
        languageServers.removeValue(forKey: providerID)?.stop()
        languageServerRoots[providerID] = nil
        languageServerFeatures[providerID] = nil
        languageServerInfos[providerID] = nil
        languageServerFeatureProviders[providerID] = nil
        languageServerStates[providerID] = .stopped
    }

    func stopAllLanguageServers() {
        for providerID in languageServers.keys {
            recordLanguageServerLog(
                providerID: providerID,
                level: .info,
                message: "Stopping language server",
                detail: "Stop all"
            )
        }
        let sessions = Array(languageServers.values)
        clearDiagnostics()
        languageServerFeatures = [:]
        languageServerInfos = [:]
        languageServers.removeAll()
        languageServerRoots.removeAll()
        languageServerSessionIdentities.removeAll()
        languageServerFeatureProviders.removeAll()
        languageServerStates = [:]
        for session in sessions { session.stop() }
    }

    func navigate(
        method: String,
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        rootURL: URL,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        let context = featureContext(
            fileURL: fileURL,
            text: text,
            position: position,
            rootURL: rootURL
        )
        let providers = featureProviders(
            for: .navigation(method: method),
            context: context
        )
        guard !providers.isEmpty else {
            throw unavailableLanguageServerError(for: fileURL)
        }
        routeNavigation(
            providers: providers,
            index: 0,
            method: method,
            context: context,
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
        let context = featureContext(
            fileURL: fileURL,
            text: text,
            position: position,
            rootURL: rootURL
        )
        let providers = featureProviders(for: .hover, context: context)
        guard !providers.isEmpty else {
            throw unavailableLanguageServerError(for: fileURL)
        }
        routeHover(
            providers: providers,
            index: 0,
            context: context,
            completion: completion
        )
    }

    func completions(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        rootURL: URL,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        let context = featureContext(
            fileURL: fileURL,
            text: text,
            position: position,
            rootURL: rootURL
        )
        let providers = featureProviders(for: .completion, context: context)
        guard !providers.isEmpty else {
            throw unavailableLanguageServerError(for: fileURL)
        }
        routeCompletions(
            providers: providers,
            index: 0,
            context: context,
            items: [],
            seenLabels: [],
            completion: completion
        )
    }

    func rename(
        fileURL: URL,
        text _: String,
        position: LanguageServerPosition,
        newName: String,
        rootURL _: URL,
        completion: @escaping (Result<LanguageServerWorkspaceEdit, Error>) -> Void
    ) throws {
        if let session = readyLanguageServerSession(for: fileURL) {
            try session.rename(
                fileURL: fileURL,
                position: position,
                newName: newName,
                completion: completion
            )
            return
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
        if let session = readyLanguageServerSession(for: fileURL) {
            try session.format(fileURL: fileURL, completion: completion)
            return
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
        if let session = readyLanguageServerSession(for: fileURL) {
            try session.codeActions(
                fileURL: fileURL,
                range: range,
                diagnostics: diagnostics,
                completion: completion
            )
            return
        }
        throw unavailableLanguageServerError(for: fileURL)
    }

    func execute(
        _ command: LanguageServerCommand,
        fileURL: URL,
        text _: String,
        rootURL _: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) throws {
        guard command.command.isEmpty == false else {
            throw LanguageToolingSessionError.capabilityUnavailable(
                provider: catalog.provider(for: fileURL)?.displayName ?? fileURL.pathExtension,
                capability: "execute command"
            )
        }
        if let session = readyLanguageServerSession(for: fileURL) {
            try session.execute(command, fileURL: fileURL, completion: completion)
            return
        }
        throw unavailableLanguageServerError(for: fileURL)
    }

    func resolveVirtualDocument(
        providerID: String,
        uri: URL,
        completion: @escaping (Result<String, Error>) -> Void
    ) throws {
        guard !uri.isFileURL,
              let descriptor = catalog.descriptors.first(where: { $0.id == providerID }) else {
            throw LanguageToolingSessionError.capabilityUnavailable(
                provider: providerID,
                capability: "virtual document"
            )
        }
        guard languageServerStates[providerID] == .ready,
              let session = languageServers[providerID],
              session.isRunning else {
            throw LanguageToolingSessionError.toolingUnavailable(descriptor.displayName)
        }
        try session.resolveVirtualDocument(uri: uri.absoluteString, completion: completion)
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
        if let session = readyLanguageServerSession(for: fileURL) {
            try session.resolveCompletion(item, fileURL: fileURL, completion: completion)
            return
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
        if let session = readyLanguageServerSession(for: fileURL) {
            try session.resolveCodeAction(action, fileURL: fileURL, completion: completion)
            return
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
        guard let runtime = runtime(for: descriptor) else {
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

    private func runtime(
        for descriptor: LanguageProviderDescriptor
    ) -> (any LanguageProviderRuntime)? {
        if let existing = runtimesByID[descriptor.id],
           existing.descriptor == descriptor {
            return existing
        }
        guard let runtimeFactory,
              let runtime = runtimeFactory.makeRuntime(for: descriptor) else {
            return runtimesByID[descriptor.id]
        }
        runtimesByID[descriptor.id] = runtime
        return runtime
    }

    func stopDebugAdapter(providerID: String) {
        debugAdapters.removeValue(forKey: providerID)?.stop()
        debugAdapterRoots[providerID] = nil
        debugStates[providerID] = .idle
    }

    func stopAll() {
        let languageServerSessions = Array(languageServers.values)
        for session in debugAdapters.values { session.stop() }
        clearDiagnostics()
        languageServerFeatures = [:]
        languageServerInfos = [:]
        languageServers.removeAll()
        languageServerRoots.removeAll()
        languageServerSessionIdentities.removeAll()
        languageServerFeatureProviders.removeAll()
        languageServerStates = [:]
        for session in languageServerSessions { session.stop() }
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
        guard let descriptor = catalog.provider(for: fileURL) else {
            return .noProvider(fileExtension: fileURL.pathExtension.lowercased())
        }
        let provider = descriptor.displayName
        if let state = languageServerStates[descriptor.id] {
            switch state {
            case .startingProcess:
                return .toolingUnavailable("\(provider) language server process is starting.")
            case .initializing:
                return .toolingUnavailable("\(provider) language server is initializing.")
            case .failed(_, let message):
                return .toolingUnavailable(message ?? "\(provider) language server failed.")
            case .stopping:
                return .toolingUnavailable("\(provider) language server is stopping.")
            case .stopped:
                break
            case .ready:
                return .capabilityUnavailable(provider: provider, capability: "this language feature")
            }
        }
        return .toolingUnavailable(
            "\(provider) language server is not ready."
        )
    }

    private func languageServerSession(for fileURL: URL) -> (any LanguageServerSession)? {
        guard let descriptor = catalog.provider(for: fileURL) else { return nil }
        return languageServers[descriptor.id]
    }

    private func readyLanguageServerSession(for fileURL: URL) -> (any LanguageServerSession)? {
        guard let descriptor = catalog.provider(for: fileURL),
              languageServerStates[descriptor.id] == .ready,
              let session = languageServers[descriptor.id],
              session.isRunning else { return nil }
        return session
    }

    private func featureContext(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        rootURL: URL?
    ) -> LanguageFeatureRequestContext {
        let descriptor = catalog.provider(for: fileURL)
        return LanguageFeatureRequestContext(
            fileURL: fileURL,
            text: text,
            position: position,
            languageID: descriptor?.languageIdentifier(for: fileURL),
            workspaceURL: rootURL
        )
    }

    private func featureProviders(
        for feature: LanguageFeature,
        context: LanguageFeatureRequestContext
    ) -> [any LanguageFeatureProvider] {
        var providers = languageFeatureProviders
        if let descriptor = catalog.provider(for: context.fileURL),
           let languageServerProvider = languageServerFeatureProviders[descriptor.id] {
            providers.append(languageServerProvider)
        }
        return providers
            .filter { $0.supports(feature, in: context) }
            .sorted { $0.priority > $1.priority }
    }

    private func routeCompletions(
        providers: [any LanguageFeatureProvider],
        index: Int,
        context: LanguageFeatureRequestContext,
        items: [LanguageServerCompletionItem],
        seenLabels: Set<String>,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) {
        guard index < providers.count else {
            completion(.success(items))
            return
        }
        do {
            try providers[index].completions(in: context) { [self] result in
                switch result {
                case .success(let providerItems):
                    var merged = items
                    var labels = seenLabels
                    for item in providerItems where labels.insert(item.label).inserted {
                        merged.append(item)
                    }
                    routeCompletions(
                        providers: providers,
                        index: index + 1,
                        context: context,
                        items: merged,
                        seenLabels: labels,
                        completion: completion
                    )
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    private func routeHover(
        providers: [any LanguageFeatureProvider],
        index: Int,
        context: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) {
        guard index < providers.count else {
            completion(.success(nil))
            return
        }
        do {
            try providers[index].hover(in: context) { [self] result in
                switch result {
                case .success(let hover?):
                    completion(.success(hover))
                case .success(nil):
                    routeHover(
                        providers: providers,
                        index: index + 1,
                        context: context,
                        completion: completion
                    )
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    private func routeNavigation(
        providers: [any LanguageFeatureProvider],
        index: Int,
        method: String,
        context: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) {
        guard index < providers.count else {
            completion(.success([]))
            return
        }
        do {
            try providers[index].navigate(method: method, in: context) { [self] result in
                switch result {
                case .success(let locations):
                    if locations.isEmpty {
                        routeNavigation(
                            providers: providers,
                            index: index + 1,
                            method: method,
                            context: context,
                            completion: completion
                        )
                    } else {
                        completion(.success(locations))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    private func configureLanguageServerCallbacks(
        _ session: any LanguageServerSession,
        providerID: String,
        sessionIdentity: ObjectIdentifier
    ) {
        session.onDiagnostics = { [weak self] fileURL, diagnostics in
            guard let self else { return }
            guard self.languageServerSessionIdentities[providerID] == sessionIdentity else { return }
            self.replaceDiagnostics(
                diagnostics,
                for: fileURL.standardizedFileURL,
                providerID: providerID
            )
        }
        session.onFeaturesChange = { [weak self] features in
            guard let self else { return }
            guard self.languageServerSessionIdentities[providerID] == sessionIdentity else { return }
            self.languageServerFeatureProviders[providerID]?.updateFeatures(features)
            if self.languageServerStates[providerID] == .ready {
                self.languageServerFeatures[providerID] = features
            } else {
                self.languageServerFeatures[providerID] = nil
            }
            self.recordLanguageServerLog(
                providerID: providerID,
                level: .info,
                message: features.isEmpty ? "Language server features cleared" : "Language server features updated",
                detail: features.isEmpty ? nil : "\(features.rawValue)"
            )
        }
        session.onServerInfoChange = { [weak self] info in
            guard let self else { return }
            guard self.languageServerSessionIdentities[providerID] == sessionIdentity else { return }
            if self.languageServerStates[providerID] == .ready {
                self.languageServerInfos[providerID] = info
            }
        }
        session.onLog = { [weak self] level, message, detail in
            self?.recordLanguageServerLog(
                providerID: providerID,
                level: level,
                message: message,
                detail: detail
            )
        }
        session.onStateChange = { [weak self] state in
            self?.handleLanguageServerState(
                state,
                providerID: providerID,
                sessionIdentity: sessionIdentity,
                session: session
            )
        }
    }

    private func handleLanguageServerState(
        _ state: LanguageServerSessionState,
        providerID: String,
        sessionIdentity: ObjectIdentifier,
        session: any LanguageServerSession
    ) {
        guard languageServerSessionIdentities[providerID] == sessionIdentity else { return }
        languageServerStates[providerID] = state
        switch state {
        case .stopped, .failed:
            clearDiagnostics(providerID: providerID)
            languageServerSessionIdentities[providerID] = nil
            languageServers[providerID] = nil
            languageServerRoots[providerID] = nil
            languageServerFeatures[providerID] = nil
            languageServerInfos[providerID] = nil
            languageServerFeatureProviders[providerID] = nil
        case .startingProcess, .initializing, .stopping:
            languageServerFeatures[providerID] = nil
            languageServerInfos[providerID] = nil
        case .ready:
            languageServerFeatures[providerID] = session.features
            languageServerInfos[providerID] = session.serverInfo
        }
    }

    private func replaceDiagnostics(
        _ updatedDiagnostics: [LanguageServerDiagnostic],
        for fileURL: URL,
        providerID: String
    ) {
        let standardizedURL = fileURL.standardizedFileURL
        var providerDiagnostics = diagnosticsByProviderID[providerID] ?? [:]
        if updatedDiagnostics.isEmpty {
            providerDiagnostics[standardizedURL] = nil
        } else {
            providerDiagnostics[standardizedURL] = updatedDiagnostics
        }
        diagnosticsByProviderID[providerID] = providerDiagnostics.isEmpty
            ? nil
            : providerDiagnostics
        rebuildDiagnostics()
    }

    private func clearDiagnostics(for fileURL: URL) {
        let standardizedURL = fileURL.standardizedFileURL
        var didChange = false
        for providerID in diagnosticsByProviderID.keys.sorted() {
            guard var providerDiagnostics = diagnosticsByProviderID[providerID],
                  providerDiagnostics.removeValue(forKey: standardizedURL) != nil else { continue }
            diagnosticsByProviderID[providerID] = providerDiagnostics.isEmpty
                ? nil
                : providerDiagnostics
            didChange = true
        }
        if didChange { rebuildDiagnostics() }
    }

    private func rebuildDiagnostics() {
        var flattened: [URL: [LanguageServerDiagnostic]] = [:]
        for providerID in diagnosticsByProviderID.keys.sorted() {
            for (fileURL, values) in diagnosticsByProviderID[providerID] ?? [:] {
                flattened[fileURL, default: []].append(contentsOf: values)
            }
        }
        diagnostics = flattened
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
