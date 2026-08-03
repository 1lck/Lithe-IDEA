import Foundation
import LitheRustCore

/// Language-neutral application boundary backed by the Rust Core.
///
/// The JSON request/response shape is also the contract that the future
/// Windows Qt binding will consume. The bridge stays synchronous at this
/// layer; callers move filesystem and Git work off the main actor.
struct RustCoreBridge: Sendable {
    private struct Request<Payload: Encodable>: Encodable {
        let id: String
        let command: String
        let payload: Payload
    }

    private struct Envelope<Data: Decodable>: Decodable {
        let ok: Bool
        let data: Data?
        let error: ErrorPayload?
    }

    private struct ErrorPayload: Decodable {
        let code: String
        let message: String
        let details: String?
    }

    struct WorkspaceNodePayload: Decodable, Sendable {
        let path: String
        let name: String
        let isDirectory: Bool
        let children: [WorkspaceNodePayload]?
    }

    struct WorkspaceSnapshotPayload: Decodable, Sendable {
        let root: WorkspaceNodePayload
        let files: [String]

        func makeSnapshot(at rootURL: URL) -> WorkspaceSnapshot {
            WorkspaceSnapshot(
                root: root.makeFileNode(at: rootURL),
                files: files.map { rootURL.appendingPathComponent($0) }
            )
        }
    }

    struct SearchMatchPayload: Decodable, Sendable {
        let kind: String
        let path: String
        let line: Int?
        let preview: String
        let symbolName: String?
    }

    struct SearchResponsePayload: Decodable, Sendable {
        let matches: [SearchMatchPayload]

        func makeResults(at rootURL: URL) -> [FileSearchResult] {
            matches.map { match in
                FileSearchResult(
                    url: rootURL.appendingPathComponent(match.path),
                    line: match.line,
                    preview: match.preview,
                    kind: SearchResultKind(rawValue: match.kind) ?? .content,
                    symbolName: match.symbolName
                )
            }
        }
    }

    struct FileReadPayload: Decodable, Sendable {
        let path: String
        let text: String
    }

    struct FileWritePayload: Decodable, Sendable {
        let path: String
        let bytesWritten: Int
    }

    struct GitChangePayload: Decodable, Sendable {
        let path: String
        let originalPath: String?
        let status: String
        let staged: Bool
        let worktree: Bool
        let untracked: Bool
    }

    struct GitStatusPayload: Decodable, Sendable {
        let repositoryRoot: String?
        let branch: String?
        let changes: [GitChangePayload]
    }

    private struct EmptyPayload: Encodable {
        let value = 0
    }

    private struct SnapshotRequest: Encodable {
        let root: String
        let hiddenDirectoryNames: [String]
        let hiddenFilePatterns: [String]
    }

    private struct SearchRequest: Encodable {
        let root: String
        let query: String
        let caseSensitive: Bool
        let wholeWords: Bool
        let regularExpression: Bool
        let maxResults: Int
        let maxFileResults: Int?
        let maxContentResults: Int?
        let hiddenDirectoryNames: [String]
        let hiddenFilePatterns: [String]
    }

    private struct FileRequest: Encodable {
        let root: String
        let path: String
    }

    private struct FileWriteRequest: Encodable {
        let root: String
        let path: String
        let text: String
    }

    private struct GitStatusRequest: Encodable {
        let root: String
    }

    var isAvailable: Bool {
        String(cString: lithe_bridge_version()) != "unlinked"
    }

    func version() -> String? {
        guard isAvailable else { return nil }
        return String(cString: lithe_bridge_version())
    }

    func snapshot(
        at rootURL: URL,
        hiddenDirectoryNames: [String] = [],
        hiddenFilePatterns: [String] = []
    ) -> WorkspaceSnapshotPayload? {
        execute(
            command: "workspace.snapshot",
            payload: SnapshotRequest(
                root: rootURL.standardizedFileURL.path,
                hiddenDirectoryNames: hiddenDirectoryNames,
                hiddenFilePatterns: hiddenFilePatterns
            )
        )
    }

    func search(
        at rootURL: URL,
        query: String,
        caseSensitive: Bool,
        wholeWords: Bool,
        regularExpression: Bool,
        maxResults: Int = 200,
        maxFileResults: Int? = nil,
        maxContentResults: Int? = nil,
        hiddenDirectoryNames: [String] = [],
        hiddenFilePatterns: [String] = []
    ) -> SearchResponsePayload? {
        execute(
            command: "workspace.search",
            payload: SearchRequest(
                root: rootURL.standardizedFileURL.path,
                query: query,
                caseSensitive: caseSensitive,
                wholeWords: wholeWords,
                regularExpression: regularExpression,
                maxResults: maxResults,
                maxFileResults: maxFileResults,
                maxContentResults: maxContentResults,
                hiddenDirectoryNames: hiddenDirectoryNames,
                hiddenFilePatterns: hiddenFilePatterns
            )
        )
    }

    func readFile(at rootURL: URL, relativePath: String) -> FileReadPayload? {
        execute(
            command: "file.read",
            payload: FileRequest(root: rootURL.standardizedFileURL.path, path: relativePath)
        )
    }

    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> FileWritePayload? {
        execute(
            command: "file.write",
            payload: FileWriteRequest(root: rootURL.standardizedFileURL.path, path: relativePath, text: text)
        )
    }

    func gitStatus(at rootURL: URL) -> GitStatusPayload? {
        execute(
            command: "git.status",
            payload: GitStatusRequest(root: rootURL.standardizedFileURL.path)
        )
    }

    private func execute<Payload: Encodable, Data: Decodable>(
        command: String,
        payload: Payload
    ) -> Data? {
        guard isAvailable,
              let requestData = try? JSONEncoder().encode(Request(id: UUID().uuidString, command: command, payload: payload)),
              let request = String(data: requestData, encoding: .utf8),
              let responsePointer = lithe_bridge_execute_json(request) else {
            return nil
        }
        defer { lithe_bridge_free_string(responsePointer) }

        let response = String(cString: responsePointer)
        guard let data = response.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope<Data>.self, from: data),
              envelope.ok else {
            return nil
        }
        return envelope.data
    }
}

private extension RustCoreBridge.WorkspaceNodePayload {
    func makeFileNode(at rootURL: URL) -> FileNode {
        let url = path.isEmpty ? rootURL : rootURL.appendingPathComponent(path)
        return FileNode(
            url: url,
            isDirectory: isDirectory,
            children: children?.map { $0.makeFileNode(at: rootURL) }
        )
    }
}
