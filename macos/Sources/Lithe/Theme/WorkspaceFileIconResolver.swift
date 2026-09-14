import Foundation

/// Resolves icons for files whose extension does not identify their content.
/// Known language and configuration kinds remain semantic; only generic files
/// are sniffed so extensionless text and binary files match IDEA's file glyphs.
enum WorkspaceFileIconResolver {
    static func resolve(
        for url: URL,
        suggested: LitheIconKind,
        storage: any FileStorage
    ) async -> (kind: LitheIconKind, isExecutable: Bool) {
        let executable = storage.isExecutable(at: url)
        guard suggested == .generic else { return (suggested, executable) }
        let data = await Task.detached(priority: .utility) {
            try? storage.readPrefix(from: url, byteCount: 4 * 1024)
        }.value
        guard let data else { return (.generic, executable) }
        return (WorkspaceTextFilePolicy.isPlainText(data) ? .plainText : .binary, executable)
    }
}
