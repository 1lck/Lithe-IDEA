import Foundation

/// Receives the app's custom URL scheme and retains an early callback until a
/// community authorization workflow installs its handler.
@MainActor
final class MacExternalAuthorizationCallbackRouter: ExternalAuthorizationCallbackRouting {
    private var handlers: [@MainActor (URL) -> Void] = []
    private var pendingURL: URL?

    func installHandler(_ handler: @escaping @MainActor (URL) -> Void) {
        handlers.append(handler)
        guard let pendingURL else { return }
        self.pendingURL = nil
        handler(pendingURL)
    }

    func route(_ url: URL) {
        guard url.scheme?.lowercased() == "lithe",
              url.host?.lowercased() == "auth",
              url.path == "/linux-do" else { return }
        guard !handlers.isEmpty else {
            pendingURL = url
            return
        }
        handlers.forEach { $0(url) }
    }
}
