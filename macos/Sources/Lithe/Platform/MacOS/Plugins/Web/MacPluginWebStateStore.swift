import AppKit
import Foundation

/// `ui.setState` values in Application Support, beside the plugin's other
/// state: `PluginState/<plugin>/web-state/<window>/<workspace digest>.json`.
/// The plugin owns them; removing the plugin's state removes them too.
@MainActor
final class MacPluginWebStateStore: PluginWebStateStoring {
    private let directories: MacPluginStateDirectories
    private let fileStorage: any FileStorage

    init(directories: MacPluginStateDirectories, fileStorage: any FileStorage) {
        self.directories = directories
        self.fileStorage = fileStorage
    }

    func state(pluginID: String, windowID: String, workspaceURL: URL) -> Data? {
        guard let url = try? fileURL(pluginID: pluginID, windowID: windowID, workspaceURL: workspaceURL),
              fileStorage.fileExists(at: url),
              let data = try? fileStorage.readPrefix(from: url, byteCount: PluginWebBridge.stateLimit + 1),
              data.count <= PluginWebBridge.stateLimit else { return nil }
        return data
    }

    func setState(_ data: Data?, pluginID: String, windowID: String, workspaceURL: URL) throws {
        guard (data?.count ?? 0) <= PluginWebBridge.stateLimit else { throw CocoaError(.fileWriteOutOfSpace) }
        let url = try fileURL(pluginID: pluginID, windowID: windowID, workspaceURL: workspaceURL)
        guard let data else {
            if fileStorage.fileExists(at: url) { try fileStorage.removeItem(at: url) }
            return
        }
        try fileStorage.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileStorage.writeData(data, to: url, options: .atomic)
    }

    private func fileURL(pluginID: String, windowID: String, workspaceURL: URL) throws -> URL {
        // Core restricts both IDs to this alphabet; anything else never names a path.
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-_")
        guard [pluginID, windowID].allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy(allowed.contains) }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return directories.pluginDirectory(pluginID: pluginID)
            .appendingPathComponent("web-state", isDirectory: true)
            .appendingPathComponent(windowID, isDirectory: true)
            .appendingPathComponent(MacPluginStateDirectories.workspaceDigest(workspaceURL) + ".json")
    }
}

/// Asks before a plugin page starts a build tool.
enum MacPluginWebConsentPrompt {
    @MainActor
    static func confirm(_ consent: PluginWebProcessConsent) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: String(localized: "Allow “%@” to run build tools?"), consent.pluginName)
        var details = [
            consent.action,
            String(format: String(localized: "The plugin’s page asks to run them in %@."), consent.workspaceURL.lastPathComponent)
        ]
        if consent.userArguments.isEmpty {
            details.append(String(localized: "Lithe asks again after the plugin is disabled, updated, or Lithe restarts."))
        } else {
            details.append(String(localized: "Arguments from the page:") + "\n" + consent.userArguments.joined(separator: " "))
        }
        alert.informativeText = details.joined(separator: "\n\n")
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Don’t Allow"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
