import Foundation
import Darwin
import LitheCoreContracts
import LitheModuleAPI

/// Sources must come from the host's validated installed-package registry, not project files.
struct ToolchainSettingsPluginSource: Equatable, Sendable {
    let pluginID: String
    let name: String
    let manifest: Data
    let isEnabled: Bool
}

struct ToolchainSettingsSavedPin: Equatable, Sendable {
    let home: String
    let version: String
    /// The directory whose entry applies: the requested one or its nearest ancestor.
    var directory = "."
}

enum ToolchainSettingsLoadError: LocalizedError, Equatable {
    case readFailed, invalidLocal, invalidDeclarations

    var errorDescription: String? {
        switch self {
        case .readFailed: L10n.string("Could not read toolchain settings.")
        case .invalidLocal: L10n.string("The saved toolchain settings are invalid.")
        case .invalidDeclarations: L10n.string("The installed toolchain declarations are invalid.")
        }
    }
}

/// Reads inert declarations, saved pins and filesystem facts; it never runs a tool,
/// queries a provider or selects a runtime.
struct MacToolchainSettingsLoader: ToolchainSettingsLoading {
    /// Bounds the existence checks for version files; the tree projection can hold 1,024 directories.
    static let versionFileCheckBudget = 16_384
    /// Bounds Core pin resolutions, one per listed directory and tool.
    static let rowBudget = 4_096

    private let readLocalData: @Sendable (URL) throws -> Data?
    private let sources: @MainActor @Sendable () -> [ToolchainSettingsPluginSource]
    private let resolvePin: @Sendable (Data, String, String) throws -> ToolchainSettingsSavedPin?
    private let directories: @MainActor @Sendable (URL?) -> [String]
    private let isRemoteWorkspace: @Sendable (URL) -> Bool
    private let environment: @Sendable () -> [String: String]
    private let fileExists: @Sendable (URL) -> Bool
    private let isExecutable: @Sendable (String) -> Bool

    init(
        sources: @escaping @MainActor @Sendable () -> [ToolchainSettingsPluginSource],
        directories: @escaping @MainActor @Sendable (URL?) -> [String] = { _ in [] },
        resolvePin: @escaping @Sendable (Data, String, String) throws -> ToolchainSettingsSavedPin? = Self.resolvePinUsingCore,
        isRemoteWorkspace: @escaping @Sendable (URL) -> Bool = { _ in false },
        environment: @escaping @Sendable () -> [String: String] = {
            MacLoginShellEnvironment.shared.merged(ProcessInfo.processInfo.environment)
        },
        fileExists: @escaping @Sendable (URL) -> Bool = Self.regularFileExists,
        isExecutable: @escaping @Sendable (String) -> Bool = Self.executableExists,
        readLocalData: (@Sendable (URL) throws -> Data?)? = nil
    ) {
        // FileStorage's generic prefix reader may open special files; production
        // reads use a checked nonblocking native descriptor instead.
        self.readLocalData = readLocalData ?? Self.safeNativeRead
        self.sources = sources
        self.directories = directories
        self.resolvePin = resolvePin
        self.isRemoteWorkspace = isRemoteWorkspace
        self.environment = environment
        self.fileExists = fileExists
        self.isExecutable = isExecutable
    }

    func load(workspace: URL?) async throws -> ToolchainSettingsSnapshot {
        try Task.checkCancellation()
        if let workspace, isRemoteWorkspace(workspace) {
            return .init(workspaceURL: workspace,
                diagnostics: [L10n.string("Toolchain settings are not available for remote workspaces yet.")])
        }
        let installed = await sources()
        let directoryIDs = await directories(workspace)
        let io = IO(readLocalData: readLocalData, resolvePin: resolvePin, environment: environment,
                    fileExists: fileExists, isExecutable: isExecutable)
        let worker = Task.detached(priority: .userInitiated) {
            try Self.snapshot(workspace: workspace, sources: installed, directoryIDs: directoryIDs, io: io)
        }
        return try await withTaskCancellationHandler {
            let snapshot = try await worker.value
            try Task.checkCancellation()
            return snapshot
        } onCancel: {
            worker.cancel()
        }
    }

    private struct IO: Sendable {
        let readLocalData: @Sendable (URL) throws -> Data?
        let resolvePin: @Sendable (Data, String, String) throws -> ToolchainSettingsSavedPin?
        let environment: @Sendable () -> [String: String]
        let fileExists: @Sendable (URL) -> Bool
        let isExecutable: @Sendable (String) -> Bool
    }

    /// The automatic candidates a settings page can check without running anything.
    private enum Probe {
        case variable(name: String, path: String)
        case command(String)
    }

    private struct Definition {
        let id: String
        let name: String
        let pluginID: String
        let pluginName: String
        let icon: String?
        let probes: [Probe]
    }

    private static func snapshot(
        workspace: URL?, sources: [ToolchainSettingsPluginSource], directoryIDs: [String], io: IO
    ) throws -> ToolchainSettingsSnapshot {
        try Task.checkCancellation()
        guard sources.count <= 128 else { throw ToolchainSettingsLoadError.invalidDeclarations }
        var definitions: [Definition] = []
        var providers: [ToolchainSettingsSnapshot.Provider] = []
        var knownTools: Set<String> = []
        var knownPlugins: Set<String> = []
        for source in sources.filter(\.isEnabled).sorted(by: { $0.pluginID < $1.pluginID }) {
            try Task.checkCancellation()
            guard source.manifest.count <= 1_048_576, knownPlugins.insert(source.pluginID).inserted,
                  let manifest = try? JSONSerialization.jsonObject(with: source.manifest) as? [String: Any],
                  manifest["id"] as? String == source.pluginID
            else { throw ToolchainSettingsLoadError.invalidDeclarations }
            for tool in try contribution(manifest, key: "toolDefinitions", maximum: 32) {
                guard let id = text(tool["id"], maximum: 192), let name = text(tool["displayName"], maximum: 128),
                      knownTools.insert(id).inserted
                else { throw ToolchainSettingsLoadError.invalidDeclarations }
                let icon = (tool["icon"] as? [String: Any])?["host"] as? String
                definitions.append(Definition(id: id, name: name, pluginID: source.pluginID,
                                              pluginName: source.name, icon: icon, probes: probes(tool)))
            }
            var providerIDs: Set<String> = []
            for provider in try contribution(manifest, key: "toolchainProviders", maximum: 8) {
                guard let id = text(provider["id"], maximum: 64), providerIDs.insert(id).inserted,
                      let title = text(provider["displayName"], maximum: 128),
                      let tools = provider["tools"] as? [String], tools.count <= 64,
                      let watches = provider["watchFiles"] as? [[String: Any]], watches.count <= 32
                else { throw ToolchainSettingsLoadError.invalidDeclarations }
                let patterns = try watches.map { watch in
                    guard let pattern = text(watch["pattern"], maximum: 256) else {
                        throw ToolchainSettingsLoadError.invalidDeclarations
                    }
                    return pattern
                }
                providers.append(.init(id: "\(source.pluginID):\(id)", title: title, pluginID: source.pluginID,
                                       pluginName: source.name, tools: tools, watchFiles: patterns))
            }
        }
        guard definitions.count <= 256 else { throw ToolchainSettingsLoadError.invalidDeclarations }
        definitions.sort { $0.id < $1.id }
        // Disabled definitions also disappear from provider tool capsules; no provider is invoked.
        providers = providers.map { provider in
            var result = provider
            result.tools = provider.tools.filter { knownTools.contains($0) }.sorted()
            return result
        }
        guard let workspace else {
            return .init(providers: providers)
        }
        let document = try localDocument(workspace: workspace, readLocalData: io.readLocalData)
        // Core validates every dormant pin as well as the requested directory.
        if let document { _ = try io.resolvePin(document, ".", "toolchain-settings-validation") }
        let pinDirectories = document.flatMap {
            (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["pins"] as? [String: Any]
        }.map { Array($0.keys) } ?? []
        guard directoryIDs.count <= 1_024 else { throw ToolchainSettingsLoadError.invalidLocal }
        for id in directoryIDs + pinDirectories {
            guard validDirectory(id) else { throw ToolchainSettingsLoadError.invalidLocal }
        }
        var diagnostics: [String] = []
        let found = try versionFiles(workspace: workspace, directories: ["."] + directoryIDs, providers: providers,
                                     fileExists: io.fileExists, diagnostics: &diagnostics)
        // Only directories with their own facts are listed, with the ancestors that connect them.
        var listed: Set<String> = ["."]
        for id in Array(found.keys) + pinDirectories {
            var current = id
            while current != "." {
                listed.insert(current)
                current = parent(current)
            }
        }
        var ordered = listed.sorted(by: treeOrder)
        let limit = max(1, rowBudget / max(definitions.count, 1))
        if ordered.count > limit {
            ordered = Array(ordered.prefix(limit))
            diagnostics.append(L10n.string("Only the first \(limit) directories are shown."))
        }
        let directories = ordered.map { id in
            ToolchainSettingsSnapshot.Directory(id: id,
                title: id == "." ? workspace.lastPathComponent : String(id.split(separator: "/").last ?? ""),
                depth: id == "." ? 0 : id.split(separator: "/").count,
                versionFiles: found[id] ?? [])
        }
        let environment = io.environment()
        let candidates = definitions.map { candidate(for: $0, environment: environment, isExecutable: io.isExecutable) }
        var rows: [ToolchainSettingsSnapshot.Tool] = []
        for directory in directories {
            try Task.checkCancellation()
            for (definition, candidate) in zip(definitions, candidates) {
                try Task.checkCancellation()
                let saved = try document.flatMap { try io.resolvePin($0, directory.id, definition.id) }
                let watching = Set(providers.filter { $0.tools.contains(definition.id) }.map(\.id))
                var files: [ToolchainSettingsSnapshot.VersionFile] = []
                var current: String? = directory.id
                while let id = current {
                    files += (found[id] ?? []).filter { !watching.isDisjoint(with: $0.providerIDs) }
                    current = id == "." ? nil : parent(id)
                }
                rows.append(.init(id: definition.id, directoryID: directory.id, displayName: definition.name,
                    pluginID: definition.pluginID, pluginName: definition.pluginName, iconName: definition.icon,
                    pin: saved.map { .init(version: $0.version, home: $0.home, directory: $0.directory) },
                    versionFiles: files, candidate: candidate))
            }
        }
        return .init(workspaceURL: workspace, directories: directories, tools: rows, providers: providers,
                     diagnostics: diagnostics)
    }

    /// Literal provider watch files that exist as regular files; glob patterns stay with the provider.
    private static func versionFiles(
        workspace: URL, directories: [String], providers: [ToolchainSettingsSnapshot.Provider],
        fileExists: @Sendable (URL) -> Bool, diagnostics: inout [String]
    ) throws -> [String: [ToolchainSettingsSnapshot.VersionFile]] {
        var watchers: [String: [String]] = [:]
        for provider in providers {
            for pattern in provider.watchFiles where !pattern.contains("*") && validDirectory(pattern) {
                watchers[pattern, default: []].append(provider.id)
            }
        }
        let patterns = watchers.keys.sorted()
        guard !patterns.isEmpty else { return [:] }
        // Shallow directories first, so a budget cut keeps the files that most rows inherit.
        let ordered = Set(directories).sorted { left, right in
            let (l, r) = (left == "." ? 0 : left.split(separator: "/").count,
                          right == "." ? 0 : right.split(separator: "/").count)
            return l == r ? treeOrder(left, right) : l < r
        }
        let reachable = max(1, versionFileCheckBudget / patterns.count)
        if ordered.count > reachable {
            diagnostics.append(L10n.string("Version files were checked in the first \(reachable) directories only."))
        }
        var found: [String: [ToolchainSettingsSnapshot.VersionFile]] = [:]
        for directory in ordered.prefix(reachable) {
            try Task.checkCancellation()
            for pattern in patterns {
                let path = directory == "." ? pattern : directory + "/" + pattern
                guard fileExists(workspace.appendingPathComponent(path)) else { continue }
                found[directory, default: []].append(.init(path: path, providerIDs: watchers[pattern] ?? []))
            }
        }
        return found
    }

    private static func probes(_ tool: [String: Any]) -> [Probe] {
        guard let executables = tool["executables"] as? [[String: Any]] else { return [] }
        return executables.prefix(32).compactMap { candidate in
            if let platforms = candidate["platforms"] as? [String], !platforms.contains("macos") { return nil }
            switch candidate["kind"] as? String {
            case "environment":
                guard let name = text(candidate["variable"], maximum: 64),
                      let path = text(candidate["path"], maximum: 256), validDirectory(path), path != "."
                else { return nil }
                return .variable(name: name, path: path)
            case "command":
                guard let command = text(candidate["command"], maximum: 64), !command.contains("/") else { return nil }
                return .command(command)
            default:
                return nil
            }
        }
    }

    /// The first declared environment or `PATH` candidate that exists, in declaration order.
    private static func candidate(
        for definition: Definition, environment: [String: String], isExecutable: @Sendable (String) -> Bool
    ) -> ToolchainSettingsSnapshot.Candidate? {
        let searchPath = (environment["PATH"] ?? "").split(separator: ":").prefix(256)
            .map(String.init).filter { $0.hasPrefix("/") }
        for probe in definition.probes {
            switch probe {
            case let .variable(name, path):
                guard let home = environment[name], home.hasPrefix("/") else { continue }
                let executable = (home.hasSuffix("/") ? String(home.dropLast()) : home) + "/" + path
                if isExecutable(executable) { return .init(executable: executable, origin: .variable(name)) }
            case let .command(command):
                for directory in searchPath {
                    let executable = (directory.hasSuffix("/") ? String(directory.dropLast()) : directory) + "/" + command
                    if isExecutable(executable) { return .init(executable: executable, origin: .path) }
                }
            }
        }
        return nil
    }

    private static func parent(_ id: String) -> String {
        id.lastIndex(of: "/").map { String(id[..<$0]) } ?? "."
    }

    private static func treeOrder(_ left: String, _ right: String) -> Bool {
        if left == "." { return right != "." }
        if right == "." { return false }
        return left.split(separator: "/").lexicographicallyPrecedes(right.split(separator: "/"))
    }

    /// A regular file at `url`, without following a final symbolic link or opening it.
    static func regularFileExists(_ url: URL) -> Bool {
        var status = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return lstat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFREG
        }
    }

    /// An executable regular file, following links as `execve` does.
    static func executableExists(_ path: String) -> Bool {
        var status = stat()
        return stat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
    }

    private static func contribution(_ manifest: [String: Any], key: String, maximum: Int) throws -> [[String: Any]] {
        guard let value = manifest[key] else { return [] }
        guard let values = value as? [[String: Any]], values.count <= maximum else {
            throw ToolchainSettingsLoadError.invalidDeclarations
        }
        return values
    }

    private static func text(_ value: Any?, maximum: Int) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }

    private static func validDirectory(_ value: String) -> Bool {
        value == "." || (text(value, maximum: 2_048) != nil && value.split(separator: "/").count <= 64
            && !value.contains("\\") && !value.contains(":")
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            })
    }

    private static func localDocument(workspace: URL?, readLocalData: @Sendable (URL) throws -> Data?) throws -> Data? {
        guard let workspace else { return nil }
        let url = workspace.appendingPathComponent(".lithe/toolchains/local.json")
        let data: Data
        do {
            guard let captured = try readLocalData(url) else { return nil }
            data = captured
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
        catch { throw ToolchainSettingsLoadError.readFailed }
        guard data.count <= 1_048_576 else { throw ToolchainSettingsLoadError.invalidLocal }
        return data
    }

    /// Refuses links and special files before any read, including FIFO targets.
    static func safeNativeRead(_ url: URL) throws -> Data? {
        try Task.checkCancellation()
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw ToolchainSettingsLoadError.readFailed
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw ToolchainSettingsLoadError.readFailed
        }
        guard status.st_size <= 1_048_576 else { throw ToolchainSettingsLoadError.invalidLocal }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count <= 1_048_576 {
            try Task.checkCancellation()
            let wanted = min(buffer.count, 1_048_577 - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, wanted) }
            if count < 0 {
                if errno == EINTR { continue }
                throw ToolchainSettingsLoadError.readFailed
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer[..<count])
        }
        throw ToolchainSettingsLoadError.invalidLocal
    }

    /// Pin validation and inheritance stay in the shared Core, never in this presenter.
    @Sendable static func resolvePinUsingCore(_ data: Data, _ directory: String, _ tool: String) throws -> ToolchainSettingsSavedPin? {
        struct Payload: Encodable {
            let document: ToolingJSONValue
            let directory: String
            let tool: String
        }
        struct Saved: Decodable { let home: String; let version: String }
        struct Resolution: Decodable { let pin: Saved?; let sourceDirectory: String? }
        struct Outcome: Decodable { let status: String; let resolution: Resolution? }
        do {
            let document = try JSONDecoder().decode(ToolingJSONValue.self, from: data)
            let result: Outcome = try RustCoreBridge().executeResult(command: "toolchains.resolvePins",
                payload: Payload(document: document, directory: directory, tool: tool)).get()
            guard result.status == "ok", let resolution = result.resolution else { throw ToolchainSettingsLoadError.invalidLocal }
            return resolution.pin.map { .init(home: $0.home, version: $0.version, directory: resolution.sourceDirectory ?? directory) }
        } catch { throw ToolchainSettingsLoadError.invalidLocal }
    }
}
