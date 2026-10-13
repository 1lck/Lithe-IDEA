import Foundation
import LitheCoreContracts

@MainActor
final class MacIdeHostTransport: IdeHostTransport {
    private let core: RustCoreBridge
    private let storage: any FileStorage

    init(core: RustCoreBridge, storage: any FileStorage) {
        self.core = core
        self.storage = storage
    }

    func open(workspace: URL, permissions: [String: Bool]) throws -> [String: Any] {
        // Only the connection descriptor is writable. The signed helper remains in the bundle.
        let directory = storage.applicationSupportDirectory().appendingPathComponent("mcp", isDirectory: true)
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lithe-mcp")
        return try control("open", arguments: [
            "directory": directory.path, "helperPath": helper.path,
            "workspaceKey": workspace.standardizedFileURL.path, "permissions": permissions
        ])
    }

    func control(_ action: String, arguments: [String: Any]) throws -> [String: Any] {
        guard let payload = ToolingJSONValue.fromFoundation(["action": action, "arguments": arguments]) else {
            throw NSError(domain: "IdeHost", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid IDE API request"])
        }
        let result: Result<ToolingJSONValue, RustCoreBridge.CoreCallError> = core.executeResult(command: "ideHost.control", payload: payload)
        guard let object = try result.get().foundationObject as? [String: Any] else {
            throw NSError(domain: "IdeHost", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid IDE API response"])
        }
        return object
    }
}
