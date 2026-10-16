import Foundation

/// Distribution identity is stamped before signing, never derived from an update
/// preference. Stable retains its historical paths and Keychain services.
struct MacAppIdentity: Sendable {
    let isDevelopment: Bool

    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        isDevelopment = bundleIdentifier == "app.lithe.desktop.dev"
    }

    var bundleIdentifier: String { isDevelopment ? "app.lithe.desktop.dev" : "app.lithe.desktop" }

    /// Mutable per-user state belongs outside the signed bundle. Existing callers
    /// append their own Lithe subdirectory; only development gains this root.
    func storageRoot(_ base: URL) -> URL {
        isDevelopment ? base.appendingPathComponent(bundleIdentifier, isDirectory: true) : base
    }

    func keychainService(_ purpose: String) -> String { "\(bundleIdentifier).\(purpose)" }
}
