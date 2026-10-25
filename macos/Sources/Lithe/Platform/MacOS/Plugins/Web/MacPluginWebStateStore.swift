import AppKit
import Foundation
import LitheModuleAPI
import UniformTypeIdentifiers

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
        alert.messageText = String(format: L10n.string("Allow “%@” to run build tools?"), consent.pluginName)
        var details = [
            consent.action,
            String(format: L10n.string("The plugin’s page asks to run them in %@."), consent.workspaceURL.lastPathComponent)
        ]
        if consent.userArguments.isEmpty {
            details.append(L10n.string("Lithe asks again after the plugin is disabled, updated, or Lithe restarts."))
        } else {
            details.append(L10n.string("Arguments from the page:") + "\n" + consent.userArguments.joined(separator: " "))
        }
        alert.informativeText = details.joined(separator: "\n\n")
        alert.addButton(withTitle: L10n.string("Allow"))
        alert.addButton(withTitle: L10n.string("Don’t Allow"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// The file dialogs a plugin page opens. The message names the plugin, and
/// the page learns only the path the user chose.
enum MacPluginWebFileDialog {
    @MainActor
    static func choose(_ request: PluginWebFileRequest) async -> URL? {
        let panel: NSSavePanel
        switch request.kind {
        case .open:
            let open = NSOpenPanel()
            open.canChooseFiles = true
            open.canChooseDirectories = false
            open.allowsMultipleSelection = false
            panel = open
        case .save:
            panel = NSSavePanel()
            panel.canCreateDirectories = true
            if let name = request.suggestedName { panel.nameFieldStringValue = name }
        }
        if let title = request.title { panel.title = title }
        panel.message = String(format: L10n.string("Requested by the plugin “%@”."), request.pluginName)
        let types = request.allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
