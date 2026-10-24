import Foundation
import LitheCoreContracts

// Note: 插件后端与宿主凭据服务的决策见 .agents/notes/implemented/architecture/2026-10-24-database-provider-plugin.md

/// Secrets plugin backends store through the `credentials` host service.
/// Every entry belongs to one plugin ID: a plugin can never name another
/// plugin's entries, and the host's own secrets live in other stores.
protocol PluginCredentialStoring: Sendable {
    func secret(pluginID: String, key: String) throws -> String?
    func setSecret(_ secret: String, pluginID: String, key: String) throws
    /// Succeeds when nothing is stored under the key.
    func deleteSecret(pluginID: String, key: String) throws
    /// Removes everything the plugin stored, when it is uninstalled.
    func deleteAll(pluginID: String) throws
}

/// Performs the host services of plugin function protocol 2 for one
/// plugin. Core has already checked the method, the grant, and the params;
/// this maps them onto the host's stores and never puts a secret in a
/// failure message, which reaches the backend.
enum PluginHostServices {
    static func answer(
        _ request: PluginHostRequest,
        pluginID: String,
        credentials: any PluginCredentialStoring
    ) -> Result<ToolingJSONValue, PluginHostRequestFailure> {
        guard request.service == "credentials",
              case .object(let params) = request.params,
              case .string(let key)? = params["key"] else {
            return .failure(PluginHostRequestFailure(message: "The host does not serve \(request.method)."))
        }
        do {
            switch request.method {
            case "lithe/host/credentials/get":
                let secret = try credentials.secret(pluginID: pluginID, key: key)
                return .success(.object(["secret": secret.map(ToolingJSONValue.string) ?? .null]))
            case "lithe/host/credentials/set":
                guard case .string(let secret)? = params["secret"] else {
                    return .failure(PluginHostRequestFailure(message: "The request has no secret."))
                }
                try credentials.setSecret(secret, pluginID: pluginID, key: key)
                return .success(.null)
            case "lithe/host/credentials/delete":
                try credentials.deleteSecret(pluginID: pluginID, key: key)
                return .success(.null)
            default:
                return .failure(PluginHostRequestFailure(message: "The host does not serve \(request.method)."))
            }
        } catch {
            return .failure(PluginHostRequestFailure(
                message: "The credential store failed: \(error.localizedDescription)"
            ))
        }
    }
}

/// Process-lifetime store for tests and hosts without a secret store.
final class MemoryPluginCredentialStore: PluginCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String: String]] = [:]

    func secret(pluginID: String, key: String) throws -> String? {
        lock.withLock { values[pluginID]?[key] }
    }

    func setSecret(_ secret: String, pluginID: String, key: String) throws {
        lock.withLock { values[pluginID, default: [:]][key] = secret }
    }

    func deleteSecret(pluginID: String, key: String) throws {
        lock.withLock { _ = values[pluginID]?.removeValue(forKey: key) }
    }

    func deleteAll(pluginID: String) throws {
        lock.withLock { _ = values.removeValue(forKey: pluginID) }
    }
}
