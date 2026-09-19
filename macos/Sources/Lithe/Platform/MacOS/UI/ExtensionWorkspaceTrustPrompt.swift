import AppKit
import Foundation

/// The decision applies to one host activation, never to an arbitrary parent directory.
@MainActor
final class ExtensionWorkspaceTrustPrompt {
    private var alert: NSAlert?
    private weak var parent: NSWindow?
    private var cancelled = false

    func present(_ workspace: URL) async -> Bool {
        guard !cancelled, !Task.isCancelled, let window = NSApp.keyWindow,
              window.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.messageText = String(localized: "Trust this workspace for Java extensions?")
        alert.informativeText = String(format: String(localized:
            "Java extensions can run build scripts and other tools from %@. Continue only if you trust this project's source."),
            workspace.path)
        alert.addButton(withTitle: String(localized: "Trust and Enable"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        self.alert = alert
        parent = window
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        self.alert = nil
        parent = nil
        return !cancelled && !Task.isCancelled && response == .alertFirstButtonReturn
    }

    func cancel() {
        cancelled = true
        if let alert, let parent { parent.endSheet(alert.window, returnCode: .cancel) }
    }
}
