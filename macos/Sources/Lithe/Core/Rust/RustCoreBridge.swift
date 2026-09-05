import Foundation
import LitheCoreContracts
import LitheGitModule
import LitheSearchModule
import LitheRustCore

/// Language-neutral application boundary backed by the Rust Core.
///
/// The JSON request/response shape is also the contract that the future
/// Windows Qt binding will consume. The bridge stays synchronous at this
/// layer; callers move filesystem and Git work off the main actor.
struct RustCoreBridge: Sendable, IncrementalLanguageServerRuntimeCore {
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

        private enum CodingKeys: String, CodingKey {
            case ok
            case data
            case error
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ok = try container.decode(Bool.self, forKey: .ok)
            data = container.contains(.data) ? try container.decode(Data.self, forKey: .data) : nil
            error = try container.decodeIfPresent(ErrorPayload.self, forKey: .error)
        }
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

    private struct SearchIndexStatusPayload: Decodable {
        let fileCount: Int
        let symbolCount: Int
        let postingCount: Int
        let rebuilt: Bool
    }

    private struct EmptyResponsePayload: Decodable {}

    private struct GitHubParseRemoteRequest: Encodable {
        let remoteURL: String

        private enum CodingKeys: String, CodingKey {
            case remoteURL = "remoteUrl"
        }
    }

    private struct GitHubNormalizeResponseRequest: Encodable {
        let operation: String
        let status: Int
        let body: String
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

    struct MarkdownRenderPayload: Decodable, Sendable {
        let html: String
    }

    struct MavenScanPayload: Decodable, Sendable {
        struct SourceRoot: Decodable, Sendable {
            let path: String
            let kind: String

            func makeModel() -> MavenSourceRoot? {
                guard let kind = MavenSourceRootKind(rawValue: kind) else { return nil }
                return MavenSourceRoot(path: path, kind: kind)
            }
        }

        struct Profile: Decodable, Sendable {
            let id: String
            let isActiveByDefault: Bool
        }

        /// The core serializes Maven coordinates as `groupId` / `artifactId`,
        /// matching Maven itself. Swift spells the same properties with a
        /// capital D, so the mapping has to be explicit -- without it decoding
        /// fails and the whole scan silently returns nil.
        struct Module: Decodable, Sendable {
            let relativePath: String
            let groupID: String?
            let artifactID: String
            let version: String?
            let packaging: String
            let sourceRoots: [SourceRoot]?
            let modules: [Module]

            enum CodingKeys: String, CodingKey {
                case relativePath
                case groupID = "groupId"
                case artifactID = "artifactId"
                case version
                case packaging
                case sourceRoots
                case modules
            }

            func makeModel(rootURL: URL) -> MavenModule {
                MavenModule(
                    relativePath: relativePath,
                    url: rootURL.appendingPathComponent(relativePath),
                    groupID: groupID,
                    artifactID: artifactID,
                    version: version,
                    packaging: packaging,
                    modules: modules.map { $0.makeModel(rootURL: rootURL) },
                    sourceRoots: sourceRoots?.compactMap { $0.makeModel() } ?? []
                )
            }
        }

        let relativePath: String
        let groupID: String?
        let artifactID: String
        let version: String?
        let packaging: String
        let sourceRoots: [SourceRoot]?
        let modules: [Module]
        let profiles: [Profile]
        let hasWrapper: Bool

        enum CodingKeys: String, CodingKey {
            case groupID = "groupId"
            case relativePath
            case artifactID = "artifactId"
            case version
            case packaging
            case sourceRoots
            case modules
            case profiles
            case hasWrapper
        }

        func makeProject(workspaceRootURL: URL) -> MavenProject {
            let rootURL = relativePath == "."
                ? workspaceRootURL
                : workspaceRootURL.appending(path: relativePath, directoryHint: .isDirectory)
            return MavenProject(
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
                hasWrapper: hasWrapper,
                sourceRoots: sourceRoots?.compactMap { $0.makeModel() } ?? []
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

    struct MavenLaunchPlanPayload: Decodable, Sendable {
        struct Executable: Decodable, Sendable {
            let toolchain: String
        }

        let version: Int
        let executable: Executable
        let arguments: [String]
        let workingDirectory: String
        let configurationFingerprint: String

        func makeModel() -> MavenLaunchPlan {
            MavenLaunchPlan(
                version: version,
                toolchain: executable.toolchain,
                arguments: arguments,
                workingDirectory: workingDirectory,
                configurationFingerprint: configurationFingerprint
            )
        }
    }

    struct MavenDependenciesPayload: Decodable, Sendable {
        struct Dependency: Decodable, Sendable {
            let modulePath: String
            let groupID: String
            let artifactID: String
            let version: String
            let type: String
            let classifier: String?
            let scope: String
            let resolution: String
            let selectedVersion: String?
            let children: [Dependency]

            enum CodingKeys: String, CodingKey {
                case modulePath
                case groupID = "groupId"
                case artifactID = "artifactId"
                case version
                case type
                case classifier
                case scope
                case resolution
                case selectedVersion
                case children
            }

            func makeModel() throws -> MavenDependency {
                guard let resolution = MavenDependencyResolution(rawValue: resolution) else {
                    throw MavenOperationError(
                        code: "parse_failed",
                        message: "Maven dependency resolution state is invalid.",
                        details: resolution
                    )
                }
                return MavenDependency(
                    modulePath: modulePath,
                    groupID: groupID,
                    artifactID: artifactID,
                    version: version,
                    type: type,
                    classifier: classifier,
                    scope: scope,
                    resolution: resolution,
                    selectedVersion: selectedVersion,
                    children: try children.map { try $0.makeModel() }
                )
            }
        }

        let modulePath: String
        let dependencies: [Dependency]

        func makeModel() throws -> MavenDependencyTree {
            MavenDependencyTree(
                modulePath: modulePath,
                dependencies: try dependencies.map { try $0.makeModel() }
            )
        }
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

    struct SpringIndexPayload: Decodable, Sendable {
        struct Property: Decodable, Sendable {
            let name: String
            let typeName: String?
            let description: String?
            let defaultValue: String?
            let sourcePath: String?
            let sourceLine: Int?
            let sourceColumn: Int?
        }
        struct ConfigurationValue: Decodable, Sendable {
            let key: String
            let value: String
            let path: String
            let line: Int
            let column: Int
            let profile: String?
            let overridesBaseValue: Bool
            let targetPath: String?
            let targetLine: Int?
            let targetColumn: Int?
        }
        struct PropertyReference: Decodable, Sendable {
            let key: String
            let path: String
            let line: Int
            let column: Int
        }
        struct Diagnostic: Decodable, Sendable {
            let path: String
            let line: Int
            let column: Int
            let severity: String
            let message: String
        }
        struct Bean: Decodable, Sendable {
            let id: String
            let name: String
            let typeName: String
            let path: String
            let line: Int
            let column: Int
            let kind: String
        }
        struct Injection: Decodable, Sendable {
            let path: String
            let line: Int
            let column: Int
            let typeName: String
            let qualifier: String?
            let beanIds: [String]
        }
        struct Endpoint: Decodable, Sendable {
            let id: String
            let httpMethods: [String]
            let route: String
            let controller: String
            let method: String
            let path: String
            let line: Int
            let column: Int
        }

        let properties: [Property]
        let values: [ConfigurationValue]
        let propertyReferences: [PropertyReference]
        let diagnostics: [Diagnostic]
        let beans: [Bean]
        let injections: [Injection]
        let endpoints: [Endpoint]
    }

    struct RunConfigurationPayload: Codable, Sendable {
        struct Toolchain: Codable, Sendable {
            struct Java: Codable, Sendable { let homePath: String? }
            struct Maven: Codable, Sendable {
                let executablePath: String?
                let javaHomePath: String?
            }

            let java: Java?
            let maven: Maven?
        }
        struct Generator: Codable, Sendable {
            let fingerprint: String
            let inputs: [String: String]?
        }
        struct Configuration: Codable, Sendable {
            struct Maven: Codable, Sendable {
                let module: String?
                let mainClass: String?
                let jvmArguments: [String]?
                let programArguments: [String]?
                let profiles: [String]?
                let skipTests: Bool?
            }
            struct Java: Codable, Sendable {
                let homePath: String?
                let mavenExecutablePath: String?
                let mavenJavaHomePath: String?
            }
            struct Debug: Codable, Sendable {
                let adapter: String
            }
            struct Extensions: Codable, Sendable {
                let maven: Maven?
                let java: Java?
            }
            let id: String
            let name: String
            let provider: String
            let execution: String?
            let command: String?
            let args: [String]?
            let cwd: String?
            let env: [String: String]?
            let confidence: String?
            let toolchains: [String: String]
            let debug: Debug?
            let members: [String]?
            let extensions: Extensions?
            let disabled: Bool
            let source: String?

            var maven: Maven? { extensions?.maven }
        }

        let version: Int
        let generator: Generator?
        let configurations: [Configuration]
        let diagnostics: [[String: String]]?
        let defaultRunConfiguration: String?
        let toolchain: Toolchain?
    }

    struct RunConfigurationGeneratePayload: Codable, Sendable {
        let generated: RunConfigurationPayload
        let toolchainRequirements: ToolchainRequirementsPayload
        let entryCount: Int
    }

    struct ToolchainRequirementsPayload: Codable, Sendable {
        struct Requirement: Codable, Sendable {
            let type: String
            let minimumVersion: String?
            let preferredVendor: String?
            let wrapper: String?
            let version: String?
            let java: String?
        }
        let version: Int
        let toolchains: [String: Requirement]
    }

    struct RunConfigurationInspectPayload: Codable, Sendable {
        let status: String
        let generated: RunConfigurationPayload?
        let toolchainRequirements: ToolchainRequirementsPayload?
        let diagnostics: [[String: String]]?
    }

    struct LaunchPlanPayload: Codable, Sendable {
        struct Executable: Codable, Sendable {
            let toolchain: String?
            let command: String?
        }
        let executable: Executable
        let arguments: [String]
        let workingDirectory: String
        let environment: [String: [String: String]]
        let env: [String: String]?
    }

    struct RunConfigurationMutationPayload: Codable, Sendable {
        let id: String?
        let document: String
    }

    struct RunConfigurationEditorMutationPayload: Codable, Sendable {
        let localDocument: String
        let projectDocument: String?
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

    struct TextPayload: Decodable, Sendable {
        let text: String
    }

    struct LspPositionPayload: Decodable, Sendable {
        let line: Int
        let utf16Column: Int

        func makeModel() -> LanguageServerPosition {
            LanguageServerPosition(line: line, utf16Column: utf16Column)
        }
    }

    struct LspRangePayload: Decodable, Sendable {
        let start: LspPositionPayload
        let end: LspPositionPayload

        func makeModel() -> LanguageServerRange {
            LanguageServerRange(start: start.makeModel(), end: end.makeModel())
        }
    }

    struct LspTextEditPayload: Decodable, Sendable {
        let range: LspRangePayload
        let newText: String

        func makeModel() -> LanguageServerTextEdit {
            LanguageServerTextEdit(range: range.makeModel(), newText: newText)
        }
    }

    struct BuiltinCompletionPayload: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let label: String
            let insertText: String
            let kind: Int?
            let detail: String?
            let documentation: String?
            let sortText: String?
            let filterText: String?
            let textEdit: LspTextEditPayload?
            let additionalTextEdits: [LspTextEditPayload]?
            let data: ToolingJSONValue?

            func makeModel() -> LanguageServerCompletionItem {
                LanguageServerCompletionItem(
                    label: label,
                    detail: detail,
                    documentation: documentation,
                    insertText: insertText,
                    sortText: sortText,
                    filterText: filterText,
                    kind: kind,
                    textEdit: textEdit?.makeModel(),
                    additionalTextEdits: additionalTextEdits?.map { $0.makeModel() } ?? [],
                    data: data
                )
            }
        }

        let items: [Item]

        func makeModels() -> [LanguageServerCompletionItem] {
            items.map { $0.makeModel() }
        }
    }

    struct LspCompletionResolvePayload: Decodable, Sendable {
        let item: BuiltinCompletionPayload.Item

        func makeModel() -> LanguageServerCompletionItem {
            item.makeModel()
        }
    }

    struct BuiltinHoverPayload: Decodable, Sendable {
        struct Hover: Decodable, Sendable {
            let contents: String
            let isMarkdown: Bool
            let range: LspRangePayload?

            func makeModel() -> LanguageServerHover {
                LanguageServerHover(
                    contents: contents,
                    isMarkdown: isMarkdown,
                    range: range?.makeModel()
                )
            }
        }

        let hover: Hover?
    }

    struct BuiltinNavigationPayload: Decodable, Sendable {
        struct Location: Decodable, Sendable {
            let uri: String?
            let filePath: String?
            let range: LspRangePayload
            let isReadOnly: Bool
            let displayPath: String?

            func makeModel() -> LanguageServerLocation? {
                let url: URL
                if let filePath {
                    url = URL(fileURLWithPath: filePath)
                } else if let uri, let virtualURL = URL(string: uri) {
                    url = virtualURL
                } else {
                    return nil
                }
                return LanguageServerLocation(
                    url: url,
                    range: range.makeModel(),
                    isReadOnly: isReadOnly,
                    displayPath: displayPath
                )
            }
        }

        let locations: [Location]

        func makeModels() -> [LanguageServerLocation] {
            locations.compactMap { $0.makeModel() }
        }
    }

    struct LspVirtualDocumentPayload: Decodable, Sendable {
        let text: String
    }

    struct LspWorkspaceEditPayload: Decodable, Sendable {
        let changes: [String: [LspTextEditPayload]]

        func makeModel() -> LanguageServerWorkspaceEdit {
            LanguageServerWorkspaceEdit(
                changes: Dictionary(
                    uniqueKeysWithValues: changes.map { path, edits in
                        (
                            URL(fileURLWithPath: path).standardizedFileURL,
                            edits.map { $0.makeModel() }
                        )
                    }
                )
            )
        }
    }

    struct LspFormattingPayload: Decodable, Sendable {
        let edits: [LspTextEditPayload]

        func makeModels() -> [LanguageServerTextEdit] {
            edits.map { $0.makeModel() }
        }
    }

    struct LspCommandPayload: Decodable, Sendable {
        let title: String
        let command: String
        let arguments: [ToolingJSONValue]?

        func makeModel() -> LanguageServerCommand {
            LanguageServerCommand(
                title: title,
                command: command,
                arguments: arguments ?? []
            )
        }
    }

    struct LspCodeActionsPayload: Decodable, Sendable {
        struct Action: Decodable, Sendable {
            let title: String
            let kind: String?
            let isPreferred: Bool
            let edit: LspWorkspaceEditPayload?
            let command: LspCommandPayload?
            let data: ToolingJSONValue?

            func makeModel() -> LanguageServerCodeAction {
                LanguageServerCodeAction(
                    title: title,
                    kind: kind,
                    isPreferred: isPreferred,
                    edit: edit?.makeModel(),
                    command: command?.makeModel(),
                    data: data
                )
            }
        }

        let actions: [Action]

        func makeModels() -> [LanguageServerCodeAction] {
            actions.map { $0.makeModel() }
        }
    }

    struct LspCodeActionResolvePayload: Decodable, Sendable {
        let action: LspCodeActionsPayload.Action

        func makeModel() -> LanguageServerCodeAction {
            action.makeModel()
        }
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

        struct SyntaxHighlight: Decodable, Sendable {
            let utf16Start: Int
            let utf16Length: Int
            let role: String

            func makeModel() -> JavaSyntaxHighlight? {
                guard utf16Start >= 0, utf16Length > 0 else { return nil }
                return JavaSyntaxHighlight(
                    range: NSRange(location: utf16Start, length: utf16Length),
                    role: role
                )
            }
        }

        let foldRegions: [FoldRegion]
        let syntaxHighlights: [SyntaxHighlight]

        func makeFoldRegions() -> [JavaFoldRegion] { foldRegions.compactMap { $0.makeModel() } }
        func makeSyntaxHighlights() -> [JavaSyntaxHighlight] {
            syntaxHighlights.compactMap { $0.makeModel() }
        }
    }

    struct GitCommandPayload: Decodable, Sendable {
        struct Invocation: Decodable, Sendable {
            let arguments: [String]
            let stdout: String
            let stderr: String
            let exitCode: Int32
        }

        struct OperationError: Decodable, Sendable {
            let code: String
            let message: String
            let details: String?

            var userMessage: String {
                if let details, !details.isEmpty {
                    return message + ": " + details
                }
                return message
            }
        }

        struct StashRestore: Decodable, Sendable {
            let stashReference: String
            let conflictedPaths: [String]
        }

        struct TagDeletion: Decodable, Sendable {
            let name: String
            let deletedTarget: String
            let kind: GitTagKind
            let message: String?
        }

        struct BranchDeletion: Decodable, Sendable {
            let name: String
            let deletedTarget: String
        }

        struct Warning: Decodable, Sendable {
            let code: String
            let message: String
            let details: String?
        }

        let arguments: [String]?
        let output: String
        let stdout: String?
        let stderr: String?
        let exitCode: Int32
        let invocations: [Invocation]?
        let operationError: OperationError?
        let stashRestore: StashRestore?
        let tagDeletion: TagDeletion?
        let branchDeletion: BranchDeletion?
        let warnings: [Warning]?
    }

    struct GitDiffPayload: Decodable, Sendable {
        struct Row: Decodable, Sendable {
            let oldLine: Int?
            let newLine: Int?
            let left: String?
            let right: String?
            let kind: String
            let hunkID: String?

            enum CodingKeys: String, CodingKey {
                case oldLine
                case newLine
                case left
                case right
                case kind
                case hunkID = "hunkId"
            }

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
            let peelsToCommit: Bool
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
        let recentReferences: [Reference]?
        let commits: [Commit]
        let hasMore: Bool
        let userName: String?
        let userEmail: String?

        func makeSnapshot() -> GitHistorySnapshot {
            GitHistorySnapshot(
                references: references.compactMap { reference in
                    guard let kind = GitReferenceKind(rawValue: reference.kind) else { return nil }
                    return GitReference(
                        fullName: reference.fullName,
                        shortName: reference.shortName,
                        kind: kind,
                        peelsToCommit: reference.peelsToCommit,
                        isCurrent: reference.isCurrent,
                        upstreamShortName: reference.upstreamShortName
                    )
                },
                recentReferences: (recentReferences ?? []).compactMap { reference in
                    guard let kind = GitReferenceKind(rawValue: reference.kind) else { return nil }
                    return GitReference(
                        fullName: reference.fullName,
                        shortName: reference.shortName,
                        kind: kind,
                        peelsToCommit: reference.peelsToCommit,
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
                hasMore: hasMore,
                identity: (userName == nil && userEmail == nil)
                    ? nil
                    : GitIdentity(name: userName, email: userEmail)
            )
        }
    }

    struct GitReferencesPayload: Decodable, Sendable {
        let references: [GitHistoryPayload.Reference]
        let recentReferences: [GitHistoryPayload.Reference]
        let userName: String?
        let userEmail: String?

        func makeSnapshot() -> GitReferenceSnapshot {
            GitReferenceSnapshot(
                references: references.compactMap(makeReference),
                recentReferences: recentReferences.compactMap(makeReference),
                identity: (userName == nil && userEmail == nil)
                    ? nil
                    : GitIdentity(name: userName, email: userEmail)
            )
        }

        private func makeReference(_ reference: GitHistoryPayload.Reference) -> GitReference? {
            guard let kind = GitReferenceKind(rawValue: reference.kind) else { return nil }
            return GitReference(
                fullName: reference.fullName,
                shortName: reference.shortName,
                kind: kind,
                isCurrent: reference.isCurrent,
                upstreamShortName: reference.upstreamShortName
            )
        }
    }

    struct GitHistoryPagePayload: Decodable, Sendable {
        let commits: [GitHistoryPayload.Commit]
        let nextCursor: String?
        let hasMore: Bool

        func makePage() -> GitHistoryPage {
            GitHistoryPage(
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
                nextCursor: nextCursor,
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

    struct GitCheckoutPreflightPayload: Decodable, Sendable {
        let blockingPaths: [String]
    }

    struct GitConflictMarkerPayload: Decodable, Sendable {
        let paths: [String]
    }

    struct GitIntegrationPreflightPayload: Decodable, Sendable {
        let blockingPaths: [String]
        let blocksEntirely: Bool
    }

    struct GitPullPreflightPayload: Decodable, Sendable {
        let upstream: String?
        let ahead: Int
        let behind: Int
        let diverged: Bool
        let hasLocalChanges: Bool
    }

    struct GitOperationStatePayload: Decodable, Sendable {
        let kind: String
        let reference: String?
        let step: Int?
        let total: Int?
        let conflictedPaths: [String]
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

    struct GitWatchContextPayload: Decodable, Sendable {
        let repositoryRoot: String
        let gitDirectory: String
        let gitCommonDirectory: String

        func makeContext() -> GitWatchContext {
            GitWatchContext(
                repositoryRoot: URL(fileURLWithPath: repositoryRoot).standardizedFileURL,
                gitDirectory: URL(fileURLWithPath: gitDirectory).standardizedFileURL,
                gitCommonDirectory: URL(fileURLWithPath: gitCommonDirectory).standardizedFileURL
            )
        }
    }

    struct GitWorktreesPayload: Decodable, Sendable {
        struct Worktree: Decodable, Sendable {
            let path: String
            let head: String
            let branch: String?
            let isCurrent: Bool
            let isPrimary: Bool
            let isBare: Bool
            let isDetached: Bool
            let isLocked: Bool
            let lockReason: String?
            let isPrunable: Bool
            let pruneReason: String?

            func makeModel() -> GitWorktree {
                GitWorktree(
                    path: path,
                    head: head,
                    branch: branch,
                    isCurrent: isCurrent,
                    isPrimary: isPrimary,
                    isBare: isBare,
                    isDetached: isDetached,
                    isLocked: isLocked,
                    lockReason: lockReason,
                    isPrunable: isPrunable,
                    pruneReason: pruneReason
                )
            }
        }

        let worktrees: [Worktree]
    }

    struct GitPullRequestContextPayload: Decodable, Sendable {
        let currentBranch: String?
        let suggestedBaseBranch: String?
        let suggestedPublishBranch: String?
        let requiresPublish: Bool
        let detached: Bool
        let hasUncommittedChanges: Bool
    }


    private struct EmptyPayload: Encodable {
        let value = 0
    }

    private struct SnapshotRequest: Encodable {
        let root: String
        let hiddenDirectoryNames: [String]
        let hiddenFilePatterns: [String]
    }

    private struct SearchIndexUpdateRequest: Encodable {
        let root: String
        let paths: [String]
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
        let fileMask: String
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
        let preserveCase: Bool
        let fileMask: String
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
        let paths: [String]
    }

    private struct MavenLaunchPlanRequest: Encodable {
        let root: String
        let context: MavenLaunchContext
        let module: String?
        let goals: [String]
    }

    private struct MavenDependencyPlanRequest: Encodable {
        let root: String
        let context: MavenLaunchContext
        let module: String?
    }

    private struct MarkdownRenderRequest: Encodable {
        let source: String
    }

    private struct LspTextEditsRequest: Encodable {
        struct TextEdit: Encodable {
            struct Range: Encodable {
                struct Position: Encodable {
                    let line: Int
                    let utf16Column: Int
                }

                let start: Position
                let end: Position
            }

            let range: Range
            let newText: String
        }

        let text: String
        let edits: [TextEdit]
    }

    private struct LspPlainSnippetRequest: Encodable {
        let value: String
    }

    private struct LspBuiltinRequest: Encodable {
        let filePath: String
        let text: String
        let position: LspTextEditsRequest.TextEdit.Range.Position
    }

    private struct LspBuiltinNavigationRequest: Encodable {
        let filePath: String
        let text: String
        let position: LspTextEditsRequest.TextEdit.Range.Position
        let method: String
    }

    struct LspClientDiagnosticPayload: Decodable, Sendable {
        let range: LspRangePayload
        let severity: Int?
        let message: String
        let source: String?
        let code: String?
        let tags: [Int]?
        let relatedInformation: [LspClientDiagnosticRelatedInformationPayload]?

        init(
            range: LspRangePayload,
            severity: Int?,
            message: String,
            source: String?,
            code: String?,
            tags: [Int]? = nil,
            relatedInformation: [LspClientDiagnosticRelatedInformationPayload]? = nil
        ) {
            self.range = range
            self.severity = severity
            self.message = message
            self.source = source
            self.code = code
            self.tags = tags
            self.relatedInformation = relatedInformation
        }

        func makeModel() -> LanguageServerDiagnostic {
            LanguageServerDiagnostic(
                range: range.makeModel(),
                severity: severity,
                message: message,
                source: source,
                code: code,
                tags: tags ?? [],
                relatedInformation: (relatedInformation ?? []).compactMap { $0.makeModel() }
            )
        }
    }

    struct LspClientDiagnosticRelatedInformationPayload: Decodable, Sendable {
        let location: LspClientDiagnosticLocationPayload
        let message: String

        func makeModel() -> LanguageServerDiagnosticRelatedInformation? {
            guard let fileURL = URL(string: location.uri) else { return nil }
            return LanguageServerDiagnosticRelatedInformation(
                fileURL: fileURL.standardizedFileURL,
                range: location.range.makeModel(),
                message: message
            )
        }
    }

    struct LspClientDiagnosticLocationPayload: Decodable, Sendable {
        let uri: String
        let range: LspRangePayload
    }

    private struct LspClientDiagnosticRequest: Encodable {
        let range: LspTextEditsRequest.TextEdit.Range
        let severity: Int?
        let message: String
        let source: String?
        let code: String?
        let tags: [Int]
        let relatedInformation: [LspClientDiagnosticRelatedInformationRequest]
    }

    private struct LspClientDiagnosticRelatedInformationRequest: Encodable {
        let location: LspClientDiagnosticLocationRequest
        let message: String
    }

    private struct LspClientDiagnosticLocationRequest: Encodable {
        let uri: String
        let range: LspTextEditsRequest.TextEdit.Range
    }

    private struct LspClientCompletionItemRequest: Encodable {
        let label: String
        let detail: String?
        let documentation: String?
        let insertText: String
        let sortText: String?
        let filterText: String?
        let kind: Int?
        let textEdit: LspClientTextEditRequest?
        let additionalTextEdits: [LspClientTextEditRequest]
        let data: ToolingJSONValue?
    }

    private struct LspClientTextEditRequest: Encodable {
        let range: LspTextEditsRequest.TextEdit.Range
        let newText: String
    }

    private struct LspClientWorkspaceEditRequest: Encodable {
        let changes: [String: [LspClientTextEditRequest]]
    }

    private struct LspClientCommandRequest: Encodable {
        let title: String
        let command: String
        let arguments: [ToolingJSONValue]
    }

    private struct LspClientCodeActionRequest: Encodable {
        let title: String
        let kind: String?
        let isPreferred: Bool
        let edit: LspClientWorkspaceEditRequest?
        let command: LspClientCommandRequest?
        let data: ToolingJSONValue?
    }

    // MARK: - Language-server runtime
    //
    // Rust owns the language-server process, wire protocol, and document
    // versions. These types carry only what the UI needs: an opaque
    // session ID, opaque operation IDs, and the events Rust chooses to publish.

    struct LspStartServerPayload: Decodable, Sendable {
        let sessionId: String
        let state: String
        let processId: Int32?
    }

    private struct JdtWorkspaceKeyRequest: Encodable {
        let workspaceRoot: String
        let workspaceFingerprint: String?
    }

    private struct JdtWorkspaceKeyPayload: Decodable {
        let workspaceKey: String
    }

    struct JdtBuildFileObservation: Encodable, Equatable, Sendable {
        let path: String
        let modifiedUnixMilliseconds: UInt64
        let sizeBytes: UInt64
    }

    private struct JdtWorkspaceFingerprintRequest: Encodable {
        let buildFiles: [JdtBuildFileObservation]
        let directMavenModules: [String]
        let jdtlsVersion: String
    }

    private struct JdtWorkspaceFingerprintPayload: Decodable {
        let workspaceFingerprint: String
    }

    struct JdtCacheEntry: Encodable, Sendable {
        let workspaceKey: String
        let lastModifiedUnixSeconds: UInt64
    }

    private struct JdtCacheRetentionRequest: Encodable {
        let nowUnixSeconds: UInt64
        let activeWorkspaceKey: String?
        let entries: [JdtCacheEntry]
    }

    struct JdtCacheRetentionPayload: Decodable, Sendable {
        let retentionDays: UInt64
        let expiredWorkspaceKeys: [String]
    }

    private struct JavaWorkspacePolicyRequest: Encodable {
        let workspacePaths: [String]
        let changedPaths: [String]
    }

    struct JavaWorkspacePolicyPayload: Decodable, Sendable {
        struct Change: Decodable, Sendable {
            let path: String
            let kind: String
        }

        let shouldStart: Bool
        let representativeJavaPath: String?
        let changes: [Change]
    }

    private struct LspStartServerRequest: Encodable {
        let providerId: String
        let executablePath: String
        let arguments: [String]
        let environment: [String: String]
        let rootUri: String
        let workingDirectory: String
        let initializationOptions: ToolingJSONValue?
        let runtimeExecutablePath: String?
        let jdtlsLaunchResources: LspJdtlsLaunchResourcesRequest?
        let cacheDirectory: String?
        let workspaceFingerprint: String?
        let mavenContext: MavenLaunchContext?
        let initializeTimeoutMilliseconds: Int
        let requestTimeoutMilliseconds: Int
        let shutdownTimeoutMilliseconds: Int
    }

    private struct LspJdtlsLaunchResourcesRequest: Encodable {
        let launcherJarPath: String
        let configurationDirectory: String
        let lombokAgentPath: String
        let javaDebugBundlePath: String?
        let javaExtensionBundlePaths: [String]
    }

    private struct LspSessionIdentifierRequest: Encodable {
        let sessionId: String
    }

    private struct LspSyncDocumentRequest: Encodable {
        struct Change: Encodable {
            let range: Range
            let text: String
        }
        struct Position: Encodable {
            let line: Int
            let character: Int
        }
        struct Range: Encodable {
            let start: LspSyncDocumentRequest.Position
            let end: LspSyncDocumentRequest.Position
        }
        let sessionId: String
        let uri: String
        let languageId: String
        let text: String
        let contentChanges: [Change]
    }

    private struct LspWorkspaceFilesChangedRequest: Encodable {
        struct Change: Encodable {
            let uri: String
            let kind: String
        }

        let sessionId: String
        let changes: [Change]
    }

    struct LspSyncDocumentPayload: Decodable, Sendable {
        let documentVersion: Int
        let changed: Bool
    }

    private struct JavaNavigationMarkersRequest: Encodable {
        let sessionId: String
        let uri: String
        let documentVersion: Int
    }

    private struct JavaResolveNavigationRequest: Encodable {
        let sessionId: String
        let uri: String
        let line: Int
        let utf16Column: Int
        let direction: String
        let relation: String
        let documentVersion: Int
    }

    private struct LspCloseDocumentRequest: Encodable {
        let sessionId: String
        let uri: String
    }

    /// A semantic request names the operation it wants, not the LSP method that
    /// implements it, so the wire protocol stays Rust's concern.
    private struct LspSemanticRequest: Encodable {
        let sessionId: String
        let operationId: String?
        let operation: String
        let uri: String?
        let virtualUri: String?
        let position: LspTextEditsRequest.TextEdit.Range.Position?
        let newName: String?
        let range: LspTextEditsRequest.TextEdit.Range?
        let diagnostics: [LspClientDiagnosticRequest]
        let completionItem: LspClientCompletionItemRequest?
        let codeAction: LspClientCodeActionRequest?
        let command: LspClientCommandRequest?

        init(
            sessionId: String,
            operationId: String? = nil,
            operation: String,
            uri: String? = nil,
            virtualUri: String? = nil,
            position: LspTextEditsRequest.TextEdit.Range.Position? = nil,
            newName: String? = nil,
            range: LspTextEditsRequest.TextEdit.Range? = nil,
            diagnostics: [LspClientDiagnosticRequest] = [],
            completionItem: LspClientCompletionItemRequest? = nil,
            codeAction: LspClientCodeActionRequest? = nil,
            command: LspClientCommandRequest? = nil
        ) {
            self.sessionId = sessionId
            self.operationId = operationId
            self.operation = operation
            self.uri = uri
            self.virtualUri = virtualUri
            self.position = position
            self.newName = newName
            self.range = range
            self.diagnostics = diagnostics
            self.completionItem = completionItem
            self.codeAction = codeAction
            self.command = command
        }
    }

    private struct LspCancelOperationRequest: Encodable {
        let sessionId: String
        let operationId: String
    }

    struct LspOperationPayload: Decodable, Sendable {
        let operationId: String
    }

    struct LspPollEventsPayload: Decodable, Sendable {
        let events: [LspRuntimeEventPayload]
    }

    struct LspRuntimeEventPayload: Decodable, Sendable {
        let type: String
        let sequence: UInt64
        let providerId: String
        let sessionId: String
        let state: String?
        let operationId: String?
        let method: String?
        let uri: String?
        let version: Int?
        let diagnostics: [LspClientDiagnosticPayload]?
        let result: ToolingJSONValue?
        let error: LspRuntimeErrorPayload?
        let capabilities: [String]?
        let serverInfo: LspServerInfoPayload?
        let level: String?
        let message: String?
        let detail: String?
    }

    struct LspRuntimeErrorPayload: Decodable, Sendable {
        let code: String
        let providerId: String
        let sessionId: String
        let stage: String
        let method: String?
        let documentUri: String?
        let message: String
        let underlyingMessage: String?
        let processExitCode: Int?
    }

    struct LspServerInfoPayload: Decodable, Sendable {
        let name: String
        let version: String?
    }

    private struct MavenDiagnosticsRequest: Encodable {
        let root: String
        let output: String
    }

    private struct MavenDependenciesRequest: Encodable {
        let modulePath: String
        let output: String
    }

    private struct JavaRunConfigurationsRequest: Encodable {
        let root: String
        let paths: [String]
        let modulePaths: [String]
    }

    private struct RunConfigurationInspectRequest: Encodable { let root: String }
    private struct RunConfigurationGenerateRequest: Encodable {
        let root: String
        let paths: [String]
        let modulePaths: [String]
    }
    private struct RunConfigurationResolveRequest: Encodable {
        let root: String
        let toolchainCandidates: [ProjectToolchainCandidate]
    }
    private struct RunConfigurationUpdateOptionsRequest: Encodable {
        let root: String
        let scope: String
        let configurationId: String
        let workingDirectory: String
        let jvmArguments: String
        let arguments: String
        let environment: [String: String]
        let mavenProfiles: [String]
        let mavenSkipTests: Bool?
        let javaHomePath: String
        let mavenExecutablePath: String
        let mavenJavaHomePath: String
        let toolchain: ProjectToolchainSelection?
    }
    private struct RunConfigurationCreateUserRequest: Encodable {
        let root: String
        let scope: String
        let name: String
        let type: String
        let module: String
        let mainClass: String
    }
    private struct LaunchPlanRequest: Encodable {
        let root: String
        let configurationId: String
        let currentFile: String?
        let classPath: String?
        let debugPort: Int?
        let mavenContext: MavenLaunchContext?
    }

    private struct JavaStructureRequest: Encodable {
        let source: String
        let declarationSources: [String]
    }

    private struct SpringIndexRequest: Encodable {
        let root: String
        let paths: [String]
        let metadataRepositories: [String]
        let refreshDependencyMetadata: Bool
        let textOverrides: [String: String]
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

    private struct GitWatchContextRequest: Encodable {
        let root: String
    }

    private struct GitPullRequestContextRequest: Encodable {
        let root: String
    }


    private struct GitCommandRequest: Encodable {
        let root: String
        let arguments: [String]
        let input: String?
    }

    private struct GitReferenceRequest: Encodable {
        let fullName: String
        let shortName: String
        let kind: String

        init(_ reference: GitReference) {
            fullName = reference.fullName
            shortName = reference.shortName
            kind = reference.kind.rawValue
        }
    }

    private struct GitWriteRequest: Encodable {
        let root: String
        let operation: String
        let paths: [String]
        let reference: String?
        let gitReference: GitReferenceRequest?
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
        let force: Bool
        let autoStash: Bool
    }

    private struct GitDiffRequest: Encodable {
        let root: String
        let pathspecs: [String]
        let reference: String?
        let gitReference: GitReferenceRequest?
        let targetGitReference: GitReferenceRequest?
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

    private struct GitReferencesRequest: Encodable {
        let root: String
    }

    private struct GitHistoryPageRequest: Encodable {
        let root: String
        let reference: String?
        let cursor: String?
        let limit: Int
    }

    private struct GitHistoryCursorCloseRequest: Encodable {
        let root: String
        let cursor: String
    }

    private struct GitHistoryCursorClosePayload: Decodable {
        let closed: Bool
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
        let reference: String?
        let gitReference: GitReferenceRequest?
        let targetGitReference: GitReferenceRequest?
    }

    private struct GitStashesRequest: Encodable {
        let root: String
    }

    private struct GitCheckoutPreflightRequest: Encodable {
        let root: String
        let gitReference: GitReferenceRequest
    }

    private struct GitOperationStateRequest: Encodable {
        let root: String
    }

    private struct GitPullPreflightRequest: Encodable {
        let root: String
    }

    private struct GitConflictMarkerRequest: Encodable {
        let root: String
    }

    private struct GitIntegrationPreflightRequest: Encodable {
        let root: String
        let reference: String?
        let gitReference: GitReferenceRequest?
        let operation: String
    }

    private struct GitBlameRequest: Encodable {
        let root: String
        let path: String
    }

    struct DiscourseAuthorizationStart: Decodable, Sendable {
        let flowId: String
        let authorizationUrl: String
        let expiresAt: UInt64
    }

    struct DiscourseAuthorizationCredential: Decodable, Sendable {
        let userApiKey: String
        let apiVersion: UInt64
    }

    struct DiscourseTopicSummary: Decodable, Identifiable, Sendable {
        let id: UInt64
        let slug: String
        let title: String
        let postsCount: UInt64
        let replyCount: UInt64
        let views: UInt64
        let likeCount: UInt64
        let categoryId: UInt64?
        let createdAt: String?
        let lastPostedAt: String?
        let lastPosterUsername: String?
        let pinned: Bool
        let closed: Bool
        let archived: Bool
    }

    struct DiscoursePost: Decodable, Identifiable, Sendable {
        let id: UInt64
        let postNumber: UInt64
        let username: String
        let name: String?
        let cooked: String
        let createdAt: String?
        let updatedAt: String?
        let replyCount: UInt64
        let reads: UInt64
    }

    struct DiscourseTopicsResponse: Decodable, Sendable {
        let topics: [DiscourseTopicSummary]
        let moreTopicsUrl: String?
    }

    struct DiscourseTopicResponse: Decodable, Sendable {
        let id: UInt64
        let title: String
        let slug: String
        let posts: [DiscoursePost]
    }

    struct DiscourseCategory: Decodable, Identifiable, Sendable {
        let id: UInt64
        let name: String
        let slug: String
        let color: String?
        let topicCount: UInt64
        let descriptionText: String?
    }

    struct DiscourseCategoriesResponse: Decodable, Sendable {
        let categories: [DiscourseCategory]
    }

    struct DiscourseSearchResponse: Decodable, Sendable {
        let topics: [DiscourseTopicSummary]
        let posts: [DiscoursePost]
    }

    private struct DiscourseAuthorizationBeginRequest: Encodable {
        let origin: String
        let clientId: String
        let applicationName: String
        let authRedirect: String
        let scopes: [String]
    }

    private struct DiscourseAuthorizationCompleteRequest: Encodable {
        let flowId: String
        let callbackUrl: String
    }

    private struct DiscourseAPIRequest: Encodable {
        let origin: String
        let userApiKey: String
        let clientId: String
    }

    private struct DiscourseTopicsRequest: Encodable {
        let origin: String
        let userApiKey: String
        let clientId: String
        let feed: String
        let period: String?
        let page: UInt32?
    }

    private struct DiscourseTopicRequest: Encodable {
        let origin: String
        let userApiKey: String
        let clientId: String
        let topicId: UInt64
    }

    private struct DiscourseSearchRequest: Encodable {
        let origin: String
        let userApiKey: String
        let clientId: String
        let query: String
        let page: UInt32?
    }

    var isAvailable: Bool {
        String(cString: lithe_bridge_version()) != "unlinked"
    }

    func version() -> String? {
        guard isAvailable else { return nil }
        return String(cString: lithe_bridge_version())
    }

    func beginDiscourseAuthorization(
        origin: String,
        clientID: String,
        applicationName: String,
        authRedirect: String,
        scopes: [String]
    ) -> Result<DiscourseAuthorizationStart, CoreCallError> {
        executeResult(
            command: "community.discourse.auth.begin",
            payload: DiscourseAuthorizationBeginRequest(
                origin: origin,
                clientId: clientID,
                applicationName: applicationName,
                authRedirect: authRedirect,
                scopes: scopes
            )
        )
    }

    func completeDiscourseAuthorization(
        flowID: String,
        callbackURL: String
    ) -> Result<DiscourseAuthorizationCredential, CoreCallError> {
        executeResult(
            command: "community.discourse.auth.complete",
            payload: DiscourseAuthorizationCompleteRequest(
                flowId: flowID,
                callbackUrl: callbackURL
            )
        )
    }

    func discourseTopics(
        origin: String,
        userAPIKey: String,
        clientID: String,
        feed: String,
        period: String? = nil,
        page: UInt32? = nil
    ) -> Result<DiscourseTopicsResponse, CoreCallError> {
        executeResult(
            command: "community.discourse.topics",
            payload: DiscourseTopicsRequest(
                origin: origin,
                userApiKey: userAPIKey,
                clientId: clientID,
                feed: feed,
                period: period,
                page: page
            )
        )
    }

    func discourseTopic(
        origin: String,
        userAPIKey: String,
        clientID: String,
        topicID: UInt64
    ) -> Result<DiscourseTopicResponse, CoreCallError> {
        executeResult(
            command: "community.discourse.topic",
            payload: DiscourseTopicRequest(
                origin: origin,
                userApiKey: userAPIKey,
                clientId: clientID,
                topicId: topicID
            )
        )
    }

    func discourseCategories(
        origin: String,
        userAPIKey: String,
        clientID: String
    ) -> Result<DiscourseCategoriesResponse, CoreCallError> {
        executeResult(
            command: "community.discourse.categories",
            payload: DiscourseAPIRequest(
                origin: origin,
                userApiKey: userAPIKey,
                clientId: clientID
            )
        )
    }

    func searchDiscourse(
        origin: String,
        userAPIKey: String,
        clientID: String,
        query: String,
        page: UInt32? = nil
    ) -> Result<DiscourseSearchResponse, CoreCallError> {
        executeResult(
            command: "community.discourse.search",
            payload: DiscourseSearchRequest(
                origin: origin,
                userApiKey: userAPIKey,
                clientId: clientID,
                query: query,
                page: page
            )
        )
    }

    func revokeDiscourseAuthorization(
        origin: String,
        userAPIKey: String,
        clientID: String
    ) -> Result<Void, CoreCallError> {
        executeVoid(
            command: "community.discourse.auth.revoke",
            payload: DiscourseAPIRequest(
                origin: origin,
                userApiKey: userAPIKey,
                clientId: clientID
            )
        )
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

    func warmSearchIndex(
        at rootURL: URL,
        hiddenDirectoryNames: [String] = [],
        hiddenFilePatterns: [String] = []
    ) {
        let _: SearchIndexStatusPayload? = execute(
            command: "workspace.searchIndex.warm",
            payload: SnapshotRequest(
                root: rootURL.standardizedFileURL.path,
                hiddenDirectoryNames: hiddenDirectoryNames,
                hiddenFilePatterns: hiddenFilePatterns
            )
        )
    }

    func updateSearchIndex(
        at rootURL: URL,
        changedPaths: [String],
        hiddenDirectoryNames: [String] = [],
        hiddenFilePatterns: [String] = []
    ) {
        let _: SearchIndexStatusPayload? = execute(
            command: "workspace.searchIndex.update",
            payload: SearchIndexUpdateRequest(
                root: rootURL.standardizedFileURL.path,
                paths: changedPaths,
                hiddenDirectoryNames: hiddenDirectoryNames,
                hiddenFilePatterns: hiddenFilePatterns
            )
        )
    }

    func invalidateSearchIndex(
        at rootURL: URL,
        hiddenDirectoryNames: [String] = [],
        hiddenFilePatterns: [String] = []
    ) {
        let _: EmptyResponsePayload? = execute(
            command: "workspace.searchIndex.invalidate",
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
        fileMask: String = "",
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
                fileMask: fileMask,
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
        fileMask: String = "",
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
                fileMask: fileMask,
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
        preserveCase: Bool = false,
        fileMask: String = "",
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
                preserveCase: preserveCase,
                fileMask: fileMask,
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

    func scanMaven(at rootURL: URL, paths: [String] = []) -> MavenScanPayload? {
        try? scanMavenResult(at: rootURL, paths: paths).get()
    }

    func scanMavenResult(
        at rootURL: URL,
        paths: [String] = []
    ) -> Result<MavenScanPayload?, CoreCallError> {
        let result: Result<Envelope<MavenScanPayload>, CoreCallError> = decodeEnvelope(
            command: "maven.scan",
            payload: MavenScanRequest(
                root: rootURL.standardizedFileURL.path,
                paths: paths
            )
        )
        return result.map(\.data)
    }

    func mavenLaunchPlan(
        at rootURL: URL,
        context: MavenLaunchContext,
        module: String?,
        goals: [String]
    ) -> Result<MavenLaunchPlanPayload, CoreCallError> {
        executeResult(
            command: "maven.launchPlan",
            payload: MavenLaunchPlanRequest(
                root: rootURL.standardizedFileURL.path,
                context: context,
                module: module,
                goals: goals
            )
        )
    }

    func mavenDependencyPlan(
        at rootURL: URL,
        context: MavenLaunchContext,
        module: String?
    ) -> Result<MavenLaunchPlanPayload, CoreCallError> {
        executeResult(
            command: "maven.dependencyPlan",
            payload: MavenDependencyPlanRequest(
                root: rootURL.standardizedFileURL.path,
                context: context,
                module: module
            )
        )
    }

    func mavenDependencies(
        modulePath: String,
        output: String
    ) -> Result<MavenDependenciesPayload, CoreCallError> {
        executeResult(
            command: "maven.dependencies",
            payload: MavenDependenciesRequest(modulePath: modulePath, output: output)
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

    func inspectRunConfiguration(at rootURL: URL) -> Result<RunConfigurationInspectPayload, CoreCallError> {
        executeResult(
            command: "runConfig.inspect",
            payload: RunConfigurationInspectRequest(root: rootURL.standardizedFileURL.path)
        )
    }

    func generateRunConfiguration(
        at rootURL: URL,
        paths: [String],
        modulePaths: [String]
    ) -> Result<RunConfigurationGeneratePayload, CoreCallError> {
        executeResult(
            command: "runConfig.generate",
            payload: RunConfigurationGenerateRequest(
                root: rootURL.standardizedFileURL.path,
                paths: paths,
                modulePaths: modulePaths
            )
        )
    }

    func resolveRunConfiguration(
        at rootURL: URL,
        toolchainCandidates: [ProjectToolchainCandidate]
    ) -> Result<RunConfigurationPayload, CoreCallError> {
        executeResult(
            command: "runConfig.resolve",
            payload: RunConfigurationResolveRequest(
                root: rootURL.standardizedFileURL.path,
                toolchainCandidates: toolchainCandidates
            )
        )
    }

    func createLaunchPlan(
        at rootURL: URL,
        configurationID: String,
        currentFile: String? = nil,
        classPath: String? = nil,
        debugPort: Int? = nil,
        mavenContext: MavenLaunchContext? = nil
    ) -> Result<LaunchPlanPayload, CoreCallError> {
        executeResult(
            command: "runConfig.createLaunchPlan",
            payload: LaunchPlanRequest(
                root: rootURL.standardizedFileURL.path,
                configurationId: configurationID,
                currentFile: currentFile,
                classPath: classPath,
                debugPort: debugPort,
                mavenContext: mavenContext
            )
        )
    }

    func updateRunConfigurationOptions(
        at rootURL: URL,
        configurationID: String,
        scope: RunConfigurationSaveScope,
        options: RunOptions
    ) -> Result<RunConfigurationMutationPayload, CoreCallError> {
        executeResult(
            command: "runConfig.updateOptions",
            payload: RunConfigurationUpdateOptionsRequest(
                root: rootURL.standardizedFileURL.path,
                scope: scope.rawValue,
                configurationId: configurationID,
                workingDirectory: options.workingDirectoryPath,
                jvmArguments: options.vmArguments,
                arguments: options.arguments,
                environment: options.environment,
                mavenProfiles: options.activeProfiles.sorted(),
                mavenSkipTests: options.mavenSkipTests,
                javaHomePath: options.javaHomePath,
                mavenExecutablePath: options.mavenExecutablePath,
                mavenJavaHomePath: options.mavenJavaHomePath,
                toolchain: nil
            )
        )
    }

    func saveRunConfigurationEditorChanges(
        at rootURL: URL,
        configurationID: String,
        scope: RunConfigurationSaveScope,
        options: RunOptions,
        toolchain: ProjectToolchainSelection
    ) -> Result<RunConfigurationEditorMutationPayload, CoreCallError> {
        executeResult(
            command: "runConfig.saveEditorChanges",
            payload: RunConfigurationUpdateOptionsRequest(
                root: rootURL.standardizedFileURL.path,
                scope: scope.rawValue,
                configurationId: configurationID,
                workingDirectory: options.workingDirectoryPath,
                jvmArguments: options.vmArguments,
                arguments: options.arguments,
                environment: options.environment,
                mavenProfiles: options.activeProfiles.sorted(),
                mavenSkipTests: options.mavenSkipTests,
                javaHomePath: options.javaHomePath,
                mavenExecutablePath: options.mavenExecutablePath,
                mavenJavaHomePath: options.mavenJavaHomePath,
                toolchain: toolchain
            )
        )
    }

    func createUserRunConfiguration(
        at rootURL: URL,
        draft: RunConfigurationDraft
    ) -> Result<RunConfigurationMutationPayload, CoreCallError> {
        executeResult(
            command: "runConfig.createUserConfiguration",
            payload: RunConfigurationCreateUserRequest(
                root: rootURL.standardizedFileURL.path,
                scope: draft.scope.rawValue,
                name: draft.name,
                type: draft.kind.id,
                module: draft.modulePath,
                mainClass: draft.mainClass
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

    func springIndex(
        at rootURL: URL,
        paths: [String],
        metadataRepositoryURLs: [URL] = [],
        refreshDependencyMetadata: Bool = false,
        textOverrides: [String: String] = [:]
    ) -> SpringIndexPayload? {
        execute(
            command: "spring.index",
            payload: SpringIndexRequest(
                root: rootURL.standardizedFileURL.path,
                paths: paths,
                metadataRepositories: metadataRepositoryURLs.map {
                    $0.standardizedFileURL.path
                },
                refreshDependencyMetadata: refreshDependencyMetadata,
                textOverrides: textOverrides
            )
        )
    }

    func gitStatus(at rootURL: URL) -> GitStatusPayload? {
        execute(
            command: "git.status",
            payload: GitStatusRequest(root: rootURL.standardizedFileURL.path)
        )
    }

    func gitWatchContext(at rootURL: URL) -> GitWatchContextPayload? {
        let result: Result<GitWatchContextPayload?, CoreCallError> = executeResult(
            command: "git.watchContext",
            payload: GitWatchContextRequest(root: rootURL.standardizedFileURL.path)
        )
        return try? result.get()
    }

    func gitWorktrees(at rootURL: URL) -> GitWorktreesPayload? {
        execute(
            command: "git.worktrees",
            payload: GitStatusRequest(root: rootURL.standardizedFileURL.path)
        )
    }

    func gitPullRequestContext(
        at rootURL: URL
    ) -> Result<GitPullRequestContextPayload, CoreCallError> {
        executeResult(
            command: "git.pullRequestContext",
            payload: GitPullRequestContextRequest(root: rootURL.standardizedFileURL.path)
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
        gitReference: GitReference? = nil,
        referenceKind: String? = nil,
        revision: String? = nil,
        name: String? = nil,
        message: String? = nil,
        remote: String? = nil,
        destination: String? = nil,
        mode: String? = nil,
        includeUntracked: Bool = false,
        checkout: Bool = false,
        amend: Bool = false,
        force: Bool = false,
        autoStash: Bool = false
    ) -> GitCommandPayload? {
        execute(
            command: "git.write",
            payload: GitWriteRequest(
                root: rootURL.standardizedFileURL.path,
                operation: operation,
                paths: paths,
                reference: reference,
                gitReference: gitReference.map(GitReferenceRequest.init),
                referenceKind: referenceKind,
                revision: revision,
                name: name,
                message: message,
                remote: remote,
                destination: destination,
                mode: mode,
                includeUntracked: includeUntracked,
                checkout: checkout,
                amend: amend,
                force: force,
                autoStash: autoStash
            )
        )
    }

    func gitCheckoutPreflight(at rootURL: URL, reference: GitReference) -> GitCheckoutPreflightPayload? {
        execute(
            command: "git.checkoutPreflight",
            payload: GitCheckoutPreflightRequest(
                root: rootURL.standardizedFileURL.path,
                gitReference: GitReferenceRequest(reference)
            )
        )
    }

    func gitOperationState(at rootURL: URL) -> GitOperationStatePayload? {
        execute(
            command: "git.operationState",
            payload: GitOperationStateRequest(
                root: rootURL.standardizedFileURL.path
            )
        )
    }

    func gitPullPreflight(at rootURL: URL) -> GitPullPreflightPayload? {
        execute(
            command: "git.pullPreflight",
            payload: GitPullPreflightRequest(
                root: rootURL.standardizedFileURL.path
            )
        )
    }

    func gitConflictMarkerPaths(at rootURL: URL) -> GitConflictMarkerPayload? {
        execute(
            command: "git.conflictMarkers",
            payload: GitConflictMarkerRequest(
                root: rootURL.standardizedFileURL.path
            )
        )
    }

    func gitIntegrationPreflight(
        at rootURL: URL,
        reference: String? = nil,
        gitReference: GitReference? = nil,
        operation: String
    ) -> GitIntegrationPreflightPayload? {
        execute(
            command: "git.integrationPreflight",
            payload: GitIntegrationPreflightRequest(
                root: rootURL.standardizedFileURL.path,
                reference: reference,
                gitReference: gitReference.map(GitReferenceRequest.init),
                operation: operation
            )
        )
    }

    func gitWriteResult(
        at rootURL: URL,
        operation: String,
        paths: [String] = [],
        reference: String? = nil,
        gitReference: GitReference? = nil,
        referenceKind: String? = nil,
        revision: String? = nil,
        name: String? = nil,
        message: String? = nil,
        remote: String? = nil,
        destination: String? = nil,
        mode: String? = nil,
        includeUntracked: Bool = false,
        checkout: Bool = false,
        amend: Bool = false,
        force: Bool = false,
        autoStash: Bool = false
    ) -> Result<GitCommandPayload, CoreCallError> {
        executeResult(
            command: "git.write",
            payload: GitWriteRequest(
                root: rootURL.standardizedFileURL.path,
                operation: operation,
                paths: paths,
                reference: reference,
                gitReference: gitReference.map(GitReferenceRequest.init),
                referenceKind: referenceKind,
                revision: revision,
                name: name,
                message: message,
                remote: remote,
                destination: destination,
                mode: mode,
                includeUntracked: includeUntracked,
                checkout: checkout,
                amend: amend,
                force: force,
                autoStash: autoStash
            )
        )
    }

    func gitDiff(
        at rootURL: URL,
        pathspecs: [String],
        reference: String? = nil,
        gitReference: GitReference? = nil,
        targetGitReference: GitReference? = nil,
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
                gitReference: gitReference.map(GitReferenceRequest.init),
                targetGitReference: targetGitReference.map(GitReferenceRequest.init),
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

    func gitReferences(
        at rootURL: URL,
        operationID: String
    ) -> GitReferencesPayload? {
        execute(
            command: "git.references",
            payload: GitReferencesRequest(root: rootURL.standardizedFileURL.path),
            operationID: operationID
        )
    }

    func gitHistoryPage(
        at rootURL: URL,
        reference: String?,
        cursor: String?,
        limit: Int,
        operationID: String
    ) -> GitHistoryPagePayload? {
        execute(
            command: "git.historyPage",
            payload: GitHistoryPageRequest(
                root: rootURL.standardizedFileURL.path,
                reference: reference,
                cursor: cursor,
                limit: limit
            ),
            operationID: operationID
        )
    }

    func closeGitHistoryCursor(at rootURL: URL, cursor: String) -> Bool {
        let payload: GitHistoryCursorClosePayload? = execute(
            command: "git.historyCursorClose",
            payload: GitHistoryCursorCloseRequest(
                root: rootURL.standardizedFileURL.path,
                cursor: cursor
            )
        )
        return payload?.closed ?? false
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

    func gitComparison(
        at rootURL: URL,
        reference: String? = nil,
        gitReference: GitReference? = nil,
        targetGitReference: GitReference? = nil
    ) -> GitComparisonPayload? {
        execute(
            command: "git.comparison",
            payload: GitComparisonRequest(
                root: rootURL.standardizedFileURL.path,
                reference: reference,
                gitReference: gitReference.map(GitReferenceRequest.init),
                targetGitReference: targetGitReference.map(GitReferenceRequest.init)
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

    func markdownRender(_ source: String) -> Result<MarkdownRenderPayload, CoreCallError> {
        executeResult(
            command: "markdown.render",
            payload: MarkdownRenderRequest(source: source)
        )
    }

    func applyLanguageServerTextEdits(
        _ edits: [LanguageServerTextEdit],
        to text: String
    ) -> Result<TextPayload, CoreCallError> {
        executeResult(
            command: "lsp.applyTextEdits",
            payload: LspTextEditsRequest(
                text: text,
                edits: edits.map { edit in
                    LspTextEditsRequest.TextEdit(
                        range: LspTextEditsRequest.TextEdit.Range(
                            start: LspTextEditsRequest.TextEdit.Range.Position(
                                line: edit.range.start.line,
                                utf16Column: edit.range.start.utf16Column
                            ),
                            end: LspTextEditsRequest.TextEdit.Range.Position(
                                line: edit.range.end.line,
                                utf16Column: edit.range.end.utf16Column
                            )
                        ),
                        newText: edit.newText
                    )
                }
            )
        )
    }

    func plainLanguageServerSnippet(_ value: String) -> String? {
        let response: TextPayload? = execute(
            command: "lsp.plainSnippet",
            payload: LspPlainSnippetRequest(value: value)
        )
        return response?.text
    }

    package func builtinLanguageCompletions(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition
    ) -> [LanguageServerCompletionItem]? {
        let response: BuiltinCompletionPayload? = execute(
            command: "lsp.builtinCompletions",
            payload: LspBuiltinRequest(
                filePath: fileURL.standardizedFileURL.path,
                text: text,
                position: .init(line: position.line, utf16Column: position.utf16Column)
            )
        )
        return response?.makeModels()
    }

    package func builtinLanguageHover(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition
    ) -> LanguageServerHover? {
        let response: BuiltinHoverPayload? = execute(
            command: "lsp.builtinHover",
            payload: LspBuiltinRequest(
                filePath: fileURL.standardizedFileURL.path,
                text: text,
                position: .init(line: position.line, utf16Column: position.utf16Column)
            )
        )
        return response?.hover?.makeModel()
    }

    package func builtinLanguageNavigation(
        method: String,
        fileURL: URL,
        text: String,
        position: LanguageServerPosition
    ) -> [LanguageServerLocation]? {
        let response: BuiltinNavigationPayload? = execute(
            command: "lsp.builtinNavigation",
            payload: LspBuiltinNavigationRequest(
                filePath: fileURL.standardizedFileURL.path,
                text: text,
                position: .init(line: position.line, utf16Column: position.utf16Column),
                method: method
            )
        )
        return response?.makeModels()
    }

    // MARK: - Language-server runtime

    /// Resolves the exact JDT LS directory key used by the Rust runtime.
    func jdtWorkspaceKey(
        workspaceRootURL: URL,
        workspaceFingerprint: String?
    ) -> Result<String, CoreCallError> {
        let result: Result<JdtWorkspaceKeyPayload, CoreCallError> = executeResult(
            command: "lsp.jdtWorkspaceKey",
            payload: JdtWorkspaceKeyRequest(
                workspaceRoot: workspaceRootURL.standardizedFileURL.path,
                workspaceFingerprint: workspaceFingerprint
            )
        )
        return result.map(\.workspaceKey)
    }

    /// Reduces platform filesystem observations to the shared JDT LS
    /// workspace-fingerprint representation owned by Rust Core.
    func jdtWorkspaceFingerprint(
        buildFiles: [JdtBuildFileObservation],
        directMavenModules: [String],
        jdtlsVersion: String
    ) -> Result<String, CoreCallError> {
        let result: Result<JdtWorkspaceFingerprintPayload, CoreCallError> = executeResult(
            command: "java.jdtWorkspaceFingerprint",
            payload: JdtWorkspaceFingerprintRequest(
                buildFiles: buildFiles,
                directMavenModules: directMavenModules,
                jdtlsVersion: jdtlsVersion
            )
        )
        return result.map(\.workspaceFingerprint)
    }

    /// Applies the shared retention policy to filesystem metadata collected by
    /// a platform adapter. Rust Core selects keys but never deletes directories.
    func jdtCacheRetention(
        nowUnixSeconds: UInt64,
        activeWorkspaceKey: String?,
        entries: [JdtCacheEntry]
    ) -> Result<JdtCacheRetentionPayload, CoreCallError> {
        executeResult(
            command: "java.jdtCacheRetention",
            payload: JdtCacheRetentionRequest(
                nowUnixSeconds: nowUnixSeconds,
                activeWorkspaceKey: activeWorkspaceKey,
                entries: entries
            )
        )
    }

    func javaWorkspacePolicy(
        workspacePaths: [String],
        changedPaths: [String]
    ) -> JavaWorkspacePolicyPayload? {
        execute(
            command: "java.workspacePolicy",
            payload: JavaWorkspacePolicyRequest(
                workspacePaths: workspacePaths,
                changedPaths: changedPaths
            )
        )
    }

    /// Starts a language server and returns its opaque session ID. Rust spawns
    /// and owns the process; nothing about it crosses back except this ID.
    func lspStartServer(
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        workingDirectoryURL: URL,
        initializationOptions: ToolingJSONValue? = nil,
        runtimeExecutableURL: URL? = nil,
        jdtlsLaunchResources: JDTLSLaunchResources? = nil,
        cacheDirectoryURL: URL? = nil,
        workspaceFingerprint: String? = nil,
        mavenContext: MavenLaunchContext? = nil,
        initializeTimeout: TimeInterval = 30,
        requestTimeout: TimeInterval = 30,
        shutdownTimeout: TimeInterval = 2
    ) -> Result<LspStartServerPayload, CoreCallError> {
        executeResult(
            command: "lsp.startServer",
            payload: LspStartServerRequest(
                providerId: providerID,
                executablePath: executableURL.standardizedFileURL.path,
                arguments: arguments,
                environment: environment,
                rootUri: rootURL.standardizedFileURL.absoluteString,
                workingDirectory: workingDirectoryURL.standardizedFileURL.path,
                initializationOptions: initializationOptions,
                runtimeExecutablePath: runtimeExecutableURL?.standardizedFileURL.path,
                jdtlsLaunchResources: jdtlsLaunchResources.map {
                    LspJdtlsLaunchResourcesRequest(
                        launcherJarPath: $0.launcherJarURL.path,
                        configurationDirectory: $0.configurationDirectoryURL.path,
                        lombokAgentPath: $0.lombokAgentURL.path,
                        javaDebugBundlePath: $0.javaDebugBundleURL?.path,
                        javaExtensionBundlePaths: $0.javaExtensionBundleURLs.map(\.path)
                    )
                },
                cacheDirectory: cacheDirectoryURL?.standardizedFileURL.path,
                workspaceFingerprint: workspaceFingerprint,
                mavenContext: mavenContext,
                initializeTimeoutMilliseconds: Self.milliseconds(initializeTimeout),
                requestTimeoutMilliseconds: Self.milliseconds(requestTimeout),
                shutdownTimeoutMilliseconds: Self.milliseconds(shutdownTimeout)
            )
        )
    }

    /// Asks the server to shut down. The session stays addressable until
    /// `lspDestroyServer`, so its terminal events can still be polled.
    func lspStopServer(sessionID: String) {
        executeVoid(
            command: "lsp.stopServer",
            payload: LspSessionIdentifierRequest(sessionId: sessionID)
        )
    }

    /// Publishes the current text of a document. Rust decides whether that means
    /// an open or a change, and assigns the version.
    func lspSyncDocument(
        sessionID: String,
        fileURL: URL,
        languageID: String,
        text: String,
        changes: [LanguageServerDocumentChange] = []
    ) -> Result<LspSyncDocumentPayload, CoreCallError> {
        executeResult(
            command: "lsp.syncDocument",
            payload: LspSyncDocumentRequest(
                sessionId: sessionID,
                uri: fileURL.standardizedFileURL.absoluteString,
                languageId: languageID,
                // Keep the full snapshot for the initial didOpen and as a
                // recovery source; Rust emits range-based didChange when safe.
                text: text,
                contentChanges: changes.map { change in
                    LspSyncDocumentRequest.Change(
                        range: .init(
                            start: LspSyncDocumentRequest.Position(
                                line: change.start.line,
                                character: change.start.utf16Column
                            ),
                            end: LspSyncDocumentRequest.Position(
                                line: change.end.line,
                                character: change.end.utf16Column
                            )
                        ),
                        text: change.text
                    )
                }
            )
        )
    }

    func syncLanguageServerDocument(
        sessionID: String,
        fileURL: URL,
        languageID: String,
        text: String,
        changes: [LanguageServerDocumentChange]
    ) -> Result<LanguageServerDocumentSync, LanguageServerRuntimeFailure> {
        lspSyncDocument(
            sessionID: sessionID,
            fileURL: fileURL,
            languageID: languageID,
            text: text,
            changes: changes
        ).map {
            LanguageServerDocumentSync(
                documentVersion: $0.documentVersion,
                changed: $0.changed
            )
        }.mapError { error in
            LanguageServerRuntimeFailure(
                code: error.code,
                message: error.message,
                details: error.details
            )
        }
    }

    func lspWorkspaceFilesChanged(
        sessionID: String,
        changes: [LanguageServerWorkspaceFileChange]
    ) -> Result<Void, CoreCallError> {
        executeVoid(
            command: "lsp.workspaceFilesChanged",
            payload: LspWorkspaceFilesChangedRequest(
                sessionId: sessionID,
                changes: changes.map {
                    LspWorkspaceFilesChangedRequest.Change(
                        uri: $0.fileURL.standardizedFileURL.absoluteString,
                        kind: $0.kind.rawValue
                    )
                }
            )
        )
    }

    func lspCloseDocument(sessionID: String, fileURL: URL) {
        executeVoid(
            command: "lsp.closeDocument",
            payload: LspCloseDocumentRequest(
                sessionId: sessionID,
                uri: fileURL.standardizedFileURL.absoluteString
            )
        )
    }

    /// Issues a semantic request and returns the operation ID its completion
    /// event will carry. The result arrives through `lspPollEvents`, not here.
    func lspRequest(
        sessionID: String,
        operation: LanguageServerOperation,
        fileURL: URL? = nil,
        virtualURI: String? = nil,
        position: LanguageServerPosition? = nil,
        newName: String? = nil,
        range: LanguageServerRange? = nil,
        diagnostics: [LanguageServerDiagnostic] = [],
        completionItem: LanguageServerCompletionItem? = nil,
        codeAction: LanguageServerCodeAction? = nil,
        command: LanguageServerCommand? = nil
    ) -> Result<LspOperationPayload, CoreCallError> {
        executeResult(
            command: "lsp.request",
            payload: LspSemanticRequest(
                sessionId: sessionID,
                operation: operation.rawValue,
                uri: fileURL?.standardizedFileURL.absoluteString,
                virtualUri: virtualURI,
                position: position.map {
                    .init(line: $0.line, utf16Column: $0.utf16Column)
                },
                newName: newName,
                range: range.map(Self.makeRangeRequest),
                diagnostics: diagnostics.map(Self.makeDiagnosticRequest),
                completionItem: completionItem.map(Self.makeCompletionItemRequest),
                codeAction: codeAction.map(Self.makeCodeActionRequest),
                command: command.map(Self.makeCommandRequest)
            )
        )
    }

    func lspJavaNavigationMarkers(
        sessionID: String,
        fileURL: URL,
        documentVersion: Int
    ) -> Result<LspOperationPayload, CoreCallError> {
        executeResult(
            command: "java.navigationMarkers",
            payload: JavaNavigationMarkersRequest(
                sessionId: sessionID,
                uri: fileURL.standardizedFileURL.absoluteString,
                documentVersion: documentVersion
            )
        )
    }

    func lspResolveJavaNavigation(
        sessionID: String,
        fileURL: URL,
        marker: JavaNavigationMarker,
        documentVersion: Int
    ) -> Result<LspOperationPayload, CoreCallError> {
        executeResult(
            command: "java.resolveNavigation",
            payload: JavaResolveNavigationRequest(
                sessionId: sessionID,
                uri: fileURL.standardizedFileURL.absoluteString,
                line: marker.line,
                utf16Column: marker.utf16Column,
                direction: marker.direction.rawValue,
                relation: marker.relation.rawValue,
                documentVersion: documentVersion
            )
        )
    }

    /// Cancels a pending operation. Its completion event still arrives, carrying
    /// a cancellation error, so callers never leak a continuation.
    func lspCancelOperation(sessionID: String, operationID: String) {
        executeVoid(
            command: "lsp.cancelOperation",
            payload: LspCancelOperationRequest(
                sessionId: sessionID,
                operationId: operationID
            )
        )
    }

    /// Drains everything the runtime has published since the last poll.
    func lspPollEvents(sessionID: String) -> [LspRuntimeEventPayload] {
        let payload: LspPollEventsPayload? = execute(
            command: "lsp.pollEvents",
            payload: LspSessionIdentifierRequest(sessionId: sessionID)
        )
        return payload?.events ?? []
    }

    /// Releases a stopped or failed session. A running session is refused, so
    /// callers stop first and destroy once the terminal event arrives.
    func lspDestroyServer(sessionID: String) {
        executeVoid(
            command: "lsp.destroyServer",
            payload: LspSessionIdentifierRequest(sessionId: sessionID)
        )
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int {
        Int((interval * 1000).rounded())
    }

    private static func makeCompletionItemRequest(
        _ item: LanguageServerCompletionItem
    ) -> LspClientCompletionItemRequest {
        LspClientCompletionItemRequest(
            label: item.label,
            detail: item.detail,
            documentation: item.documentation,
            insertText: item.insertText,
            sortText: item.sortText,
            filterText: item.filterText,
            kind: item.kind,
            textEdit: item.textEdit.map(makeTextEditRequest),
            additionalTextEdits: item.additionalTextEdits.map(makeTextEditRequest),
            data: item.data
        )
    }

    private static func makeRangeRequest(
        _ range: LanguageServerRange
    ) -> LspTextEditsRequest.TextEdit.Range {
        .init(
            start: .init(
                line: range.start.line,
                utf16Column: range.start.utf16Column
            ),
            end: .init(
                line: range.end.line,
                utf16Column: range.end.utf16Column
            )
        )
    }

    private static func makeDiagnosticRequest(
        _ diagnostic: LanguageServerDiagnostic
    ) -> LspClientDiagnosticRequest {
        LspClientDiagnosticRequest(
            range: makeRangeRequest(diagnostic.range),
            severity: diagnostic.severity,
            message: diagnostic.message,
            source: diagnostic.source,
            code: diagnostic.code,
            tags: diagnostic.tags,
            relatedInformation: diagnostic.relatedInformation.map {
                LspClientDiagnosticRelatedInformationRequest(
                    location: LspClientDiagnosticLocationRequest(
                        uri: $0.fileURL.standardizedFileURL.absoluteString,
                        range: makeRangeRequest($0.range)
                    ),
                    message: $0.message
                )
            }
        )
    }

    private static func makeTextEditRequest(
        _ edit: LanguageServerTextEdit
    ) -> LspClientTextEditRequest {
        LspClientTextEditRequest(
            range: .init(
                start: .init(line: edit.range.start.line, utf16Column: edit.range.start.utf16Column),
                end: .init(line: edit.range.end.line, utf16Column: edit.range.end.utf16Column)
            ),
            newText: edit.newText
        )
    }

    private static func makeCodeActionRequest(
        _ action: LanguageServerCodeAction
    ) -> LspClientCodeActionRequest {
        LspClientCodeActionRequest(
            title: action.title,
            kind: action.kind,
            isPreferred: action.isPreferred,
            edit: action.edit.map(makeWorkspaceEditRequest),
            command: action.command.map {
                makeCommandRequest($0)
            },
            data: action.data
        )
    }

    private static func makeCommandRequest(
        _ command: LanguageServerCommand
    ) -> LspClientCommandRequest {
        LspClientCommandRequest(
            title: command.title,
            command: command.command,
            arguments: command.arguments
        )
    }

    private static func makeWorkspaceEditRequest(
        _ edit: LanguageServerWorkspaceEdit
    ) -> LspClientWorkspaceEditRequest {
        LspClientWorkspaceEditRequest(
            changes: Dictionary(
                uniqueKeysWithValues: edit.changes.map { url, edits in
                    (url.standardizedFileURL.path, edits.map(makeTextEditRequest))
                }
            )
        )
    }

    private func execute<Payload: Encodable, Data: Decodable>(
        command: String,
        payload: Payload,
        operationID: String? = nil
    ) -> Data? {
        try? executeResult(
            command: command,
            payload: payload,
            operationID: operationID
        ).get()
    }

    /// Runs a command whose success carries no data. The core encodes those as a
    /// null payload, so success is the absence of an error rather than a decoded
    /// value, and `executeResult`'s missing-data check does not apply.
    @discardableResult
    private func executeVoid<Payload: Encodable>(
        command: String,
        payload: Payload
    ) -> Result<Void, CoreCallError> {
        let outcome: Result<Envelope<ToolingJSONValue>, CoreCallError> = decodeEnvelope(
            command: command,
            payload: payload
        )
        return outcome.map { _ in () }
    }

    func executeResult<Payload: Encodable, Data: Decodable>(
        command: String,
        payload: Payload,
        operationID: String? = nil
    ) -> Result<Data, CoreCallError> {
        let outcome: Result<Envelope<Data>, CoreCallError> = decodeEnvelope(
            command: command,
            payload: payload,
            operationID: operationID
        )
        return outcome.flatMap { envelope in
            guard let value = envelope.data else {
                return .failure(CoreCallError(
                    code: "unknown",
                    message: "Rust Core response did not contain data",
                    details: nil
                ))
            }
            return .success(value)
        }
    }

    /// Performs the call and reports the envelope's own verdict. Whether a
    /// payload is required is the caller's business.
    private func decodeEnvelope<Payload: Encodable, Data: Decodable>(
        command: String,
        payload: Payload,
        operationID: String? = nil
    ) -> Result<Envelope<Data>, CoreCallError> {
        guard isAvailable else {
            return .failure(CoreCallError(
                code: "unknown",
                message: "Rust Core is unavailable",
                details: nil
            ))
        }
        let requestID = operationID ?? UUID().uuidString
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
        return .success(envelope)
    }

    @discardableResult
    func cancel(operationID: String) -> Bool {
        operationID.withCString { lithe_bridge_cancel($0) != 0 }
    }

    func githubParseRemote(_ remoteURL: String) -> Result<GitHubRepository, CoreCallError> {
        executeResult(
            command: "github.parseRemote",
            payload: GitHubParseRemoteRequest(remoteURL: remoteURL)
        )
    }

    func githubRequestPlan(_ request: GitHubRequest) -> Result<GitHubRequestPlan, CoreCallError> {
        executeResult(command: "github.requestPlan", payload: request)
    }

    func githubNormalizeResponse(
        operation: String,
        status: Int,
        body: String
    ) -> Result<GitHubNormalizedResponse, CoreCallError> {
        let payload = GitHubNormalizeResponseRequest(
            operation: operation,
            status: status,
            body: body
        )
        switch operation {
        case "deviceCode":
            let result: Result<GitHubDeviceAuthorization, CoreCallError> = executeResult(
                command: "github.normalizeResponse",
                payload: payload
            )
            return result.map(GitHubNormalizedResponse.deviceAuthorization)
        case "deviceToken":
            let result: Result<GitHubDeviceTokenResponse, CoreCallError> = executeResult(
                command: "github.normalizeResponse",
                payload: payload
            )
            return result.map(GitHubNormalizedResponse.deviceToken)
        case "currentUser":
            let result: Result<GitHubUser, CoreCallError> = executeResult(
                command: "github.normalizeResponse",
                payload: payload
            )
            return result.map(GitHubNormalizedResponse.user)
        case "listBranches":
            let result: Result<[GitHubBranch], CoreCallError> = executeResult(
                command: "github.normalizeResponse",
                payload: payload
            )
            return result.map(GitHubNormalizedResponse.branches)
        case "compareBranches":
            let result: Result<GitHubComparison, CoreCallError> = executeResult(
                command: "github.normalizeResponse",
                payload: payload
            )
            return result.map(GitHubNormalizedResponse.comparison)
        case "listPullRequests":
            let result: Result<[GitHubPullRequest], CoreCallError> = executeResult(
                command: "github.normalizeResponse",
                payload: payload
            )
            return result.map(GitHubNormalizedResponse.pullRequests)
        case "getPullRequest", "createPullRequest", "updatePullRequest":
            let result: Result<GitHubPullRequest, CoreCallError> = executeResult(
                command: "github.normalizeResponse",
                payload: payload
            )
            return result.map(GitHubNormalizedResponse.pullRequest)
        case "listPullRequestFiles":
            let result: Result<[GitHubPullRequestFile], CoreCallError> = executeResult(
                command: "github.normalizeResponse",
                payload: payload
            )
            return result.map(GitHubNormalizedResponse.files)
        case "listPullRequestComments":
            let result: Result<[GitHubComment], CoreCallError> = executeResult(
                command: "github.normalizeResponse",
                payload: payload
            )
            return result.map(GitHubNormalizedResponse.comments)
        case "createPullRequestComment":
            let result: Result<GitHubComment, CoreCallError> = executeResult(
                command: "github.normalizeResponse",
                payload: payload
            )
            return result.map(GitHubNormalizedResponse.comment)
        case "createPullRequestReview":
            let result: Result<EmptyResponsePayload, CoreCallError> = executeResult(
                command: "github.normalizeResponse",
                payload: payload
            )
            return result.map { _ in GitHubNormalizedResponse.review }
        case "updatePullRequestMetadata":
            let result: Result<EmptyResponsePayload, CoreCallError> = executeResult(
                command: "github.normalizeResponse",
                payload: payload
            )
            return result.map { _ in GitHubNormalizedResponse.metadata }
        case "mergePullRequest":
            let result: Result<GitHubMergeResult, CoreCallError> = executeResult(
                command: "github.normalizeResponse",
                payload: payload
            )
            return result.map(GitHubNormalizedResponse.merge)
        default:
            return .failure(CoreCallError(
                code: "not_supported",
                message: "Unsupported GitHub response operation",
                details: operation
            ))
        }
    }
}

private extension RustCoreBridge.WorkspaceNodePayload {
    func makeFileNode(at rootURL: URL) -> FileNode {
        makeFileNode(at: rootURL, insideSourceRoot: false)
    }

    /// 把只含单个子目录的中间包压缩成一行（IDEA 的 Compact Middle Packages）。
    /// 规则对齐 TreeViewUtil.isEmptyMiddlePackage：唯一的子节点是目录、且当前
    /// 目录下没有文件时才压缩。只在源码根之下压缩，src/main/java 之外的目录树
    /// 保持原样，否则普通项目里任意的单层目录也会被合并，反而更难看懂。
    private func makeFileNode(at rootURL: URL, insideSourceRoot: Bool) -> FileNode {
        let url = path.isEmpty ? rootURL : rootURL.appendingPathComponent(path)

        guard isDirectory else {
            return FileNode(url: url, isDirectory: false, children: nil)
        }

        let selfIsSourceRoot = LitheIcons.isSourceRootDirectory(url)
        let childrenInsideSourceRoot = insideSourceRoot || selfIsSourceRoot

        // 源码根本身不参与压缩，从它的子目录开始。
        var collapsed: [String] = []
        var node = self
        var nodeURL = url
        if insideSourceRoot {
            while let kids = node.children,
                  kids.count == 1,
                  let only = kids.first,
                  only.isDirectory,
                  LitheIcons.isValidPackageName(only.name) {
                collapsed.append(nodeURL.path)
                node = only
                nodeURL = rootURL.appendingPathComponent(only.path)
            }
        }

        return FileNode(
            url: nodeURL,
            isDirectory: true,
            children: node.children?.map {
                $0.makeFileNode(at: rootURL, insideSourceRoot: childrenInsideSourceRoot)
            },
            collapsedAncestorPaths: collapsed,
            isInsideSourceRoot: insideSourceRoot
        )
    }
}
