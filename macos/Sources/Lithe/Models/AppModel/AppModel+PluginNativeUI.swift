import Foundation
import LitheCoreContracts
import LitheModuleAPI

extension AppModel {
    func releaseNativeUIFeature(_ feature: PluginNativeUIFeature, windowID: String) {
        services.pluginWebPages.releaseNative(feature, windowID: windowID)
    }

    func makeNativeUIFeature(_ contribution: ModuleContribution, declaration: PluginNativeUI) throws -> PluginNativeUIFeature {
        guard let workspace = workspaceURL?.standardizedFileURL else {
            throw PluginWebBridgeFailure.unavailable("Open a workspace before opening this plugin panel.")
        }
        guard let validateNodes = services.validatePluginNativeUI else {
            throw PluginWebBridgeFailure.unavailable("Native plugin UI validation is unavailable.")
        }
        guard let owner = services.pluginCatalog.manifests.first(where: {
            $0.modules.contains { $0.contributions.contains(contribution) }
        }) else {
            throw PluginWebBridgeFailure.unavailable("The plugin panel has no registered owner.")
        }
        let context = PluginUIRequestContext(pluginID: owner.id.rawValue, pluginName: owner.displayName,
            windowID: contribution.id, buildSystemIDs: Set(declaration.source.map { [$0.buildSystemID] } ?? []))
        let store = services.pluginWebPages.stateStore
        let bridge = PluginWebBridge(context: context, host: self, stateStore: store)
        let saved = store.state(pluginID: context.pluginID, windowID: context.windowID, workspaceURL: workspace)
        let state = saved.flatMap { $0.count <= PluginWebBridge.stateLimit ? $0 : nil }.flatMap { data in
            do { return try JSONDecoder().decode(PluginNativeUIFeature.State.self, from: data) }
            catch {
                services.logSink?.emit(AppSettingsDecodeFailed(error: error, stage: "plugin-native-ui"))
                return nil
            }
        } ?? .init()
        let feature = PluginNativeUIFeature(declaration: declaration, state: state, validateNodes: validateNodes, request: { [weak self] method, params in
            guard let self, self.workspaceURL?.standardizedFileURL == workspace,
                  self.workbenchContributions.contains(contribution),
                  self.pluginSnapshots.contains(where: { $0.id.rawValue == context.pluginID && $0.isEnabled && !$0.requiresRestart }) else {
                throw PluginWebBridgeFailure.forbidden("The plugin window is no longer available.")
            }
            return try await bridge.handle(method: method, params: params)
        }, close: { bridge.close() }, saveState: { [weak self] state in
            guard let self, self.workspaceURL?.standardizedFileURL == workspace else { return }
            do {
                let data = try JSONEncoder().encode(state)
                guard data.count <= PluginWebBridge.stateLimit else {
                    throw PluginWebBridgeFailure.invalidRequest("The native panel state exceeds 64 KiB.")
                }
                try store.setState(data, pluginID: context.pluginID, windowID: context.windowID, workspaceURL: workspace)
            } catch { self.showNotification(error.localizedDescription, logReference: self.notificationFailure(error, operation: "plugin_native_ui")) }
        })
        guard services.pluginWebPages.registerNative(feature, windowID: contribution.id, pluginID: context.pluginID) else {
            feature.close()
            throw PluginWebBridgeFailure.unavailable("The plugin panel is disabled or already registered.")
        }
        return feature
    }
}
