import Darwin
import Foundation
import Testing
@testable import Lithe
import LitheCoreContracts
import LitheModuleAPI

/// Real directories and the real Core; only the home directory and version probes are injected,
/// so no installed developer tool is read or run.
@Suite("macOS toolchain discovery")
struct MacToolchainDiscoveryTests {
    private static let pluginID = "dev.lithe.fixture.discovery"

    @MainActor @Test func consumerDefaultsAreReadAgainAndRemainIndependentFromExplicitRuns() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let first = try root.installation("selected-one"), second = try root.installation("selected-two")
        let probes = DiscoveryProbes(outputs: [first + "/bin/compiler": "compiler 17", second + "/bin/compiler": "compiler 21"])
        let url = root.url("workspace/.lithe/run/local.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        func save(_ home: String) throws {
            let value: [String: Any] = ["version": 2, "configurations": [], "toolchain": ["preferences": ["version": 1,
                "workspace": ["tools": ["compiler": ["home": home]],
                    "consumers": ["dev.example.build/engine": ["compiler": ["inherit": "workspace"]]]]]]]
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
        }
        let resolver = MacDefinedToolchainResolver()
        let source = Self.source()
        resolver.sources = { [source] }; resolver.discovery = discovery(root: root, probes: probes)
        try save(first)
        let selected = try await resolver.resolve(tool: "compiler", directory: ".", workspace: root.url("workspace"), environment: [:],
            minimumVersion: "11", projectCodeAllowed: true, fixed: nil, use: .installation, consumerID: "dev.example.build/engine")
        #expect(selected?.executable.path == first + "/bin/compiler")
        try save(second)
        let inherited = try await resolver.resolve(tool: "compiler", directory: ".", workspace: root.url("workspace"), environment: [:],
            minimumVersion: "11", projectCodeAllowed: true, fixed: nil, use: .installation, consumerID: "dev.example.build/engine")
        #expect(inherited?.executable.path == second + "/bin/compiler")
        let explicit = try await resolver.resolve(tool: "compiler", directory: ".", workspace: root.url("workspace"), environment: [:],
            minimumVersion: "11", projectCodeAllowed: true, fixed: .installation(home: first), use: .installation, consumerID: "dev.example.build/engine")
        #expect(explicit?.executable.path == first + "/bin/compiler")
        let before = try Data(contentsOf: url)
        await #expect(throws: BuildToolResolutionError.self) {
            try await resolver.resolve(tool: "compiler", directory: ".", workspace: root.url("workspace"), environment: [:],
                minimumVersion: "11", projectCodeAllowed: true, fixed: .installation(home: root.path + "/missing"), use: .installation,
                consumerID: "dev.example.build/engine")
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @MainActor @Test func consumerDefaultsChangedDuringNativeProofCannotPublishASelection() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let home = try root.installation("selected")
        let url = root.url("workspace/.lithe/run/local.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 2, "toolchain": ["preferences": ["version": 1,
            "workspace": ["tools": ["compiler": ["home": home]]]]]]).write(to: url)
        let resolver = MacDefinedToolchainResolver(), source = Self.source()
        resolver.sources = { [source] }
        var discovery = MacToolchainDiscovery()
        discovery.consumerProbe = { _, _, _ in
            do { try Data(#"{"version":2,"toolchain":{"preferences":{"version":1}}}"#.utf8).write(to: url) }
            catch { return nil }
            return "compiler 21"
        }
        resolver.discovery = discovery
        await #expect(throws: CancellationError.self) {
            try await resolver.resolve(tool: "compiler", directory: ".", workspace: root.url("workspace"), environment: [:],
                minimumVersion: "11", projectCodeAllowed: true, fixed: nil, use: .installation, consumerID: "dev.example.build/engine")
        }
    }

    @MainActor @Test func invalidConsumerPreferenceDocumentsAndExternalAliasesNeverProbeTools() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let source = Self.source(), resolver = MacDefinedToolchainResolver()
        resolver.sources = { [source] }
        let probes = DiscoveryProbes(outputs: [:]); resolver.discovery = discovery(root: root, probes: probes)
        let url = root.url("workspace/.lithe/run/local.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for value in [#"{"version":99}"#, #"{"version":2,"toolchain":[]}"#, #"{"version":2,"toolchain":{"preferences":{"version":1,"unknown":true}}}"#] {
            try Data(value.utf8).write(to: url)
            await #expect(throws: BuildToolResolutionError.self) {
                try await resolver.resolve(tool: "compiler", directory: ".", workspace: root.url("workspace"), environment: [:],
                    minimumVersion: nil, projectCodeAllowed: true, fixed: nil, use: .installation, consumerID: "dev.example.build/engine")
            }
        }
        let external = root.url("external-run")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data(#"{"version":2}"#.utf8).write(to: external.appendingPathComponent("local.json"))
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: url.deletingLastPathComponent(), withDestinationURL: external)
        await #expect(throws: BuildToolResolutionError.self) {
            try await resolver.resolve(tool: "compiler", directory: ".", workspace: root.url("workspace"), environment: [:],
                minimumVersion: nil, projectCodeAllowed: true, fixed: nil, use: .installation, consumerID: "dev.example.build/engine")
        }
        #expect(probes.calls.isEmpty)
    }

    @MainActor @Test func unrelatedRunMetadataKeepsTheExistingNativeDocumentBudget() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let home = try root.installation("selected"), source = Self.source()
        let probes = DiscoveryProbes(outputs: [home + "/bin/compiler": "compiler 21"])
        let resolver = MacDefinedToolchainResolver(); resolver.sources = { [source] }
        resolver.discovery = discovery(root: root, probes: probes)
        let url = root.url("workspace/.lithe/run/local.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let document: [String: Any] = ["version": 2, "metadata": String(repeating: "x", count: 1_100_000),
            "toolchain": ["preferences": ["version": 1, "workspace": ["tools": ["compiler": ["home": home]]]]]]
        let bytes = try JSONSerialization.data(withJSONObject: document)
        try bytes.write(to: url)
        let selected = try await resolver.resolve(tool: "compiler", directory: ".", workspace: root.url("workspace"), environment: [:],
            minimumVersion: "11", projectCodeAllowed: true, fixed: nil, use: .installation, consumerID: "dev.example.build/engine")
        #expect(selected?.executable.path == home + "/bin/compiler")
        #expect(try Data(contentsOf: url) == bytes)
    }

    private static func manifest(complete: Bool = true) -> Data {
        let definition: [String: Any] = [
            "id": "compiler", "displayName": "Fixture compiler", "icon": ["host": "plugin"],
            "executableLayouts": [["path": "bin/compiler"]],
            "executables": [
                ["id": "home", "kind": "environment", "variable": "FIXTURE_HOME", "path": "bin/compiler"],
                ["id": "shell", "kind": "command", "command": "compiler"],
                ["id": "detected", "kind": "toolchain", "scope": "installed"]
            ],
            "version": ["arguments": ["--version"], "pattern": #"compiler (\d+(?:\.\d+)*)"#],
            "homeLayouts": [["match": "*.kit", "home": "Contents/Home"]],
            "discovery": [["root": ["kind": "home"], "pattern": "Kits/*"]],
            "homeVariable": "FIXTURE_HOME", "commands": ["compiler"], "wrappers": [], "exports": [],
            "pathPrepend": ["${home}/bin"], "launch": ["${executable}", "${arguments}"]
        ]
        var manifest: [String: Any] = [
            "schemaVersion": 2, "id": pluginID, "displayName": "Discovery fixture", "version": "1.0.0",
            "pluginAPIVersion": 3,
            "vendor": ["id": "org.example", "displayName": "Fixture publisher", "signatureRequirement": "publisherPackage"],
            "permissions": [], "toolDefinitions": [definition]
        ]
        if complete { manifest["requires"] = ["toolDefinitions": 1, "executableResolution": 2] }
        return (try? JSONSerialization.data(withJSONObject: manifest)) ?? Data()
    }

    private static func source(complete: Bool = true) -> ToolchainSettingsPluginSource {
        .init(pluginID: pluginID, name: "Discovery fixture", manifest: manifest(complete: complete), isEnabled: true,
              verifiedOfficial: true)
    }

    @Test func installedToolDeclarationsPassTheProductionHostAdmission() throws {
        // Discovery accepts raw declarations; installation must also admit them
        // through the capabilities of the host that actually resolves consumers.
        let operations = RustDeclarativePluginOperations(core: RustCoreBridge())
        _ = try operations.validate(manifest: Self.manifest())
        _ = try operations.validate(manifest: Self.providerSource().manifest)
    }

    @Test func consumerRefusesUnsupportedLaunchTemplatesInsteadOfDroppingTheirFlags() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let home = try root.installation("home/Kits/tool.kit/Contents/Home")
        let probes = DiscoveryProbes(outputs: [home + "/bin/compiler": "compiler 21"])
        var manifest = try #require(JSONSerialization.jsonObject(with: Self.manifest()) as? [String: Any])
        var definitions = try #require(manifest["toolDefinitions"] as? [[String: Any]])
        definitions[0]["launch"] = ["${executable}", "--fixture", "${arguments}"]
        manifest["toolDefinitions"] = definitions
        let source = ToolchainSettingsPluginSource(pluginID: Self.pluginID, name: "Fixture",
            manifest: try JSONSerialization.data(withJSONObject: manifest), isEnabled: true, verifiedOfficial: true)
        let local: ToolingJSONValue = .object(["version": .number(1), "toolchains": .object([:])])
        await #expect(throws: BuildToolResolutionError.self) {
            try await discovery(root: root, probes: probes).resolve(
                .init(workspace: root.url("workspace"), sources: [source], environment: [:]),
                tool: "compiler", directory: ".", minimumVersion: nil, local: local, projectCodeAllowed: true)
        }
        #expect(probes.calls.isEmpty)
    }

    @Test func installationDependenciesConsumeExportsWithoutInstantiatingAnEntryRecipe() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let home = try root.installation("home/Kits/runtime.kit/Contents/Home")
        let probes = DiscoveryProbes(outputs: [home + "/bin/compiler": "compiler 21"])
        var manifest = try #require(JSONSerialization.jsonObject(with: Self.manifest()) as? [String: Any])
        var definitions = try #require(manifest["toolDefinitions"] as? [[String: Any]])
        definitions[0]["launch"] = ["${executable}", "${runtimeArguments}", "-jar", "${entry}", "${arguments}"]
        definitions[0]["exports"] = [["name": "COMPILER_HOME", "value": "${home}"]]
        manifest["toolDefinitions"] = definitions
        let source = ToolchainSettingsPluginSource(pluginID: Self.pluginID, name: "Runtime",
            manifest: try JSONSerialization.data(withJSONObject: manifest), isEnabled: true, verifiedOfficial: true)
        let selected = try await discovery(root: root, probes: probes).resolve(
            .init(workspace: root.url("workspace"), sources: [source], environment: [:]), tool: "compiler",
            directory: ".", minimumVersion: "17", local: .object(["version": .number(1), "toolchains": .object([:])]),
            projectCodeAllowed: false, requiresDirectLaunch: false)
        #expect(selected?.version == "21")
        #expect(selected?.environment["COMPILER_HOME"] == home)
        #expect(probes.calls == [.init(executable: home + "/bin/compiler", arguments: ["--version"])])
    }

    @Test func scannedHomesAreCheckedProbedAndTheHighestVersionIsSelected() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let newer = try root.installation("home/Kits/newer.kit/Contents/Home")
        let older = try root.installation("home/Kits/older.kit/Contents/Home")
        let broken = try root.installation("home/Kits/broken.kit/Contents/Home")
        let shell = try root.installation("shell-home")
        _ = try root.installation("home/Kits/plain/Contents/Home")
        _ = try root.installation("home/Kits/.hidden.kit/Contents/Home")
        try Data().write(to: root.url("home/Kits/notes.kit"))
        let inside = try root.installation("workspace/inside.kit/Contents/Home")
        try FileManager.default.createSymbolicLink(at: root.url("home/Kits/linked.kit"),
                                                   withDestinationURL: root.url("workspace/inside.kit"))
        let probes = DiscoveryProbes(outputs: [
            newer + "/bin/compiler": "compiler 21.0.1", older + "/bin/compiler": "compiler 17.0.2",
            shell + "/bin/compiler": "compiler 23.1"
        ])
        let result = await discovery(root: root, probes: probes).discover(.init(
            workspace: root.url("workspace"), sources: [Self.source()],
            environment: ["FIXTURE_HOME": shell, "UNDECLARED": "/private"]))

        let detection = try #require(result.detections["compiler"])
        #expect(result.unchecked.isEmpty && result.diagnostics.isEmpty)
        #expect(Set(detection.installations.map(\.home)) == [newer, older])
        #expect(detection.installations.allSatisfy { $0.provider == "host:system" })
        #expect(detection.installations.first { $0.home == newer }?.version == "21.0.1")
        #expect(detection.installations.first { $0.home == newer }?.executable == newer + "/bin/compiler")
        // The home layout's suffix is shared by every kit; the scanned entry names the installation.
        #expect(detection.installations.first { $0.home == newer }?.location == root.path + "/home/Kits/newer.kit")
        #expect(detection.selected == newer && !detection.conflict)
        #expect(detection.skipped == [.init(home: broken, reason: "probeFailed")])
        #expect(detection.shell == [.init(variable: "FIXTURE_HOME", home: shell, executable: shell + "/bin/compiler",
                                          version: "23.1")])
        // Only homes Core checked are probed: never the project, an unmatched or hidden entry.
        let probed = probes.calls
        #expect(Set(probed.map(\.executable)) == Set([newer, older, broken, shell].map { $0 + "/bin/compiler" }))
        #expect(probed.allSatisfy { $0.arguments == ["--version"] })
        #expect(!probed.contains { $0.executable.hasPrefix(inside) })
    }

    @Test func equalHighestVersionsInDifferentHomesAreAConflict() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let first = try root.installation("home/Kits/first.kit/Contents/Home")
        let second = try root.installation("home/Kits/second.kit/Contents/Home")
        let probes = DiscoveryProbes(outputs: [first + "/bin/compiler": "compiler 21", second + "/bin/compiler": "compiler 21.0"])
        let result = await discovery(root: root, probes: probes).discover(.init(
            workspace: root.url("workspace"), sources: [Self.source()], environment: [:]))
        let detection = try #require(result.detections["compiler"])
        #expect(detection.installations.count == 2)
        #expect(detection.selected == nil && detection.conflict)
    }

    @Test func refusedDeclarationsAreReportedWithoutScanningOrProbing() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let home = try root.installation("home/Kits/only.kit/Contents/Home")
        let probes = DiscoveryProbes(outputs: [home + "/bin/compiler": "compiler 1"])
        let result = await discovery(root: root, probes: probes).discover(.init(
            workspace: root.url("workspace"), sources: [Self.source(complete: false)], environment: [:]))
        #expect(result.detections.isEmpty && result.unchecked.isEmpty)
        #expect(result.diagnostics == [L10n.string("Installed toolchain declarations could not be checked for discovery.")])
        #expect(probes.calls.isEmpty)
    }

    /// The definition plugin as its own provider, as a version-manager plugin declares one. Its
    /// definition gains the project and global layers, where provider statements decide.
    private static func providerSource(providers: [String] = ["kits"]) throws -> ToolchainSettingsPluginSource {
        var manifest = try #require(try JSONSerialization.jsonObject(with: manifest()) as? [String: Any])
        var definitions = try #require(manifest["toolDefinitions"] as? [[String: Any]])
        let executables = try #require(definitions.first?["executables"] as? [[String: Any]])
        definitions[0]["executables"] = [["id": "project", "kind": "toolchain", "scope": "project"],
                                         ["id": "global", "kind": "toolchain", "scope": "global"]] + executables
        manifest["toolDefinitions"] = definitions
        manifest["requires"] = ["toolDefinitions": 1, "executableResolution": 2, "toolchainProviders": 1,
                                "backend": 2, "serverProcess": 1]
        manifest["permissions"] = ["backend.launch", "toolchains.provide"]
        manifest["toolchainProviders"] = providers.map { id in
            ["id": id, "displayName": id.capitalized, "tools": ["compiler"],
             "watchFiles": [["pattern": ".compiler-version", "reader": "native"]]] as [String: Any]
        }
        manifest["backend"] = ["launch": ["kind": "packaged", "path": "bin/kits"]]
        return .init(pluginID: pluginID, name: "Discovery fixture",
                     manifest: try JSONSerialization.data(withJSONObject: manifest), isEnabled: true, verifiedOfficial: true)
    }

    /// A provider reports an alias link; Core keeps the canonical home, the project
    /// requirement and the global one apart, and the installation joins the candidates.
    @Test func providerAnswersAreValidatedAndJoinTheCandidates() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let installed = try root.installation("manager/installs/compiler/21.0.1")
        try FileManager.default.createSymbolicLink(atPath: root.path + "/manager/installs/compiler/latest",
                                                   withDestinationPath: installed)
        let alias = root.path + "/manager/installs/compiler/latest"
        let versionFile = root.path + "/workspace/.compiler-version"
        try Data("21\n".utf8).write(to: URL(fileURLWithPath: versionFile))
        let globalFile = root.path + "/home/.compiler-version"
        try Data("21\n".utf8).write(to: URL(fileURLWithPath: globalFile))
        let queries = ProviderQueries { params in
            let project = params["workspace"] is [String: Any]
            let statements: [[String: Any]] = [
                ["tool": "compiler", "scope": "global", "source": globalFile, "request": "21", "installation": alias,
                 "kind": "declaration", "reader": "native"]
            ] + (project ? [["tool": "compiler", "scope": "project", "source": versionFile, "request": "21",
                              "installation": alias, "kind": "declaration", "reader": "native"]] : [])
            return ["installations": [["tool": "compiler", "version": "21.0.1", "home": alias]],
                    "statements": statements, "watch": [root.path + "/manager/installs"]]
        }
        let probes = DiscoveryProbes(outputs: [installed + "/bin/compiler": "compiler 21.0.1"])
        var discovery = discovery(root: root, probes: probes)
        discovery.queryProvider = { plugin, provider, params, _ in try queries.answer(pluginID: plugin, providerID: provider, params: params) }
        discovery.workspaceContext = { _, _ in .init(contextID: "context-1", generation: 3, rootID: "root-1") }
        let result = await discovery.discover(.init(
            workspace: root.url("workspace"), sources: [try Self.providerSource()], environment: [:]))

        let provider = Self.pluginID + ":kits"
        #expect(result.diagnostics.isEmpty)
        let detection = try #require(result.detections["compiler"])
        #expect(detection.installations.map(\.home) == [installed])
        #expect(detection.installations.first?.provider == provider)
        #expect(result.requirements["."]?["compiler"] == [.init(request: "21", source: versionFile, providerID: provider,
                                                                 home: installed, version: "21.0.1")])
        #expect(result.globalRequirements["compiler"] == [.init(request: "21", source: globalFile, providerID: provider,
                                                                 home: installed, version: "21.0.1")])
        #expect(result.watch == [root.path + "/manager/installs"])
        guard case .answered? = result.providerStates[provider] else {
            Issue.record("the provider should have answered")
            return
        }
        // Core resolves the same replies: the project requirement decides, not the page.
        #expect(result.unresolved.isEmpty)
        #expect(result.resolutions["."]?["compiler"] == .init(layer: .project, outcome: .resolved(
            home: installed, executable: installed + "/bin/compiler", version: "21.0.1", provider: provider)))
        // A global query, then one round per directory. Every provider in a round shares its
        // generation, and every request has its own operation.
        let sent = queries.sent
        #expect(sent.count == 2)
        #expect(sent.first?["workspace"] is NSNull && sent.first?["context"] is NSNull)
        let workspace = try #require(sent.last?["workspace"] as? [String: Any])
        #expect(workspace["rootID"] as? String == "root-1" && workspace["directory"] as? String == ".")
        #expect(Set(sent.compactMap { $0["operationID"] as? String }).count == 2)
        #expect(Set(sent.compactMap { $0["generation"] as? Int }).count == 2)
    }

    /// A requirement nothing installs is reported and the next layer decides.
    @Test func anUninstalledRequirementIsUnmetAndTheNextLayerDecides() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let installed = try root.installation("manager/installs/compiler/21.0.1")
        let versionFile = root.path + "/workspace/.compiler-version"
        try Data("22\n".utf8).write(to: URL(fileURLWithPath: versionFile))
        let queries = ProviderQueries { params in
            let project = params["workspace"] is [String: Any]
            return ["installations": [["tool": "compiler", "version": "21.0.1", "home": installed]],
                    "statements": project ? [["tool": "compiler", "scope": "project", "source": versionFile,
                                              "request": "22", "installation": NSNull(), "kind": "declaration",
                                              "reader": "native"]] : [],
                    "watch": []]
        }
        let probes = DiscoveryProbes(outputs: [installed + "/bin/compiler": "compiler 21.0.1"])
        var discovery = discovery(root: root, probes: probes)
        discovery.queryProvider = { plugin, provider, params, _ in try queries.answer(pluginID: plugin, providerID: provider, params: params) }
        discovery.workspaceContext = { _, _ in .init(contextID: "context-1", generation: 3, rootID: "root-1") }
        let result = await discovery.discover(.init(
            workspace: root.url("workspace"), sources: [try Self.providerSource()], environment: [:]))

        let provider = Self.pluginID + ":kits"
        #expect(result.requirements["."]?["compiler"] == [.init(request: "22", source: versionFile, providerID: provider)])
        #expect(result.resolutions["."]?["compiler"] == .init(layer: .automatic, outcome: .resolved(
            home: installed, executable: installed + "/bin/compiler", version: "21.0.1", provider: provider),
            unmet: ["22"]))
    }

    /// The window's context changed during one load: the round keeps the context it opened
    /// with, and a reply under the newer one is neither resolved nor shown for that directory.
    @Test func aReplyUnderAChangedContextIsLeftOutOfItsDirectory() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let installed = try root.installation("manager/installs/compiler/21.0.1")
        let versionFile = root.path + "/workspace/.compiler-version"
        try Data("21\n".utf8).write(to: URL(fileURLWithPath: versionFile))
        let queries = ProviderQueries { params in
            let project = params["workspace"] is [String: Any]
            return ["installations": [["tool": "compiler", "version": "21.0.1", "home": installed]],
                    "statements": project ? [["tool": "compiler", "scope": "project", "source": versionFile,
                                              "request": "21", "installation": installed, "kind": "declaration",
                                              "reader": "native"]] : [],
                    "watch": []]
        }
        let contexts = ContextGenerations(first: 3)
        let probes = DiscoveryProbes(outputs: [installed + "/bin/compiler": "compiler 21.0.1"])
        var discovery = discovery(root: root, probes: probes)
        discovery.queryProvider = { plugin, provider, params, _ in try queries.answer(pluginID: plugin, providerID: provider, params: params) }
        discovery.workspaceContext = { _, _ in .init(contextID: "context-1", generation: contexts.next(), rootID: "root-1") }
        let result = await discovery.discover(.init(
            workspace: root.url("workspace"), sources: [try Self.providerSource(providers: ["kits", "other"])],
            environment: [:]))

        // Providers are asked in name order, so `kits` opened the round and `other` came under generation 4.
        let kits = Self.pluginID + ":kits"
        #expect(queries.sent.contains { ($0["context"] as? [String: Any])?["generation"] as? Int == 4 })
        #expect(result.requirements["."]?["compiler"] == [.init(request: "21", source: versionFile, providerID: kits,
                                                                 home: installed, version: "21.0.1")])
        #expect(result.resolutions["."]?["compiler"] == .init(layer: .project, outcome: .resolved(
            home: installed, executable: installed + "/bin/compiler", version: "21.0.1", provider: kits)))
    }

    /// A saved pin decides alone in its directory, even one no provider was asked about. Its home
    /// is checked and probed like a scanned one, yet never listed as an installation.
    @Test func pinsDecideTheirDirectoryAndAnUnusableOneFails() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let pinned = try root.installation("pinned/compiler-17")
        try FileManager.default.createDirectory(at: root.url("workspace/apps"), withIntermediateDirectories: true)
        let missing = root.path + "/pinned/removed"
        let local: [String: Any] = ["version": 1, "toolchains": [:], "pins": [
            ".": ["compiler": ["home": pinned, "version": "17.0.2", "provider": "host:manual"]],
            "apps": ["compiler": ["home": missing, "version": "18", "provider": "host:manual"]]
        ]]
        let probes = DiscoveryProbes(outputs: [pinned + "/bin/compiler": "compiler 17.0.2"])
        let result = await discovery(root: root, probes: probes).discover(.init(
            workspace: root.url("workspace"), sources: [Self.source()], environment: [:],
            local: try JSONSerialization.data(withJSONObject: local)))

        #expect(result.unresolved.isEmpty)
        #expect(result.detections["compiler"]?.installations.isEmpty == true)
        #expect(probes.calls.map(\.executable) == [pinned + "/bin/compiler"])
        #expect(result.resolutions["."]?["compiler"] == .init(layer: .pinned, outcome: .resolved(
            home: pinned, executable: pinned + "/bin/compiler", version: "17.0.2", provider: "host:manual")))
        let failed = try #require(result.resolutions["apps"]?["compiler"])
        #expect(failed.layer == .pinned)
        guard case .failed = failed.outcome else {
            Issue.record("an unusable pin must fail instead of falling through: \(failed.outcome)")
            return
        }
    }

    /// A refused reply names the failure and contributes nothing, not even its valid parts.
    @Test func aRejectedReplyAddsNoInstallationAndIsReported() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let inside = try root.installation("workspace/vendor/compiler")
        let queries = ProviderQueries { _ in
            ["installations": [["tool": "compiler", "version": "1", "home": inside]], "statements": [], "watch": []]
        }
        var discovery = discovery(root: root, probes: DiscoveryProbes(outputs: [:]))
        discovery.queryProvider = { plugin, provider, params, _ in try queries.answer(pluginID: plugin, providerID: provider, params: params) }
        let result = await discovery.discover(.init(
            workspace: root.url("workspace"), sources: [try Self.providerSource()], environment: [:]))
        #expect(result.detections["compiler"]?.installations.isEmpty == true)
        guard case .failed? = result.providerStates[Self.pluginID + ":kits"] else {
            Issue.record("a workspace home must be refused")
            return
        }
        // Without an open context only the global query is sent.
        #expect(queries.sent.count == 1)
        // The refusal is the reported reason; a missing context does not hide it.
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.contains("kits") == true)
    }

    @Test func globsMatchOneComponentLikeCore() {
        #expect(MacToolchainDiscovery.matches("*.kit", "a.kit"))
        #expect(MacToolchainDiscovery.matches("*", "anything"))
        #expect(MacToolchainDiscovery.matches("a*b*c", "aXXbYYc"))
        #expect(MacToolchainDiscovery.matches("kit", "kit"))
        #expect(!MacToolchainDiscovery.matches("*.kit", "a.kit.bak"))
        #expect(!MacToolchainDiscovery.matches("a*b*c", "aXXc"))
        #expect(!MacToolchainDiscovery.matches("kit", "kits"))
    }

    #if DEBUG
    /// The settings preview scans this Mac for real, so its sample manifests must pass Core's admission.
    @MainActor @Test func previewSamplesAreAdmittedByCore() throws {
        let plugins: [[String: Any]] = try ToolchainSettingsDemo.samplePlugins.map { source in
            ["manifest": try JSONSerialization.jsonObject(with: source.manifest), "verifiedOfficial": source.verifiedOfficial]
        }
        let plan = MacToolchainDiscovery.callCore("toolchains.discoveryPlan",
                                                  ["registry": ["plugins": plugins], "platform": "macos"])?["plan"]
        let tools = try #require((plan as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["tool"] as? String }.sorted() == ["java", "maven", "node", "python"])
        #expect(tools.allSatisfy { !($0["scans"] as? [Any] ?? []).isEmpty })
    }
    #endif

    @Test func consumerResolvesAnUnscannedFixedHomeBeforeNewerInstallations() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let manual = try root.installation("manual")
        let automatic = try root.installation("home/Kits/newer.kit/Contents/Home")
        let probes = DiscoveryProbes(outputs: [manual + "/bin/compiler": "compiler 17", automatic + "/bin/compiler": "compiler 23"])
        let local = try #require(ToolingJSONValue.fromFoundation([
            "version": 1, "toolchains": [:], "pins": [".": ["compiler": ["home": manual, "version": "17", "provider": "host:manual"]]]
        ]))
        let selected = try await discovery(root: root, probes: probes).resolve(
            .init(workspace: root.url("workspace"), sources: [Self.source()], environment: ["PATH": "/fixture/path"]),
            tool: "compiler", directory: ".", minimumVersion: "11", local: local, projectCodeAllowed: true)
        #expect(selected?.executable.path == manual + "/bin/compiler")
        #expect(selected?.version == "17" && selected?.projectCode == false)
        #expect(selected?.environment["PATH"] == manual + "/bin:/fixture/path")
    }

    @Test func consumerChoicesKeepTwoRunsIndependentFromTheDirectoryPin() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let pinned = try root.installation("pinned")
        let selected = try root.installation("per run")
        let probes = DiscoveryProbes(outputs: [pinned + "/bin/compiler": "compiler 21", selected + "/bin/compiler": "compiler 17"])
        let local = try #require(ToolingJSONValue.fromFoundation([
            "version": 1, "toolchains": [:], "pins": [".": ["compiler": ["home": pinned, "version": "21", "provider": "host:manual"]]]
        ]))
        let request = MacToolchainDiscovery.Request(workspace: root.url("workspace"), sources: [Self.source()], environment: [:])
        let resolver = discovery(root: root, probes: probes)
        let first = try await resolver.resolve(request, tool: "compiler", directory: ".", minimumVersion: "11", local: local,
            projectCodeAllowed: true, fixed: .installation(home: selected))
        let second = try await resolver.resolve(request, tool: "compiler", directory: ".", minimumVersion: "11", local: local,
            projectCodeAllowed: true)
        #expect(first?.executable.path == selected + "/bin/compiler")
        #expect(second?.executable.path == pinned + "/bin/compiler")
        #expect(probes.calls.map(\.executable) == [selected + "/bin/compiler", pinned + "/bin/compiler"])
        await #expect(throws: BuildToolResolutionError.self) {
            try await resolver.resolve(request, tool: "compiler", directory: ".", minimumVersion: nil, local: local,
                projectCodeAllowed: true, fixed: .installation(home: root.path + "/missing"))
        }
        #expect(probes.calls.count == 2)
    }

    @Test func consumerWorkspaceLauncherIsOnlyProbedForTheCurrentExplicitAction() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let executable = root.url("workspace/custom runner")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let probes = DiscoveryProbes(outputs: [executable.path: "compiler 21"])
        let resolver = discovery(root: root, probes: probes)
        let request = MacToolchainDiscovery.Request(workspace: root.url("workspace"), sources: [Self.source()], environment: [:])
        let local: ToolingJSONValue = .object(["version": .number(1), "toolchains": .object([:])])
        await #expect(throws: BuildToolResolutionError.self) {
            try await resolver.resolve(request, tool: "compiler", directory: ".", minimumVersion: "17", local: local,
                projectCodeAllowed: false, fixed: .executable(path: executable.path))
        }
        #expect(probes.calls.isEmpty)
        let selected = try await resolver.resolve(request, tool: "compiler", directory: ".", minimumVersion: "17", local: local,
            projectCodeAllowed: true, fixed: .executable(path: executable.path))
        #expect(selected?.executable == executable && selected?.projectCode == true)
        #expect(selected?.environment.isEmpty == true)
        #expect(probes.calls == [.init(executable: executable.path, arguments: ["--version"])])
    }

    @Test func consumerNeverFallsBackFromAnInvalidFixedHome() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let automatic = try root.installation("home/Kits/newer.kit/Contents/Home")
        let probes = DiscoveryProbes(outputs: [automatic + "/bin/compiler": "compiler 23"])
        let local = try #require(ToolingJSONValue.fromFoundation([
            "version": 1, "toolchains": [:], "pins": [".": ["compiler": ["home": root.path + "/missing", "version": "17", "provider": "host:manual"]]]
        ]))
        await #expect(throws: BuildToolResolutionError.self) {
            try await discovery(root: root, probes: probes).resolve(
                .init(workspace: root.url("workspace"), sources: [Self.source()], environment: [:]),
                tool: "compiler", directory: ".", minimumVersion: nil, local: local, projectCodeAllowed: true)
        }
    }

    @Test func consumerWrapperRequiresAnExplicitActionAndIsNeverPassivelyProbed() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let wrapper = root.url("workspace/compilerw")
        try Data("#!/bin/sh\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        var manifest = try #require(JSONSerialization.jsonObject(with: Self.manifest()) as? [String: Any])
        var definitions = try #require(manifest["toolDefinitions"] as? [[String: Any]])
        var candidates = try #require(definitions[0]["executables"] as? [[String: Any]])
        candidates.insert(["id": "wrapper", "kind": "projectFile", "path": "compilerw"], at: 0)
        definitions[0]["executables"] = candidates
        definitions[0]["wrappers"] = [["path": "compilerw"]]
        manifest["toolDefinitions"] = definitions
        let source = ToolchainSettingsPluginSource(pluginID: Self.pluginID, name: "Fixture",
            manifest: try JSONSerialization.data(withJSONObject: manifest), isEnabled: true, verifiedOfficial: true)
        let probes = DiscoveryProbes(outputs: [wrapper.path: "compiler 21"])
        let discovery = discovery(root: root, probes: probes)
        let request = MacToolchainDiscovery.Request(workspace: root.url("workspace"), sources: [source], environment: [:])
        let local: ToolingJSONValue = .object(["version": .number(1), "toolchains": .object([:])])
        await #expect(throws: BuildToolResolutionError.self) {
            try await discovery.resolve(request, tool: "compiler", directory: ".", minimumVersion: nil,
                                        local: local, projectCodeAllowed: false)
        }
        let selected = try await discovery.resolve(request, tool: "compiler", directory: ".", minimumVersion: nil,
                                                   local: local, projectCodeAllowed: true)
        #expect(selected?.executable == wrapper && selected?.projectCode == true)
        #expect(probes.calls.isEmpty)
        await #expect(throws: BuildToolResolutionError.self) {
            try await discovery.resolve(request, tool: "compiler", directory: ".", minimumVersion: "17",
                                        local: local, projectCodeAllowed: false)
        }
        #expect(probes.calls.isEmpty)
        let checked = try await discovery.resolve(request, tool: "compiler", directory: ".", minimumVersion: "17",
                                                  local: local, projectCodeAllowed: true)
        #expect(checked?.executable == wrapper && checked?.version == "21" && checked?.projectCode == true)
        #expect(probes.calls == [.init(executable: wrapper.path, arguments: ["--version"])])
        await #expect(throws: BuildToolResolutionError.self) {
            try await discovery.resolve(request, tool: "compiler", directory: ".", minimumVersion: "23",
                                        local: local, projectCodeAllowed: true)
        }
    }

    @Test(arguments: [false, true]) func consumerQueriesCurrentWorkspaceProviderWithMatchingResolutionIdentity(stringIDs: Bool) async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let home = try root.installation("manager/current")
        let source = root.url("workspace/.compiler-version")
        try Data("21\n".utf8).write(to: source)
        let queries = ProviderQueries { _ in [
            "installations": [["tool": "compiler", "version": "21", "home": home]],
            "statements": [["tool": "compiler", "scope": "project", "source": source.path, "request": "21",
                             "installation": home, "kind": "declaration", "reader": "native"]],
            "watch": [source.path]
        ] }
        var discovery = discovery(root: root, probes: DiscoveryProbes(outputs: [home + "/bin/compiler": "compiler 21"]))
        discovery.queryProvider = { plugin, provider, params, _ in
            let answer = try queries.answer(pluginID: plugin, providerID: provider, params: params)
            if !stringIDs { return answer }
            var wire = try #require(answer.foundationObject as? [String: Any])
            var response = try #require(wire["response"] as? [String: Any])
            wire["id"] = "rpc:雪-2"; response["id"] = "rpc:雪-2"; wire["response"] = response
            return try #require(ToolingJSONValue.fromFoundation(wire))
        }
        discovery.workspaceContext = { _, _ in .init(contextID: "context-1", generation: 3, rootID: "root-1") }
        let result = try await discovery.resolve(
            .init(workspace: root.url("workspace"), sources: [try Self.providerSource()], environment: [:]),
            tool: "compiler", directory: ".", minimumVersion: nil,
            local: .object(["version": .number(1), "toolchains": .object([:])]), projectCodeAllowed: true)
        #expect(result?.executable.path == home + "/bin/compiler")
        #expect(queries.sent.count == 1)
        let workspace = try #require(queries.sent.first?["workspace"] as? [String: Any])
        #expect(workspace["directory"] as? String == "." && workspace["rootID"] as? String == "root-1")
    }

    @Test func consumerRetainsShellFallbackForACheckedUnavailableProvider() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let home = try root.installation("shell-home")
        var discovery = discovery(root: root, probes: DiscoveryProbes(outputs: [home + "/bin/compiler": "compiler 21"]))
        discovery.queryProvider = { _, _, params, _ in
            let object = try #require(params.foundationObject as? [String: Any])
            return try #require(ToolingJSONValue.fromFoundation(["id": 1, "response": ["jsonrpc": "2.0", "id": 1,
                "error": ["code": -32073, "message": "Fixture unavailable", "data": [
                    "code": "plugin.toolchain.providerUnavailable", "operationID": object["operationID"]!, "providerID": object["providerID"]!
                ]]]]))
        }
        discovery.workspaceContext = { _, _ in .init(contextID: "context-1", generation: 3, rootID: "root-1") }
        let selected = try await discovery.resolve(
            .init(workspace: root.url("workspace"), sources: [try Self.providerSource()], environment: ["FIXTURE_HOME": home]),
            tool: "compiler", directory: ".", minimumVersion: nil,
            local: .object(["version": .number(1), "toolchains": .object([:])]), projectCodeAllowed: true)
        #expect(selected?.executable.path == home + "/bin/compiler")
    }

    @Test func consumerRejectsNativeEvidenceChangedDuringProbe() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let home = try root.installation("home/Kits/newer.kit/Contents/Home")
        var discovery = discovery(root: root, probes: DiscoveryProbes(outputs: [:]))
        discovery.consumerProbe = { executable, _, _ in
            try? FileManager.default.removeItem(atPath: executable)
            return "compiler 23"
        }
        await #expect(throws: CancellationError.self) {
            try await discovery.resolve(.init(workspace: root.url("workspace"), sources: [Self.source()], environment: [:]),
                tool: "compiler", directory: ".", minimumVersion: nil,
                local: .object(["version": .number(1), "toolchains": .object([:])]), projectCodeAllowed: true)
        }
        #expect(!FileManager.default.fileExists(atPath: home + "/bin/compiler"))
    }

    /// A provider past its deadline and one whose backend could not answer both reach Core as
    /// unavailable: the scanned installation still decides, and each keeps its own reason.
    @Test func providersWithoutAnAnswerAreNamedWithTheirReasonWhileLowerSourcesDecide() async throws {
        struct BackendDown: LocalizedError {
            var errorDescription: String? { "fixture backend stopped" }
        }
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let scanned = try root.installation("home/Kits/scanned.kit/Contents/Home")
        try Data("21\n".utf8).write(to: root.url("workspace/.compiler-version"))
        let probes = DiscoveryProbes(outputs: [scanned + "/bin/compiler": "compiler 21.0.1"])
        var discovery = discovery(root: root, probes: probes)
        discovery.queryProvider = { _, provider, _, _ in
            if provider == "kits" { throw MacToolchainDiscovery.QueryTimeout() }
            throw BackendDown()
        }
        discovery.workspaceContext = { _, _ in .init(contextID: "context-1", generation: 3, rootID: "root-1") }
        let result = await discovery.discover(.init(
            workspace: root.url("workspace"), sources: [try Self.providerSource(providers: ["kits", "other"])],
            environment: [:]))

        let kits = Self.pluginID + ":kits"
        let other = Self.pluginID + ":other"
        #expect(result.requirements["."] == nil)
        #expect(result.resolutions["."]?["compiler"] == .init(layer: .automatic, outcome: .resolved(
            home: scanned, executable: scanned + "/bin/compiler", version: "21.0.1", provider: "host:system"),
            unavailable: [.init(provider: kits, timedOut: true), .init(provider: other, timedOut: false)]))
        #expect(result.providerStates[kits] == .failed(L10n.string("No answer within \(Int(MacToolchainDiscovery.queryTimeout)) s")))
        #expect(result.providerStates[other] == .failed("fixture backend stopped"))
        #expect(result.diagnostics.count == 2)
    }

    private func discovery(root: DiscoveryFixtureRoot, probes: DiscoveryProbes) -> MacToolchainDiscovery {
        var discovery = MacToolchainDiscovery()
        let home = root.url("home").path
        discovery.homeDirectory = { home }
        discovery.probe = { probes.run($0, $1) }
        discovery.consumerProbe = { executable, arguments, _ in probes.run(executable, arguments) }
        return discovery
    }
}

/// A canonical temporary directory with a home and a workspace, removed by the test.
private struct DiscoveryFixtureRoot {
    let path: String

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-toolchain-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let resolved = Darwin.realpath(base.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        path = String(cString: resolved)
        try FileManager.default.createDirectory(at: url("home"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url("workspace"), withIntermediateDirectories: true)
    }

    func url(_ relative: String) -> URL { URL(fileURLWithPath: path + "/" + relative) }

    /// A home with an executable `bin/compiler`; returns the home path.
    func installation(_ relative: String) throws -> String {
        let executable = url(relative + "/bin/compiler")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return path + "/" + relative
    }

    func remove() { try? FileManager.default.removeItem(atPath: path) }
}

/// Canned probe outputs keyed by executable; a missing entry is a failed probe.
private final class DiscoveryProbes: @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private let outputs: [String: String]
    private var recorded: [Call] = []

    init(outputs: [String: String]) { self.outputs = outputs }

    var calls: [Call] { lock.withLock { recorded } }

    func run(_ executable: String, _ arguments: [String]) -> String? {
        lock.withLock {
            recorded.append(.init(executable: executable, arguments: arguments))
            return outputs[executable]
        }
    }
}

/// A window context whose generation advances on every lookup, as one changing mid-load would.
private final class ContextGenerations: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(first: Int) { value = first }

    func next() -> Int {
        lock.withLock { () -> Int in
            defer { value += 1 }
            return value
        }
    }
}

/// Answers queries like a backend would; each result echoes the request's identity.
private final class ProviderQueries: @unchecked Sendable {
    private let lock = NSLock()
    private let result: @Sendable ([String: Any]) -> [String: Any]
    private var recorded: [[String: Any]] = []
    private var nextID = 0

    init(result: @escaping @Sendable ([String: Any]) -> [String: Any]) { self.result = result }

    var sent: [[String: Any]] { lock.withLock { recorded } }

    func answer(pluginID _: String, providerID _: String, params: ToolingJSONValue) throws -> ToolingJSONValue {
        let params = params.foundationObject as? [String: Any] ?? [:]
        let id = lock.withLock { () -> Int in
            recorded.append(params)
            nextID += 1
            return nextID
        }
        var body = result(params)
        for key in ["operationID", "generation", "providerID"] { body[key] = params[key] }
        let reply: [String: Any] = ["id": id, "response": ["jsonrpc": "2.0", "id": id, "result": body]]
        return try #require(ToolingJSONValue.fromFoundation(reply))
    }
}
