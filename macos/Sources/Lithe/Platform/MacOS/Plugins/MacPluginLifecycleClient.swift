import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Native handles stay in their adapters; Core owns operation and resource state.
final class MacPluginLifecycleClient {
    struct Snapshot: Decodable {
        struct Lifecycle: Decodable {
            let pluginId: String
            let state: String
            let generation: UInt64
            let resources: [String]
        }
        let lifecycle: Lifecycle
        let operationId: String?
        let installed: Bool
    }

    private let ownerID = UUID().uuidString
    private let core = RustCoreBridge()

    @discardableResult
    func restore(_ id: PluginID, installed: Bool, enabled: Bool = false) throws -> Snapshot {
        try request(id, action: "restore", fields: ["installed": .bool(installed), "enabled": .bool(enabled)])
    }

    func snapshot(_ id: PluginID) throws -> Snapshot {
        try request(id, action: "snapshot")
    }

    @discardableResult
    func transition(_ id: PluginID, _ action: String, operationID: String) throws -> Snapshot {
        try request(id, action: "transition", fields: [
            "transition": .string(action), "operationId": .string(operationID)
        ])
    }

    func bind(_ id: PluginID, resourceID: String) throws {
        _ = try request(id, action: "bindResource", fields: ["resourceId": .string(resourceID)])
    }

    func release(_ id: PluginID, resourceID: String) throws {
        _ = try request(id, action: "releaseResource", fields: ["resourceId": .string(resourceID)])
    }

    func transaction<T>(_ id: PluginID, begin: String, complete: String, body: () throws -> T) throws -> T {
        let operationID = UUID().uuidString
        try transition(id, begin, operationID: operationID)
        do {
            let result = try body()
            try transition(id, complete, operationID: operationID)
            return result
        } catch {
            do { try transition(id, "fail", operationID: operationID) }
            catch { NSLog("Plugin lifecycle failure could not be committed: %@", error.localizedDescription) }
            throw error
        }
    }

    private func request(_ id: PluginID, action: String, fields: [String: ToolingJSONValue] = [:]) throws -> Snapshot {
        var payload = fields
        payload["ownerId"] = .string(ownerID)
        payload["pluginId"] = .string(id.rawValue)
        payload["action"] = .string(action)
        return try core.executeResult(command: "plugin.session", payload: payload).get()
    }
}

/// A module lease covers its pending activation and every child it owns. Release
/// follows ModuleResourceScope's confirmed shutdown, including failed activations.
@MainActor
final class MacPluginModuleOwnership: ModuleActivationOwnership {
    private let client: MacPluginLifecycleClient
    private let owners: [ModuleID: PluginID]

    init(client: MacPluginLifecycleClient, manifests: [PluginManifest]) {
        self.client = client
        owners = Dictionary(uniqueKeysWithValues: manifests.flatMap { manifest in
            manifest.modules.map { ($0.manifest.id, manifest.id) }
        })
    }

    func acquire(_ moduleID: ModuleID) throws {
        guard let pluginID = owners[moduleID] else { return }
        let snapshot = try client.restore(pluginID, installed: true)
        if ["installed", "disabled"].contains(snapshot.lifecycle.state) {
            let operationID = UUID().uuidString
            try client.transition(pluginID, "enable", operationID: operationID)
            try client.transition(pluginID, "completeEnable", operationID: operationID)
        }
        try client.bind(pluginID, resourceID: moduleID.rawValue)
    }

    func release(_ moduleID: ModuleID) throws {
        guard let pluginID = owners[moduleID] else { return }
        try client.restore(pluginID, installed: true)
        try client.release(pluginID, resourceID: moduleID.rawValue)
    }
}
