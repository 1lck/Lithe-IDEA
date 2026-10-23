import AppKit

/// The folder chooser of windows that create something on disk (Clone
/// Repository, New Project).
enum LitheDirectoryPicker {
    /// Shows an open panel for one directory, starting at `path` when it
    /// exists. Returns the chosen path, or nil when the user cancels.
    @MainActor
    static func choose(startingAt path: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        if let path {
            let expanded = (path as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
