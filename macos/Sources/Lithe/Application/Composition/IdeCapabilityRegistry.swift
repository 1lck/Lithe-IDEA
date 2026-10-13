import Foundation
import LitheModuleAPI

/// Keeps plugin callers bound to an explicitly enabled workspace, never the focused window.
@MainActor
final class IdeCapabilityRegistry: IDECapabilitiesProviding {
    private struct Entry { weak var feature: IdeCapabilitiesFeatureModel? }
    private var entries: [String: Entry] = [:]

    func register(_ feature: IdeCapabilitiesFeatureModel, workspaceID: String) {
        entries[workspaceID] = Entry(feature: feature)
    }
    func unregister(workspaceID: String) { entries[workspaceID] = nil }
    func authorizedWorkspaceIDs() -> [String] {
        entries.filter { $0.value.feature?.isEnabled == true }.keys.sorted()
    }
    func call(workspaceID: String, name: String, argumentsJSON: String) async -> String {
        let result: [String: Any]
        if let feature = entries[workspaceID]?.feature,
           argumentsJSON.utf8.count <= 65_536,
           let data = argumentsJSON.data(using: .utf8),
           let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            result = await feature.call(name, arguments: args)
        } else {
            result = ["error": ["code": "UNAVAILABLE", "message": "Select an authorized project and supply valid JSON arguments"]]
        }
        do { return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self) }
        catch { return "{\"error\":{\"code\":\"ENCODING_FAILED\",\"message\":\"Could not encode IDE result\"}}" }
    }
}
