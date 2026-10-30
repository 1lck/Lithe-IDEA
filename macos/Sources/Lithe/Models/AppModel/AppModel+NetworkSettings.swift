import Foundation
import LitheModuleAPI

/// Network settings page support: the proxy password lives in the Keychain
/// and the connectivity check runs through the platform tester, so the page
/// reaches both through the application model.
@MainActor
extension AppModel {
    /// Persists the custom proxy password and refreshes the live snapshot.
    /// Returns a user-facing message when the Keychain write fails; an empty
    /// password clears a saved one.
    @discardableResult
    func saveNetworkProxyPassword(_ password: String) -> String? {
        guard let store = services.proxyPasswordStore else {
            return L10n.string("Proxy credentials cannot be saved in this build.")
        }
        do {
            if password.isEmpty {
                try store.delete(key: AppSettings.networkProxyPasswordKey)
            } else {
                let credential = NetworkProxyCredential(
                    identity: NetworkProxyIdentity(configuration: settings.networkProxyPreferences.snapshot),
                    password: password
                )
                try credential.save(to: store, key: AppSettings.networkProxyPasswordKey)
                settings.updateNetworkProxyCredential(credential)
                return nil
            }
            settings.updateNetworkProxyCredential(nil)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Whether the platform can check a proxy connection; the settings page
    /// hides the test button otherwise.
    var supportsProxyConnectionCheck: Bool {
        services.proxyConnectionChecker != nil
    }

    /// Runs the bounded connectivity check through the drafted proxy values.
    func checkProxyConnection(configuration: NetworkProxyConfiguration) async -> NetworkProxyCheckOutcome? {
        guard let checker = services.proxyConnectionChecker else { return nil }
        return await checker.check(configuration: configuration)
    }
}
