import Foundation
import LocalAuthentication
import Security

/// Stores secrets in the current user's macOS Keychain. A legacy store can be
/// supplied so existing installations migrate their locally stored secrets on
/// first use without asking the user to enter them again.
final class MacKeychainSecureStore: SecureStore, @unchecked Sendable {
    enum StoreError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .unexpectedStatus(status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
                return "Keychain error \(status): \(message)"
            }
        }
    }

    private let service: String
    private let legacyStore: (any SecureStore)?

    init(service: String, legacyStore: (any SecureStore)? = nil) {
        self.service = service
        self.legacyStore = legacyStore
    }

    func read(key: String) -> String? {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(baseQuery(key: key).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Credential restoration runs automatically during app startup.
            // A re-signed development or preview build must fail closed instead
            // of presenting a login-Keychain password prompt without a user action.
            kSecUseAuthenticationContext as String: authenticationContext
        ]) { _, new in new } as CFDictionary, &result)

        if status == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        guard status == errSecItemNotFound,
              let value = legacyStore?.read(key: key) else {
            return nil
        }

        // Migration is best-effort. Falling back to the legacy value keeps an
        // existing connection usable even if Keychain is temporarily locked.
        try? write(value, key: key)
        return value
    }

    func write(_ value: String, key: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(key: key)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw StoreError.unexpectedStatus(updateStatus)
        }

        let addStatus = SecItemAdd(query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]) { _, new in new } as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw StoreError.unexpectedStatus(addStatus)
        }
    }

    func delete(key: String) throws {
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.unexpectedStatus(status)
        }
        try legacyStore?.delete(key: key)
    }

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}
