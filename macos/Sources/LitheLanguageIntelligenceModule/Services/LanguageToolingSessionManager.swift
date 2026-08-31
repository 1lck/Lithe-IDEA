import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

package enum LanguageToolingSessionError: LocalizedError, Equatable, Sendable {
    case noProvider(fileExtension: String)
    case providerNotInstalled(String)
    case toolingUnavailable(String)
    case capabilityUnavailable(provider: String, capability: String)

    package var errorDescription: String? {
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
package final class LanguageToolingSessionManager: ObservableObject {
    @Published package private(set) var diagnostics: [URL: [LanguageServerDiagnostic]] = [:]
    @Published package private(set) var languageServerFeatures: [String: LanguageServerFeatureSet] = [:]
    @Published package private(set) var languageServerLogs: [LanguageServerLogEntry] = []
    @Published package private(set) var languageServerStates: [String: LanguageServerSessionState] = [:]
    @Published package private(set) var languageServerInfos: [String: LanguageServerInfo] = [:]
    @Published package private(set) var languageServerOperationIDs: [String: UUID] = [:]
    package var onLanguageServerStateChange: ((String, LanguageServerSessionState, UUID?) -> Void)?
    private var catalog: LanguageProviderCatalog
    private let extensionRequiredProviderIDs: Set<String>

    package var catalogSnapshot: LanguageProviderCatalog { catalog }
    private var runtimesByID: [String: any LanguageProviderRuntime]
    private var extensionRuntimeIDs: Set<String> = []
    private var extensionProviderIdentities: [String: ObjectIdentifier] = [:]
    private var extensionLanguageIdentifiers: [String: String] = [:]
    private var extensionLifecycles: [String: WeakLanguageServerExtensionLifecycle] = [:]
    private let runtimeFactory: (any LanguageProviderRuntimeFactory)?
    private var languageServers: [String: any LanguageServerSession] = [:]
    private var languageServerRoots: [String: URL] = [:]
    private var languageServerWorkspaceFingerprints: [String: String] = [:]
    private var languageServerSessionIdentities: [String: ObjectIdentifier] = [:]
    private var diagnosticsByProviderID: [String: [URL: [LanguageServerDiagnostic]]] = [:]
    private var languageFeatureProviders: [any LanguageFeatureProvider]
    private var languageServerFeatureProviders: [String: LanguageServerFeatureProvider] = [:]
    private let workspaceFingerprintProvider: (LanguageProviderDescriptor, URL) throws -> String?
    private let workspaceStateResetter: ((LanguageProviderDescriptor, URL, String?) throws -> Void)?
    private let workspaceStateCleaner: ((LanguageProviderDescriptor, URL, String?) throws -> Int)?
    private var mavenContextProvider: (LanguageProviderDescriptor, URL) -> MavenLaunchContext? = { _, _ in nil }

    package init(
        catalog: LanguageProviderCatalog = .compatibilityFallback,
        runtimes: [any LanguageProviderRuntime] = [],
        runtimeFactory: (any LanguageProviderRuntimeFactory)? = nil,
        builtinCore: (any BuiltinLanguageFeatureCore)? = nil,
        languageFeatureProviders: [any LanguageFeatureProvider] = [],
        extensionRequiredProviderIDs: Set<String> = [],
        workspaceFingerprintProvider: @escaping (LanguageProviderDescriptor, URL) throws -> String? = { _, _ in nil },
        workspaceStateResetter: ((LanguageProviderDescriptor, URL, String?) throws -> Void)? = nil,
        workspaceStateCleaner: ((LanguageProviderDescriptor, URL, String?) throws -> Int)? = nil
    ) {
        self.catalog = catalog
        self.runtimeFactory = runtimeFactory
        self.extensionRequiredProviderIDs = extensionRequiredProviderIDs
        self.workspaceFingerprintProvider = workspaceFingerprintProvider
        self.workspaceStateResetter = workspaceStateResetter
        self.workspaceStateCleaner = workspaceStateCleaner
        self.languageFeatureProviders = languageFeatureProviders + [
            BuiltinLanguageFeatureProvider(core: builtinCore ?? UnavailableBuiltinLanguageFeatureCore())
        ]
        runtimesByID = Dictionary(uniqueKeysWithValues: runtimes.map { ($0.descriptor.id, $0) })
    }

    package var activeLanguageServerIDs: Set<String> {
        Set(languageServers.compactMap { providerID, session in
            guard session.isRunning,
                  languageServerStates[providerID] == .ready else { return nil }
            return providerID
        })
    }

    package func configureMavenContextProvider(
        _ provider: @escaping (LanguageProviderDescriptor, URL) -> MavenLaunchContext?
    ) {
        mavenContextProvider = provider
    }

    package func updateCatalog(_ catalog: LanguageProviderCatalog) {
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
        languageServerOperationIDs = languageServerOperationIDs.filter {
            validProviderIDs.contains($0.key)
        }
        diagnosticsByProviderID = diagnosticsByProviderID.filter {
            validProviderIDs.contains($0.key)
        }
        rebuildDiagnostics()
        languageServerLogs = languageServerLogs.filter { validProviderIDs.contains($0.providerID) }
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
              !configuration.executableNames.isEmpty,
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
            environment: configuration.environment
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
        rootURL: URL
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
        try session.synchronize(
            fileURL: fileURL,
            text: text,
            languageID: extensionLanguageIdentifiers[descriptor.id]
                ?? descriptor.languageIdentifier(for: fileURL)
        )
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

    package func notifyWorkspaceFilesChanged(
        providerID: String,
        changes: [LanguageServerWorkspaceFileChange]
    ) throws {
        guard !changes.isEmpty,
              let session = languageServers[providerID],
              session.isRunning else { return }
        try session.notifyWorkspaceFilesChanged(changes)
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

    package func clearLanguageServerLogs() {
        languageServerLogs = []
    }

    package func recordLanguageServerLog(
        providerID: String,
        operationID: String? = nil,
        level: LanguageServerLogLevel,
        message: String,
        detail: String? = nil
    ) {
        languageServerLogs.insert(LanguageServerLogEntry(
            providerID: providerID,
            operationID: operationID ?? languageServerOperationIDs[providerID]?.uuidString,
            level: level,
            message: message,
            detail: detail
        ), at: 0)
        if languageServerLogs.count > 100 {
            languageServerLogs.removeLast(languageServerLogs.count - 100)
        }
    }

    package func recordLanguageServerLog(
        providerID: String,
        operationID: UUID,
        level: LanguageServerLogLevel,
        message: String,
        detail: String? = nil
    ) {
        recordLanguageServerLog(
            providerID: providerID,
            operationID: operationID.uuidString,
            level: level,
            message: message,
            detail: detail
        )
    }

    package func stopLanguageServer(providerID: String) {
        let operationID = languageServerOperationIDs[providerID]
        if languageServers[providerID] != nil {
            let wasPreparing = switch languageServerStates[providerID] {
            case .startingProcess, .initializing: true
            default: false
            }
            recordLanguageServerLog(
                providerID: providerID,
                level: wasPreparing ? .warning : .info,
                message: wasPreparing
                    ? "Language server start cancelled"
                    : "Stopping language server",
                detail: nil
            )
        }
        clearDiagnostics(providerID: providerID)
        languageServerSessionIdentities[providerID] = nil
        languageServers.removeValue(forKey: providerID)?.stop()
        languageServerRoots[providerID] = nil
        languageServerWorkspaceFingerprints[providerID] = nil
        languageServerFeatures[providerID] = nil
        languageServerInfos[providerID] = nil
        languageServerFeatureProviders[providerID] = nil
        languageServerStates[providerID] = .stopped
        onLanguageServerStateChange?(
            providerID,
            .stopped,
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
        languageServerWorkspaceFingerprints = [:]
        languageServerSessionIdentities = [:]
        languageServerFeatureProviders = [:]
        languageServerStates = [:]
        languageServerOperationIDs = [:]
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
        let fingerprint: String?
        if languageServerRoots[providerID] == normalizedRoot,
           let activeFingerprint = languageServerWorkspaceFingerprints[providerID] {
            fingerprint = activeFingerprint
        } else {
            fingerprint = try workspaceFingerprintProvider(descriptor, normalizedRoot)
        }
        stopLanguageServer(providerID: providerID)
        try workspaceStateResetter(descriptor, normalizedRoot, fingerprint)
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

    package func javaNavigationMarkers(
        fileURL: URL,
        completion: @escaping (Result<[JavaNavigationMarker], Error>) -> Void
    ) throws {
        guard let session = readyLanguageServerSession(for: fileURL) else {
            throw unavailableLanguageServerError(for: fileURL)
        }
        try session.javaNavigationMarkers(fileURL: fileURL, completion: completion)
    }

    package func resolveJavaNavigation(
        fileURL: URL,
        marker: JavaNavigationMarker,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        guard let session = readyLanguageServerSession(for: fileURL) else {
            throw unavailableLanguageServerError(for: fileURL)
        }
        try session.resolveJavaNavigation(
            fileURL: fileURL,
            marker: marker,
            completion: completion
        )
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
        if let active = languageServers[descriptor.id],
           active.isRunning,
           languageServerRoots[descriptor.id] == rootURL {
            return active
        }

        guard let runtime = runtime(for: descriptor) else {
            throw LanguageToolingSessionError.toolingUnavailable(descriptor.displayName)
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
        let operationID = requestedOperationID ?? UUID()
        languageServerOperationIDs[descriptor.id] = operationID
        recordLanguageServerLog(
            providerID: descriptor.id,
            operationID: operationID,
            level: .info,
            message: "Language server start requested",
            detail: rootURL.path
        )
        recordLanguageServerLog(
            providerID: descriptor.id,
            operationID: operationID,
            level: .info,
            message: "Resolving language server",
            detail: descriptor.languageServerLaunch?.executableNames.joined(separator: ", ")
        )

        guard let created = runtime.makeLanguageServerSession() else {
            let message = runtime.unavailableToolingMessage ?? descriptor.displayName
            let state = LanguageServerSessionState.failed(LanguageServerSessionFailure(
                code: "tool_not_found",
                stage: "discovery",
                message: message
            ))
            languageServerStates[descriptor.id] = state
            recordLanguageServerLog(
                providerID: descriptor.id,
                operationID: operationID,
                level: .error,
                message: "Language server executable was not found",
                detail: message
            )
            onLanguageServerStateChange?(descriptor.id, state, operationID)
            throw LanguageToolingSessionError.toolingUnavailable(message)
        }

        let workspaceFingerprint: String?
        do {
            workspaceFingerprint = try workspaceFingerprintProvider(
                descriptor,
                rootURL
            )
        } catch {
            let state = LanguageServerSessionState.failed(LanguageServerSessionFailure(
                code: "workspace_fingerprint_failed",
                stage: "workspaceFingerprint",
                message: error.localizedDescription
            ))
            languageServerStates[descriptor.id] = state
            recordLanguageServerLog(
                providerID: descriptor.id,
                operationID: operationID,
                level: .error,
                message: "Language server workspace fingerprint failed",
                detail: error.localizedDescription
            )
            onLanguageServerStateChange?(descriptor.id, state, operationID)
            throw error
        }
        if let workspaceFingerprint, let workspaceStateCleaner {
            recordLanguageServerLog(
                providerID: descriptor.id,
                operationID: operationID,
                level: .info,
                message: "Language server cache cleanup started",
                detail: nil
            )
            do {
                let removedCount = try workspaceStateCleaner(
                    descriptor,
                    rootURL,
                    workspaceFingerprint
                )
                recordLanguageServerLog(
                    providerID: descriptor.id,
                    operationID: operationID,
                    level: .info,
                    message: "Language server cache cleanup succeeded",
                    detail: "removedCount=\(removedCount)"
                )
            } catch {
                // Cache maintenance is best-effort and must not prevent the
                // current workspace's language server from starting.
                recordLanguageServerLog(
                    providerID: descriptor.id,
                    operationID: operationID,
                    level: .warning,
                    message: "Language server cache cleanup failed",
                    detail: error.localizedDescription
                )
            }
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
        languageServers[descriptor.id] = created
        languageServerRoots[descriptor.id] = rootURL
        languageServerWorkspaceFingerprints[descriptor.id] = workspaceFingerprint
        configureLanguageServerCallbacks(
            created,
            providerID: descriptor.id,
            sessionIdentity: sessionIdentity
        )
        extensionLifecycles[descriptor.id]?.value?.attach(
            isRunning: { [weak created] in created?.isRunning ?? false },
            stop: { [weak self] in
                self?.stopLanguageServer(providerID: descriptor.id)
            }
        )

        do {
            try created.start(
                rootURL: rootURL,
                workspaceFingerprint: workspaceFingerprint,
                mavenContext: mavenContextProvider(descriptor, rootURL)
            )
        } catch {
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
                recordLanguageServerLog(
                    providerID: descriptor.id,
                    operationID: operationID,
                    level: .error,
                    message: failure.isTimedOut
                        ? "Language server start timed out"
                        : "Language server failed to start",
                    detail: error.localizedDescription
                )
                onLanguageServerStateChange?(descriptor.id, state, operationID)
            }
            throw error
        }

        recordLanguageServerLog(
            providerID: descriptor.id,
            operationID: operationID,
            level: .info,
            message: "Language server session registered",
            detail: rootURL.path
        )
        return created
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
        languageServerWorkspaceFingerprints[providerID] = nil
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
        session.onLog = { [weak self] level, message, detail, operationID in
            self?.recordLanguageServerLog(
                providerID: providerID,
                operationID: operationID,
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
            clearLanguageServerSession(
                providerID: providerID,
                sessionIdentity: sessionIdentity,
                stop: false
            )
            if case .failed(let failure) = state {
                recordLanguageServerLog(
                    providerID: providerID,
                    level: .error,
                    message: failure.isTimedOut
                        ? "Language server start timed out"
                        : "Language server failed",
                    detail: failure.message
                )
            }
        case .startingProcess, .initializing, .stopping:
            languageServerFeatures[providerID] = nil
            languageServerInfos[providerID] = nil
        case .ready:
            languageServerFeatures[providerID] = session.features
            languageServerInfos[providerID] = session.serverInfo
            recordLanguageServerLog(
                providerID: providerID,
                level: .info,
                message: "Language server ready",
                detail: session.serverInfo?.version
            )
        }
        onLanguageServerStateChange?(
            providerID,
            state,
            languageServerOperationIDs[providerID]
        )
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
