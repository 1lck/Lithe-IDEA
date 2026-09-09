import AppKit
import Foundation
import LitheGitModule
import UniformTypeIdentifiers

/// Native dialogs and bounded file I/O for exchanging portable Git patches.
@MainActor
struct MacGitPatchFileAccess: GitPatchFileAccess {
    let storage: any FileStorage

    func choosePatchFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open Git Patch")
        panel.prompt = String(localized: "Preview")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func choosePatchDestination() -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Save Git Patch")
        panel.allowedContentTypes = [UTType(filenameExtension: "patch") ?? .plainText]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "changes-\(formatter.string(from: Date())).patch"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func clipboardPatch() -> String? { NSPasteboard.general.string(forType: .string) }

    func readPatch(at url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) { [storage] in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try storage.readPrefix(from: url, byteCount: GitPatchContent.maximumByteCount + 1)
            return try GitPatchContent.decode(data)
        }.value
    }

    func writePatch(_ patch: String, at url: URL) async throws {
        try await Task.detached(priority: .userInitiated) { [storage] in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = Data(patch.utf8)
            guard data.count <= GitPatchContent.maximumByteCount else {
                throw GitPatchFailure("Patch files must be at most 32 MiB.")
            }
            try storage.writeData(data, to: url, options: .atomic)
        }.value
    }
}
