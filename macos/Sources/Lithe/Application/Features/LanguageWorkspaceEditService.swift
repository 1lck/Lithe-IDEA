import Foundation
import LitheCoreContracts

/// Applies language-server workspace edits while preserving editor ownership.
///
/// Writes to closed files are rolled back when any one of them fails, so a
/// rename or code action cannot leave the workspace half-edited.
@MainActor
final class LanguageWorkspaceEditService {
    private let notify: @MainActor (String) -> Void

    init(notify: @escaping @MainActor (String) -> Void) {
        self.notify = notify
    }

    enum EditError: LocalizedError {
        case outsideWorkspace
        case unreadableFile

        var errorDescription: String? {
            switch self {
            case .outsideWorkspace:
                return "Language edit targets a file outside the workspace."
            case .unreadableFile:
                return "Language edit targets an unreadable file."
            }
        }
    }

    @discardableResult
    func apply(
        _ edit: LanguageServerWorkspaceEdit,
        workspaceURL: URL,
        openDocuments: [EditorDocument],
        fileOperations: any WorkspaceFileOperations,
        updateDocument: @MainActor (EditorDocument, String) -> Void
    ) -> Bool {
        let root = workspaceURL.standardizedFileURL.path
        var sources: [URL: String] = [:]
        var documents: [URL: EditorDocument] = [:]
        do {
            for rawURL in edit.changes.keys {
                let url = rawURL.standardizedFileURL
                guard url.path == root || url.path.hasPrefix(root + "/") else {
                    throw EditError.outsideWorkspace
                }
                if let document = openDocuments.first(where: {
                    $0.url.standardizedFileURL == url
                }) {
                    guard !document.isReadOnly else {
                        throw EditorDocument.DocumentError.readOnly
                    }
                    documents[url] = document
                    sources[url] = document.text
                } else {
                    guard WorkspaceTextFilePolicy.isReadableTextFile(url) else {
                        throw EditError.unreadableFile
                    }
                    sources[url] = try fileOperations.readText(from: url)
                }
            }
            var replacements: [URL: String] = [:]
            for (url, edits) in edit.changes {
                let normalized = url.standardizedFileURL
                guard let source = sources[normalized] else { continue }
                replacements[normalized] = try LanguageServerTextEditApplicator.apply(
                    edits,
                    to: source
                )
            }
            var originals: [URL: String] = [:]
            do {
                for (url, replacement) in replacements where documents[url] == nil {
                    originals[url] = sources[url]
                    try fileOperations.writeText(replacement, to: url)
                }
            } catch {
                for (url, original) in originals {
                    try? fileOperations.writeText(original, to: url)
                }
                throw error
            }
            for (url, replacement) in replacements {
                if let document = documents[url] {
                    updateDocument(document, replacement)
                }
            }
            return true
        } catch {
            notify("Could not apply language edit: \(error.localizedDescription)")
            return false
        }
    }
}
