import Foundation
import Darwin
import Testing
@testable import Lithe
import LitheModuleAPI

@Suite("Toolchain settings loader")
struct ToolchainSettingsLoaderTests {
    private let workspace = URL(fileURLWithPath: "/fixture/toolchain-settings/project", isDirectory: true)
    private var localPath: String { workspace.appendingPathComponent(".lithe/toolchains/local.json").path }

    private func source(
        pluginID: String = "dev.lithe.fixture.tools", enabled: Bool = true,
        executables: [[String: Any]] = [], watchFiles: [String]? = [".fixture-version"]
    ) throws -> ToolchainSettingsPluginSource {
        var provider: [String: Any] = ["id": "manager", "displayName": "Fixture manager", "tools": ["compiler", "disabled-tool"]]
        if let watchFiles { provider["watchFiles"] = watchFiles.map { ["pattern": $0, "reader": "native"] } }
        let manifest: [String: Any] = [
            "schemaVersion": 2, "id": pluginID, "displayName": "Fixture support",
            "version": "1.0.0", "pluginAPIVersion": 3,
            "toolDefinitions": [["id": "compiler", "displayName": "Fixture compiler", "icon": ["host": "plugin"],
                                 "executables": executables]],
            "toolchainProviders": [provider]
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
        environment: [String: String] = [:],
        discover: @escaping @Sendable (MacToolchainDiscovery.Request) async -> MacToolchainDiscovery.Result = { _ in .init() }
    ) -> MacToolchainSettingsLoader {
        MacToolchainSettingsLoader(sources: sources, directories: directories, resolvePin: resolvePin,
            isRemoteWorkspace: isRemoteWorkspace, environment: { environment },
            fileExists: { files.exists($0) }, isExecutable: { files.executable($0) },
            readLocalData: { try files.read($0) }, discover: discover)
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

    @Test func buildConsumersComeFromTheCurrentCoreInvocationAndDisappearWhenDisabled() async throws {
        let definition = try source()
        let fixture = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/contracts/plugins/v1/fixtures/build-toolchains.plugin.json")
        let data = Data(try String(contentsOf: fixture, encoding: .utf8)
            .replacingOccurrences(of: "dev.lithe.fixture.build-toolchains:compiler", with: "compiler").utf8)
        let build = ToolchainSettingsPluginSource(pluginID: "dev.lithe.fixture.build-toolchains", name: "Build fixture",
            manifest: data, isEnabled: true)
        let snapshot = try await loader(sources: { [definition, build] }).load(workspace: workspace)
        #expect(snapshot.tools.first?.consumers == [.init(id: build.pluginID + "/cargo", title: "Cargo", pluginName: "Build fixture")])
        let disabled = ToolchainSettingsPluginSource(pluginID: build.pluginID, name: build.name, manifest: data, isEnabled: false)
        let withdrawn = try await loader(sources: { [definition, disabled] }).load(workspace: workspace)
        #expect(withdrawn.tools.first?.consumers.isEmpty == true)
    }

    @Test func savedPreferenceScopesStayEditableWithoutVersionFilesOrPins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-preference-directories-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(".lithe/run/local.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data(#"{"version":2,"configurations":[],"toolchain":{"preferences":{"version":1,"directories":{"modules/service":{"tools":{"compiler":{"home":"/fixture/sdk"}}},"modules/worker":{"consumers":{"dev.example.build/engine":{"compiler":{"inherit":"consumer"}}}}}}}}"#.utf8)
        try bytes.write(to: url)
        let source = try source()
        let reading = loader(sources: { [source] })
        let saved = try await reading.load(workspace: root)
        #expect(saved.directories.map(\.id) == [".", "modules", "modules/service", "modules/worker"])
        #expect(saved.directories.filter(\.hasToolPreferences).map(\.id) == ["modules/service", "modules/worker"])
        #expect(saved.tools.map(\.directoryID) == saved.directories.map(\.id))
        #expect(saved.watch.contains(url.path))
        #expect(try Data(contentsOf: url) == bytes)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".lithe/.gitignore").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".lithe/toolchains").path))
        try Data(#"{"version":2,"configurations":[]}"#.utf8).write(to: url)
        let reset = try await reading.load(workspace: root)
        #expect(reset.directories.map(\.id) == ["."])
        #expect(reset.directories.first?.hasToolPreferences == false)
    }

    @Test func changingSavedScopesDuringDiscoveryDiscardsOldRowsAndRetriesOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-preference-scope-change-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(".lithe/run/local.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"version":2,"configurations":[]}"#.utf8)
        let changed = Data(#"{"version":2,"configurations":[],"toolchain":{"preferences":{"version":1,"directories":{"nested":{"tools":{"compiler":{"home":"/fixture/sdk"}}}}}}}"#.utf8)
        try original.write(to: url)
        let source = try source()
        let reading = loader(sources: { [source] }, discover: { _ in
            try? changed.write(to: url)
            return .init()
        })
        let snapshot = try await reading.load(workspace: root)
        #expect(snapshot.directories.map(\.id) == [".", "nested"])
        #expect(snapshot.directories.last?.hasToolPreferences == true)
        #expect(try Data(contentsOf: url) == changed)
    }

    @Test func continuouslyChangingScopesStopAfterOneRetryWithARefreshableFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-continuous-preference-change-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(".lithe/run/local.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"version":2,"configurations":[]}"#.utf8)
        try original.write(to: url)
        let source = try source()
        let reading = loader(sources: { [source] }, discover: { _ in
            if var current = try? Data(contentsOf: url) { current.append(32); try? current.write(to: url) }
            return .init()
        })
        await #expect(throws: ToolchainSettingsLoadError.sourceChanged) { try await reading.load(workspace: root) }
        #expect(try Data(contentsOf: url).count == original.count + 2)
    }

    @Test(arguments: ["traversal", "too-deep"])
    func invalidPreferenceDirectoriesAreRejectedBeforeNativeDiscovery(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-invalid-preference-scopes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(".lithe/run/local.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let directory = kind == "traversal" ? "../outside" : Array(repeating: "nested", count: 65).joined(separator: "/")
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 2, "configurations": [], "toolchain": ["preferences": ["version": 1,
            "directories": [directory: ["tools": ["compiler": ["home": "/fixture/sdk"]]]]]]])
        try bytes.write(to: url)
        let source = try source()
        let reading = loader(sources: { [source] }, discover: { _ in
            Issue.record("An invalid preference scope must not query or probe tools")
            return .init()
        })
        await #expect(throws: (any Error).self) { try await reading.load(workspace: root) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test(arguments: ["parent-alias", "file-alias"])
    func preferenceScopeReaderRefusesExternalAliasesBeforeReading(kind: String) throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-preference-source-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("workspace"), outside = scratch.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("run"), withIntermediateDirectories: true)
        let source = outside.appendingPathComponent("run/local.json")
        let bytes = Data(#"{"version":2,"configurations":[]}"#.utf8)
        try bytes.write(to: source)
        let target = root.appendingPathComponent(".lithe/run/local.json")
        if kind == "parent-alias" {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".lithe"), withDestinationURL: outside)
        } else {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
        }
        #expect(throws: ToolchainSettingsLoadError.readFailed) { try MacToolchainSettingsLoader.safeNativePreferenceRead(target) }
        #expect(try Data(contentsOf: source) == bytes)
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

    @Test func pathCandidateFollowsDeclarationOrderAndSkipsOtherPlatforms() async throws {
        let source = try source(executables: [
            ["kind": "command", "command": "linuxc", "platforms": ["linux"]],
            ["kind": "environment", "variable": "FIXTURE_HOME", "path": "bin/fixturec"],
            ["kind": "command", "command": "fixturec"],
            ["kind": "command", "command": "otherc"]
        ])
        let environment = ["FIXTURE_HOME": "/fixture/home/", "PATH": "relative/bin:/fixture/first:/fixture/second"]
        let onPath = ToolchainLoaderFiles(executables: ["/fixture/second/fixturec", "relative/bin/fixturec",
                                                        "/fixture/first/linuxc", "/fixture/home/bin/fixturec"])
        let found = try await loader(files: onPath, sources: { [source] }, environment: environment).load(workspace: workspace)
        // Home variables are checked by Core through discovery, never by this existence test.
        #expect(found.tools.first?.candidate == .init(executable: "/fixture/second/fixturec"))
        // An earlier command wins even when a later one is earlier on PATH.
        let both = ToolchainLoaderFiles(executables: ["/fixture/second/fixturec", "/fixture/first/otherc"])
        let preferred = try await loader(files: both, sources: { [source] }, environment: environment).load(workspace: workspace)
        #expect(preferred.tools.first?.candidate == .init(executable: "/fixture/second/fixturec"))
        let missing = try await loader(sources: { [source] }, environment: environment).load(workspace: workspace)
        #expect(missing.tools.first?.candidate == nil)
    }

    @Test func discoveryReceivesEnabledSourcesAndEveryDirectoryRowSharesItsDetection() async throws {
        let enabled = try source()
        let disabled = try source(pluginID: "dev.lithe.fixture.disabled", enabled: false)
        let requests = ToolchainDiscoveryRequests()
        let detection = ToolchainSettingsSnapshot.Detection(
            shell: [.init(variable: "FIXTURE_HOME", home: "/fixture/home", executable: "/fixture/home/bin/fixturec",
                          version: "3.1")],
            installations: [.init(home: "/fixture/installed/4.0", executable: "/fixture/installed/4.0/bin/fixturec",
                                  version: "4.0", provider: "host:system")],
            skipped: [.init(home: "/fixture/installed/broken", reason: "probeFailed")],
            selected: "/fixture/installed/4.0")
        let files = ToolchainLoaderFiles(existing: [workspace.appendingPathComponent("apps/.fixture-version").path])
        let snapshot = try await loader(files: files, sources: { [disabled, enabled] }, directories: { _ in ["apps"] },
            environment: ["FIXTURE_HOME": "/fixture/home"],
            discover: { request in
                requests.record(request)
                return .init(detections: ["compiler": detection], diagnostics: ["Fixture discovery note"])
            }).load(workspace: workspace)
        let request = try #require(requests.values.first)
        #expect(requests.values.count == 1)
        #expect(request.workspace == workspace)
        #expect(request.sources.map(\.pluginID) == [enabled.pluginID])
        #expect(request.environment == ["FIXTURE_HOME": "/fixture/home"])
        #expect(snapshot.tools.map(\.directoryID) == [".", "apps"])
        #expect(snapshot.tools.allSatisfy { $0.detection == detection })
        #expect(snapshot.diagnostics == ["Fixture discovery note"])
    }

    @Test func toolsCoreCouldNotCheckAreNamedWithoutADetection() async throws {
        let source = try source()
        let snapshot = try await loader(sources: { [source] },
            discover: { _ in .init(unchecked: ["compiler"]) }).load(workspace: workspace)
        #expect(snapshot.tools.first?.detection == nil)
        #expect(snapshot.diagnostics == [L10n.string("Installations of \("Fixture compiler") could not be checked.")])
    }

    /// A row shows what Core resolved for the directory that decides it: a saved pin's own
    /// directory, otherwise the nearest one with a version file of its own.
    @Test func rowsShowCoreResolutionOfTheirPinOrNearestQueriedDirectory() async throws {
        let source = try source()
        let document = try local(["apps/web": ["compiler": pin("2")]])
        let files = ToolchainLoaderFiles(contents: [localPath: document],
                                         existing: [workspace.appendingPathComponent("apps/.fixture-version").path])
        typealias Resolution = ToolchainSettingsSnapshot.Resolution
        let root = Resolution(layer: .automatic, outcome: .resolved(home: "/fixture/installed/1", executable:
            "/fixture/installed/1/bin/fixturec", version: "1", provider: "host:system"))
        let apps = Resolution(layer: .project, outcome: .skipped(reason: "requestedNotInstalled"), unmet: ["3"])
        let web = Resolution(layer: .pinned, outcome: .failed(reason: "probeFailed"))
        let requests = ToolchainDiscoveryRequests()
        let snapshot = try await loader(files: files, sources: { [source] }, directories: { _ in ["apps", "apps/web"] },
            discover: { request in
                requests.record(request)
                return .init(resolutions: [".": ["compiler": root], "apps": ["compiler": apps],
                                           "apps/web": ["compiler": web]],
                             unresolved: ["compiler"])
            }).load(workspace: workspace)
        let request = try #require(requests.values.first)
        #expect(request.directories == [".", "apps"])
        #expect(request.local == document)
        #expect(snapshot.tools.map(\.directoryID) == [".", "apps", "apps/web"])
        #expect(snapshot.tools.map(\.resolution) == [root, apps, web])
        #expect(snapshot.diagnostics == [L10n.string("Which \("Fixture compiler") to use could not be determined.")])
    }

    @Test func discoveryDoesNotRunWithoutAWorkspaceOrDefinitions() async throws {
        let requests = ToolchainDiscoveryRequests()
        let discover: @Sendable (MacToolchainDiscovery.Request) async -> MacToolchainDiscovery.Result = { request in
            requests.record(request)
            return .init()
        }
        let source = try source()
        _ = try await loader(sources: { [source] }, discover: discover).load(workspace: nil)
        let manifest = try JSONSerialization.data(withJSONObject: ["id": "dev.lithe.fixture.empty"])
        let empty = ToolchainSettingsPluginSource(pluginID: "dev.lithe.fixture.empty", name: "Empty", manifest: manifest,
                                                  isEnabled: true)
        _ = try await loader(sources: { [empty] }, discover: discover).load(workspace: workspace)
        #expect(requests.values.isEmpty)
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

    @Test func installationOnlyProvidersAreListedWithoutCheckingVersionFiles() async throws {
        let source = try source(watchFiles: nil)
        let files = ToolchainLoaderFiles()
        let snapshot = try await loader(files: files, sources: { [source] },
            directories: { _ in ["apps"] }).load(workspace: workspace)
        #expect(snapshot.providers.map(\.id) == ["dev.lithe.fixture.tools:manager"])
        #expect(snapshot.providers.first?.watchFiles == [])
        #expect(snapshot.tools.allSatisfy { $0.versionFiles.isEmpty })
        #expect(files.checkedPaths.isEmpty)
        // Omitting `watchFiles` is allowed; declaring something other than a list is not.
        var manifest = try #require(try JSONSerialization.jsonObject(with: source.manifest) as? [String: Any])
        manifest["toolchainProviders"] = [["id": "manager", "displayName": "Fixture manager",
                                           "tools": ["compiler"], "watchFiles": ".fixture-version"]]
        let malformed = ToolchainSettingsPluginSource(pluginID: source.pluginID, name: source.name,
            manifest: try JSONSerialization.data(withJSONObject: manifest), isEnabled: true)
        await #expect(throws: ToolchainSettingsLoadError.invalidDeclarations) {
            try await loader(sources: { [malformed] }).load(workspace: nil)
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

/// Records discovery requests without scanning or running anything.
private final class ToolchainDiscoveryRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [MacToolchainDiscovery.Request] = []

    var values: [MacToolchainDiscovery.Request] { lock.withLock { recorded } }

    func record(_ request: MacToolchainDiscovery.Request) {
        lock.withLock { recorded.append(request) }
    }
}
