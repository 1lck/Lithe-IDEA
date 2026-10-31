import Foundation
import Darwin
import Testing
@testable import Lithe

@Suite("Toolchain settings loader")
struct ToolchainSettingsLoaderTests {
    private let workspace = URL(fileURLWithPath: "/fixture/toolchain-settings/project", isDirectory: true)
    private var localPath: String { workspace.appendingPathComponent(".lithe/toolchains/local.json").path }

    private func source(
        pluginID: String = "dev.lithe.fixture.tools", enabled: Bool = true,
        executables: [[String: Any]] = [], watchFiles: [String] = [".fixture-version"]
    ) throws -> ToolchainSettingsPluginSource {
        let manifest: [String: Any] = [
            "schemaVersion": 2, "id": pluginID, "displayName": "Fixture support",
            "version": "1.0.0", "pluginAPIVersion": 3,
            "toolDefinitions": [["id": "compiler", "displayName": "Fixture compiler", "icon": ["host": "plugin"],
                                 "executables": executables]],
            "toolchainProviders": [["id": "manager", "displayName": "Fixture manager", "tools": ["compiler", "disabled-tool"],
                "watchFiles": watchFiles.map { ["pattern": $0, "reader": "native"] }]]
        ]
        return .init(pluginID: pluginID, name: "Fixture support",
                     manifest: try JSONSerialization.data(withJSONObject: manifest), isEnabled: enabled)
    }

    private func local(_ pins: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "toolchains": [:], "pins": pins])
    }

    private func pin(_ version: String) -> [String: String] {
        ["home": "/fixture/installed/compiler/\(version)", "version": version, "provider": "host:manual"]
    }

    private func loader(
        files: ToolchainLoaderFiles = ToolchainLoaderFiles(),
        sources: @escaping @MainActor @Sendable () -> [ToolchainSettingsPluginSource],
        directories: @escaping @MainActor @Sendable (URL?) -> [String] = { _ in [] },
        resolvePin: @escaping @Sendable (Data, String, String) throws -> ToolchainSettingsSavedPin? = MacToolchainSettingsLoader.resolvePinUsingCore,
        isRemoteWorkspace: @escaping @Sendable (URL) -> Bool = { _ in false },
        environment: [String: String] = [:]
    ) -> MacToolchainSettingsLoader {
        MacToolchainSettingsLoader(sources: sources, directories: directories, resolvePin: resolvePin,
            isRemoteWorkspace: isRemoteWorkspace, environment: { environment },
            fileExists: { files.exists($0) }, isExecutable: { files.executable($0) },
            readLocalData: { try files.read($0) })
    }

    @Test func missingLocalFileListsDeclarationsWithoutClaimingAnyValue() async throws {
        let source = try source()
        let files = ToolchainLoaderFiles()
        let snapshot = try await loader(files: files, sources: { [source] }).load(workspace: workspace)
        #expect(snapshot.workspaceURL == workspace)
        #expect(snapshot.directories.map(\.id) == ["."])
        #expect(snapshot.directories.first?.title == "project")
        let tool = try #require(snapshot.tools.first)
        #expect(tool.displayName == "Fixture compiler")
        #expect(tool.pluginID == source.pluginID && tool.pluginName == "Fixture support")
        #expect(tool.iconName == "plugin")
        #expect(tool.pin == nil && tool.versionFiles.isEmpty && tool.candidate == nil)
        #expect(snapshot.providers.first?.id == "dev.lithe.fixture.tools:manager")
        #expect(snapshot.providers.first?.tools == ["compiler"])
        #expect(snapshot.providers.first?.watchFiles == [".fixture-version"])
        #expect(snapshot.diagnostics.isEmpty)
        #expect(files.readPaths == [localPath])
    }

    @Test func versionFilesListTheirDirectoriesAndRowsInheritTheNearestFirst() async throws {
        let source = try source(watchFiles: [".fixture-version", "*.fixture"])
        let files = ToolchainLoaderFiles(existing: [
            workspace.appendingPathComponent(".fixture-version").path,
            workspace.appendingPathComponent("apps/web/.fixture-version").path
        ])
        let snapshot = try await loader(files: files, sources: { [source] },
            directories: { _ in ["apps", "apps/web", "apps/web/src", "docs"] }).load(workspace: workspace)
        // Directories without their own facts are listed only to connect a deeper one.
        #expect(snapshot.directories.map(\.id) == [".", "apps", "apps/web"])
        #expect(snapshot.directories.map(\.versionFiles.count) == [1, 0, 1])
        let provider = "dev.lithe.fixture.tools:manager"
        let web = try #require(snapshot.tools.first { $0.directoryID == "apps/web" })
        #expect(web.versionFiles == [.init(path: "apps/web/.fixture-version", providerIDs: [provider]),
                                     .init(path: ".fixture-version", providerIDs: [provider])])
        let apps = try #require(snapshot.tools.first { $0.directoryID == "apps" })
        #expect(apps.versionFiles.map(\.path) == [".fixture-version"])
        // Glob patterns stay with the provider; the loader never expands them.
        #expect(!files.checkedPaths.contains { $0.contains("*") })
    }

    @Test func coreResolvesSavedPinsAndTheirSourceDirectories() async throws {
        let source = try source()
        let files = ToolchainLoaderFiles(contents: [localPath: try local([
            ".": ["compiler": pin("1")], "apps/web": ["compiler": pin("2")]
        ])])
        let snapshot = try await loader(files: files, sources: { [source] },
            directories: { _ in ["apps/web/src", "apps/website"] }).load(workspace: workspace)
        #expect(snapshot.directories.map(\.id) == [".", "apps", "apps/web"])
        let pins = snapshot.tools.map { [$0.directoryID, $0.pin?.version ?? "", $0.pin?.directory ?? ""] }
        #expect(pins == [[".", "1", "."], ["apps", "1", "."], ["apps/web", "2", "apps/web"]])
        #expect(snapshot.tools.last?.pin?.home == "/fixture/installed/compiler/2")
    }

    @Test func automaticDiscoveryFollowsDeclarationOrderAndSkipsOtherPlatforms() async throws {
        let source = try source(executables: [
            ["kind": "command", "command": "fixturec", "platforms": ["linux"]],
            ["kind": "environment", "variable": "FIXTURE_HOME", "path": "bin/fixturec"],
            ["kind": "command", "command": "fixturec"]
        ])
        let environment = ["FIXTURE_HOME": "/fixture/home/", "PATH": "relative/bin:/fixture/first:/fixture/second"]
        let onPath = ToolchainLoaderFiles(executables: ["/fixture/second/fixturec", "relative/bin/fixturec"])
        let found = try await loader(files: onPath, sources: { [source] }, environment: environment).load(workspace: workspace)
        #expect(found.tools.first?.candidate == .init(executable: "/fixture/second/fixturec", origin: .path))
        // An earlier declaration wins even when a later one also exists.
        let both = ToolchainLoaderFiles(executables: ["/fixture/second/fixturec", "/fixture/home/bin/fixturec"])
        let preferred = try await loader(files: both, sources: { [source] }, environment: environment).load(workspace: workspace)
        #expect(preferred.tools.first?.candidate == .init(executable: "/fixture/home/bin/fixturec", origin: .variable("FIXTURE_HOME")))
        let missing = try await loader(sources: { [source] }, environment: environment).load(workspace: workspace)
        #expect(missing.tools.first?.candidate == nil)
    }

    @Test func truncatedListsSayHowManyDirectoriesWereCovered() async throws {
        let definitions = (0..<32).map { ["id": "tool-\($0)", "displayName": "Tool \($0)"] }
        let manifest: [String: Any] = ["id": "dev.lithe.fixture.many", "toolDefinitions": definitions,
            "toolchainProviders": [["id": "manager", "displayName": "Manager", "tools": ["tool-0"],
                "watchFiles": (0..<32).map { ["pattern": ".file-\($0)"] }]]]
        let source = ToolchainSettingsPluginSource(pluginID: "dev.lithe.fixture.many", name: "Many",
            manifest: try JSONSerialization.data(withJSONObject: manifest), isEnabled: true)
        let directories = (0..<600).map { String(format: "dir-%03d", $0) }
        let files = ToolchainLoaderFiles(existing: Set(directories.map { workspace.appendingPathComponent($0 + "/.file-0").path }))
        let snapshot = try await loader(files: files, sources: { [source] }, directories: { _ in directories })
            .load(workspace: workspace)
        // 16,384 checks over 32 patterns reach 512 directories; 4,096 rows over 32 tools list 128.
        #expect(files.checkedPaths.count == 16_384)
        #expect(snapshot.directories.count == 128)
        #expect(snapshot.tools.count == 128 * 32)
        #expect(snapshot.diagnostics.count == 2)
    }

    @Test func disabledDefinitionsDisappearAndTheirPinsReturnWithThem() async throws {
        let files = ToolchainLoaderFiles(contents: [localPath: try local([".": ["compiler": pin("1")]])])
        let (disabled, enabled) = (try source(enabled: false), try source())
        let hidden = try await loader(files: files, sources: { [disabled] }).load(workspace: workspace)
        #expect(hidden.tools.isEmpty && hidden.providers.isEmpty)
        let restored = try await loader(files: files, sources: { [enabled] }).load(workspace: workspace)
        #expect(restored.tools.first?.pin?.version == "1")
    }

    @Test func malformedDisabledPluginIsNotParsed() async throws {
        let disabled = ToolchainSettingsPluginSource(pluginID: "disabled", name: "Disabled", manifest: Data("invalid".utf8), isEnabled: false)
        let snapshot = try await loader(sources: { [disabled] }).load(workspace: nil)
        #expect(snapshot.tools.isEmpty && snapshot.providers.isEmpty)
    }

    @Test func sharedCoreRejectionOfMalformedDocumentsIsNotTreatedAsMissing() async throws {
        for data in [Data("invalid".utf8), try local(["../parent": ["compiler": pin("1")]]),
                     try local(["src//nested": ["compiler": pin("1")]])] {
            let loader = loader(files: ToolchainLoaderFiles(contents: [localPath: data]), sources: { [] })
            await #expect(throws: ToolchainSettingsLoadError.invalidLocal) {
                try await loader.load(workspace: workspace)
            }
        }
    }

    @Test func unreadableExistingLocalFileIsNotTreatedAsMissing() async throws {
        let files = ToolchainLoaderFiles()
        files.failReads = true
        await #expect(throws: ToolchainSettingsLoadError.readFailed) {
            try await loader(files: files, sources: { [] }).load(workspace: workspace)
        }
    }

    @Test func duplicateToolOwnersAndMalformedEnabledDeclarationsAreRefused() async throws {
        let (first, second) = (try source(), try source(pluginID: "dev.lithe.fixture.other"))
        let malformed = ToolchainSettingsPluginSource(pluginID: "invalid", name: "Invalid", manifest: Data("invalid".utf8), isEnabled: true)
        for sources in [[first, second], [first, first], [malformed]] {
            await #expect(throws: ToolchainSettingsLoadError.invalidDeclarations) {
                try await loader(sources: { sources }).load(workspace: nil)
            }
        }
    }

    @Test func nilWorkspaceListsProvidersWithoutReadingProjectFiles() async throws {
        let source = try source()
        let files = ToolchainLoaderFiles()
        let snapshot = try await loader(files: files, sources: { [source] }).load(workspace: nil)
        #expect(snapshot.workspaceURL == nil)
        #expect(snapshot.directories.isEmpty && snapshot.tools.isEmpty)
        #expect(snapshot.providers.map(\.title) == ["Fixture manager"])
        #expect(files.readPaths.isEmpty && files.checkedPaths.isEmpty)
    }

    @Test func remoteWorkspaceNeverReadsPlaceholderOrEnumeratesLocalSources() async throws {
        let files = ToolchainLoaderFiles()
        files.failReads = true
        let loader = loader(files: files, sources: {
            Issue.record("A remote workspace must not enumerate local plugin sources.")
            return []
        }, directories: { _ in
            Issue.record("A remote workspace must not enumerate local directories.")
            return []
        }, isRemoteWorkspace: { _ in true })
        let snapshot = try await loader.load(workspace: workspace)
        #expect(snapshot.workspaceURL == workspace)
        #expect(snapshot.tools.isEmpty && snapshot.providers.isEmpty && snapshot.directories.isEmpty)
        #expect(snapshot.diagnostics.count == 1)
        #expect(files.readPaths.isEmpty && files.checkedPaths.isEmpty)
    }

    @Test func directoryProjectionKeepsEveryBranchTogetherBeforeItsSibling() async throws {
        let directories = ["a/b/nested", "a-b", ".config/tools", "a/z"]
        let files = ToolchainLoaderFiles(existing: Set(directories.map {
            workspace.appendingPathComponent($0 + "/.fixture-version").path
        }))
        let source = try source()
        let snapshot = try await loader(files: files, sources: { [source] }, directories: { _ in directories })
            .load(workspace: workspace)
        #expect(snapshot.directories.map(\.id) == [".", ".config", ".config/tools", "a", "a/b", "a/b/nested", "a/z", "a-b"])
        #expect(snapshot.directories.map(\.depth) == [0, 1, 2, 1, 2, 3, 2, 1])
    }

    @Test func nativeReaderRefusesFifoAndSymlinkWithoutWaitingForWriter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("local.json")
        let result = fifo.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.mkfifo($0, 0o600) } ?? -1
        }
        #expect(result == 0)
        #expect(throws: ToolchainSettingsLoadError.readFailed) {
            try MacToolchainSettingsLoader.safeNativeRead(fifo)
        }
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fifo)
        #expect(throws: ToolchainSettingsLoadError.readFailed) {
            try MacToolchainSettingsLoader.safeNativeRead(link)
        }
        let regular = root.appendingPathComponent("regular.json")
        let bytes = Data("{}".utf8)
        try bytes.write(to: regular)
        #expect(try MacToolchainSettingsLoader.safeNativeRead(regular) == bytes)
        #expect(try MacToolchainSettingsLoader.safeNativeRead(root.appendingPathComponent("missing")) == nil)
        #expect(!MacToolchainSettingsLoader.regularFileExists(link))
        #expect(MacToolchainSettingsLoader.regularFileExists(regular))
    }
}

/// In-memory files: tests never discover developer tools or touch a real project.
private final class ToolchainLoaderFiles: @unchecked Sendable {
    private let lock = NSLock()
    private let contents: [String: Data]
    private let existing: Set<String>
    private let executables: Set<String>
    private var reads: [String] = []
    private var checks: [String] = []
    private var denyReads = false

    init(contents: [String: Data] = [:], existing: Set<String> = [], executables: Set<String> = []) {
        self.contents = contents
        self.existing = existing
        self.executables = executables
    }

    var readPaths: [String] { lock.withLock { reads } }
    var checkedPaths: [String] { lock.withLock { checks } }
    var failReads: Bool {
        get { lock.withLock { denyReads } }
        set { lock.withLock { denyReads = newValue } }
    }

    func read(_ url: URL) throws -> Data? {
        try lock.withLock {
            reads.append(url.path)
            if denyReads { throw CocoaError(.fileReadNoPermission) }
            return contents[url.path]
        }
    }

    func exists(_ url: URL) -> Bool {
        lock.withLock { checks.append(url.path) }
        return existing.contains(url.path)
    }

    func executable(_ path: String) -> Bool { executables.contains(path) }
}
