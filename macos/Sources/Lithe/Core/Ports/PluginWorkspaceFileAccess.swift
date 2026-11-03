import Foundation

// Note: 插件公共 API 计划见 docs/development/macos-plugin-api-plan.md 第 3.2 节（API-06/07/08）
// 与第 4.2、4.3 节。这里只是宿主内部服务，尚未暴露为插件公共 API；M0 的宿主服务分发层负责
// 授权、能力协商和把插件请求映射成下面的显式根与调用方身份。

/// Where the files of a workspace root live.
///
/// Only `.local` is served. A remote root is backed on this Mac by an empty
/// placeholder directory (`MacRemoteWorkspaceRoots`), so reading it locally
/// would silently return an empty tree; every operation rejects it with
/// ``PluginWorkspaceFileError/unsupportedAuthority`` instead.
enum PluginWorkspaceAuthority: Hashable, Sendable {
    case local
    /// Host-issued authority of a non-local root, for example a remote connection.
    case remote(String)
}

/// A workspace root as issued by the host to one caller.
///
/// Every request carries it explicitly; the service never falls back to the
/// active window. `url` is platform-owned and never appears in results.
struct PluginWorkspaceRoot: Hashable, Sendable {
    /// Host-issued root ID, echoed in every ``PluginWorkspaceResource``.
    let id: String
    let url: URL
    let authority: PluginWorkspaceAuthority
    /// Host-issued generation of this root. Reopening a root with the same ID
    /// uses a larger value; older generations are rejected as stale and their
    /// watchers are released.
    let generation: UInt64
    /// The workspace's own Project-view rules. They are host state, never a
    /// caller argument, so listings, search and watch hide what the tree hides.
    let visibilityRules: FileVisibilityRules

    init(
        id: String,
        url: URL,
        authority: PluginWorkspaceAuthority,
        generation: UInt64,
        visibilityRules: FileVisibilityRules = .default
    ) {
        self.id = id
        self.url = url
        self.authority = authority
        self.generation = generation
        self.visibilityRules = visibilityRules
    }
}

/// Identity of the requesting plugin session, verified by the dispatcher.
/// Watch subscriptions and concurrency budgets are owned per caller.
struct PluginWorkspaceCaller: Hashable, Sendable {
    let pluginID: String
    let sessionID: String
}

/// Stable resource identifier: a root ID plus a `/`-separated, NFC-normalized
/// path relative to that root. `""` is the root itself. It never contains an
/// OS absolute path, `.` or `..` components, or empty components.
struct PluginWorkspaceResource: Hashable, Sendable, Codable {
    let rootID: String
    let path: String
}

enum PluginWorkspaceEntryKind: String, Hashable, Sendable, Codable {
    case file
    case directory
    /// Reported by `stat`, omitted from listings and never followed (see the
    /// symbolic-link policy on ``PluginWorkspaceFileAccess``).
    case symbolicLink
    /// FIFOs, sockets and device nodes. Listed, never read.
    case other
}

struct PluginWorkspaceDirectoryEntry: Hashable, Sendable {
    let name: String
    let resource: PluginWorkspaceResource
    let kind: PluginWorkspaceEntryKind
}

/// One page of a directory, ordered like Project-view siblings (directories
/// first, then natural file-name order). `nextCursor` is opaque, bound to the
/// directory, root and generation, and `nil` on the last page. Entries added
/// or removed between pages do not shift unrelated entries, because the
/// cursor is the last returned sort key, not an offset.
struct PluginWorkspaceDirectoryPage: Sendable {
    let directory: PluginWorkspaceResource
    let entries: [PluginWorkspaceDirectoryEntry]
    let nextCursor: String?
}

struct PluginWorkspaceFileStat: Hashable, Sendable {
    let resource: PluginWorkspaceResource
    let kind: PluginWorkspaceEntryKind
    /// Size in bytes as reported by the file system (the link itself for
    /// `.symbolicLink`).
    let size: UInt64
    let modificationDate: Date
}

enum PluginWorkspaceFileContent: Sendable, Equatable {
    /// Decoded text. `encoding` is a ``DocumentEncoding`` stable ID such as
    /// `utf-8` or `gb18030`, detected the way the editor detects it.
    case text(String, encoding: String)
    /// Bytes that are not plain text in any detected encoding.
    case binary(Data)
}

/// Disk contents of one regular file. Unsaved editor buffers are never
/// consulted; `source` states that explicitly.
struct PluginWorkspaceFileContents: Sendable {
    let resource: PluginWorkspaceResource
    let content: PluginWorkspaceFileContent
    /// Bytes read from disk (at most the requested maximum).
    let byteCount: Int
    /// The file has more bytes than were read. Text ends at the last complete
    /// character inside the limit.
    let isTruncated: Bool
    /// SHA-256 of the complete file, matching the editor's document identity.
    /// `nil` when truncated, because a prefix hash identifies no file version.
    let identity: String?
    let source: PluginWorkspaceDataSource
}

/// Which data a read or search used.
enum PluginWorkspaceDataSource: String, Hashable, Sendable, Codable {
    /// Bytes on disk. Unsaved editor changes are not included.
    case disk
}

/// A coalesced change notice. It is not a log of every file-system event:
/// `changedPaths` may name paths that changed, were created or were deleted,
/// and a caller must `stat` or list them again. When `requiresRescan` is set,
/// changes were lost (native overflow, root replaced, or the pending set
/// exceeded its budget) and `changedPaths` is empty; the caller must reload the
/// subscribed directory.
struct PluginWorkspaceWatchEvent: Sendable, Equatable {
    let subscriptionID: UUID
    let rootID: String
    let generation: UInt64
    /// Strictly increasing per subscription, starting at 1.
    let sequence: UInt64
    let changedPaths: [String]
    let requiresRescan: Bool
}

/// Owned by the caller that created it. Disposing is idempotent; after
/// `dispose()` returns no further event is delivered.
protocol PluginWorkspaceWatchSubscription: AnyObject, Sendable {
    var id: UUID { get }
    func dispose()
}

struct PluginWorkspaceFindFilesQuery: Hashable, Sendable {
    /// File-name query, matched like Search Everywhere's Files provider.
    var query: String
    /// Comma-separated globs such as `*.swift, *.md`; empty means all files.
    var fileMask: String = ""
}

struct PluginWorkspaceFindTextQuery: Hashable, Sendable {
    var pattern: String
    var caseSensitive = false
    var wholeWords = false
    var regularExpression = false
    var fileMask = ""
}

struct PluginWorkspaceFileMatch: Hashable, Sendable {
    let resource: PluginWorkspaceResource
}

struct PluginWorkspaceTextMatch: Hashable, Sendable {
    let resource: PluginWorkspaceResource
    /// One-based line number.
    let line: Int
    let preview: String
}

/// A page of search results. The underlying project search returns at most
/// ``PluginWorkspaceFileBudgets/searchResultCap`` matches; `isTruncated` means
/// that cap was reached and more matches may exist. Pages are cut from a fresh
/// search each time, so files changed between pages can shift results.
struct PluginWorkspaceSearchPage<Match: Sendable>: Sendable {
    let matches: [Match]
    let nextCursor: String?
    let isTruncated: Bool
    let source: PluginWorkspaceDataSource
}

enum PluginWorkspacePathRejection: String, Hashable, Sendable {
    case absolute
    case emptyComponent
    case currentDirectoryComponent
    case parentTraversal
    case nulCharacter
    case componentTooLong
    case pathTooLong
}

enum PluginWorkspaceLimit: String, Hashable, Sendable {
    case concurrentOperations
    case directoryEntries
    case watchSubscriptions
}

/// Stable failure categories. The contract PR maps them to wire error codes;
/// platform detail stays in `io(errno:)` and must not reach users verbatim.
enum PluginWorkspaceFileError: Error, Hashable, Sendable {
    case unsupportedAuthority
    case invalidRoot
    /// The root generation was closed or superseded.
    case staleWorkspace
    case invalidPath(PluginWorkspacePathRejection)
    case notFound
    case notDirectory
    case notRegularFile
    /// A path component is a symbolic link; links are never followed.
    case symbolicLinkNotFollowed
    case permissionDenied
    case invalidCursor
    case limitExceeded(PluginWorkspaceLimit)
    case cancelled
    /// The project search owner could not answer (index unavailable).
    case searchUnavailable
    case io(errno: Int32)
}

/// Resource budgets of the plugin workspace file service. All values are
/// enforced by the service; requested sizes above a maximum are clamped.
struct PluginWorkspaceFileBudgets: Hashable, Sendable {
    /// Matches Search Everywhere's provider limit, the largest list the
    /// existing workbench renders per request.
    var defaultDirectoryPageSize = 200
    /// One tree page stays well below a single function result (1 MiB,
    /// `plugin_function.rs` `MAX_RESULT_BYTES`) even with 255-byte names.
    var maximumDirectoryPageSize = 1_000
    /// Each page re-reads the directory names to resume from the cursor, so a
    /// single directory is capped. 100k names is about 10 MB transient memory
    /// per page and is far above source directories (`node_modules` and other
    /// generated folders are hidden by the default rules anyway).
    var maximumDirectoryScanEntries = 100_000
    /// Same as one plugin function result (`MAX_RESULT_BYTES` = 1 MiB).
    var defaultReadBytes = 1 << 20
    /// Same as the editor's standalone text file limit
    /// (`WorkspaceTextFilePolicy.standaloneFileByteLimit`); base64 of it still
    /// fits the 64 MiB LSP/JSON-RPC frame limit of `transport.rs`.
    var maximumReadBytes = 32 << 20
    /// Blocking file-system work runs on a host queue, never on Swift's
    /// cooperative pool or the main thread. A small per-caller fan-out keeps
    /// one plugin from occupying that queue; revise with measurements.
    var maximumConcurrentOperationsPerCaller = 4
    /// Subscriptions of one root generation share one native stream, so each
    /// is cheap; the caps catch leaked subscriptions, not normal use.
    var maximumWatchSubscriptionsPerCaller = 32
    var maximumWatchSubscriptions = 256
    /// Pending paths per subscription while its consumer is busy; beyond this
    /// the event collapses to `requiresRescan`, which costs no more than one
    /// directory page to recover.
    var maximumPendingWatchPaths = 1_000
    var defaultSearchPageSize = 100
    /// Same as Search Everywhere's provider limit.
    var maximumSearchPageSize = 200
    /// The project search owner's own result cap (`RustCoreBridge.search`
    /// default `maxResults` and `SearchEverywhereResults.providerLimit`).
    var searchResultCap = 200

    static let `default` = PluginWorkspaceFileBudgets()
}

/// Host-internal workspace file service for plugins (API-06/07/08).
///
/// - Every call names its root and caller; nothing defaults to the active
///   window. Non-local authorities are rejected.
/// - Paths are validated and normalized (see `MacWorkspaceSecurePath`) and
///   resolved with descriptor-relative opens that refuse symbolic links in
///   every component.
/// - Symbolic links are never followed, whether they point inside or outside
///   the root. Listings omit them, as the Project view and the search index
///   do; `stat` reports them as `.symbolicLink`; reading through one fails
///   with `.symbolicLinkNotFollowed`. Following in-root links can be added
///   later as an explicit option.
/// - Visibility rules are the Project view's: hidden entries are omitted from
///   listings, search and watch events. They are presentation rules, not
///   access control, so `stat` and `readFile` on an explicit hidden path are
///   allowed; authorization belongs to the dispatcher.
/// - Reads and searches use disk contents only.
protocol PluginWorkspaceFileAccess: Sendable {
    func readDirectory(
        _ path: String,
        in root: PluginWorkspaceRoot,
        caller: PluginWorkspaceCaller,
        cursor: String?,
        limit: Int?
    ) async throws -> PluginWorkspaceDirectoryPage

    func stat(
        _ path: String,
        in root: PluginWorkspaceRoot,
        caller: PluginWorkspaceCaller
    ) async throws -> PluginWorkspaceFileStat

    func readFile(
        _ path: String,
        in root: PluginWorkspaceRoot,
        caller: PluginWorkspaceCaller,
        maximumBytes: Int?
    ) async throws -> PluginWorkspaceFileContents

    /// Watches `path` (a directory or file). `recursive == false` reports the
    /// path itself and its direct children only. `onEvent` is called serially
    /// per subscription on a host queue and must return quickly.
    func watch(
        _ path: String,
        recursive: Bool,
        in root: PluginWorkspaceRoot,
        caller: PluginWorkspaceCaller,
        onEvent: @escaping @Sendable (PluginWorkspaceWatchEvent) -> Void
    ) throws -> any PluginWorkspaceWatchSubscription

    func findFiles(
        _ query: PluginWorkspaceFindFilesQuery,
        in root: PluginWorkspaceRoot,
        caller: PluginWorkspaceCaller,
        cursor: String?,
        limit: Int?
    ) async throws -> PluginWorkspaceSearchPage<PluginWorkspaceFileMatch>

    func findText(
        _ query: PluginWorkspaceFindTextQuery,
        in root: PluginWorkspaceRoot,
        caller: PluginWorkspaceCaller,
        cursor: String?,
        limit: Int?
    ) async throws -> PluginWorkspaceSearchPage<PluginWorkspaceTextMatch>

    /// Releases every subscription of `caller` (plugin disabled, updated,
    /// uninstalled, crashed or its grant revoked).
    func releaseResources(of caller: PluginWorkspaceCaller)

    /// Marks a root generation closed: its watchers are released and later
    /// requests with that generation fail with `.staleWorkspace`.
    func closeWorkspace(rootID: String, generation: UInt64)
}
