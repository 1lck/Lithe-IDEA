import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// A direct argv launch in a terminal owned by one plugin and workspace.
/// Tool-specific commands stay in the plugin; the host never interprets shell text.
struct PluginTerminalLaunch: Equatable, Sendable {
    let pluginID: String
    let title: String
    let executable: String
    let arguments: [String]
    let workingDirectory: URL
    let environment: [String: String?]
    var show: Bool
    var retainedContextBytes: Int = 16 * 1024
    var displayHistory: String = ""
}

struct PluginTerminalExit: Equatable, Sendable {
    let code: Int32?
    let reason: String
}

@MainActor
protocol PluginTerminalSessionAccess: AnyObject {
    var exit: PluginTerminalExit? { get }
    func show() throws
    func displayText(maximumBytes: Int) -> String
    /// Stops the terminal's process tree, using the existing bounded native cleanup.
    func close() async
}

/// Implemented by the window's terminal owner, not by the plugin dispatcher.
@MainActor
protocol PluginTerminalWindowPort: AnyObject {
    func hostCreatePluginTerminal(
        _ launch: PluginTerminalLaunch,
        onExit: @escaping @MainActor @Sendable (PluginTerminalExit) -> Void
    ) async throws -> any PluginTerminalSessionAccess
}

// Note: 插件原生终端的所有权与直接 argv 启动见 .agents/notes/implemented/architecture/2026-11-02-plugin-owned-native-terminals.md

/// Function-protocol-3 terminal service. Handles are private to a backend session
/// and context; it cannot enumerate, read or write any existing user terminal.
@MainActor
final class PluginTerminalHostService: PluginHostServiceHandling {
    let service = "terminal"
    let methods = Set(["create", "show", "close", "reopen", "dispose", "onExit"].map { "lithe/host/terminal/" + $0 })
    static let maximumTerminals = 8
    static let maximumContextBytes = 256 * 1024
    private let contexts: PluginWorkspaceContexts
    private let metadata: PluginWorkspaceHostService
    private final class Entry {
        let pluginID: String
        let sessionID: String
        let context: PluginWorkspaceContextReference
        var access: (any PluginTerminalSessionAccess)?
        var exit: PluginTerminalExit?
        var live = true
        var busy = false
        var launch: PluginTerminalLaunch?
        var history = ""
        var generation = 1
        var runToken = UUID()
        var starting = false
        var retirement: Task<Void, Never>?
        var subscriptions: [String: PluginHostSubscriptions] = [:]
        init(_ call: PluginHostCall, context: PluginWorkspaceContextReference) {
            pluginID = call.pluginID; sessionID = call.sessionID; self.context = context
        }
    }
    private var entries: [String: Entry] = [:]
    private var cleanup: [UUID: Task<Void, Never>] = [:]

    init(contexts: PluginWorkspaceContexts, metadata: PluginWorkspaceHostService) {
        self.contexts = contexts; self.metadata = metadata
    }

    func answer(_ call: PluginHostCall) async -> Result<ToolingJSONValue, PluginHostServiceError> {
        do {
            let scope = try PluginHostAPIContext(call, contexts: contexts)
            let method = String(call.request.method.split(separator: "/").last ?? "")
            let allowed: Set<String>
            switch method {
            case "create": allowed = ["context", "title", "executable", "arguments", "cwd", "environment", "show", "retainedContextBytes"]
            case "close": allowed = ["context", "terminalID", "retainedContextBytes"]
            case "reopen": allowed = ["context", "terminalID", "show"]
            default: allowed = ["context", "terminalID"]
            }
            let args = try PluginHostArguments(call.params, allowed: allowed)
            if method == "create" {
                return .success(try await create(call, scope: scope, args: args))
            }
            let id = try args.string("terminalID")
            guard let entry = entries[id], entry.live, entry.pluginID == call.pluginID,
                  entry.sessionID == call.sessionID, entry.context == scope.workspace.reference else {
                throw PluginHostServiceError(.notFound, L10n.string("The plugin terminal does not exist."))
            }
            switch method {
            case "show":
                guard entry.exit == nil, let access = entry.access else {
                    throw PluginHostServiceError(.preconditionFailed, L10n.string("The plugin terminal is closed. Reopen it first."))
                }
                try access.show()
                return .success(.null)
            case "close":
                guard !entry.busy else { throw busy }
                let bytes = try contextBytes(args, fallback: entry.launch?.retainedContextBytes ?? 0)
                entry.launch?.retainedContextBytes = bytes
                entry.busy = true
                defer { entry.busy = false }
                if let access = entry.access { entry.history = access.displayText(maximumBytes: bytes) }
                else { entry.history = Self.suffix(entry.history, bytes: bytes) }
                let needsExitNotification = entry.exit == nil
                finish(entry, id: id, exit: .init(code: nil, reason: "closed"))
                await entry.access?.close()
                if let access = entry.access { entry.history = access.displayText(maximumBytes: bytes) }
                entry.access = nil
                if needsExitNotification, entry.live, let exit = entry.exit { publish(entry, id: id, exit: exit) }
                return .success(.object(["retainedContextBytes": .integer(entry.history.utf8.count)]))
            case "reopen":
                guard !entry.busy else { throw busy }
                guard entry.exit != nil, var launch = entry.launch else {
                    throw PluginHostServiceError(.preconditionFailed, L10n.string("The plugin terminal is still running."))
                }
                guard let window = scope.window as? any PluginTerminalWindowPort else { throw PluginHostArguments.invalid }
                launch.show = try args.bool("show", default: true)
                entry.busy = true
                defer {
                    entry.busy = false
                    retireExitedTerminal(entry, id: id)
                }
                if let access = entry.access {
                    entry.history = access.displayText(maximumBytes: launch.retainedContextBytes)
                    await access.close()
                    entry.access = nil
                }
                try Task.checkCancellation()
                _ = try PluginHostAPIContext(call, contexts: contexts)
                guard entry.live else { throw CancellationError() }
                launch.displayHistory = entry.history
                let oldExit = entry.exit, oldGeneration = entry.generation
                entry.runToken = UUID()
                let token = entry.runToken
                entry.starting = true
                entry.exit = nil; entry.generation += 1
                let generation = entry.generation
                do {
                    let access = try await window.hostCreatePluginTerminal(launch) { [weak self, weak entry] exit in
                        guard let entry, entry.runToken == token else { return }
                        self?.finish(entry, id: id, exit: exit)
                    }
                    entry.access = access
                    do {
                        try Task.checkCancellation()
                        _ = try PluginHostAPIContext(call, contexts: contexts)
                        guard entry.live, entries[id] === entry else { throw CancellationError() }
                    } catch { await access.close(); entry.access = nil; throw error }
                    if let exit = access.exit { finish(entry, id: id, exit: exit) }
                    entry.starting = false
                    return .success(.object(["terminalID": .string(id), "generation": .integer(generation),
                                             "restoredContextBytes": .integer(entry.history.utf8.count)]))
                } catch {
                    entry.runToken = UUID(); entry.starting = false
                    entry.exit = oldExit; entry.generation = oldGeneration
                    throw error
                }
            case "dispose":
                guard !entry.busy else { throw busy }
                entries[id] = nil; entry.live = false
                finish(entry, id: id, exit: .init(code: nil, reason: "closed"))
                await entry.access?.close()
                for (subscription, store) in entry.subscriptions {
                    store.dispose(pluginID: entry.pluginID, subscriptionID: subscription)
                }
                entry.history = ""; entry.launch = nil; entry.access = nil
                return .success(.null)
            case "onExit":
                guard !entry.busy else { throw busy }
                guard entry.subscriptions.isEmpty else {
                    throw PluginHostServiceError(.limitExceeded, L10n.string("The plugin host request could not be completed."))
                }
                let subscription = call.subscriptions.add(pluginID: call.pluginID, contextID: entry.context.contextID) { [weak entry] in
                    entry?.subscriptions.removeAll()
                }
                entry.subscriptions[subscription] = call.subscriptions
                if let exit = entry.exit { publish(entry, id: id, exit: exit) }
                return .success(.object(["subscriptionID": .string(subscription)]))
            default: throw PluginHostArguments.invalid
            }
        } catch {
            var failure = PluginHostAPIValues.failure(error)
            failure.logError = error
            return .failure(failure)
        }
    }

    private func create(_ call: PluginHostCall, scope: PluginHostAPIContext, args: PluginHostArguments) async throws -> ToolingJSONValue {
        guard entries.values.filter({ $0.pluginID == call.pluginID }).count < Self.maximumTerminals else {
            throw PluginHostServiceError(.limitExceeded, L10n.string("The plugin host request could not be completed."))
        }
        guard let window = scope.window as? any PluginTerminalWindowPort else {
            throw PluginHostServiceError(.unavailable, L10n.string("The terminal is unavailable."))
        }
        let launch = try decodeLaunch(call, scope: scope, args: args)
        let id = UUID().uuidString
        let entry = Entry(call, context: scope.workspace.reference)
        entry.launch = launch
        entry.busy = true
        entry.starting = true
        entries[id] = entry
        defer {
            entry.busy = false
            retireExitedTerminal(entry, id: id)
        }
        do {
            let token = entry.runToken
            let access = try await window.hostCreatePluginTerminal(launch) { [weak self, weak entry] exit in
                guard let entry, entry.runToken == token else { return }
                self?.finish(entry, id: id, exit: exit)
            }
            entry.access = access
            do {
                try Task.checkCancellation()
                _ = try PluginHostAPIContext(call, contexts: contexts)
                guard entry.live, entries[id] === entry else { throw CancellationError() }
            } catch {
                await access.close()
                throw error
            }
            if let exit = access.exit { finish(entry, id: id, exit: exit) }
            entry.starting = false
            return .object(["terminalID": .string(id), "generation": .integer(1)])
        } catch {
            entries[id] = nil; entry.live = false; entry.runToken = UUID()
            throw error
        }
    }

    private func decodeLaunch(_ call: PluginHostCall, scope: PluginHostAPIContext, args: PluginHostArguments) throws -> PluginTerminalLaunch {
        func text(_ value: String, limit: Int, empty: Bool = true) throws -> String {
            guard (empty || !value.isEmpty), value.utf8.count <= limit, !value.contains("\0") else { throw PluginHostArguments.invalid }
            return value
        }
        let executable = try text(args.string("executable"), limit: 4096, empty: false)
        // Relative executables can change meaning with cwd. Accept an absolute
        // path or a bare command, resolved by the native terminal's PATH lookup.
        guard executable.hasPrefix("/") || !executable.contains("/") && !executable.contains("\\") && !executable.hasPrefix("-") else {
            throw PluginHostArguments.invalid
        }
        let arguments = try (args.values["arguments"] == nil ? [] : args.array("arguments")).map { value -> String in
            guard case .string(let argument) = value else { throw PluginHostArguments.invalid }
            return try text(argument, limit: 16_384)
        }
        guard arguments.count <= 256 else { throw PluginHostArguments.invalid }
        let title = try text(args.string("title", default: executable), limit: 128, empty: false)
        guard !title.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw PluginHostArguments.invalid }
        var cwd = scope.snapshot.workspaceURL
        if args.values["cwd"] != nil {
            let resource = try PluginHostArguments(args.object("cwd"), allowed: ["rootID", "path"])
            let root = try resource.string("rootID"), path = try resource.string("path")
            guard let folder = scope.workspace.folders.first(where: { metadata.rootID(of: $0, pluginID: call.pluginID) == root }) else {
                throw PluginHostServiceError(.permissionDenied, L10n.string("The plugin host request parameters are invalid."))
            }
            cwd = folder.localURL
            if !path.isEmpty {
                for component in try PluginHostResourceResolver.components(of: path) { cwd.appendPathComponent(component) }
            }
        }
        var environment: [String: String?] = [:]
        if args.values["environment"] != nil {
            let values = try args.object("environment")
            guard values.count <= 64 else { throw PluginHostArguments.invalid }
            for (key, value) in values {
                guard key.utf8.count <= 128, key.first?.isLetter == true || key.first == "_",
                      key != "LITHE_PROCESS_SCOPE", key != "LITHE_AGENT_SCOPE",
                      key.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
                    throw PluginHostArguments.invalid
                }
                switch value {
                case .null: environment[key] = .some(nil)
                case .string(let value): environment[key] = try .some(text(value, limit: 16_384))
                default: throw PluginHostArguments.invalid
                }
            }
        }
        let bytes = arguments.reduce(executable.utf8.count) { $0 + $1.utf8.count }
            + environment.reduce(0) { $0 + $1.key.utf8.count + ($1.value?.utf8.count ?? 0) }
        guard bytes <= 64 * 1024 else { throw PluginHostArguments.invalid }
        return PluginTerminalLaunch(pluginID: call.pluginID, title: title, executable: executable, arguments: arguments,
                                    workingDirectory: cwd, environment: environment, show: try args.bool("show", default: true),
                                    retainedContextBytes: try contextBytes(args, fallback: 16 * 1024))
    }

    private var busy: PluginHostServiceError {
        PluginHostServiceError(.busy, L10n.string("The plugin terminal is changing state. Try again when it finishes."))
    }

    private func contextBytes(_ args: PluginHostArguments, fallback: Int) throws -> Int {
        let count = try args.integer("retainedContextBytes", default: fallback)
        guard count <= Self.maximumContextBytes else { throw PluginHostArguments.invalid }
        return count
    }

    private static func suffix(_ text: String, bytes: Int) -> String {
        let tail = Array(text.utf8.suffix(bytes))
        let first = tail.firstIndex { $0 & 0xc0 != 0x80 } ?? tail.endIndex
        return String(decoding: tail[first...], as: UTF8.self)
    }

    private func finish(_ entry: Entry, id: String, exit: PluginTerminalExit) {
        guard entry.exit == nil else { return }
        entry.exit = exit
        retireExitedTerminal(entry, id: id)
    }

    /// Native tab closure and natural exit must release the renderer just like
    /// an API close. Keep the handle busy until process cleanup and its bounded
    /// snapshot finish, so reopen cannot race the previous native session.
    private func retireExitedTerminal(_ entry: Entry, id: String) {
        guard entry.live, !entry.starting, !entry.busy, entry.retirement == nil,
              let exit = entry.exit, let access = entry.access else { return }
        entry.busy = true
        entry.retirement = Task { @MainActor [weak self] in
            await access.close()
            entry.history = access.displayText(maximumBytes: entry.live ? entry.launch?.retainedContextBytes ?? 0 : 0)
            entry.access = nil
            entry.retirement = nil
            entry.busy = false
            if entry.live { self?.publish(entry, id: id, exit: exit) }
        }
    }

    private func publish(_ entry: Entry, id: String, exit: PluginTerminalExit) {
        for (subscription, store) in entry.subscriptions {
            store.notify(pluginID: entry.pluginID, subscriptionID: subscription, event: [
                "type": .string("exit"), "terminalID": .string(id), "reason": .string(exit.reason),
                "generation": .integer(entry.generation),
                "exitCode": exit.code.map { .integer(Int($0)) } ?? .null,
            ])
        }
    }

    func endSession(pluginID: String, sessionID: String) {
        remove { $0.pluginID == pluginID && $0.sessionID == sessionID }
    }

    func closeContext(_ contextID: String) { remove { $0.context.contextID == contextID } }

    private func remove(where matches: (Entry) -> Bool) {
        for (id, entry) in entries where matches(entry) {
            entries[id] = nil; entry.live = false
            entry.history = ""; entry.launch = nil
            if entry.retirement != nil { continue }
            guard let access = entry.access else { continue }
            entry.access = nil
            let key = UUID()
            cleanup[key] = Task { @MainActor [weak self] in
                await access.close()
                self?.cleanup[key] = nil
            }
        }
    }
}
