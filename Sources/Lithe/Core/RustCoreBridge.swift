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
        let operationId: String?
        let timeoutMilliseconds: Int?
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

    struct CoreCallError: LocalizedError, Sendable {
        let code: String
        let message: String
        let details: String?

        var errorDescription: String? { message }

        var userMessage: String {
            if let details, !details.isEmpty {
                return message + ": " + details
            }
            return message
        }
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

        func makeEverywhereResults(at rootURL: URL) -> SearchEverywhereResults {
            let results = makeResults(at: rootURL)
            return SearchEverywhereResults(
                fileMatches: results.filter { $0.kind == .file },
                classMatches: results.filter { $0.kind == .type },
                symbolMatches: results.filter { $0.kind == .symbol },
                contentMatches: results.filter { $0.kind == .content }
            )
        }
    }

    struct ReplacementPreviewPayload: Decodable, Sendable {
        struct Match: Decodable, Sendable {
            let line: Int
            let before: String
            let after: String
            let occurrenceCount: Int
        }

        struct File: Decodable, Sendable {
            let path: String
            let matches: [Match]
            let replacementText: String
        }

        let files: [File]

        func makeModels(at rootURL: URL) -> [ProjectReplacementFile] {
            files.map { file in
                ProjectReplacementFile(
                    url: rootURL.appendingPathComponent(file.path),
                    relativePath: file.path,
                    matches: file.matches.map { match in
                        ProjectReplacementMatch(
                            line: match.line,
                            before: match.before,
                            after: match.after,
                            occurrenceCount: match.occurrenceCount
                        )
                    },
                    replacementText: file.replacementText
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

    struct HistoryEntryPayload: Decodable, Sendable {
        let id: String
        let timestamp: Int64
        let relativePath: String
        let reason: String
        let contentPath: String
        let byteCount: Int
    }

    struct HistoryEntriesPayload: Decodable, Sendable {
        let entries: [HistoryEntryPayload]
    }

    struct HistoryContentPayload: Decodable, Sendable {
        let text: String
    }

    struct HistoryRelocatePayload: Decodable, Sendable {
        let relocated: Bool
    }

    struct MavenScanPayload: Decodable, Sendable {
        struct Profile: Decodable, Sendable {
            let id: String
            let isActiveByDefault: Bool
        }

        struct Module: Decodable, Sendable {
            let relativePath: String
            let groupID: String?
            let artifactID: String
            let version: String?
            let packaging: String
            let modules: [Module]

            func makeModel(rootURL: URL) -> MavenModule {
                MavenModule(
                    relativePath: relativePath,
                    url: rootURL.appendingPathComponent(relativePath),
                    groupID: groupID,
                    artifactID: artifactID,
                    version: version,
                    packaging: packaging,
                    modules: modules.map { $0.makeModel(rootURL: rootURL) }
                )
            }
        }

        let groupID: String?
        let artifactID: String
        let version: String?
        let packaging: String
        let modules: [Module]
        let profiles: [Profile]
        let hasWrapper: Bool

        func makeProject(rootURL: URL) -> MavenProject {
            MavenProject(
                rootURL: rootURL,
                pomURL: rootURL.appendingPathComponent("pom.xml"),
                groupID: groupID,
                artifactID: artifactID,
                version: version,
                packaging: packaging,
                modules: modules.map { $0.makeModel(rootURL: rootURL) },
                profiles: profiles.map {
                    MavenProfile(id: $0.id, isActiveByDefault: $0.isActiveByDefault)
                },
                hasWrapper: hasWrapper
            )
        }
    }

    struct MavenDiagnosticsPayload: Decodable, Sendable {
        struct Issue: Decodable, Sendable {
            let path: String
            let line: Int
            let column: Int?
            let severity: String
            let message: String
        }

        let issues: [Issue]
    }

    struct JavaRunConfigurationsPayload: Decodable, Sendable {
        struct MainClass: Decodable, Sendable {
            let path: String
            let qualifiedName: String
            let simpleName: String
            let isSpringBoot: Bool
        }

        struct Configuration: Decodable, Sendable {
            let id: String
            let name: String
            let kind: String
            let modulePath: String?
            let mainClass: String?
        }

        let mainClasses: [MainClass]
        let configurations: [Configuration]
    }

    struct JavaCodeVisionPayload: Decodable, Sendable {
        struct Hint: Decodable, Sendable {
            let line: Int
            let utf16Column: Int
            let symbol: String
            let usageCount: Int
        }

        let hints: [Hint]
    }

    struct JavaClassNamePayload: Decodable, Sendable {
        let className: String
    }

    struct JavaSourceDefinitionPayload: Decodable, Sendable {
        let line: Int
        let utf16Column: Int
    }

    struct JavaServerPortPayload: Decodable, Sendable {
        let port: Int?
    }

    struct JavaStructurePayload: Decodable, Sendable {
        struct FoldRegion: Decodable, Sendable {
            let kind: String
            let startLine: Int
            let endLine: Int
            let hiddenStart: Int
            let hiddenLength: Int

            func makeModel() -> JavaFoldRegion? {
                guard let kind = JavaFoldKind(rawValue: kind) else { return nil }
                return JavaFoldRegion(
                    kind: kind,
                    startLine: startLine,
                    endLine: endLine,
                    hiddenRange: NSRange(location: hiddenStart, length: hiddenLength)
                )
            }
        }

        struct ImplementationMarker: Decodable, Sendable {
            let line: Int
            let utf16Column: Int
            let implementationCount: Int
            let direction: String

            func makeModel() -> JavaImplementationMarker? {
                guard let direction = JavaImplementationDirection(rawValue: direction) else { return nil }
                return JavaImplementationMarker(
                    line: line,
                    utf16Column: utf16Column,
                    implementationCount: implementationCount,
                    direction: direction
                )
            }
        }

        struct InlayHint: Decodable, Sendable {
            let line: Int
            let utf16Column: Int
            let label: String

            func makeModel() -> JavaInlayHint {
                JavaInlayHint(line: line, utf16Column: utf16Column, label: label)
            }
        }

        let foldRegions: [FoldRegion]
        let implementationMarkers: [ImplementationMarker]
        let inlayHints: [InlayHint]

        func makeFoldRegions() -> [JavaFoldRegion] { foldRegions.compactMap { $0.makeModel() } }
        func makeImplementationMarkers() -> [JavaImplementationMarker] {
            implementationMarkers.compactMap { $0.makeModel() }
        }
        func makeInlayHints() -> [JavaInlayHint] { inlayHints.map { $0.makeModel() } }
    }

    struct GitCommandPayload: Decodable, Sendable {
        let output: String
        let exitCode: Int32
    }

    struct GitDiffPayload: Decodable, Sendable {
        struct Row: Decodable, Sendable {
            let oldLine: Int?
            let newLine: Int?
            let left: String?
            let right: String?
            let kind: String
            let hunkID: String?

            func makeModel(sequence: Int) -> DiffRow {
                DiffRow(
                    oldLine: oldLine,
                    newLine: newLine,
                    left: left,
                    right: right,
                    kind: Self.makeKind(kind),
                    hunkID: hunkID,
                    sequence: sequence
                )
            }

            private static func makeKind(_ rawValue: String) -> DiffRowKind {
                switch rawValue {
                case "context": .context
                case "changed": .changed
                case "addition": .addition
                case "removal": .removal
                default: .information
                }
            }
        }

        struct Hunk: Decodable, Sendable {
            let id: String
            let header: String
            let patch: String
        }

        let patch: String
        let rows: [Row]
        let hunks: [Hunk]

        func makeDocument() -> DiffDocument {
            DiffDocument(
                patch: patch,
                rows: rows.enumerated().map { $0.element.makeModel(sequence: $0.offset) },
                hunks: hunks.map { hunk in
                    DiffHunk(
                        id: hunk.id,
                        header: hunk.header,
                        patch: hunk.patch
                    )
                }
            )
        }
    }

    struct GitHistoryPayload: Decodable, Sendable {
        struct Reference: Decodable, Sendable {
            let fullName: String
            let shortName: String
            let kind: String
            let isCurrent: Bool
            let upstreamShortName: String?
        }

        struct Commit: Decodable, Sendable {
            let hash: String
            let shortHash: String
            let parentHashes: [String]
            let authorName: String
            let authorEmail: String
            let date: String
            let subject: String
            let decorations: String
        }

        let references: [Reference]
        let commits: [Commit]
        let hasMore: Bool

        func makeSnapshot() -> GitHistorySnapshot {
            GitHistorySnapshot(
                references: references.compactMap { reference in
                    guard let kind = GitReferenceKind(rawValue: reference.kind) else { return nil }
                    return GitReference(
                        fullName: reference.fullName,
                        shortName: reference.shortName,
                        kind: kind,
                        isCurrent: reference.isCurrent,
                        upstreamShortName: reference.upstreamShortName
                    )
                },
                commits: commits.map { commit in
                    GitCommit(
                        hash: commit.hash,
                        shortHash: commit.shortHash,
                        parentHashes: commit.parentHashes,
                        authorName: commit.authorName,
                        authorEmail: commit.authorEmail,
                        date: commit.date,
                        subject: commit.subject,
                        decorations: commit.decorations
                    )
                },
                hasMore: hasMore
            )
        }
    }

    struct GitCommitPayload: Decodable, Sendable {
        let commit: GitHistoryPayload.Commit

        func makeModel() -> GitCommit {
            GitCommit(
                hash: commit.hash,
                shortHash: commit.shortHash,
                parentHashes: commit.parentHashes,
                authorName: commit.authorName,
                authorEmail: commit.authorEmail,
                date: commit.date,
                subject: commit.subject,
                decorations: commit.decorations
            )
        }
    }

    struct GitFilesPayload: Decodable, Sendable {
        struct File: Decodable, Sendable {
            let status: String
            let path: String
        }

        let files: [File]
    }

    struct GitComparisonPayload: Decodable, Sendable {
        let files: [GitFilesPayload.File]
    }

    struct GitStashesPayload: Decodable, Sendable {
        struct Stash: Decodable, Sendable {
            let reference: String
            let message: String
            let branch: String?
            let date: String
        }

        let stashes: [Stash]
    }

    struct GitBlamePayload: Decodable, Sendable {
        struct Line: Decodable, Sendable {
            let line: Int
            let commitHash: String
            let authorName: String
            let authorTime: Int64
        }

        let lines: [Line]

        func makeModels() -> [GitBlameLine] {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy/M/d"
            return lines.map { line in
                GitBlameLine(
                    line: max(0, line.line - 1),
                    commitHash: line.commitHash,
                    authorName: line.authorName,
                    date: line.authorTime > 0
                        ? dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(line.authorTime)))
                        : "Working tree"
                )
            }
        }
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

        func makeSnapshot(at workspaceURL: URL) -> GitSnapshot? {
            guard let repositoryRoot else { return nil }
            let root = repositoryRoot.hasPrefix("/")
                ? URL(fileURLWithPath: repositoryRoot)
                : workspaceURL.appendingPathComponent(repositoryRoot)
            return GitSnapshot(
                repositoryRoot: root.standardizedFileURL,
                branch: branch ?? "detached",
                changes: changes.map { change in
                    let status = Array(change.status)
                    return GitChange(
                        repositoryRoot: root.standardizedFileURL,
                        path: change.path,
                        originalPath: change.originalPath,
                        indexStatus: status.first ?? " ",
                        workTreeStatus: status.dropFirst().first ?? " "
                    )
                }
            )
        }
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
        let maxSymbolResults: Int?
        let hiddenDirectoryNames: [String]
        let hiddenFilePatterns: [String]
    }

    private struct ReplacementPreviewRequest: Encodable {
        let root: String
        let query: String
        let replacement: String
        let caseSensitive: Bool
        let wholeWords: Bool
        let regularExpression: Bool
        let paths: [String]
        let textOverrides: [String: String]
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

    private struct HistoryRecordRequest: Encodable {
        let workspaceRoot: String
        let storageRoot: String
        let path: String
        let reason: String
        let content: String?
        let pruneExpired: Bool
        let hiddenDirectoryNames: [String]
        let hiddenFilePatterns: [String]
    }

    private struct HistoryEntriesRequest: Encodable {
        let workspaceRoot: String
        let storageRoot: String
        let path: String?
        let hiddenDirectoryNames: [String]
        let hiddenFilePatterns: [String]
    }

    private struct HistoryContentRequest: Encodable {
        let storageRoot: String
        let contentPath: String
    }

    private struct HistoryRelocateRequest: Encodable {
        let storageRoot: String
        let sourcePath: String
        let destinationPath: String
    }

    private struct MavenScanRequest: Encodable {
        let root: String
    }

    private struct MavenDiagnosticsRequest: Encodable {
        let root: String
        let output: String
    }

    private struct JavaRunConfigurationsRequest: Encodable {
        let root: String
        let paths: [String]
        let modulePaths: [String]
    }

    private struct JavaStructureRequest: Encodable {
        let source: String
        let declarationSources: [String]
    }

    private struct JavaCodeVisionRequest: Encodable {
        let root: String
        let targetPath: String
        let paths: [String]
    }

    private struct JavaClassNameRequest: Encodable {
        let source: String
        let simpleName: String
    }

    private struct JavaSourceDefinitionRequest: Encodable {
        let source: String
        let declarationName: String
        let memberName: String?
    }

    private struct JavaServerPortRequest: Encodable {
        let content: String
        let fileExtension: String
    }

    private struct GitStatusRequest: Encodable {
        let root: String
    }

    private struct GitCommandRequest: Encodable {
        let root: String
        let arguments: [String]
        let input: String?
    }

    private struct GitWriteRequest: Encodable {
        let root: String
        let operation: String
        let paths: [String]
        let reference: String?
        let referenceKind: String?
        let revision: String?
        let name: String?
        let message: String?
        let remote: String?
        let destination: String?
        let mode: String?
        let includeUntracked: Bool
        let checkout: Bool
        let amend: Bool
    }

    private struct GitDiffRequest: Encodable {
        let root: String
        let pathspecs: [String]
        let reference: String?
        let commit: String?
        let staged: Bool
        let untracked: Bool
        let contextLines: Int
        let ignoreAllWhitespace: Bool
    }

    private struct GitApplyRequest: Encodable {
        let root: String
        let patch: String
        let mode: String
    }

    private struct GitHistoryRequest: Encodable {
        let root: String
        let reference: String?
        let limit: Int
    }

    private struct GitCommitRequest: Encodable {
        let root: String
        let commit: String
    }

    private struct GitCommitFilesRequest: Encodable {
        let root: String
        let commit: String
    }

    private struct GitComparisonRequest: Encodable {
        let root: String
        let reference: String
    }

    private struct GitStashesRequest: Encodable {
        let root: String
    }

    private struct GitBlameRequest: Encodable {
        let root: String
        let path: String
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
        maxSymbolResults: Int? = nil,
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
                maxSymbolResults: maxSymbolResults,
                hiddenDirectoryNames: hiddenDirectoryNames,
                hiddenFilePatterns: hiddenFilePatterns
            )
        )
    }

    func searchEverywhere(
        at rootURL: URL,
        query: String,
        caseSensitive: Bool,
        wholeWords: Bool,
        regularExpression: Bool,
        maxResults: Int = 200,
        maxFileResults: Int? = nil,
        maxContentResults: Int? = nil,
        maxSymbolResults: Int? = 50,
        hiddenDirectoryNames: [String] = [],
        hiddenFilePatterns: [String] = []
    ) -> SearchResponsePayload? {
        execute(
            command: "workspace.searchEverywhere",
            payload: SearchRequest(
                root: rootURL.standardizedFileURL.path,
                query: query,
                caseSensitive: caseSensitive,
                wholeWords: wholeWords,
                regularExpression: regularExpression,
                maxResults: maxResults,
                maxFileResults: maxFileResults,
                maxContentResults: maxContentResults,
                maxSymbolResults: maxSymbolResults,
                hiddenDirectoryNames: hiddenDirectoryNames,
                hiddenFilePatterns: hiddenFilePatterns
            )
        )
    }

    func previewReplacement(
        at rootURL: URL,
        query: String,
        replacement: String,
        caseSensitive: Bool = false,
        wholeWords: Bool = false,
        regularExpression: Bool = false,
        paths: [String] = [],
        textOverrides: [String: String] = [:],
        hiddenDirectoryNames: [String] = [],
        hiddenFilePatterns: [String] = []
    ) -> ReplacementPreviewPayload? {
        execute(
            command: "workspace.replacePreview",
            payload: ReplacementPreviewRequest(
                root: rootURL.standardizedFileURL.path,
                query: query,
                replacement: replacement,
                caseSensitive: caseSensitive,
                wholeWords: wholeWords,
                regularExpression: regularExpression,
                paths: paths,
                textOverrides: textOverrides,
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

    func historyRecord(
        at workspaceURL: URL,
        storageURL: URL,
        relativePath: String,
        reason: String,
        content: String?,
        pruneExpired: Bool,
        hiddenDirectoryNames: [String],
        hiddenFilePatterns: [String]
    ) -> HistoryEntryPayload? {
        execute(
            command: "history.record",
            payload: HistoryRecordRequest(
                workspaceRoot: workspaceURL.standardizedFileURL.path,
                storageRoot: storageURL.standardizedFileURL.path,
                path: relativePath,
                reason: reason,
                content: content,
                pruneExpired: pruneExpired,
                hiddenDirectoryNames: hiddenDirectoryNames,
                hiddenFilePatterns: hiddenFilePatterns
            )
        )
    }

    func historyEntries(
        at workspaceURL: URL,
        storageURL: URL,
        relativePath: String?,
        hiddenDirectoryNames: [String],
        hiddenFilePatterns: [String]
    ) -> HistoryEntriesPayload? {
        execute(
            command: "history.entries",
            payload: HistoryEntriesRequest(
                workspaceRoot: workspaceURL.standardizedFileURL.path,
                storageRoot: storageURL.standardizedFileURL.path,
                path: relativePath,
                hiddenDirectoryNames: hiddenDirectoryNames,
                hiddenFilePatterns: hiddenFilePatterns
            )
        )
    }

    func historyContent(storageURL: URL, contentPath: String) -> HistoryContentPayload? {
        execute(
            command: "history.content",
            payload: HistoryContentRequest(
                storageRoot: storageURL.standardizedFileURL.path,
                contentPath: contentPath
            )
        )
    }

    func historyRelocate(
        storageURL: URL,
        sourcePath: String,
        destinationPath: String
    ) -> Bool {
        let response: HistoryRelocatePayload? = execute(
            command: "history.relocate",
            payload: HistoryRelocateRequest(
                storageRoot: storageURL.standardizedFileURL.path,
                sourcePath: sourcePath,
                destinationPath: destinationPath
            )
        )
        return response?.relocated == true
    }

    func scanMaven(at rootURL: URL) -> MavenScanPayload? {
        execute(
            command: "maven.scan",
            payload: MavenScanRequest(root: rootURL.standardizedFileURL.path)
        )
    }

    func mavenDiagnostics(at rootURL: URL, output: String) -> MavenDiagnosticsPayload? {
        execute(
            command: "maven.diagnostics",
            payload: MavenDiagnosticsRequest(
                root: rootURL.standardizedFileURL.path,
                output: output
            )
        )
    }

    func scanJavaRunConfigurations(
        at rootURL: URL,
        paths: [String],
        modulePaths: [String]
    ) -> JavaRunConfigurationsPayload? {
        execute(
            command: "java.runConfigurations",
            payload: JavaRunConfigurationsRequest(
                root: rootURL.standardizedFileURL.path,
                paths: paths,
                modulePaths: modulePaths
            )
        )
    }

    func javaCodeVision(
        at rootURL: URL,
        targetPath: String,
        paths: [String]
    ) -> JavaCodeVisionPayload? {
        execute(
            command: "java.codeVision",
            payload: JavaCodeVisionRequest(
                root: rootURL.standardizedFileURL.path,
                targetPath: targetPath,
                paths: paths
            )
        )
    }

    func javaClassName(source: String, simpleName: String) -> JavaClassNamePayload? {
        execute(
            command: "java.className",
            payload: JavaClassNameRequest(source: source, simpleName: simpleName)
        )
    }

    func javaSourceDefinition(
        source: String,
        declarationName: String,
        memberName: String?
    ) -> JavaSourceDefinitionPayload? {
        execute(
            command: "java.sourceDefinition",
            payload: JavaSourceDefinitionRequest(
                source: source,
                declarationName: declarationName,
                memberName: memberName
            )
        )
    }

    func javaServerPort(content: String, fileExtension: String) -> JavaServerPortPayload? {
        execute(
            command: "java.serverPort",
            payload: JavaServerPortRequest(content: content, fileExtension: fileExtension)
        )
    }

    func javaStructure(source: String, declarationSources: [String] = []) -> JavaStructurePayload? {
        execute(
            command: "java.structure",
            payload: JavaStructureRequest(source: source, declarationSources: declarationSources)
        )
    }

    func gitStatus(at rootURL: URL) -> GitStatusPayload? {
        execute(
            command: "git.status",
            payload: GitStatusRequest(root: rootURL.standardizedFileURL.path)
        )
    }

    func gitCommand(
        at rootURL: URL,
        arguments: [String],
        input: String? = nil
    ) -> GitCommandPayload? {
        execute(
            command: "git.command",
            payload: GitCommandRequest(
                root: rootURL.standardizedFileURL.path,
                arguments: arguments,
                input: input
            )
        )
    }

    func gitCommandResult(
        at rootURL: URL,
        arguments: [String],
        input: String? = nil
    ) -> Result<GitCommandPayload, CoreCallError> {
        executeResult(
            command: "git.command",
            payload: GitCommandRequest(
                root: rootURL.standardizedFileURL.path,
                arguments: arguments,
                input: input
            )
        )
    }

    func gitWrite(
        at rootURL: URL,
        operation: String,
        paths: [String] = [],
        reference: String? = nil,
        referenceKind: String? = nil,
        revision: String? = nil,
        name: String? = nil,
        message: String? = nil,
        remote: String? = nil,
        destination: String? = nil,
        mode: String? = nil,
        includeUntracked: Bool = false,
        checkout: Bool = false,
        amend: Bool = false
    ) -> GitCommandPayload? {
        execute(
            command: "git.write",
            payload: GitWriteRequest(
                root: rootURL.standardizedFileURL.path,
                operation: operation,
                paths: paths,
                reference: reference,
                referenceKind: referenceKind,
                revision: revision,
                name: name,
                message: message,
                remote: remote,
                destination: destination,
                mode: mode,
                includeUntracked: includeUntracked,
                checkout: checkout,
                amend: amend
            )
        )
    }

    func gitWriteResult(
        at rootURL: URL,
        operation: String,
        paths: [String] = [],
        reference: String? = nil,
        referenceKind: String? = nil,
        revision: String? = nil,
        name: String? = nil,
        message: String? = nil,
        remote: String? = nil,
        destination: String? = nil,
        mode: String? = nil,
        includeUntracked: Bool = false,
        checkout: Bool = false,
        amend: Bool = false
    ) -> Result<GitCommandPayload, CoreCallError> {
        executeResult(
            command: "git.write",
            payload: GitWriteRequest(
                root: rootURL.standardizedFileURL.path,
                operation: operation,
                paths: paths,
                reference: reference,
                referenceKind: referenceKind,
                revision: revision,
                name: name,
                message: message,
                remote: remote,
                destination: destination,
                mode: mode,
                includeUntracked: includeUntracked,
                checkout: checkout,
                amend: amend
            )
        )
    }

    func gitDiff(
        at rootURL: URL,
        pathspecs: [String],
        reference: String? = nil,
        commit: String? = nil,
        staged: Bool,
        untracked: Bool,
        contextLines: Int = 80,
        ignoreAllWhitespace: Bool
    ) -> GitDiffPayload? {
        execute(
            command: "git.diff",
            payload: GitDiffRequest(
                root: rootURL.standardizedFileURL.path,
                pathspecs: pathspecs,
                reference: reference,
                commit: commit,
                staged: staged,
                untracked: untracked,
                contextLines: contextLines,
                ignoreAllWhitespace: ignoreAllWhitespace
            )
        )
    }

    func gitApply(
        at rootURL: URL,
        patch: String,
        mode: String
    ) -> GitCommandPayload? {
        execute(
            command: "git.apply",
            payload: GitApplyRequest(
                root: rootURL.standardizedFileURL.path,
                patch: patch,
                mode: mode
            )
        )
    }

    func gitApplyResult(
        at rootURL: URL,
        patch: String,
        mode: String
    ) -> Result<GitCommandPayload, CoreCallError> {
        executeResult(
            command: "git.apply",
            payload: GitApplyRequest(
                root: rootURL.standardizedFileURL.path,
                patch: patch,
                mode: mode
            )
        )
    }

    func gitHistory(
        at rootURL: URL,
        reference: String?,
        limit: Int
    ) -> GitHistoryPayload? {
        execute(
            command: "git.history",
            payload: GitHistoryRequest(
                root: rootURL.standardizedFileURL.path,
                reference: reference,
                limit: limit
            )
        )
    }

    func gitCommit(at rootURL: URL, commit: String) -> GitCommitPayload? {
        execute(
            command: "git.commit",
            payload: GitCommitRequest(root: rootURL.standardizedFileURL.path, commit: commit)
        )
    }

    func gitCommitFiles(at rootURL: URL, commit: String) -> GitFilesPayload? {
        execute(
            command: "git.commitFiles",
            payload: GitCommitFilesRequest(
                root: rootURL.standardizedFileURL.path,
                commit: commit
            )
        )
    }

    func gitComparison(at rootURL: URL, reference: String) -> GitComparisonPayload? {
        execute(
            command: "git.comparison",
            payload: GitComparisonRequest(
                root: rootURL.standardizedFileURL.path,
                reference: reference
            )
        )
    }

    func gitStashes(at rootURL: URL) -> GitStashesPayload? {
        execute(
            command: "git.stashes",
            payload: GitStashesRequest(root: rootURL.standardizedFileURL.path)
        )
    }

    func gitBlame(at rootURL: URL, relativePath: String) -> GitBlamePayload? {
        execute(
            command: "git.blame",
            payload: GitBlameRequest(
                root: rootURL.standardizedFileURL.path,
                path: relativePath
            )
        )
    }

    private func execute<Payload: Encodable, Data: Decodable>(
        command: String,
        payload: Payload
    ) -> Data? {
        try? executeResult(command: command, payload: payload).get()
    }

    private func executeResult<Payload: Encodable, Data: Decodable>(
        command: String,
        payload: Payload
    ) -> Result<Data, CoreCallError> {
        guard isAvailable else {
            return .failure(CoreCallError(
                code: "unknown",
                message: "Rust Core is unavailable",
                details: nil
            ))
        }
        let requestID = UUID().uuidString
        guard let requestData = try? JSONEncoder().encode(
            Request(
                id: requestID,
                operationId: requestID,
                timeoutMilliseconds: nil,
                command: command,
                payload: payload
            )
        ),
        let request = String(data: requestData, encoding: .utf8),
        let responsePointer = lithe_bridge_execute_json(request) else {
            return .failure(CoreCallError(
                code: "unknown",
                message: "Rust Core request could not be encoded or executed",
                details: nil
            ))
        }
        defer { lithe_bridge_free_string(responsePointer) }

        let response = String(cString: responsePointer)
        guard let data = response.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope<Data>.self, from: data) else {
            return .failure(CoreCallError(
                code: "unknown",
                message: "Rust Core returned an invalid response",
                details: nil
            ))
        }
        guard envelope.ok else {
            let error = envelope.error ?? ErrorPayload(
                code: "unknown",
                message: "Rust Core request failed",
                details: nil
            )
            return .failure(CoreCallError(
                code: error.code,
                message: error.message,
                details: error.details
            ))
        }
        guard let value = envelope.data else {
            return .failure(CoreCallError(
                code: "unknown",
                message: "Rust Core response did not contain data",
                details: nil
            ))
        }
        return .success(value)
    }

    @discardableResult
    func cancel(operationID: String) -> Bool {
        operationID.withCString { lithe_bridge_cancel($0) != 0 }
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
