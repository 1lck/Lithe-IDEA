import CryptoKit
import Foundation
import LitheModuleAPI

// Note: .agents/notes/implemented/architecture/2026-09-30-lsp-plugin-build-and-distribution.md
/// Executes plugin-owned recipes. SDKs, staged servers and launchers live in
/// platform user storage; an external SDK is read-only even during installation.
@MainActor
final class MacPluginToolchainManager: PluginToolchainManaging {
    private let fileStorage: any FileStorage
    private let store: any KeyValueStore
    private let session: URLSession
    private let runCommand: (ProcessRequest) async throws -> ProcessResult
    private var busyPlugins: Set<PluginID> = []
    private(set) var declarations: [PluginID: MacPluginToolchainConfiguration] = [:]
    private(set) var snapshots: [PluginID: PluginToolchainSnapshot] = [:]

    init(
        fileStorage: any FileStorage,
        store: any KeyValueStore,
        configurationURLs: [PluginID: URL],
        session: URLSession = .shared,
        runCommand: @escaping (ProcessRequest) async throws -> ProcessResult = {
            try await MacPluginToolchainProcessOperation().run($0)
        }
    ) {
        self.fileStorage = fileStorage
        self.store = store
        self.session = session
        self.runCommand = runCommand
        for pluginID in configurationURLs.keys.sorted() {
            guard let url = configurationURLs[pluginID],
                  let declaration = try? MacPluginToolchainConfiguration.load(from: url),
                  declaration.pluginID == pluginID else { continue }
            declarations[pluginID] = declaration
            let sdk = declaration.toolchains[0]
            let path = store.string(forKey: Self.pathKey(pluginID: pluginID, toolchainID: sdk.id))
            let root = path.flatMap(Self.normalizedPath)
            let validRoot = root.flatMap { fileStorage.isExecutable(at: $0.appendingPathComponent(sdk.executable)) ? $0 : nil }
            let version = validRoot == nil ? nil : store.string(forKey: Self.versionKey(pluginID, sdk.id))
            snapshots[pluginID] = PluginToolchainSnapshot(
                pluginID: pluginID, displayName: sdk.displayName,
                canInstallLanguageServer: !declaration.languageServers.isEmpty,
                state: validRoot.map { .configured(path: $0.path, version: version) } ?? .missing,
                selectedPath: validRoot?.path, selectedVersion: version
            )
        }
    }

    func snapshot(for pluginID: PluginID) -> PluginToolchainSnapshot? { snapshots[pluginID] }

    func setToolchainPath(_ path: String, for pluginID: PluginID) async throws {
        let declaration = try begin(pluginID, state: .checking)
        defer { busyPlugins.remove(pluginID) }
        do {
            guard let root = Self.normalizedPath(path) else { throw PluginToolchainError.invalidToolchainPath(path) }
            let version = try await validate(root, sdk: declaration.toolchains[0])
            persist(root, version: version, declaration: declaration)
        } catch { fail(pluginID, error); throw error }
    }

    func downloadLatestToolchain(for pluginID: PluginID) async throws {
        let declaration = try begin(pluginID, state: .downloading)
        defer { busyPlugins.remove(pluginID) }
        let sdk = declaration.toolchains[0]
        do {
            let (metadata, metadataResponse) = try await session.data(for: URLRequest(url: sdk.metadataURL, timeoutInterval: 30))
            guard (metadataResponse as? HTTPURLResponse)?.statusCode == 200 else { throw PluginToolchainError.downloadMetadataFailed }
            let archive = try MacPluginToolchainArchive.select(from: metadata, toolchain: sdk, architecture: Self.hostArchitecture)
            let (downloaded, archiveResponse) = try await session.download(for: URLRequest(url: archive.url, timeoutInterval: 120))
            defer { try? fileStorage.removeItem(at: downloaded) }
            guard (archiveResponse as? HTTPURLResponse)?.statusCode == 200 else { throw PluginToolchainError.downloadFailed }
            try Task.checkCancellation()
            let storage = fileStorage
            // Hashing a whole SDK is filesystem work, so use a native worker,
            // not the main actor or a cooperative Swift executor thread.
            let checksum: String = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let data = try storage.readData(from: downloaded, options: [.mappedIfSafe])
                        continuation.resume(returning: Self.digest(data))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            guard checksum == archive.checksum else { throw PluginToolchainError.checksumMismatch }
            try Task.checkCancellation()
            let temporary = fileStorage.temporaryDirectory().appendingPathComponent("lithe-plugin-toolchain-\(UUID().uuidString)")
            try fileStorage.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? fileStorage.removeItem(at: temporary) }
            let extractionArguments = sdk.archiveFormat == "zip"
                ? ["-x", "-k", downloaded.path, temporary.path]
                : ["-xzf", downloaded.path, "-C", temporary.path, "--no-same-owner"]
            let result = try await runCommand(ProcessRequest(
                operationID: "plugin-toolchain-extract-\(pluginID)",
                executablePath: sdk.archiveFormat == "zip" ? "/usr/bin/ditto" : "/usr/bin/tar",
                arguments: extractionArguments, timeoutMilliseconds: 120_000
            ))
            guard result.succeeded else { throw PluginToolchainError.extractionFailed(result.output) }
            let extracted = temporary.appendingPathComponent(sdk.archiveRoot)
            let version = try await validate(extracted, sdk: sdk)
            let destination = stateRoot(pluginID).appendingPathComponent("\(sdk.id)/\(archive.version)/\(Self.hostArchitecture)")
            // A reinstall never deletes a version that a running session may
            // still use. Validate staged inputs before publishing preferences.
            if fileStorage.fileExists(at: destination) {
                _ = try await validate(destination, sdk: sdk)
            } else {
                try fileStorage.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileStorage.moveItem(at: extracted, to: destination)
            }
            try Task.checkCancellation()
            persist(destination, version: version, declaration: declaration)
        } catch { fail(pluginID, error); throw error }
    }

    func installLanguageServer(for pluginID: PluginID) async throws {
        let declaration = try begin(pluginID, state: .installingServer)
        defer { busyPlugins.remove(pluginID) }
        do {
            guard let server = declaration.languageServers.first,
                  let path = snapshots[pluginID]?.selectedPath,
                  let root = Self.normalizedPath(path) else { throw PluginToolchainError.invalidToolchainPath("") }
            let sdk = declaration.toolchains[0]
            _ = try await validate(root, sdk: sdk)
            let toolchainVersion = snapshots[pluginID]?.selectedVersion ?? "latest"
            let state = stateRoot(pluginID)
            let cache = fileStorage.cacheDirectory().appendingPathComponent("Lithe/PluginToolchains/\(pluginID)")
            let destination = state.appendingPathComponent("language-servers/\(server.id)/\(Self.digest(Data(root.path.utf8)))/\(UUID().uuidString)")
            try fileStorage.createDirectory(at: destination.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try fileStorage.createDirectory(at: cache, withIntermediateDirectories: true)
            var installed = false
            defer { if !installed { try? fileStorage.removeItem(at: destination) } }
            let inherited = ProcessInfo.processInfo.environment
            var environment = inherited
            for (key, value) in server.environment {
                environment[key] = Self.expand(value, root: root, serverRoot: destination, state: state, cache: cache, inherited: inherited, version: toolchainVersion)
            }
            let arguments = server.installCommand.map {
                Self.expand($0, root: root, serverRoot: destination, state: state, cache: cache, inherited: inherited, version: toolchainVersion)
            }
            let result = try await runCommand(ProcessRequest(
                operationID: "plugin-toolchain-install-\(pluginID)", executablePath: root.appendingPathComponent(sdk.executable).path,
                arguments: arguments, workingDirectory: destination.path, environment: environment, timeoutMilliseconds: 600_000
            ))
            let executable = destination.appendingPathComponent(server.executable)
            guard result.succeeded, fileStorage.isExecutable(at: executable) else {
                throw PluginToolchainError.languageServerInstallationFailed(result.output)
            }
            let validation = try await runCommand(ProcessRequest(
                executablePath: executable.path, arguments: server.validationArguments,
                environment: environment, timeoutMilliseconds: 5_000
            ))
            guard validation.succeeded else { throw PluginToolchainError.validationFailed(validation.output) }
            // A generic launcher carries this SDK's environment into the
            // declared server without changing the host LSP runtime.
            let launcher = destination.appendingPathComponent("launchers/\(executable.lastPathComponent)")
            try fileStorage.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
            var script = "#!/bin/sh\n"
            for key in server.runtimeEnvironment.keys.sorted() {
                let value = Self.expand(server.runtimeEnvironment[key]!, root: root, serverRoot: destination, state: state, cache: cache, inherited: inherited, version: toolchainVersion)
                script += "export \(key)=\(Self.shellQuote(value))\n"
            }
            script += "exec \(Self.shellQuote(executable.path)) \"$@\"\n"
            try fileStorage.writeData(Data(script.utf8), to: launcher, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
            try Task.checkCancellation()
            store.set(launcher.path, forKey: Self.serverKey(pluginID, server.id, root: root))
            installed = true
            setState(pluginID, .configured(path: path, version: snapshots[pluginID]?.selectedVersion))
        } catch { fail(pluginID, error); throw error }
    }

    /// Removes only state owned by the plugin manager. A user-selected SDK
    /// outside this directory is never deleted during plugin uninstall.
    func removeManagedState(for pluginID: PluginID) throws {
        guard let declaration = declarations[pluginID] else { return }
        let root = stateRoot(pluginID)
        if fileStorage.fileExists(at: root) {
            try fileStorage.removeItem(at: root)
        }
        for sdk in declaration.toolchains {
            store.set(nil, forKey: Self.pathKey(pluginID: pluginID, toolchainID: sdk.id))
            store.set(nil, forKey: Self.versionKey(pluginID, sdk.id))
        }
        for server in declaration.languageServers {
            // KeyValueStore intentionally exposes only key-based access. The
            // launcher key is content-addressed by SDK path, so clear the
            // selected launcher key when the selected path is known.
            if let selectedPath = snapshots[pluginID]?.selectedPath,
               let root = Self.normalizedPath(selectedPath) {
                store.set(nil, forKey: Self.serverKey(pluginID, server.id, root: root))
            }
        }
        snapshots[pluginID] = PluginToolchainSnapshot(
            pluginID: pluginID,
            displayName: declaration.toolchains[0].displayName,
            canInstallLanguageServer: !declaration.languageServers.isEmpty,
            state: .missing,
            selectedPath: nil,
            selectedVersion: nil
        )
    }

    /// Only declarations from accepted active plugins participate. Unrelated or
    /// uninstalled preference keys cannot inject tools into another plugin.
    nonisolated static func configuredExecutables(
        declarations: [PluginID: MacPluginToolchainConfiguration], defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: [URL]] {
        var result: [String: [URL]] = [:]
        for pluginID in declarations.keys.sorted() {
            guard let declaration = declarations[pluginID], let sdk = declaration.toolchains.first else { continue }
            for command in (declaration.discovery ?? [:]).keys.sorted() {
                for template in declaration.discovery?[command] ?? [] {
                    for path in discoveryPaths(template, environment: environment, homeDirectory: homeDirectory) {
                        result[command, default: []].append(path.appendingPathComponent(command))
                    }
                }
            }
            guard
                  let path = defaults.string(forKey: pathKey(pluginID: pluginID, toolchainID: sdk.id)),
                  let root = normalizedPath(path) else { continue }
            let executable = root.appendingPathComponent(sdk.executable)
            result[executable.lastPathComponent, default: []].insert(executable, at: 0)
            for server in declaration.languageServers {
                if let path = defaults.string(forKey: serverKey(pluginID, server.id, root: root)) {
                    result[URL(fileURLWithPath: server.executable).lastPathComponent, default: []].insert(URL(fileURLWithPath: path), at: 0)
                }
            }
        }
        return result
    }

    /// Expands plugin-declared search paths. A missing environment value yields
    /// no candidate; path-list variables expand each directory independently.
    nonisolated static func discoveryPaths(_ template: String, environment: [String: String], homeDirectory: URL) -> [URL] {
        let expanded = template.replacingOccurrences(of: "{home}", with: homeDirectory.path)
        guard let start = expanded.range(of: "{environment:"),
              let end = expanded[start.upperBound...].firstIndex(of: "}") else {
            return normalizedPath(expanded).map { [$0] } ?? []
        }
        let key = String(expanded[start.upperBound..<end])
        guard MacPluginToolchainConfiguration.isEnvironmentKey(key), let value = environment[key] else { return [] }
        return value.split(separator: ":").compactMap { directory in
            normalizedPath(String(expanded[..<start.lowerBound]) + directory + expanded[expanded.index(after: end)...])
        }
    }

    nonisolated static func pathKey(pluginID: PluginID, toolchainID: String) -> String {
        "lithe.plugin.toolchain.\(pluginID).\(toolchainID).path"
    }

    private func begin(_ pluginID: PluginID, state: PluginToolchainSnapshot.State) throws -> MacPluginToolchainConfiguration {
        guard let declaration = declarations[pluginID] else { throw PluginToolchainError.unavailable }
        guard busyPlugins.insert(pluginID).inserted else { throw PluginToolchainError.busy }
        setState(pluginID, state)
        return declaration
    }

    private func validate(_ root: URL, sdk: MacPluginToolchainConfiguration.Toolchain) async throws -> String {
        let executable = root.appendingPathComponent(sdk.executable)
        guard fileStorage.isExecutable(at: executable) else { throw PluginToolchainError.invalidToolchainPath(root.path) }
        let result = try await runCommand(ProcessRequest(
            executablePath: executable.path, arguments: sdk.validationArguments,
            environment: ProcessInfo.processInfo.environment, timeoutMilliseconds: 5_000
        ))
        guard result.succeeded else { throw PluginToolchainError.validationFailed(result.output) }
        try Task.checkCancellation()
        return result.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? "unknown"
    }

    private func persist(_ root: URL, version: String, declaration: MacPluginToolchainConfiguration) {
        let sdk = declaration.toolchains[0]
        let id = declaration.pluginID
        store.set(root.path, forKey: Self.pathKey(pluginID: id, toolchainID: sdk.id))
        store.set(version, forKey: Self.versionKey(id, sdk.id))
        snapshots[id] = PluginToolchainSnapshot(
            pluginID: id, displayName: sdk.displayName, canInstallLanguageServer: !declaration.languageServers.isEmpty,
            state: .configured(path: root.path, version: version), selectedPath: root.path, selectedVersion: version
        )
    }

    private func setState(_ id: PluginID, _ state: PluginToolchainSnapshot.State) {
        guard let snapshot = snapshots[id] else { return }
        snapshots[id] = PluginToolchainSnapshot(
            pluginID: id, displayName: snapshot.displayName, canInstallLanguageServer: snapshot.canInstallLanguageServer,
            state: state, selectedPath: snapshot.selectedPath, selectedVersion: snapshot.selectedVersion
        )
    }

    private func fail(_ id: PluginID, _ error: Error) { setState(id, .failed(error.localizedDescription)) }
    private func stateRoot(_ id: PluginID) -> URL { fileStorage.applicationSupportDirectory().appendingPathComponent("Lithe/Toolchains/\(id)") }
    private nonisolated static func normalizedPath(_ value: String) -> URL? {
        let path = (value.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    private nonisolated static func versionKey(_ id: PluginID, _ sdk: String) -> String { "lithe.plugin.toolchain.\(id).\(sdk).version" }
    private nonisolated static func serverKey(_ id: PluginID, _ server: String, root: URL) -> String {
        "lithe.plugin.toolchain.\(id).\(server).\(digest(Data(root.path.utf8))).launcher"
    }
    private nonisolated static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private nonisolated static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "amd64"
        #endif
    }
    private nonisolated static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private nonisolated static func expand(
        _ value: String, root: URL, serverRoot: URL, state: URL, cache: URL, inherited: [String: String], version: String = "latest"
    ) -> String {
        value.replacingOccurrences(of: "{toolchainRoot}", with: root.path)
            .replacingOccurrences(of: "{toolchainBin}", with: root.appendingPathComponent("bin").path)
            .replacingOccurrences(of: "{serverBin}", with: serverRoot.appendingPathComponent("bin").path)
            .replacingOccurrences(of: "{stateRoot}", with: state.path)
            .replacingOccurrences(of: "{cacheRoot}", with: cache.path)
            .replacingOccurrences(of: "{PATH}", with: inherited["PATH"] ?? "")
            .replacingOccurrences(of: "{version}", with: version)
    }
}
