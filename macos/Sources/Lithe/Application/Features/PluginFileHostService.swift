import Foundation
import LitheCoreContracts

/// Adapts context-owned file operations to the public resource format. Stable
/// root IDs are never used as lifetime keys: reopening a folder gets a new lease.
@MainActor
final class PluginFileHostService: PluginHostServiceHandling {
    let service = "workspace"
    let methods = Set(["readDirectory", "stat", "readFile", "watch", "findFiles", "findText"].map { "lithe/host/workspace/" + $0 })
    private let contexts: PluginWorkspaceContexts
    private let metadata: PluginWorkspaceHostService
    private let files: any PluginWorkspaceFileAccess
    private var leases: [String: [String: UInt64]] = [:]

    init(contexts: PluginWorkspaceContexts, metadata: PluginWorkspaceHostService, files: any PluginWorkspaceFileAccess) {
        self.contexts = contexts
        self.metadata = metadata
        self.files = files
    }

    func endSession(pluginID: String, sessionID: String) {
        files.releaseResources(of: PluginWorkspaceCaller(pluginID: pluginID, sessionID: sessionID))
    }

    func closeContext(_ contextID: String) {
        for (root, generation) in leases.removeValue(forKey: contextID) ?? [:] {
            files.closeWorkspace(rootID: root, generation: generation)
        }
    }

    func answer(_ call: PluginHostCall) async -> Result<ToolingJSONValue, PluginHostServiceError> {
        do {
            let scope = try PluginHostAPIContext(call, contexts: contexts)
            let method = String(call.request.method.split(separator: "/").last ?? "")
            var allowed: Set<String> = ["context", "resource"]
            switch method {
            case "readDirectory": allowed.formUnion(["cursor", "limit"])
            case "readFile": allowed.insert("maximumBytes")
            case "watch": allowed.insert("recursive")
            case "findFiles": allowed.formUnion(["query", "fileMask", "cursor", "limit"])
            case "findText": allowed.formUnion(["pattern", "fileMask", "caseSensitive", "wholeWords", "regularExpression", "cursor", "limit"])
            case "stat": break
            default: throw PluginHostArguments.invalid
            }
            let args = try PluginHostArguments(call.params, allowed: allowed)
            let resource = try PluginHostArguments(args.object("resource"), allowed: ["rootID", "path"])
            let publicRoot = try resource.string("rootID"), path = try resource.string("path")
            guard let folder = scope.workspace.folders.first(where: { metadata.rootID(of: $0, pluginID: call.pluginID) == publicRoot }) else {
                throw PluginHostError.unknownRoot
            }
            let lease = scope.workspace.contextID + ":" + publicRoot
            let generation = UInt64(scope.workspace.generation)
            leases[scope.workspace.contextID, default: [:]][lease] = generation
            let root = PluginWorkspaceRoot(id: lease, url: folder.localURL, authority: .local,
                                          generation: generation, visibilityRules: scope.window.hostVisibilityRules)
            let caller = PluginWorkspaceCaller(pluginID: call.pluginID, sessionID: call.sessionID)
            let cursor = try args.optionalString("cursor")
            let result: ToolingJSONValue
            switch method {
            case "readDirectory":
                let page = try await files.readDirectory(path, in: root, caller: caller, cursor: cursor,
                                                        limit: args.integer("limit", default: 200))
                result = .object(["entries": .array(page.entries.map { .object([
                    "name": .string($0.name), "resource": Self.resource(publicRoot, $0.resource.path), "kind": .string($0.kind.rawValue),
                ]) }), "nextCursor": page.nextCursor.map(ToolingJSONValue.string) ?? .null])
            case "stat":
                let stat = try await files.stat(path, in: root, caller: caller)
                result = .object(["resource": Self.resource(publicRoot, stat.resource.path), "kind": .string(stat.kind.rawValue),
                                  "size": .integer(Int(clamping: stat.size)), "modifiedMilliseconds": .number(stat.modificationDate.timeIntervalSince1970 * 1_000)])
            case "readFile":
                // Worst-case JSON escaping is six bytes per source byte; retain
                // envelope headroom under the shared 1 MiB response bound.
                let maximum = try args.integer("maximumBytes", default: 128 * 1024)
                guard maximum > 0, maximum <= 128 * 1024 else { throw PluginWorkspaceFileError.limitExceeded(.directoryEntries) }
                let contents = try await files.readFile(path, in: root, caller: caller, maximumBytes: maximum)
                var object: [String: ToolingJSONValue] = [
                    "resource": Self.resource(publicRoot, contents.resource.path), "source": .string("disk"),
                    "byteCount": .integer(contents.byteCount), "isTruncated": .bool(contents.isTruncated),
                    "identity": contents.identity.map(ToolingJSONValue.string) ?? .null,
                ]
                switch contents.content {
                case .text(let text, let encoding): object["text"] = .string(text); object["encoding"] = .string(encoding)
                case .binary(let data): object["base64"] = .string(data.base64EncodedString())
                }
                result = .object(object)
            case "watch":
                let relay = WatchRelay(subscriptions: call.subscriptions, pluginID: call.pluginID, rootID: publicRoot)
                let watch = try files.watch(path, recursive: args.bool("recursive"), in: root, caller: caller) { event in
                    relay.enqueue(event)
                }
                let id = call.subscriptions.add(pluginID: call.pluginID, contextID: scope.workspace.contextID) { watch.dispose() }
                relay.subscriptionID = id
                result = .object(["subscriptionID": .string(id)])
            case "findFiles":
                guard path.isEmpty else { throw PluginHostError.unsupportedOption }
                let page = try await files.findFiles(PluginWorkspaceFindFilesQuery(query: args.string("query"), fileMask: args.string("fileMask", default: "")),
                    in: root, caller: caller, cursor: cursor, limit: args.integer("limit", default: 100))
                result = Self.page(page.matches.map { Self.resource(publicRoot, $0.resource.path) }, cursor: page.nextCursor, truncated: page.isTruncated)
            default:
                guard path.isEmpty else { throw PluginHostError.unsupportedOption }
                let query = try PluginWorkspaceFindTextQuery(pattern: args.string("pattern"), caseSensitive: args.bool("caseSensitive"),
                    wholeWords: args.bool("wholeWords"), regularExpression: args.bool("regularExpression"), fileMask: args.string("fileMask", default: ""))
                let page = try await files.findText(query, in: root, caller: caller, cursor: cursor, limit: args.integer("limit", default: 100))
                // The search owner currently reports line/preview, not exact match
                // spans. Do not invent a range by re-running a different matcher.
                result = Self.page(page.matches.map { .object(["resource": Self.resource(publicRoot, $0.resource.path),
                    "line": .integer($0.line), "preview": .string($0.preview), "range": .null]) }, cursor: page.nextCursor, truncated: page.isTruncated)
            }
            _ = try PluginHostAPIContext(call, contexts: contexts)
            return .success(result)
        } catch { return .failure(PluginHostAPIValues.failure(error)) }
    }

    private static func resource(_ root: String, _ path: String) -> ToolingJSONValue {
        .object(["rootID": .string(root), "path": .string(path)])
    }

    private static func page(_ matches: [ToolingJSONValue], cursor: String?, truncated: Bool) -> ToolingJSONValue {
        .object(["matches": .array(matches), "nextCursor": cursor.map(ToolingJSONValue.string) ?? .null,
                 "isTruncated": .bool(truncated), "source": .string("disk")])
    }

    private final class WatchRelay: @unchecked Sendable {
        @MainActor weak var subscriptions: PluginHostSubscriptions?
        let pluginID: String
        let rootID: String
        @MainActor var subscriptionID: String?
        private let lock = NSLock()
        private var paths: Set<String> = []
        private var rescan = false
        private var scheduled = false
        @MainActor
        init(subscriptions: PluginHostSubscriptions, pluginID: String, rootID: String) {
            self.subscriptions = subscriptions; self.pluginID = pluginID; self.rootID = rootID
        }

        /// At most one main-actor delivery is queued even while UI work delays
        /// it. Coalescing before the actor hop bounds the transport adapter too.
        func enqueue(_ event: PluginWorkspaceWatchEvent) {
            let schedule = lock.withLock {
                rescan = rescan || event.requiresRescan
                if !rescan { paths.formUnion(event.changedPaths); rescan = paths.count > 1_000 }
                if rescan { paths.removeAll() }
                guard !scheduled else { return false }
                scheduled = true
                return true
            }
            if schedule { Task { @MainActor in self.deliver() } }
        }

        @MainActor
        private func deliver() {
            let event = lock.withLock {
                let result = (paths.sorted(), rescan)
                paths.removeAll(); rescan = false; scheduled = false
                return result
            }
            guard let subscriptionID else { return }
            subscriptions?.notify(pluginID: pluginID, subscriptionID: subscriptionID, event: [
                "rootID": .string(rootID), "changedPaths": .array(event.0.map(ToolingJSONValue.string)),
                "requiresRescan": .bool(event.1),
            ])
        }
    }
}
