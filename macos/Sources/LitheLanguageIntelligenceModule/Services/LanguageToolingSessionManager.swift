import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

package enum LanguageToolingSessionError: LocalizedError, Equatable, Sendable {
    case noProvider(fileExtension: String)
    case providerNotInstalled(String)
    case providerDisabled(String)
    case toolingUnavailable(String)
    case capabilityUnavailable(provider: String, capability: String)
    case invalidDebugAdapterPort(provider: String)
    case languageServerNotOwnedByPlugin(languageID: String)

    package var errorDescription: String? {
        switch self {
        case .noProvider(let fileExtension):
            return L10n.string("No language provider handles .\(fileExtension) files.")
        case .providerNotInstalled(let provider):
            return L10n.string("The \(provider) language provider is not installed.")
        case .providerDisabled(let provider):
            return L10n.string("The \(provider) language server is disabled in this workspace. Enable it in Settings > LSP.")
        case .toolingUnavailable(let message):
            return message
        case .capabilityUnavailable(let provider, let capability):
            return L10n.string("The \(provider) provider does not support \(capability).")
        case .invalidDebugAdapterPort(let provider):
            return L10n.string("The \(provider) language server returned an invalid TCP port for its debug adapter.")
        case .languageServerNotOwnedByPlugin(let languageID):
            return L10n.string("The \(languageID) language server of this plugin is not available.")
        }
    }
}

/// UI-facing façade that routes language features across active LSP sessions
/// and lightweight local providers without exposing either implementation.
@MainActor
package final class LanguageToolingSessionManager: ObservableObject {
    @Published package private(set) var diagnostics: [URL: [LanguageServerDiagnostic]] = [:]
    @Published package private(set) var semanticTokensGeneration: UInt64 = 0
    @Published package private(set) var languageServerFeatures: [String: LanguageServerFeatureSet] = [:]
    /// Application composition persists lifecycle facts without raw protocol payloads.
    package var onLogEvent: ((CoreLogRecord) -> Void)?
    package var onLogIssue: ((String, String?, Bool, String, String, Int?) -> Void)?
    @Published package private(set) var languageServerStates: [String: LanguageServerSessionState] = [:] {
        // Every start, crash, stop and restart passes through this one
        // property, so the plugin relay cannot miss a transition.
        didSet { relayPluginServerStates(from: oldValue) }
    }
    @Published package private(set) var languageServerInfos: [String: LanguageServerInfo] = [:]
    @Published package private(set) var languageServerOperationIDs: [String: UUID] = [:]
    package var onLanguageServerStateChange: ((String, LanguageServerSessionState, UUID?) -> Void)?
    /// What plugin backends learn about the servers their plugins own (API-25).
    package let pluginServers = PluginLanguageServerRelay()
    /// The preparation status each plugin reported for its running server.
    @Published package private(set) var pluginServerStatuses: [String: PluginServerStatus] = [:]
    private let logSink: (any LogSink)?
    private let resolveLogSubject: (String) throws -> LogSegment?
    // Cache both success and failure; diagnostics must not change startup behavior.
    private var logSubjects: [String: LogSegment?] = [:]
    private static let maximumLogSubjects = 128
    private var catalog: LanguageProviderCatalog
    private let extensionRequiredProviderIDs: Set<String>
    private let isLanguageServerEnabled: (String, URL) -> Bool

    package var catalogSnapshot: LanguageProviderCatalog { catalog }
    private var runtimesByID: [String: any LanguageProviderRuntime]
    private var extensionRuntimeIDs: Set<String> = []
    private var extensionProviderIdentities: [String: ObjectIdentifier] = [:]
    private var extensionLanguageIdentifiers: [String: String] = [:]
    private var extensionLifecycles: [String: WeakLanguageServerExtensionLifecycle] = [:]
    private let runtimeFactory: (any LanguageProviderRuntimeFactory)?
    private var languageServers: [String: any LanguageServerSession] = [:]
    /// Explicit restarts retain the old process's slot through shutdown and
    /// resource release. A timed-out close must not admit an overlapping start.
    private var stoppingServers: [String: (id: UUID, session: any LanguageServerSession, task: Task<Bool, Never>)] = [:]
    private var languageServerRoots: [String: URL] = [:]
    /// Core-owned startup failure history (`lsp.activationPolicy`) per provider
    /// and workspace root; a different root starts without history.
    private var languageServerActivation: [String: (root: URL, state: LanguageServerActivationState)] = [:]
    private let policyCore: (any LanguageToolingPolicyCore)?
    /// Monotonic milliseconds for the activation policy; tests inject a clock.
    package var monotonicNowMs: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds / 1_000_000 }
    private var languageServerSessionIdentities: [String: ObjectIdentifier] = [:]
    private var diagnosticsByProviderID: [String: [URL: [LanguageServerDiagnostic]]] = [:]
    private var languageFeatureProviders: [any LanguageFeatureProvider]
    private var languageServerFeatureProviders: [String: LanguageServerFeatureProvider] = [:]
    private var languageServerReadyWaiters: [UUID: LanguageServerReadyWaiter] = [:]
    private let workspaceStateResetter: ((LanguageProviderDescriptor, URL) throws -> Void)?

    private let pluginOperations: PluginOperationReporter

    package init(
        catalog: LanguageProviderCatalog = .compatibilityFallback,
        logSink: (any LogSink)? = nil,
        pluginOperations: PluginOperationReporter = .disabled,
        resolveLogSubject: @escaping (String) throws -> LogSegment? = { _ in nil },
        runtimes: [any LanguageProviderRuntime] = [],
        runtimeFactory: (any LanguageProviderRuntimeFactory)? = nil,
        builtinCore: (any BuiltinLanguageFeatureCore)? = nil,
        policyCore: (any LanguageToolingPolicyCore)? = nil,
        languageFeatureProviders: [any LanguageFeatureProvider] = [],
        extensionRequiredProviderIDs: Set<String> = [],
        isLanguageServerEnabled: @escaping (String, URL) -> Bool = { _, _ in true },
        workspaceStateResetter: ((LanguageProviderDescriptor, URL) throws -> Void)? = nil
    ) {
        self.pluginOperations = pluginOperations
        self.policyCore = policyCore
        self.logSink = logSink
        self.resolveLogSubject = resolveLogSubject
        self.catalog = catalog
        self.runtimeFactory = runtimeFactory
        self.extensionRequiredProviderIDs = extensionRequiredProviderIDs
        self.isLanguageServerEnabled = isLanguageServerEnabled
        self.workspaceStateResetter = workspaceStateResetter
        self.languageFeatureProviders = languageFeatureProviders + [
            BuiltinLanguageFeatureProvider(core: builtinCore ?? UnavailableBuiltinLanguageFeatureCore())
        ]
        runtimesByID = Dictionary(uniqueKeysWithValues: runtimes.map { ($0.descriptor.id, $0) })
        pluginServers.onStatusesChange = { [weak self] statuses in self?.pluginServerStatuses = statuses }
    }

    package var activeLanguageServerIDs: Set<String> {
        Set(languageServers.compactMap { providerID, session in
            guard session.isRunning,
                  languageServerStates[providerID] == .ready else { return nil }
            return providerID
        })
    }

    package func updateCatalog(_ catalog: LanguageProviderCatalog) {
        let previousDescriptors = Dictionary(
            uniqueKeysWithValues: self.catalog.descriptors.map { ($0.id, $0) }
        )
        let updatedDescriptors = Dictionary(
            uniqueKeysWithValues: catalog.descriptors.map { ($0.id, $0) }
        )
        // Adding or removing a debugger does not change how a server runs, so it
        // must not restart the server a plugin installation happened to touch.
        let changedProviderIDs = Set(previousDescriptors.keys)
            .union(updatedDescriptors.keys)
            .filter { previousDescriptors[$0]?.withoutDebugAdapter != updatedDescriptors[$0]?.withoutDebugAdapter }

        self.catalog = catalog
        let validProviderIDs = Set(catalog.descriptors.map(\.id))
        languageServerFeatures = languageServerFeatures.filter { validProviderIDs.contains($0.key) }
        languageServerStates = languageServerStates.filter { validProviderIDs.contains($0.key) }
        languageServerInfos = languageServerInfos.filter { validProviderIDs.contains($0.key) }
        languageServerOperationIDs = languageServerOperationIDs.filter {
            validProviderIDs.contains($0.key)
        }
        diagnosticsByProviderID = diagnosticsByProviderID.filter {
            validProviderIDs.contains($0.key)
        }
        rebuildDiagnostics()
        for providerID in changedProviderIDs {
            stopLanguageServer(providerID: providerID)
            if updatedDescriptors[providerID] == nil {
                languageServerStates[providerID] = nil
            }
            if runtimeFactory != nil, !extensionRuntimeIDs.contains(providerID) {
                runtimesByID[providerID] = nil
            }
        }
    }

    @discardableResult
    package func registerLanguageServerExtension(
        _ provider: any LanguageServerExtensionProviding,
        support: LanguageSupportDeclaration
    ) -> Bool {
        let configuration = provider.configuration
        guard configuration.languageID == support.id,
              let ownerModuleID = support.languageServerModuleID,
              // A server its plugin backend launches names no executable
              // until it starts.
              !configuration.executableNames.isEmpty
                  || configuration.launchSource?.resolvesLaunchWithBackend == true
                  || configuration.launchSource?.launchesThroughTool == true,
              // The module that owns this provider already stopped it.
              !provider.lifecycle.isRetired,
              let runtimeFactory else { return false }
        let providerIdentity = ObjectIdentifier(provider)
        if extensionProviderIdentities[support.id] == providerIdentity,
           runtimesByID[support.id] != nil {
            return true
        }

        let base = catalog.descriptors.first { $0.id == support.id }
        let launch = LanguageServerLaunchDescriptor(
            executableNames: configuration.executableNames,
            arguments: configuration.arguments,
            validationArguments: configuration.validationArguments,
            environment: configuration.environment,
            runtimeTools: configuration.runtimeTools,
            executableURL: configuration.executableURL,
            launchSource: configuration.launchSource,
            pluginID: configuration.pluginID,
            executableVersionRequirement: configuration.executableVersionRequirement,
            launchRuntimeTool: configuration.launchRuntimeTool
        )
        let descriptor = LanguageProviderDescriptor(
            id: support.id,
            displayName: configuration.displayName,
            fileExtensions: Set(support.fileExtensions).union(base?.fileExtensions ?? []),
            fileNames: Set(support.fileNames).union(base?.fileNames ?? []),
            fileNamePrefixes: base?.fileNamePrefixes ?? [],
            capabilities: (base?.capabilities ?? []).union(.languageServer),
            activationPolicy: base?.activationPolicy ?? .onDemand,
            languageIdentifier: configuration.languageIdentifier,
            languageIdentifiersByExtension: base?.languageIdentifiersByExtension ?? [:],
            languageIdentifiersByFileName: base?.languageIdentifiersByFileName ?? [:],
            languageServerLaunch: launch,
            languageServerInstallation: base?.languageServerInstallation
        )
        guard let runtime = runtimeFactory.makeRuntime(
            for: descriptor,
            languageServerLaunch: launch,
            ownerModuleID: ownerModuleID
        ) else { return false }

        stopLanguageServer(providerID: support.id)
        runtimesByID[support.id] = runtime
        extensionRuntimeIDs.insert(support.id)
        extensionProviderIdentities[support.id] = providerIdentity
        extensionLanguageIdentifiers[support.id] = configuration.languageIdentifier
        extensionLifecycles[support.id] = WeakLanguageServerExtensionLifecycle(
            provider.lifecycle
        )
        return true
    }

    /// The descriptor a registered plugin language server launches with,
    /// including its validation probe and runtime tools.
    package func languageServerExtensionDescriptor(languageID: String) -> LanguageProviderDescriptor? {
        guard extensionRuntimeIDs.contains(languageID) else { return nil }
        return runtimesByID[languageID]?.descriptor
    }

    package func unregisterLanguageServerExtension(languageID: String) {
        guard extensionRuntimeIDs.contains(languageID) else { return }
        stopLanguageServer(providerID: languageID)
        runtimesByID[languageID] = nil
        extensionRuntimeIDs.remove(languageID)
        extensionProviderIdentities[languageID] = nil
        extensionLanguageIdentifiers[languageID] = nil
        extensionLifecycles[languageID] = nil
    }

    package func provider(for fileURL: URL) -> LanguageProviderDescriptor? {
        catalog.provider(for: fileURL)
    }

    package func supportsGenericEditing(for fileURL: URL) -> Bool {
        return !features(for: fileURL).isEmpty
    }

    package func features(for fileURL: URL) -> LanguageServerFeatureSet {
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

    package func synchronizeLanguageServer(
        for fileURL: URL,
        text: String,
        rootURL: URL,
        changes: [LanguageServerDocumentChange] = []
    ) throws {
        guard let descriptor = catalog.provider(for: fileURL) else {
            throw LanguageToolingSessionError.noProvider(fileExtension: fileURL.pathExtension.lowercased())
        }
        guard descriptor.capabilities.contains(.languageServer) else { return }
        guard let runtime = runtime(for: descriptor),
              runtime.supportsLanguageServerSession else { return }
        let normalizedRoot = rootURL.standardizedFileURL
        let session = try ensureLanguageServerSession(
            descriptor: descriptor,
            rootURL: normalizedRoot,
            operationID: nil
        )
        if let incremental = session as? LanguageServerRuntimeSession {
            try incremental.synchronize(
                fileURL: fileURL,
                text: text,
                languageID: extensionLanguageIdentifiers[descriptor.id]
                    ?? descriptor.languageIdentifier(for: fileURL),
                changes: changes
            )
        } else {
            try session.synchronize(
                fileURL: fileURL,
                text: text,
                languageID: extensionLanguageIdentifiers[descriptor.id]
                    ?? descriptor.languageIdentifier(for: fileURL)
            )
        }
    }

    /// Starts one workspace-owned session without opening a document.
    @discardableResult
    package func startLanguageServer(
        providerID: String,
        rootURL: URL,
        operationID: UUID = UUID()
    ) throws -> UUID {
        guard let descriptor = catalog.descriptors.first(where: { $0.id == providerID }),
              descriptor.capabilities.contains(.languageServer) else {
            throw LanguageToolingSessionError.capabilityUnavailable(
                provider: providerID,
                capability: "language server"
            )
        }
        _ = try ensureLanguageServerSession(
            descriptor: descriptor,
            rootURL: rootURL.standardizedFileURL,
            operationID: operationID
        )
        return languageServerOperationIDs[providerID] ?? operationID
    }

    /// The loopback port a language server answers a debug-start command
    /// with: an integer or a numeric string, 1...65535.
    package static func debugAdapterPort(from value: ToolingJSONValue) -> UInt16? {
        let portValue: Int?
        switch value {
        case .integer(let value): portValue = value
        case .string(let value): portValue = Int(value)
        default: portValue = nil
        }
        guard let portValue, (1...Int(UInt16.max)).contains(portValue) else { return nil }
        return UInt16(portValue)
    }

    /// Starts or reuses the language server of `pluginID` for `languageID`,
    /// runs the plugin's declared debug-start `command` on it, and returns the
    /// loopback port the adapter it hosts listens on. Only the server of the
    /// same plugin qualifies, as for build requests: another plugin may answer
    /// for the same language, and must never receive this plugin's command.
    package func startHostedDebugAdapter(
        languageID: String,
        pluginID: String,
        command: String,
        rootURL: URL
    ) async throws -> UInt16 {
        try Task.checkCancellation()
        guard extensionRuntimeIDs.contains(languageID),
              runtimesByID[languageID]?.descriptor.languageServerLaunch?.launchSource?.pluginID == pluginID else {
            throw LanguageToolingSessionError.languageServerNotOwnedByPlugin(languageID: languageID)
        }
        let root = rootURL.standardizedFileURL
        _ = try startLanguageServer(providerID: languageID, rootURL: root)
        let identity = languageServerSessionIdentities[languageID]
        try await waitUntilLanguageServerReady(providerID: languageID, rootURL: root)
        try Task.checkCancellation()
        guard runtimesByID[languageID]?.descriptor.languageServerLaunch?.launchSource?.pluginID == pluginID,
              languageServerSessionIdentities[languageID] == identity,
              languageServerRoots[languageID] == root,
              let session = languageServers[languageID], session.isRunning else {
            throw LanguageToolingSessionError.languageServerNotOwnedByPlugin(languageID: languageID)
        }
        let commandRequest = LanguageServerCommand(title: command, command: command, arguments: [])
        let value = try await session.executeReturningValue(commandRequest, fileURL: root)
        try Task.checkCancellation()
        guard languageServerSessionIdentities[languageID] == identity,
              languageServerRoots[languageID] == root,
              languageServerStates[languageID] == .ready else {
            throw LanguageToolingSessionError.languageServerNotOwnedByPlugin(languageID: languageID)
        }
        guard let port = Self.debugAdapterPort(from: value) else {
            throw LanguageToolingSessionError.invalidDebugAdapterPort(provider: languageID)
        }
        return port
    }

    package func notifyWorkspaceFilesChanged(
        providerID: String,
        changes: [LanguageServerWorkspaceFileChange]
    ) throws {
        guard !changes.isEmpty,
              let session = languageServers[providerID],
              session.isRunning else { return }
        try session.notifyWorkspaceFilesChanged(changes)
    }

    package func notifyDocumentSaved(_ fileURL: URL, text: String, currentText: String) throws {
        let fileURL = fileURL.standardizedFileURL
        guard let session = languageServerSession(for: fileURL),
              let descriptor = catalog.provider(for: fileURL) else { return }
        // Flush editor state before didSave, including edits made during the
        // disk write. Core must see the newer revision to reject a stale save.
        try session.synchronize(fileURL: fileURL, text: currentText,
            languageID: extensionLanguageIdentifiers[descriptor.id]
                ?? descriptor.languageIdentifier(for: fileURL))
        try session.notifyDocumentSaved(fileURL, text: text)
    }

    package func closeDocument(_ fileURL: URL) {
        let standardizedURL = fileURL.standardizedFileURL
        clearDiagnostics(for: standardizedURL)
        languageServerSession(for: standardizedURL)?.closeDocument(standardizedURL)
    }

    package func clearDiagnostics() {
        diagnosticsByProviderID = [:]
        diagnostics = [:]
    }

    package func diagnostics(for providerID: String) -> [URL: [LanguageServerDiagnostic]] {
        diagnosticsByProviderID[providerID] ?? [:]
    }

    package func clearDiagnostics(providerID: String) {
        guard diagnosticsByProviderID.removeValue(forKey: providerID) != nil else { return }
        rebuildDiagnostics()
    }


    @discardableResult
    package func recordHostFailure(providerID: String, stage: String, error: Error) -> LogRecordReference? {
        guard !(error is CancellationError) else { return nil }
        let operationID = languageServerOperationIDs[providerID]?.uuidString
        onLogIssue?(providerID, operationID, true, stage, (error as NSError).domain, nil)
        guard let logSink, let server = logSubject(for: providerID) else { return nil }
        let failure: any Error = (error as? LanguageServerRuntimeFailure).map {
            LogFailure(domain: "LanguageRuntime", code: $0.code) as any Error
        } ?? error
        let event = LspHostOperationFailed(error: failure, server: server, stage: stage, operationID: operationID)
        logSink.emit(event)
        return event.reference
    }

    private func logSubject(for providerID: String) -> LogSegment? {
        if let cached = logSubjects[providerID] { return cached }
        let subject = try? resolveLogSubject(providerID)
        if logSubjects.count >= Self.maximumLogSubjects { logSubjects.removeAll(keepingCapacity: true) }
        logSubjects[providerID] = .some(subject)
        return subject
    }

    private enum SessionStage: String {
        case requested, resolving, registered, stopping, cancelled
    }

    private func recordSessionStage(_ stage: SessionStage, providerID: String, operationID: String?) {
        guard let logSink, let server = logSubject(for: providerID) else { return }
        logSink.emit(LspSessionStageChanged(server: server, stage: stage.rawValue, operationID: operationID))
    }

    @discardableResult
    private func recordLogIssue(_ providerID: String, _ operationID: String?, _ warning: Bool,
                                _ stage: String, _ code: String, _ exitCode: Int?) -> LogRecordReference? {
        onLogIssue?(providerID, operationID, warning, stage, code, exitCode)
        guard let logSink, let server = logSubject(for: providerID) else { return nil }
        if warning {
            let event = LspSessionDegradationReceived(exitCode: exitCode.map(Int64.init),
                failureCode: code, server: server, stage: stage, operationID: operationID)
            logSink.emit(event)
            return event.reference
        } else {
            let event = LspSessionIssueFailed(exitCode: exitCode.map(Int64.init),
                failureCode: code, server: server, stage: stage, operationID: operationID)
            logSink.emit(event)
            return event.reference
        }
    }



    package func stopLanguageServer(providerID: String) {
        guard stoppingServers[providerID] == nil else { return }
        removeLanguageServer(providerID: providerID, stopSession: true)
    }

    private func removeLanguageServer(providerID: String, stopSession: Bool) {
        languageServerActivation[providerID] = nil
        let operationID = languageServerOperationIDs[providerID]
        if languageServers[providerID] != nil {
            let wasPreparing = switch languageServerStates[providerID] {
            case .startingProcess, .initializing: true
            default: false
            }
            if wasPreparing { recordLogIssue(providerID, languageServerOperationIDs[providerID]?.uuidString,
                true, "startup", "requestCancelled", nil) }
            recordSessionStage(wasPreparing ? .cancelled : .stopping, providerID: providerID,
                               operationID: operationID?.uuidString)
        }
        clearDiagnostics(providerID: providerID)
        languageServerSessionIdentities[providerID] = nil
        let removed = languageServers.removeValue(forKey: providerID)
        if stopSession { removed?.stop() }
        languageServerRoots[providerID] = nil
        languageServerFeatures[providerID] = nil
        languageServerInfos[providerID] = nil
        languageServerFeatureProviders[providerID] = nil
        let state: LanguageServerSessionState = stopSession ? .stopped : .stopping
        languageServerStates[providerID] = state
        resumeLanguageServerReadyWaiters(
            providerID: providerID,
            state: state,
            rootURL: nil
        )
        onLanguageServerStateChange?(
            providerID,
            state,
            operationID
        )
        languageServerOperationIDs[providerID] = nil
    }

    package func stopAllLanguageServers() {
        for providerID in languageServers.keys.sorted() {
            stopLanguageServer(providerID: providerID)
        }
        clearDiagnostics()
        languageServerFeatures = [:]
        languageServerInfos = [:]
        languageServers = [:]
        languageServerRoots = [:]
        languageServerSessionIdentities = [:]
        languageServerFeatureProviders = [:]
        languageServerStates = [:]
        languageServerActivation = [:]
        languageServerOperationIDs = [:]
    }

    /// The ordinary stop API initiates shutdown. Restart callers additionally
    /// wait for the old process and its package/workspace resources to release.
    package func stopLanguageServerAndWait(providerID: String) async -> Bool {
        let retiring: any LanguageServerSession
        if let stopping = stoppingServers[providerID] {
            if await stopping.task.value { return true }
            guard !Task.isCancelled else { return false }
            // A previous wait can time out before the process finally exits.
            // An explicit retry waits on that same process, never starts over.
            retiring = stopping.session
        } else {
            guard let session = languageServers[providerID] else {
                stopLanguageServer(providerID: providerID)
                return true
            }
            retiring = session
        }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            let ended = await retiring.stopAndWait()
            guard let self, self.stoppingServers[providerID]?.id == id else { return ended }
            if ended { self.stoppingServers[providerID] = nil }
            // Full workspace teardown may already have cleared the projection.
            if self.languageServerStates[providerID] == .stopping {
                let state: LanguageServerSessionState = ended ? .stopped : .failed(.init(
                    code: "shutdownTimeout", stage: "shutdown",
                    message: L10n.string("The language server is still stopping. Try again after it has stopped.")
                ))
                self.languageServerStates[providerID] = state
                self.onLanguageServerStateChange?(providerID, state, nil)
            }
            return ended
        }
        stoppingServers[providerID] = (id, retiring, task)
        removeLanguageServer(providerID: providerID, stopSession: false)
        return await task.value
    }

    /// Stops one provider and removes only its current workspace-state directory.
    package func rebuildWorkspaceState(providerID: String, rootURL: URL) throws {
        guard let descriptor = catalog.descriptors.first(where: { $0.id == providerID }) else {
            throw LanguageToolingSessionError.capabilityUnavailable(
                provider: providerID,
                capability: "workspace state reset"
            )
        }
        guard let workspaceStateResetter else {
            throw LanguageToolingSessionError.capabilityUnavailable(
                provider: descriptor.displayName,
                capability: "workspace state reset"
            )
        }

        let normalizedRoot = rootURL.standardizedFileURL
        stopLanguageServer(providerID: providerID)
        try workspaceStateResetter(descriptor, normalizedRoot)
    }

    package func navigate(
        method: String,
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        rootURL: URL,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        // A document can remain in the editor while the language server is
        // restarted. Re-sync it before navigation so the server owns the URI
        // before handling definition, implementation, or reference requests.
        if readyLanguageServerSession(for: fileURL) != nil {
            try synchronizeLanguageServer(for: fileURL, text: text, rootURL: rootURL)
        }
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

    package func inlayHints(fileURL: URL, range: LanguageServerRange,
                            completion: @escaping (Result<[LanguageServerInlayHint], Error>) -> Void) throws {
        guard let session = readyLanguageServerSession(for: fileURL), session.features.contains(.inlayHints) else {
            completion(.success([])); return
        }
        try session.inlayHints(fileURL: fileURL, range: range, completion: completion)
    }

    package func semanticTokens(fileURL: URL, completion: @escaping (Result<LanguageServerSemanticTokens, Error>) -> Void) throws {
        guard let session = readyLanguageServerSession(for: fileURL), session.features.contains(.semanticTokens) else {
            completion(.success(.empty)); return
        }
        try session.semanticTokens(fileURL: fileURL, completion: completion)
    }

    package func hover(
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

    package func completions(
        fileURL: URL, text: String, position: LanguageServerPosition, rootURL: URL,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        try completionList(fileURL: fileURL, text: text, position: position, rootURL: rootURL) {
            completion($0.map(\.items))
        }
    }

    package func completionList(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        rootURL: URL,
        completionContext: LanguageServerCompletionContext? = nil,
        completion: @escaping (Result<LanguageServerCompletionList, Error>) -> Void
    ) throws {
        let context = featureContext(
            fileURL: fileURL,
            text: text,
            position: position,
            rootURL: rootURL, completionContext: completionContext
        )
        let providers = featureProviders(for: .completion, context: context)
        guard !providers.isEmpty else {
            throw unavailableLanguageServerError(for: fileURL)
        }
        routeCompletions(
            providers: providers,
            index: 0,
            context: context,
            lists: [],
            completion: completion
        )
    }

    package func rename(
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

    package func format(
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

    package func codeActions(
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

    package func execute(
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

    package func executeReturningValue(
        _ command: LanguageServerCommand,
        fileURL: URL,
        rootURL _: URL,
        completion: @escaping (Result<ToolingJSONValue, Error>) -> Void
    ) throws {
        guard command.command.isEmpty == false else {
            throw LanguageToolingSessionError.capabilityUnavailable(
                provider: catalog.provider(for: fileURL)?.displayName ?? fileURL.pathExtension,
                capability: "execute command"
            )
        }
        if let session = readyLanguageServerSession(for: fileURL) {
            try session.executeReturningValue(command, fileURL: fileURL, completion: completion)
            return
        }
        throw unavailableLanguageServerError(for: fileURL)
    }

    /// Sends a build request to the language server a plugin's build system
    /// shares, starting it for `rootURL` when needed. Only the server of the
    /// same plugin qualifies: another plugin may answer for the same language,
    /// and its process must never receive this plugin's requests.
    package func requestBuildProvider(
        languageID: String,
        pluginID: String,
        rootURL: URL,
        method: String,
        params: ToolingJSONValue,
        timeout: TimeInterval
    ) async throws -> ToolingJSONValue {
        guard extensionRuntimeIDs.contains(languageID),
              runtimesByID[languageID]?.descriptor.languageServerLaunch?.launchSource?.pluginID == pluginID else {
            throw LanguageToolingSessionError.toolingUnavailable(
                "The language server this build system shares is not running for its plugin."
            )
        }
        let root = rootURL.standardizedFileURL
        _ = try startLanguageServer(providerID: languageID, rootURL: root)
        try await waitUntilLanguageServerReady(providerID: languageID, rootURL: root)
        guard let session = languageServers[languageID], session.isRunning else {
            throw LanguageToolingSessionError.toolingUnavailable(
                "The language server this build system shares stopped."
            )
        }
        return try await session.buildRequest(method: method, params: params, timeout: timeout)
    }

    /// Languages whose running server was started from `pluginID`'s package.
    package func runningLanguageIDs(ofPlugin pluginID: String) -> [String] {
        languageServers.compactMap { languageID, session in
            session.isRunning
                && runtimesByID[languageID]?.descriptor.languageServerLaunch?.launchSource?.pluginID == pluginID
                ? languageID : nil
        }.sorted()
    }

    /// Sends a changed configuration off the main actor through the session's
    /// bounded write path.
    @discardableResult
    package func updateWorkspaceConfiguration(
        _ configuration: ToolingJSONValue,
        languageID: String,
        pluginID: String
    ) async -> WorkspaceConfigurationUpdateResult {
        guard runtimesByID[languageID]?.descriptor.languageServerLaunch?.launchSource?.pluginID == pluginID,
              let session = languageServers[languageID], session.isRunning else { return .failed }
        return await session.updateWorkspaceConfigurationAsync(configuration)
    }

    // MARK: Plugin-owned language servers (API-25)

    /// Sends one request of `pluginID`'s backend to the language server
    /// `serverID`. Rust Core decides whether the server belongs to the plugin
    /// and whether the method is declared; this only finds the session.
    package func requestPluginServer(
        pluginID: String,
        serverID: String,
        method: String,
        params: ToolingJSONValue,
        timeout: TimeInterval?
    ) async -> Result<ToolingJSONValue, PluginHostRequestFailure> {
        guard let session = languageServers[serverID] else { return .failure(.languageServerUnavailable) }
        return await session.requestPluginServer(
            pluginID: pluginID, serverID: serverID, method: method, params: params, timeout: timeout
        )
    }

    /// Sends one notification of `pluginID`'s backend to the language server
    /// `serverID`; `true` when it was written.
    package func notifyPluginServer(
        pluginID: String,
        serverID: String,
        method: String,
        params: ToolingJSONValue
    ) async -> Result<Bool, PluginHostRequestFailure> {
        guard let session = languageServers[serverID] else { return .failure(.languageServerUnavailable) }
        return await session.notifyPluginServer(
            pluginID: pluginID, serverID: serverID, method: method, params: params
        )
    }

    /// Records the preparation status `pluginID` reports for its server.
    /// Core never sees this call, so ownership is checked by the relay.
    package func setPluginServerStatus(
        _ status: PluginServerStatus,
        serverID: String,
        pluginID: String
    ) -> Result<Void, PluginHostRequestFailure> {
        pluginServers.setStatus(status, serverID: serverID, pluginID: pluginID)
    }

    private func relayPluginServerStates(from previous: [String: LanguageServerSessionState]) {
        for serverID in Set(previous.keys).union(languageServerStates.keys) {
            let state = languageServerStates[serverID]
            guard state != previous[serverID] else { continue }
            pluginServers.serverStateChanged(
                serverID: serverID,
                owner: runtimesByID[serverID]?.descriptor.languageServerLaunch?.pluginID,
                to: state
            )
        }
    }

    package func resolveVirtualDocument(
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

    package func resolveCompletion(
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

    package func resolveCodeAction(
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

    private func runtime(
        for descriptor: LanguageProviderDescriptor
    ) -> (any LanguageProviderRuntime)? {
        if extensionRuntimeIDs.contains(descriptor.id) {
            return runtimesByID[descriptor.id]
        }
        if extensionRequiredProviderIDs.contains(descriptor.id) {
            return nil
        }
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

    private func ensureLanguageServerSession(
        descriptor: LanguageProviderDescriptor,
        rootURL: URL,
        operationID requestedOperationID: UUID?
    ) throws -> any LanguageServerSession {
        guard stoppingServers[descriptor.id] == nil else {
            throw LanguageToolingSessionError.toolingUnavailable(
                L10n.string("The language server is still stopping. Try again after it has stopped.")
            )
        }
        // All entry points, including reload, testing, and debugging, must
        // recheck the current workspace preference before creating or reusing a session.
        guard isLanguageServerEnabled(descriptor.id, rootURL) else {
            throw LanguageToolingSessionError.providerDisabled(descriptor.displayName)
        }
        if let active = languageServers[descriptor.id],
           active.isRunning,
           languageServerRoots[descriptor.id] == rootURL {
            return active
        }

        let previousActivation = languageServerActivation[descriptor.id]
        let activationHistory = previousActivation?.root == rootURL ? previousActivation?.state : nil
        // Document synchronization must not turn a persistent startup failure
        // into an unbounded process loop. Explicit stop/restart clears the history.
        if let outcome = activationOutcome(.automaticStart, providerID: descriptor.id, history: activationHistory),
           outcome.decision != .allow {
            let failure: LanguageServerSessionFailure
            if case .failed(let previous) = languageServerStates[descriptor.id] {
                failure = previous
            } else {
                failure = LanguageServerSessionFailure(code: "start_failed", stage: "processStart", message: nil)
            }
            throw LanguageServerSessionStartError(failure: failure)
        }

        if extensionLifecycles[descriptor.id]?.value?.isRetired == true {
            // Stopped by its module before any server was started for it.
            unregisterLanguageServerExtension(languageID: descriptor.id)
        }
        guard let runtime = runtime(for: descriptor) else {
            throw LanguageToolingSessionError.toolingUnavailable(
                extensionRequiredProviderIDs.contains(descriptor.id)
                    ? "\(descriptor.displayName) language support comes from a plugin that is not enabled. Enable or restore it in Settings > Plugins."
                    : descriptor.displayName
            )
        }
        guard runtime.supportsLanguageServerSession else {
            throw LanguageToolingSessionError.toolingUnavailable(
                runtime.unavailableToolingMessage ?? descriptor.displayName
            )
        }

        // A provider owns at most one process. Retire every projection of the
        // previous root before resolving a replacement so stale callbacks cannot
        // make the new workspace appear ready.
        if languageServers[descriptor.id] != nil || languageServerRoots[descriptor.id] != nil {
            stopLanguageServer(providerID: descriptor.id)
        }
        // Retiring the previous projection clears its history; this start keeps it.
        languageServerActivation[descriptor.id] = activationHistory.map { (rootURL, $0) }
        let operationID = requestedOperationID ?? UUID()
        // Only a declarative launch has no plugin process to report its start;
        // a plugin API 1 server is one too, though it has no launch templates.
        let startupAttempt = descriptor.languageServerLaunch?.pluginID.map {
            pluginOperations.begin(
                pluginID: $0, operation: .languageServerStart, at: .resolve, operationID: operationID.uuidString
            )
        }
        languageServerOperationIDs[descriptor.id] = operationID
        recordSessionStage(.requested, providerID: descriptor.id, operationID: operationID.uuidString)
        recordSessionStage(.resolving, providerID: descriptor.id, operationID: operationID.uuidString)

        guard let created = runtime.makeLanguageServerSession(rootURL: rootURL) else {
            startupAttempt?.fail()
            let message = runtime.unavailableToolingMessage ?? descriptor.displayName
            let state = LanguageServerSessionState.failed(LanguageServerSessionFailure(
                code: "tool_not_found",
                stage: "discovery",
                message: message
            ))
            languageServerStates[descriptor.id] = state
            recordActivation(.startFailed, providerID: descriptor.id, rootURL: rootURL)
            recordLogIssue(descriptor.id, operationID.uuidString, false, "discovery", "tool_not_found", nil)
            onLanguageServerStateChange?(descriptor.id, state, operationID)
            throw LanguageToolingSessionError.toolingUnavailable(message)
        }

        if let startupAttempt { created.observePluginStartup(startupAttempt) }
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
        languageServers[descriptor.id] = created
        languageServerRoots[descriptor.id] = rootURL
        configureLanguageServerCallbacks(
            created,
            providerID: descriptor.id,
            sessionIdentity: sessionIdentity
        )
        extensionLifecycles[descriptor.id]?.value?.attach(
            isRunning: { [weak created] in created?.isRunning ?? false },
            stop: { [weak self] in
                // Host workflows start a missing server on demand. Removing
                // the extension, not only its process, keeps them from
                // restarting it while its module is being stopped.
                self?.unregisterLanguageServerExtension(languageID: descriptor.id)
            }
        )

        do {
            try created.start(rootURL: rootURL)
        } catch {
            // Before the session handed the attempt to Core; a no-op after.
            startupAttempt?.end(throwing: error)
            if languageServerSessionIdentities[descriptor.id] == sessionIdentity {
                clearLanguageServerSession(
                    providerID: descriptor.id,
                    sessionIdentity: sessionIdentity,
                    stop: true
                )
                let failure = (error as? LanguageServerSessionStartError)?.failure
                    ?? LanguageServerSessionFailure(
                        code: "start_failed",
                        stage: "processStart",
                        message: error.localizedDescription
                    )
                let state = LanguageServerSessionState.failed(failure)
                languageServerStates[descriptor.id] = state
                recordActivation(.startFailed, providerID: descriptor.id, rootURL: rootURL)
                recordLogIssue(descriptor.id, languageServerOperationIDs[descriptor.id]?.uuidString, false, failure.stage ?? "processStart", failure.code ?? "start_failed", failure.exitCode.map(Int.init))
                onLanguageServerStateChange?(descriptor.id, state, operationID)
            }
            throw error
        }

        recordSessionStage(.registered, providerID: descriptor.id, operationID: operationID.uuidString)
        return created
    }

    /// Asks Core for the activation decision. A Core failure is logged and
    /// leaves starts allowed so a policy fault never disables the language server.
    private func activationOutcome(
        _ event: LanguageServerActivationEvent,
        providerID: String,
        history: LanguageServerActivationState?
    ) -> LanguageServerActivationOutcome? {
        guard let policyCore else { return nil }
        switch policyCore.languageServerActivation(state: history, event: event, nowMs: monotonicNowMs()) {
        case .success(let outcome):
            return outcome
        case .failure(let failure):
            logSink?.emit(AppCoreFallbackSelected(error: LogFailure(domain: "RustCore", code: failure.code),
                                                  stage: "lsp.activationPolicy"))
            return nil
        }
    }

    private func recordActivation(_ event: LanguageServerActivationEvent, providerID: String, rootURL: URL) {
        let previous = languageServerActivation[providerID]
        let history = previous?.root == rootURL ? previous?.state : nil
        guard let outcome = activationOutcome(event, providerID: providerID, history: history) else { return }
        languageServerActivation[providerID] = outcome.state.map { (rootURL, $0) }
    }

    private func clearLanguageServerSession(
        providerID: String,
        sessionIdentity: ObjectIdentifier,
        stop: Bool
    ) {
        guard languageServerSessionIdentities[providerID] == sessionIdentity else { return }
        clearDiagnostics(providerID: providerID)
        languageServerSessionIdentities[providerID] = nil
        let session = languageServers.removeValue(forKey: providerID)
        languageServerRoots[providerID] = nil
        languageServerFeatures[providerID] = nil
        languageServerInfos[providerID] = nil
        languageServerFeatureProviders[providerID] = nil
        if stop { session?.stop() }
    }

    package func stopAll() {
        stopAllLanguageServers()
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
            case .failed(let failure):
                return .toolingUnavailable(failure.message ?? "\(provider) language server failed.")
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
        rootURL: URL?,
        completionContext: LanguageServerCompletionContext? = nil
    ) -> LanguageFeatureRequestContext {
        let descriptor = catalog.provider(for: fileURL)
        return LanguageFeatureRequestContext(
            fileURL: fileURL,
            text: text,
            position: position,
            languageID: descriptor?.languageIdentifier(for: fileURL),
            workspaceURL: rootURL, completionContext: completionContext
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
        lists: [LanguageServerCompletionList],
        completion: @escaping (Result<LanguageServerCompletionList, Error>) -> Void
    ) {
        guard index < providers.count else {
            completion(.success(mergeCompletionLists(lists)))
            return
        }
        do {
            try providers[index].completionList(in: context) { [self] result in
                switch result {
                case .success(let providerItems):
                    routeCompletions(
                        providers: providers,
                        index: index + 1,
                        context: context,
                        lists: lists + [providerItems],
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

    /// Core decides which candidates survive across prioritized providers
    /// (`lsp.mergeCompletions`); only labels cross the boundary.
    private func mergeCompletionLists(_ lists: [LanguageServerCompletionList]) -> LanguageServerCompletionList {
        let isIncomplete = lists.contains(where: \.isIncomplete)
        // With at most one non-empty list nothing can be shadowed, and the shared
        // rule keeps a provider's list whole, so the call is skipped.
        guard lists.filter({ !$0.items.isEmpty }).count > 1 else {
            return LanguageServerCompletionList(items: lists.flatMap(\.items), isIncomplete: isIncomplete)
        }
        guard let policyCore else {
            return LanguageServerCompletionList(items: lists.flatMap(\.items), isIncomplete: isIncomplete)
        }
        switch policyCore.mergeCompletions(labels: lists.map { $0.items.map(\.label) },
                                           incomplete: lists.map(\.isIncomplete)) {
        case .success(let selection):
            let items = zip(lists, selection.keep).flatMap { list, keep in
                keep.compactMap { list.items.indices.contains($0) ? list.items[$0] : nil }
            }
            return LanguageServerCompletionList(items: items, isIncomplete: selection.isIncomplete)
        case .failure(let failure):
            logSink?.emit(AppCoreFallbackSelected(error: LogFailure(domain: "RustCore", code: failure.code),
                                                  stage: "lsp.mergeCompletions"))
            return LanguageServerCompletionList(items: lists.flatMap(\.items), isIncomplete: isIncomplete)
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
        session.onSemanticTokensRefresh = { [weak self] in
            guard let self, self.languageServerSessionIdentities[providerID] == sessionIdentity else { return }
            self.semanticTokensGeneration &+= 1
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
        }
        session.onServerInfoChange = { [weak self] info in
            guard let self else { return }
            guard self.languageServerSessionIdentities[providerID] == sessionIdentity else { return }
            if self.languageServerStates[providerID] == .ready {
                self.languageServerInfos[providerID] = info
            }
        }
        // Retiring sessions still own their terminal facts after UI state is cleared.
        // Core records carry their own identity, so do not apply the UI stale-session gate.
        let sink = logSink
        session.onCoreLog = { [weak self] record in
            if let sink { sink.emit(record) } else { self?.onLogEvent?(record) }
        }
        session.onLogIssue = { [weak self] warning, stage, code, exitCode, operationID in
            guard let self, self.languageServerSessionIdentities[providerID] == sessionIdentity else { return }
            self.recordLogIssue(providerID, operationID ?? self.languageServerOperationIDs[providerID]?.uuidString,
                warning, stage, code, exitCode)
        }
        // The relay raised the generation when this session's state first
        // became `startingProcess`, just before these callbacks are bound.
        if let generation = pluginServers.liveGeneration(of: providerID) {
            session.onPluginServerNotification = { [weak self] notification in
                guard let self, self.languageServerSessionIdentities[providerID] == sessionIdentity else { return }
                self.pluginServers.receive(notification, serverID: providerID, generation: generation)
            }
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
        resumeLanguageServerReadyWaiters(
            providerID: providerID,
            state: state,
            rootURL: languageServerRoots[providerID]
        )
        if case .failed = state, let rootURL = languageServerRoots[providerID] {
            recordActivation(.startFailed, providerID: providerID, rootURL: rootURL)
        }
        switch state {
        case .stopped, .failed:
            clearLanguageServerSession(
                providerID: providerID,
                sessionIdentity: sessionIdentity,
                stop: false
            )
            if case .failed(let failure) = state {
                recordLogIssue(providerID, languageServerOperationIDs[providerID]?.uuidString, false, failure.stage ?? "processStart", failure.code ?? "start_failed", failure.exitCode.map(Int.init))
            }
        case .startingProcess, .initializing, .stopping:
            languageServerFeatures[providerID] = nil
            languageServerInfos[providerID] = nil
        case .ready:
            if let rootURL = languageServerRoots[providerID] {
                recordActivation(.ready, providerID: providerID, rootURL: rootURL)
            }
            languageServerFeatures[providerID] = session.features
            languageServerInfos[providerID] = session.serverInfo
        }
        onLanguageServerStateChange?(
            providerID,
            state,
            languageServerOperationIDs[providerID]
        )
    }

    private func waitUntilLanguageServerReady(
        providerID: String,
        rootURL: URL
    ) async throws {
        if languageServerStates[providerID] == .ready,
           languageServerRoots[providerID] == rootURL {
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                languageServerReadyWaiters[waiterID] = LanguageServerReadyWaiter(
                    providerID: providerID,
                    rootURL: rootURL,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelLanguageServerReadyWaiter(waiterID)
            }
        }
    }

    private func cancelLanguageServerReadyWaiter(_ waiterID: UUID) {
        languageServerReadyWaiters.removeValue(forKey: waiterID)?
            .continuation.resume(throwing: CancellationError())
    }

    private func resumeLanguageServerReadyWaiters(
        providerID: String,
        state: LanguageServerSessionState,
        rootURL: URL?
    ) {
        let matching = languageServerReadyWaiters.filter { _, waiter in
            waiter.providerID == providerID
        }
        for (waiterID, waiter) in matching {
            switch state {
            case .ready where rootURL == waiter.rootURL:
                languageServerReadyWaiters.removeValue(forKey: waiterID)?
                    .continuation.resume()
            case .failed(let failure):
                languageServerReadyWaiters.removeValue(forKey: waiterID)?
                    .continuation.resume(throwing: LanguageToolingSessionError.toolingUnavailable(
                        failure.message ?? "The \(providerID) language server failed."
                    ))
            case .stopped:
                languageServerReadyWaiters.removeValue(forKey: waiterID)?
                    .continuation.resume(throwing: LanguageToolingSessionError.toolingUnavailable(
                        "The \(providerID) language server stopped before becoming ready."
                    ))
            default:
                break
            }
        }
    }

    private struct LanguageServerReadyWaiter {
        let providerID: String
        let rootURL: URL
        let continuation: CheckedContinuation<Void, Error>
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

}

@MainActor
private final class WeakLanguageServerExtensionLifecycle {
    weak var value: (any LanguageServerExtensionLifecycle)?

    init(_ value: any LanguageServerExtensionLifecycle) {
        self.value = value
    }
}
