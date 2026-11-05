import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule

// Note: 插件自有语言服务器会话与宿主方法的决策见 .agents/notes/implemented/architecture/2026-11-04-plugin-owned-language-server-sessions.md

extension AppModel {
    /// Delivers what happens to plugin-owned language servers to the owning
    /// plugin's backend: the server's state changes and the notifications its
    /// manifest forwards (plan API-25). The backend names this window by its
    /// workspace context, so one backend can serve several windows.
    func bindPluginLanguageServers(_ relay: PluginLanguageServerRelay) {
        relay.onStateChange = { [weak self] change in
            self?.notifyPluginBackend(
                pluginID: change.pluginID,
                method: "lithe/host/languageServer/didChangeState",
                members: [
                    "serverID": .string(change.serverID),
                    "state": .string(change.state.rawValue),
                    "generation": .integer(change.generation),
                ]
            )
        }
        relay.onNotification = { [weak self] received in
            var members: [String: ToolingJSONValue] = [
                "serverID": .string(received.serverID),
                "generation": .integer(received.generation),
                "method": .string(received.notification.method),
            ]
            if let params = received.notification.params { members["params"] = params }
            if received.notification.truncated { members["truncated"] = .bool(true) }
            self?.notifyPluginBackend(
                pluginID: received.pluginID,
                method: "lithe/host/languageServer/didReceiveNotification",
                members: members
            )
        }
    }

    private func notifyPluginBackend(pluginID: String, method: String, members: [String: ToolingJSONValue]) {
        guard let context = pluginWebWorkspaceContext else { return }
        var params = members
        params["context"] = .object([
            "contextID": .string(context.contextID),
            "generation": .integer(context.generation),
        ])
        services.pluginBackendActivation?.notifyLanguageServer(
            pluginID: pluginID, method: method, params: .object(params)
        )
    }
}
