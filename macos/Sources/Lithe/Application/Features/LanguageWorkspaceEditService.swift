import LitheModuleAPI
import Foundation
import LitheCoreContracts

/// Applies language-server workspace edits while preserving editor ownership.
///
/// Writes to closed files are rolled back when any one of them fails, so a
/// rename or code action cannot leave the workspace half-edited.
@MainActor
final class LanguageWorkspaceEditService {
    private let logSink: (any LogSink)?
    private let notify: @MainActor (String) -> Void

    init(notify: @escaping @MainActor (String) -> Void, logSink: (any LogSink)? = nil) {
        self.logSink = logSink
        self.notify = notify
    }

    enum EditError: LocalizedError {
        case outsideWorkspace
        case unreadableFile
        case planUnavailable

        var errorDescription: String? {
            switch self {
            case .outsideWorkspace:
                return L10n.string("Language edit targets a file outside the workspace.")
            case .unreadableFile:
                return L10n.string("Language edit targets an unreadable file.")
            case .planUnavailable:
                return L10n.string("Language edit could not be planned.")
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
        var sources: [URL: String] = [:]
        var documents: [URL: EditorDocument] = [:]
        do {
            // Core validates every target against the workspace and the open
            // documents before anything is read, and orders the commit.
            let plan = try Self.plan(edit, workspaceURL: workspaceURL, openDocuments: openDocuments)
            for target in plan {
                let url = URL(fileURLWithPath: target.path).standardizedFileURL
                if let document = openDocuments.first(where: {
                    $0.url.standardizedFileURL == url
                }) {
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
            for target in plan {
                let url = URL(fileURLWithPath: target.path).standardizedFileURL
                guard let source = sources[url] else { continue }
                let edits = edit.changes.filter { $0.key.standardizedFileURL == url }.flatMap(\.value)
                replacements[url] = try LanguageServerTextEditApplicator.apply(edits, to: source)
            }
            var originals: [URL: String] = [:]
            do {
                for target in plan where target.effect == "writeFile" {
                    let url = URL(fileURLWithPath: target.path).standardizedFileURL
                    guard let replacement = replacements[url] else { continue }
                    originals[url] = sources[url]
                    try fileOperations.writeText(replacement, to: url)
                }
            } catch {
                var count: Int64 = 0
                var lastError: (any Error)?
                for (url, original) in originals {
                    do { try fileOperations.writeText(original, to: url) }
                    catch { count += 1; lastError = error }
                }
                if let lastError { logSink?.emit(EditorWorkspaceEditRollbackFailed(count: count, error: lastError)) }
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

    struct PlannedTarget: Decodable {
        let path: String
        let effect: String
    }

    /// Asks Core (`lsp.planWorkspaceEdit`) which targets may be edited and in
    /// what order they commit. A rejection maps to the matching edit error;
    /// a Core failure refuses the whole edit.
    static func plan(
        _ edit: LanguageServerWorkspaceEdit,
        workspaceURL: URL,
        openDocuments: [EditorDocument]
    ) throws -> [PlannedTarget] {
        struct Position: Encodable { let line: Int; let utf16Column: Int }
        struct Range: Encodable { let start: Position; let end: Position }
        struct Edit: Encodable { let range: Range; let newText: String }
        struct Open: Encodable { let path: String; let isReadOnly: Bool }
        struct Request: Encodable {
            let platform = "posix"
            let workspaceRoot: String
            let changes: [String: [Edit]]
            let openDocuments: [Open]
        }
        struct Rejection: Decodable { let code: String }
        struct Response: Decodable { let rejection: Rejection?; let targets: [PlannedTarget] }
        var changes: [String: [Edit]] = [:]
        for (url, edits) in edit.changes {
            changes[url.standardizedFileURL.path, default: []] += edits.map {
                Edit(
                    range: Range(
                        start: Position(line: $0.range.start.line, utf16Column: $0.range.start.utf16Column),
                        end: Position(line: $0.range.end.line, utf16Column: $0.range.end.utf16Column)),
                    newText: $0.newText)
            }
        }
        let request = Request(
            workspaceRoot: workspaceURL.standardizedFileURL.path,
            changes: changes,
            openDocuments: openDocuments.map {
                Open(path: $0.url.standardizedFileURL.path, isReadOnly: $0.isReadOnly)
            })
        let result: Result<Response, RustCoreBridge.CoreCallError> = RustCoreBridge().executeResult(
            command: "lsp.planWorkspaceEdit", payload: request)
        guard case .success(let response) = result else { throw EditError.planUnavailable }
        switch response.rejection?.code {
        case nil: return response.targets
        case "readOnlyDocument": throw EditorDocument.DocumentError.readOnly
        default: throw EditError.outsideWorkspace
        }
    }
}
