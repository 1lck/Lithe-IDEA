import Foundation
import LitheCoreContracts
import LitheModuleAPI
import LitheLanguageIntelligenceModule

// Note: 插件自有语言服务器会话与宿主方法的决策见 .agents/notes/implemented/architecture/2026-11-04-plugin-owned-language-server-sessions.md

/// The language server sessions of one window, as the `languageServer` host
/// service reaches them. The session manager implements it; the service never
/// sees a session, so it cannot reach a server the manager did not hand out.
@MainActor
protocol PluginLanguageServerRouting: AnyObject {
    func requestPluginServer(
        pluginID: String, serverID: String, method: String, params: ToolingJSONValue, timeout: TimeInterval?
    ) async -> Result<ToolingJSONValue, PluginHostRequestFailure>

    func notifyPluginServer(
        pluginID: String, serverID: String, method: String, params: ToolingJSONValue
    ) async -> Result<Bool, PluginHostRequestFailure>

    func setPluginServerStatus(
        _ status: PluginServerStatus, serverID: String, pluginID: String
    ) -> Result<Void, PluginHostRequestFailure>
}

extension LanguageToolingSessionManager: PluginLanguageServerRouting {}

/// `lithe/host/languageServer/request`, `notify` and `setStatus` (plan
/// API-25): a plugin backend talks to the language servers its own plugin
/// declares.
///
/// The service only finds the window's session and passes the call on. Rust
/// Core decides whether the server belongs to the plugin, whether the method
/// or command is declared, and enforces gates, serialization and timeouts;
/// its answer reaches the backend unchanged.
@MainActor
final class PluginLanguageServerHostService: PluginHostServiceHandling {
    private enum Method {
        static let request = "lithe/host/languageServer/request"
        static let notify = "lithe/host/languageServer/notify"
        static let setStatus = "lithe/host/languageServer/setStatus"
    }

    let service = "languageServer"
    let methods: Set<String> = [Method.request, Method.notify, Method.setStatus]
    private let contexts: PluginWorkspaceContexts

    init(contexts: PluginWorkspaceContexts) { self.contexts = contexts }

    func answer(_ call: PluginHostCall) async -> Result<ToolingJSONValue, PluginHostServiceError> {
        do {
            let scope = try PluginHostAPIContext(call, contexts: contexts)
            guard let servers = scope.window.hostLanguageServers else { throw Self.unavailable }
            switch call.request.method {
            case Method.request: return .success(try await request(call, on: servers))
            case Method.notify: return .success(try await notify(call, on: servers))
            case Method.setStatus: return .success(try setStatus(call, on: servers))
            default: throw PluginHostArguments.invalid
            }
        } catch {
            var failure = PluginHostAPIValues.failure(error)
            failure.logError = error
            return .failure(failure)
        }
    }

    private func request(_ call: PluginHostCall, on servers: any PluginLanguageServerRouting) async throws
        -> ToolingJSONValue {
        let arguments = try PluginHostArguments(
            call.params, allowed: ["context", "serverID", "method", "params", "timeoutMilliseconds"]
        )
        let outcome = await servers.requestPluginServer(
            pluginID: call.pluginID,
            serverID: try arguments.string("serverID"),
            method: try arguments.string("method"),
            params: try Self.serverParams(arguments),
            timeout: try Self.timeout(arguments)
        )
        return .object(["value": try Self.value(of: outcome)])
    }

    private func notify(_ call: PluginHostCall, on servers: any PluginLanguageServerRouting) async throws
        -> ToolingJSONValue {
        let arguments = try PluginHostArguments(call.params, allowed: ["context", "serverID", "method", "params"])
        let outcome = await servers.notifyPluginServer(
            pluginID: call.pluginID,
            serverID: try arguments.string("serverID"),
            method: try arguments.string("method"),
            params: try Self.serverParams(arguments)
        )
        return .object(["delivered": .bool(try Self.value(of: outcome))])
    }

    private func setStatus(_ call: PluginHostCall, on servers: any PluginLanguageServerRouting) throws
        -> ToolingJSONValue {
        let arguments = try PluginHostArguments(
            call.params, allowed: ["context", "serverID", "state", "message", "percentage"]
        )
        let outcome = servers.setPluginServerStatus(
            try Self.status(arguments), serverID: try arguments.string("serverID"), pluginID: call.pluginID
        )
        _ = try Self.value(of: outcome)
        return .object([:])
    }

    // MARK: Params

    /// The JSON-RPC params; an object, `{}` when the backend sent none.
    private static func serverParams(_ arguments: PluginHostArguments) throws -> ToolingJSONValue {
        guard arguments.values["params"] != nil else { return .object([:]) }
        return .object(try arguments.object("params"))
    }

    private static func timeout(_ arguments: PluginHostArguments) throws -> TimeInterval? {
        guard arguments.values["timeoutMilliseconds"] != nil else { return nil }
        let milliseconds = try arguments.integer("timeoutMilliseconds")
        guard (1...300_000).contains(milliseconds) else { throw PluginHostArguments.invalid }
        return TimeInterval(milliseconds) / 1000
    }

    private static func status(_ arguments: PluginHostArguments) throws -> PluginServerStatus {
        guard let state = PluginServerStatus.State(rawValue: try arguments.string("state")) else {
            throw PluginHostArguments.invalid
        }
        var percentage: Int?
        if arguments.values["percentage"] != nil {
            percentage = try arguments.integer("percentage")
            guard (0...100).contains(percentage ?? 0) else { throw PluginHostArguments.invalid }
        }
        return PluginServerStatus(state: state, message: try arguments.optionalString("message"), percentage: percentage)
    }

    // MARK: Outcomes

    /// A window whose language capability is not loaded runs no server.
    private static var unavailable: PluginHostServiceError {
        PluginHostServiceError(.languageServerUnavailable, L10n.string("The language server is not running."))
    }

    /// The value of a session's answer, or its failure in the backend's shape.
    private static func value<Value>(of outcome: Result<Value, PluginHostRequestFailure>) throws -> Value {
        switch outcome {
        case .success(let value):
            return value
        case .failure(let failure):
            throw PluginHostServiceError(failure)
        }
    }
}
