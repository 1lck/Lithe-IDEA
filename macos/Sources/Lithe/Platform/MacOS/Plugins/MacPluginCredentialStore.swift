import Foundation
import LocalAuthentication
import Security

// Note: 插件后端与宿主凭据服务的决策见 .agents/notes/proposed/architecture/2026-10-24-database-provider-plugin.md

/// Plugin credentials in the user's login Keychain. Each plugin gets a
/// Keychain service of its own (`<bundle>.plugin-credentials.<pluginID>`),
/// so one query removes everything a plugin stored and no key a plugin
/// chooses can reach another plugin's items. Nothing is written into the
/// plugin package, its state directory, or the app bundle.
final class MacPluginCredentialStore: PluginCredentialStoring, @unchecked Sendable {
    enum StoreError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
                return "Keychain error \(status): \(message)"
            }
        }
    }

    private let servicePrefix: String

    /// - Parameter servicePrefix: the app's Keychain service for plugin
    ///   credentials; the plugin ID is appended per plugin.
    init(servicePrefix: String) {
        self.servicePrefix = servicePrefix
    }

    func secret(pluginID: String, key: String) throws -> String? {
        // A backend asks without a user action in front of it, so a locked
        // or re-signed Keychain fails instead of showing a password prompt.
        let context = LAContext()
        context.interactionNotAllowed = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(pluginID: pluginID, key: key).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]) { _, new in new } as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw StoreError.unexpectedStatus(status)
        }
    }

    func setSecret(_ secret: String, pluginID: String, key: String) throws {
        let data = Data(secret.utf8)
        let query = query(pluginID: pluginID, key: key)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw StoreError.unexpectedStatus(updateStatus) }
        let addStatus = SecItemAdd(query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]) { _, new in new } as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw StoreError.unexpectedStatus(addStatus) }
    }

    func deleteSecret(pluginID: String, key: String) throws {
        try delete(query(pluginID: pluginID, key: key))
    }

    func deleteAll(pluginID: String) throws {
        try delete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(pluginID: pluginID)
        ])
    }

    private func delete(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.unexpectedStatus(status)
        }
    }

    private func service(pluginID: String) -> String {
        "\(servicePrefix).\(pluginID)"
    }

    private func query(pluginID: String, key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(pluginID: pluginID),
            kSecAttrAccount as String: key
        ]
    }
}
