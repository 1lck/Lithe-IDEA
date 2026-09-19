import Foundation
import LitheCoreContracts
import LitheModuleAPI

package struct ExtensionHostLaunchConfiguration: Sendable {
    package let node: URL
    package let entrypoint: URL
    package let workspace: URL
    package let environment: [String: String]

    package init(node: URL, entrypoint: URL, workspace: URL, environment: [String: String]) {
        self.node = node
        self.entrypoint = entrypoint
        self.workspace = workspace
        self.environment = environment
    }
}

@MainActor
package protocol ExtensionHostProcessTransport: ExtensionHostTransport {
    var onOutput: ((Data) -> Void)? { get set }
    var onDiagnostic: ((Data) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }
    var isRunning: Bool { get }
    func start(_ configuration: ExtensionHostLaunchConfiguration) throws
    func stop() async -> Bool
}

/// A single workspace host generation, registered with its owning module's resource scope.
/// Re-activation constructs a new session, so callbacks from old hosts cannot mutate it.
@MainActor
package final class ExtensionHostSession: ModuleResource {
    package enum State: Equatable {
        case idle, starting, ready, stopping, stopped
        case failed(String)
    }

    package let moduleResourceKind = "vscode-extension-host"
    package private(set) var state: State = .idle
    package let connection: ExtensionHostConnection
    package var onDiagnostic: ((String) -> Void)?
    package var onLanguageProviderRegistered: ((String, Int, Set<String>) -> Void)?
    package var onLanguageProviderUnregistered: ((Int) -> Void)?
    package var onDiagnosticsChanged: ((String, ToolingJSONValue) -> Void)?
    package var onInvalidated: (() -> Void)?
    package var onStopped: (() -> Void)?
    package var onDiagnosticsCleared: ((String) -> Void)?
    private let transport: any ExtensionHostProcessTransport
    private var shutdownTask: Task<Bool, Never>?
    private var cleanupFailed = false

    package init(transport: any ExtensionHostProcessTransport) {
        self.transport = transport
        connection = ExtensionHostConnection(transport: transport)
        transport.onOutput = { [weak self] bytes in
            guard let self else { return }
            if bytes.isEmpty { self.connection.close() }
            else { self.connection.receive(bytes) }
        }
        transport.onDiagnostic = { [weak self] bytes in
            self?.onDiagnostic?(String(decoding: bytes, as: UTF8.self))
        }
        transport.onExit = { [weak self] status in
            guard let self else { return }
            if self.state == .starting || self.state == .ready {
                self.state = .failed("Extension host exited with status \(status).")
                _ = self.requestStop()
            }
            self.connection.close()
        }
        connection.onClosed = { [weak self] in
            guard let self else { return }
            self.onInvalidated?()
            // EOF or a broken pipe can precede process exit indefinitely. Own the
            // remaining process group instead of waiting for an exit callback.
            if self.state == .starting || self.state == .ready {
                self.state = .failed("Extension host protocol connection closed.")
                _ = self.requestStop()
            }
        }
        connection.onDiagnostic = { [weak self] message in self?.onDiagnostic?(message) }
        connection.onNotification = { [weak self] method, value in self?.handleNotification(method, value) }
    }

    package var isModuleResourceActive: Bool {
        cleanupFailed || transport.isRunning || state == .starting || state == .stopping
    }

    package func start(
        _ configuration: ExtensionHostLaunchConfiguration,
        initialize: ToolingJSONValue
    ) async throws -> ToolingJSONValue {
        guard state == .idle else {
            throw ExtensionHostFailure("alreadyInitialized", "Host generation has already been started.")
        }
        state = .starting
        do {
            try transport.start(configuration)
            let result = try await connection.request("host/initialize", params: initialize)
            guard state == .starting else {
                throw ExtensionHostFailure("shuttingDown", "Host stopped during initialization.")
            }
            guard case .object(let values) = result, values["protocolVersion"] == .integer(1) else {
                throw ExtensionHostFailure("invalidParams", "Extension host protocol version does not match.")
            }
            if case .array(let failures)? = values["failedExtensions"], !failures.isEmpty {
                throw ExtensionHostFailure("notInitialized", "One or more bundled extensions could not be loaded. Check the extension host log and reinstall the runtime resources.")
            }
            state = .ready
            return result
        } catch {
            connection.close()
            _ = await stop()
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    private func handleNotification(_ method: String, _ value: ToolingJSONValue) {
        guard case .object(let fields) = value else { return }
        switch method {
        case "lithe/languageProviderRegistered":
            guard case .string(let kind)? = fields["kind"], case .integer(let handle)? = fields["handle"] else { return }
            var languages = Set<String>()
            if case .array(let selectors)? = fields["selector"] {
                for selector in selectors { if case .object(let object) = selector, case .string(let language)? = object["language"] { languages.insert(language) } }
            }
            onLanguageProviderRegistered?(kind, handle, languages)
        case "lithe/languageProviderUnregistered":
            if case .integer(let handle)? = fields["handle"] { onLanguageProviderUnregistered?(handle) }
        case "lithe/diagnosticsChanged":
            if case .string(let id)? = fields["id"] { onDiagnosticsChanged?(id, fields["delta"] ?? .null) }
        case "lithe/diagnosticsCleared":
            if case .string(let id)? = fields["id"] { onDiagnosticsCleared?(id) }
        default: break
        }
    }

    package func provideLanguageFeature(kind: String, handle: Int, uri: String, line: Int, character: Int) async throws -> ToolingJSONValue {
        try await connection.request("host/provideLanguageFeature", params: .object([
            "kind": .string(kind), "handle": .integer(handle), "uri": .string(uri), "line": .integer(line), "character": .integer(character)
        ]))
    }

    package func stopModuleResource() async { _ = await stop() }

    /// Coalesces simultaneous module shutdown and workspace-close requests.
    @discardableResult
    package func stop() async -> Bool { await requestStop().value }

    /// Starts owned cleanup synchronously, allowing non-async workspace-close
    /// callers to invalidate providers immediately while module teardown awaits it.
    @discardableResult
    package func requestStop() -> Task<Bool, Never> {
        if let shutdownTask { return shutdownTask }
        if state == .stopped { return Task { true } }
        let graceful = state == .ready
        state = .stopping
        onInvalidated?()
        let task = Task { [self] in
            if graceful {
                do {
                    _ = try await connection.request("host/shutdown", params: .object([
                        "timeoutMilliseconds": .integer(1000)
                    ]), timeout: .seconds(8))
                } catch {
                    onDiagnostic?("Extension host shutdown handshake failed: \(error.localizedDescription)")
                }
            }
            connection.close()
            let stopped = await transport.stop()
            cleanupFailed = !stopped
            state = stopped ? .stopped : .failed("Extension host process group did not stop before its deadline.")
            if stopped { onStopped?() }
            shutdownTask = nil
            return stopped
        }
        shutdownTask = task
        return task
    }
}
