import Foundation
import LitheCoreContracts
import LitheDebugModule
import LitheExecutionModule
import LitheLanguageIntelligenceModule
import Testing
@testable import Lithe

@Suite("Run configuration integration")
@MainActor
struct RunConfigurationIntegrationTests {
    @Test
    func argumentEditorTextPreservesExactArgvThroughNativeStorageAndCore() throws {
        struct Fixture: Decodable { struct Entry: Decodable { let values: [String]; let text: String }; let cases: [Entry] }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/fixtures/run-configuration/argument-text.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("run-argument-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacRunConfigurationStore(core: RustCoreBridge(), storage: MacFileStorage(), preferences: RunTestKeyValueStore())
        let reference = BuildProviderRunReference(pluginID: "dev.example.engine", buildSystemID: "engine", root: ".", run: "task",
            projectID: "project", targetID: "target", execution: .task)
        let id = try store.saveBuildProviderConfiguration(reference, name: "Arguments", at: root)
        for entry in fixture.cases {
            try store.saveOptions(RunOptions(programArguments: entry.text), configurationID: id, scope: .local, at: root)
            let resolved = try #require(store.resolve(at: root, toolchainCandidates: []).configurations.first { $0.configuration.id == id })
            #expect(resolved.options.programArguments == entry.text)
            #expect(try store.providerLaunchInputs(at: root, configurationID: id, providerRoot: ".").launchOptions.arguments == entry.values)
        }
    }

    @Test
    func providerRuntimeArgumentRowsAndEntrypointSurviveEditingAndResetThroughNativeStorage() throws {
        struct Fixture: Decodable { struct Entry: Decodable { let values: [String] }; let cases: [Entry] }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/fixtures/run-configuration/argument-text.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacRunConfigurationStore(core: RustCoreBridge(), storage: MacFileStorage(), preferences: RunTestKeyValueStore())
        let reference = BuildProviderRunReference(pluginID: "dev.example.engine", buildSystemID: "engine", root: ".", run: "task",
            projectID: "project", targetID: "target", execution: .task)
        let id = try store.saveBuildProviderConfiguration(reference, name: "Runtime choices", at: root)
        let tools: [String: FixedToolchainSelection?] = ["dev.example.engine:compiler": .executable(path: "/fixture/compiler")]
        var options = RunOptions(providerRunOptions: BuildProviderRunOptions(entrypoint: "opaque/entry 雪", options: ["offline": .bool(false)], tools: tools))
        for entry in fixture.cases {
            options.providerRunOptions?.runtimeArguments = entry.values
            try store.saveOptions(options, configurationID: id, scope: .local, at: root)
            let read = try store.providerLaunchInputs(at: root, configurationID: id, providerRoot: ".")
            #expect(read.launchOptions.runtimeArguments == entry.values)
            #expect(read.launchOptions.entrypoint == "opaque/entry 雪")
            #expect(read.optionOverrides == ["offline": .bool(false)])
            #expect(read.tools == ["dev.example.engine:compiler": .executable(path: "/fixture/compiler")])
        }
        try store.saveOptions(options.resettingProviderRunOptions(), configurationID: id, scope: .local, at: root)
        let cleared = try store.providerLaunchInputs(at: root, configurationID: id, providerRoot: ".")
        #expect(cleared.launchOptions.runtimeArguments.isEmpty)
        #expect(cleared.launchOptions.entrypoint == nil)
        #expect(cleared.tools.isEmpty)
        #expect(cleared.optionOverrides.isEmpty)
    }

    @Test
    func providerResetClearsTeamToolsFromTheResolvedEditorDraftWithoutChangingTheTeamDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacRunConfigurationStore(core: RustCoreBridge(), storage: MacFileStorage(), preferences: RunTestKeyValueStore())
        let reference = BuildProviderRunReference(pluginID: "dev.example.engine", buildSystemID: "engine", root: ".", run: "task",
            projectID: "project", targetID: "target", execution: .task)
        let id = try store.saveBuildProviderConfiguration(reference, name: "Team task", at: root)
        let localURL = root.appendingPathComponent(".lithe/run/local.json")
        let teamURL = root.appendingPathComponent(".lithe/run/configurations.json")
        try FileManager.default.moveItem(at: localURL, to: teamURL)
        let teamTools: [String: FixedToolchainSelection?] = ["dev.example.engine:compiler": .executable(path: "/fixture/team compiler"),
            "dev.example.engine:vm": .installation(home: "/fixture/team vm")]
        try store.saveOptions(RunOptions(providerRunOptions: BuildProviderRunOptions(tools: teamTools)), configurationID: id, scope: .project, at: root)
        let teamBytes = try Data(contentsOf: teamURL)
        try store.saveOptions(RunOptions(providerRunOptions: BuildProviderRunOptions(runtimeArguments: ["local argument"],
            tools: ["dev.example.engine:compiler": .executable(path: "/fixture/local compiler")])), configurationID: id, scope: .local, at: root)
        let editor = try #require(store.resolve(at: root, toolchainCandidates: []).configurations.first { $0.configuration.id == id }).options
        #expect(editor.providerRunOptions?.tools["dev.example.engine:vm"] == teamTools["dev.example.engine:vm"])
        try store.saveOptions(editor.resettingProviderRunOptions(), configurationID: id, scope: .local, at: root)
        let reset = try store.providerLaunchInputs(at: root, configurationID: id, providerRoot: ".")
        #expect(reset.tools.isEmpty)
        #expect(reset.launchOptions.runtimeArguments.isEmpty)
        #expect(try Data(contentsOf: teamURL) == teamBytes)
        let reopened = try #require(store.resolve(at: root, toolchainCandidates: []).configurations.first { $0.configuration.id == id }).options
        #expect(reopened.providerRunOptions?.tools.count == teamTools.count)
        #expect(reopened.providerRunOptions?.tools.values.allSatisfy { $0 == nil } == true)
    }

    @Test(arguments: [BuildExecution.application, .service, .task])
    func savedBuildProviderReferenceWorksWithoutGeneratedConfiguration(execution: BuildExecution) throws {
        let core = RustCoreBridge()
        try #require(core.isAvailable)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-config-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("app"), withIntermediateDirectories: true)
        let store = MacRunConfigurationStore(core: core, storage: MacFileStorage(), preferences: RunTestKeyValueStore())
        let reference = BuildProviderRunReference(pluginID: "dev.example.gradle", buildSystemID: "gradle", root: "app",
            run: "application", projectID: "p", targetID: "t", userArguments: ["a b", "--x=one two"], execution: execution == .application ? nil : execution)
        let id = try store.saveBuildProviderConfiguration(reference, name: "Main", at: root)
        #expect(store.inspect(at: root).status == .ready)
        #expect(store.inspect(at: root).requiresGeneration)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".lithe/run/generated.json").path))
        let resolved = try store.resolve(at: root, toolchainCandidates: [])
        #expect(resolved.configurations.first?.configuration.buildProvider == reference)
        #expect(resolved.configurations.first?.configuration.execution.rawValue == execution.rawValue)
        let inputs = try store.providerLaunchInputs(at: root, configurationID: id, providerRoot: "app")
        #expect(inputs.reference == reference)
        #expect(inputs.launchOptions.execution == execution)
        #expect(inputs.launchOptions.arguments == reference.userArguments)
        #expect(resolved.configurations.first?.configuration.id == id)
        #expect(try store.saveBuildProviderConfiguration(reference, name: "Renamed", at: root) == id)
        #expect(try store.resolve(at: root, toolchainCandidates: []).configurations.count == 1)
        let data = try Data(contentsOf: root.appendingPathComponent(".lithe/run/local.json"))
        let document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try #require((document["configurations"] as? [[String: Any]])?.first)
        #expect(entry["command"] == nil)
        #expect(entry["args"] == nil)
        let ignore = try String(contentsOf: root.appendingPathComponent(".lithe/.gitignore"), encoding: .utf8)
        #expect(ignore.contains("run/local.json"))
        _ = try store.generate(at: root, providerRuns: nil)
        #expect(!store.inspect(at: root).requiresGeneration)
    }

    @Test
    func portableProviderChoicesRoundTripThroughNativeStorageWithoutLosingArgumentBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-choices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("app/work"), withIntermediateDirectories: true)
        let fixtureData = try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/fixtures/run-configuration/build-provider-options.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
        func decode<T: Decodable>(_ key: String, as _: T.Type) throws -> T {
            try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: try #require(fixture[key])))
        }
        let reference = try decode("reference", as: BuildProviderRunReference.self)
        let choices = try decode("choices", as: BuildProviderRunOptions.self)
        let store = MacRunConfigurationStore(core: RustCoreBridge(), storage: MacFileStorage(), preferences: RunTestKeyValueStore())
        let id = try store.saveBuildProviderConfiguration(reference, name: "Service", at: root)
        var options = RunOptions(workingDirectoryPath: "app/work", programArguments: "--application=\"one two\" 雪",
            environment: ["EXAMPLE": "value"], providerRunOptions: choices)
        try store.saveOptions(options, configurationID: id, scope: .local, at: root)
        let resolved = try store.resolve(at: root, toolchainCandidates: [])
        #expect(resolved.configurations.first?.options.providerRunOptions == choices)
        let inputs = try store.providerLaunchInputs(at: root, configurationID: id, providerRoot: "app")
        #expect(inputs.reference == reference)
        #expect(inputs.launchOptions.runtimeArguments == choices.runtimeArguments)
        #expect(inputs.launchOptions.entrypoint == choices.entrypoint)
        #expect(inputs.optionOverrides == choices.options)
        #expect(inputs.tools == choices.tools.compactMapValues { $0 })
        #expect(inputs.launchOptions.arguments == ["--application=one two", "雪"])
        #expect(inputs.launchOptions.environment == options.environment)
        #expect(inputs.launchOptions.workingDirectory == "app/work")
        #expect(inputs.opaqueReferenceArguments == nil)
        // Native preference copies also keep the exact arrays and option values.
        let encoded = try JSONEncoder().encode(options)
        #expect(try JSONDecoder().decode(RunOptions.self, from: encoded) == options)
        #expect(try store.saveBuildProviderConfiguration(reference, name: "Renamed", at: root) == id)
        #expect(try store.providerLaunchInputs(at: root, configurationID: id, providerRoot: "app") == inputs)
        options.providerRunOptions = BuildProviderRunOptions(tools: Dictionary(uniqueKeysWithValues:
            choices.tools.keys.map { ($0, Optional<FixedToolchainSelection>.none) }))
        try store.saveOptions(options, configurationID: id, scope: .local, at: root)
        let reset = try store.providerLaunchInputs(at: root, configurationID: id, providerRoot: "app")
        #expect(reset.launchOptions.runtimeArguments.isEmpty)
        #expect(reset.launchOptions.entrypoint == nil)
        #expect(reset.optionOverrides.isEmpty)
        #expect(reset.tools.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".lithe/run/generated.json").path))
    }

    @Test
    func projectDefaultsPersistOnlyAfterTheWorkspaceDocumentsWereRead() {
        // Settings persists the project toolchain when it closes. Loading, failed or
        // foreign states hold no toolchain for this workspace and must not be saved over it.
        let workspace = URL(fileURLWithPath: "/fixture/project")
        let other = URL(fileURLWithPath: "/fixture/other")
        #expect(ProjectLoadState.bound(workspace: workspace).hasLoadedDocuments(for: workspace))
        #expect(ProjectLoadState.ready(workspace: workspace, snapshotID: UUID()).hasLoadedDocuments(for: workspace))
        #expect(!ProjectLoadState.idle.hasLoadedDocuments(for: workspace))
        #expect(!ProjectLoadState.loading(workspace: workspace).hasLoadedDocuments(for: workspace))
        #expect(!ProjectLoadState.failed(workspace: workspace, message: "fixture").hasLoadedDocuments(for: workspace))
        #expect(!ProjectLoadState.bound(workspace: other).hasLoadedDocuments(for: workspace))
    }

    @Test
    func localRunIgnoreRulesRespectOrderOfUserNegations() {
        let all = ["/run/local.json", "/run/classes/", "**/*.tmp"]
        #expect(MacRunConfigurationStore.missingLocalRunIgnoreRules(in: "") == all)
        #expect(MacRunConfigurationStore.missingLocalRunIgnoreRules(
            in: "run/local.json\r\n/run/classes/\n  **/*.tmp  \n"
        ).isEmpty)
        // A later negation re-exposes the local document, so the rule is appended after it.
        #expect(MacRunConfigurationStore.missingLocalRunIgnoreRules(
            in: "run/local.json\nrun/classes/\n**/*.tmp\n!run/local.json\n"
        ) == ["/run/local.json"])
        #expect(MacRunConfigurationStore.missingLocalRunIgnoreRules(
            in: "!/run/local.json\n/run/local.json\nrun/classes/\n**/*.tmp\n"
        ).isEmpty)
    }

    @Test
    func sourceBreakpointPlacementRetainsBraceAndAnnotatedDeclarationLines() {
        let source = """
        class Example {
            @Test void test() {
                int value = 1;
            }
        }
        """
        for line in 1...5 {
            #expect(DebugBreakpointLocationValidator.canSetSourceBreakpoint(source: source, line: line))
        }
        #expect(!DebugBreakpointLocationValidator.canSetSourceBreakpoint(source: source, line: 0))
        #expect(!DebugBreakpointLocationValidator.canSetSourceBreakpoint(source: source, line: 6))
    }

    @Test
    func sourceBreakpointPlacementDoesNotPretendToVerifyExecutableCode() {
        let source = "// comment\n\n@Test\n{\n}"
        for line in 1...5 {
            #expect(DebugBreakpointLocationValidator.canSetSourceBreakpoint(source: source, line: line))
        }
        #expect(!DebugBreakpointLocationValidator.canSetSourceBreakpoint(source: "", line: -1))
        #expect(!DebugBreakpointLocationValidator.canSetSourceBreakpoint(source: "", line: 2))
    }

    @Test
    func currentFileRunProvidersBuildPlansWithoutJavaAssumptions() throws {
        let registry = LanguageRunProviderRegistry.standard()
        let root = URL(fileURLWithPath: "/tmp/current-file-runners", isDirectory: true)
        let python = root.appendingPathComponent("scripts/server.py")
        let node = root.appendingPathComponent("web/index.js")
        let go = root.appendingPathComponent("cmd/api/main.go")

        let pythonPlan = try registry.launchPlan(
            for: python,
            workspaceURL: root,
            options: RunOptions(programArguments: "--port 8080 \"hello world\"")
        )
        #expect(pythonPlan.toolchainID == "project-python")
        #expect(pythonPlan.arguments == ["scripts/server.py", "--port", "8080", "hello world"])

        let nodePlan = try registry.launchPlan(for: node, workspaceURL: root)
        #expect(nodePlan.toolchainID == "project-node")
        #expect(nodePlan.arguments == ["web/index.js"])

        let typeScriptPlan = try registry.launchPlan(
            for: root.appendingPathComponent("web/index.ts"),
            workspaceURL: root
        )
        #expect(typeScriptPlan.toolchainID == "project-tsx")

        #expect(throws: LanguageRunPlanError.noProvider(fileExtension: "go")) {
            _ = try registry.launchPlan(for: go, workspaceURL: root)
        }

        #expect(throws: LanguageRunPlanError.noProvider(fileExtension: "java")) {
            _ = try registry.launchPlan(
                for: root.appendingPathComponent("Main.java"),
                workspaceURL: root
            )
        }
        #expect(throws: LanguageRunPlanError.fileOutsideWorkspace(
            URL(fileURLWithPath: "/tmp/outside.py")
        )) {
            _ = try registry.launchPlan(
                for: URL(fileURLWithPath: "/tmp/outside.py"),
                workspaceURL: root
            )
        }
    }

    @Test
    func languageProviderCatalogKeepsOnlyCompatibilityFallbackInSwiftWhenRustCoreIsUnavailable() {
        let catalog = LanguageProviderCatalog.standard
        let go = catalog.provider(for: URL(fileURLWithPath: "/tmp/cmd/main.go"))
        let python = catalog.provider(for: URL(fileURLWithPath: "/tmp/api/server.py"))
        let node = catalog.provider(for: URL(fileURLWithPath: "/tmp/web/App.tsx"))

        #expect(go?.id == "go")
        #expect(python?.id == "python")
        #expect(node?.id == "node")
        #expect(node?.languageIdentifier(for: URL(fileURLWithPath: "/tmp/web/App.tsx")) == "typescriptreact")
        #expect(go?.activationPolicy == .onDemand)
        #expect(go?.capabilities.contains(.languageServer) == true)
        #expect(go?.capabilities.contains(.debugAdapter) == true)
        // Java run/debug/test come from the Java plugin; the built-in row is editor-only.
        #expect(catalog.provider(for: URL(fileURLWithPath: "/tmp/Main.java"))?.capabilities.contains(.debugAdapter) == false)
        if !RustCoreBridge().isAvailable {
            #expect(catalog.provider(for: URL(fileURLWithPath: "/tmp/Package.swift")) == nil)
            #expect(catalog.provider(for: URL(fileURLWithPath: "/tmp/Dockerfile")) == nil)
        }
    }

    @Test
    func standardLanguagePackRegistryDerivesAllFocusedRegistries() {
        let registry = LanguagePackRegistry.standard()
        let providerIDs = registry.packs.map(\.descriptor.id)
        let providerIDSet = Set(providerIDs)

        #expect(providerIDs.starts(with: ["java", "go", "python", "node", "rust"]))
        #expect(registry.catalog.provider(for: URL(fileURLWithPath: "/tmp/main.go"))?.id == "go")
        #expect(registry.runProviders.provider(for: URL(fileURLWithPath: "/tmp/main.py"))?.descriptor.id == "python")
        #expect(registry.testProviders.provider(id: "python")?.descriptor.id == "python")
        #expect(registry.toolchainRegistry.contains(identifier: "project-go"))
        #expect(registry.toolchainRegistry.contains(identifier: "project-python"))
        #expect(registry.toolchainRegistry.contains(identifier: "project-tsx"))
        #expect(registry.toolchainRegistry.contains(identifier: "project-cargo"))
        #expect(registry.pack(id: "go")?.toolchainProviders.contains {
            $0.languageProviderID == "go" && $0.identifiers.contains("project-go")
        } == true)
        #expect(registry.pack(id: "python")?.descriptor.capabilities.contains(.debugAdapter) != true)
        if !RustCoreBridge().isAvailable {
            #expect(providerIDSet == ["java", "go", "python", "node", "rust"])
            #expect(registry.catalog.provider(for: URL(fileURLWithPath: "/tmp/Dockerfile")) == nil)
        }
    }

    @Test
    func extensionOwnedLanguageDoesNotReceiveBuiltInProcessProviders() throws {
        let descriptor = LanguageProviderDescriptor(
            id: "zig",
            displayName: "Zig",
            fileExtensions: ["zig"],
            capabilities: [.run, .languageServer, .debugAdapter, .testing],
            activationPolicy: .onDemand
        )
        let registry = LanguagePackRegistry.standard(
            catalog: LanguageProviderCatalog(descriptors: [descriptor]),
            extensionRequiredProviderIDs: ["zig"]
        )

        #expect(registry.runProviders.provider(id: "zig") == nil)
        #expect(registry.testProviders.provider(id: "zig") == nil)
        #expect(registry.pack(id: "zig")?.toolingRuntime == nil)
    }

    /// A package can leave a feature with the host by declaring it on its
    /// host integration. Only the declared features get a built-in tool.
    @Test
    func extensionOwnedLanguageKeepsTheBuiltInToolsItsPackageDeclares() throws {
        let descriptor = LanguageProviderDescriptor(
            id: "python",
            displayName: "Python",
            fileExtensions: ["py"],
            capabilities: [.run, .languageServer, .debugAdapter, .testing],
            activationPolicy: .onDemand
        )
        let registry = LanguagePackRegistry.standard(
            catalog: LanguageProviderCatalog(descriptors: [descriptor]),
            extensionRequiredProviderIDs: ["python"],
            hostCapabilities: ["python": [.debug, .testing]]
        )

        #expect(registry.runProviders.provider(id: "python") == nil)
        #expect(registry.testProviders.provider(id: "python") != nil)
        #expect(registry.pack(id: "python")?.toolingRuntime == nil)
    }

    @Test
    func customLanguagePackRegistersWithoutChangingCoreServices() {
        let descriptor = LanguageProviderDescriptor(
            id: "ruby",
            displayName: "Ruby",
            fileExtensions: ["rb"],
            capabilities: [.run, .testing],
            activationPolicy: .onDemand
        )
        let registry = LanguagePackRegistry(packs: [
            LanguagePack(
                descriptor: descriptor,
                runProvider: StandardLanguageRunProvider(descriptor: descriptor),
                testProviders: [StandardLanguageTestProvider(descriptor: descriptor)]
            )
        ])

        #expect(registry.catalog.provider(for: URL(fileURLWithPath: "/tmp/app.rb"))?.id == "ruby")
        #expect(registry.runProviders.provider(id: "ruby")?.descriptor.id == "ruby")
        #expect(registry.testProviders.provider(id: "ruby")?.descriptor.id == "ruby")
    }

    @Test
    func projectCatalogCreatesLanguageRuntimeOnlyWhenTheLSPIsRequested() throws {
        let factory = TestLanguageProviderRuntimeFactory()
        let manager = LanguageToolingSessionManager(
            catalog: LanguageProviderCatalog(descriptors: []),
            runtimeFactory: factory
        )
        let descriptor = LanguageProviderDescriptor(
            id: "roc",
            displayName: "Roc",
            fileExtensions: ["roc"],
            capabilities: [.languageServer, .debugAdapter],
            activationPolicy: .onDemand,
            languageIdentifier: "roc",
            languageServerLaunch: LanguageServerLaunchDescriptor(
                executableNames: ["roc_language_server"],
                arguments: []
            )
        )

        manager.updateCatalog(LanguageProviderCatalog(descriptors: [descriptor]))

        #expect(factory.createdDescriptors.isEmpty)
        try manager.synchronizeLanguageServer(
            for: URL(fileURLWithPath: "/tmp/main.roc"),
            text: "app \"main\"",
            rootURL: URL(fileURLWithPath: "/tmp")
        )
        #expect(factory.createdDescriptors == [descriptor])
    }

    @Test
    func genericDebugCapabilityReflectsTheRuntimeFactoryWithoutStartingIt() throws {
        let catalog = LanguageProviderCatalog.standard
        var nodeFactoryCalls = 0
        let sessionFactories: [String: () -> (any DebugAdapterSession)?] = ["node": {
            nodeFactoryCalls += 1
            return TestDebugAdapterSession()
        }]

        #expect(nodeFactoryCalls == 0)
        let debugManager = DebugAdapterSessionManager(
            providers: catalog.debugProviders,
            makeSession: { descriptor, _ in
                sessionFactories[descriptor.id]?()
            }
        )
        #expect(debugManager.activeAdapterIDs.isEmpty)
    }

    @Test
    func javaDAPRuntimeActivatesThroughTheSharedDebugBoundary() throws {
        let javaDescriptor = LanguageProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"],
            capabilities: [.run, .languageServer, .debugAdapter, .formatting, .testing],
            activationPolicy: .onDemand
        )
        let catalog = LanguageProviderCatalog(descriptors: [javaDescriptor])
        let runtime = TestDebugLanguageProviderRuntime(
            descriptor: javaDescriptor,
            supportsDebugAdapter: true
        )
        let debugManager = DebugAdapterSessionManager(
            providers: catalog.debugProviders,
            makeSession: { descriptor, rootURL in
                descriptor.id == runtime.descriptor.id
                    ? runtime.makeSession()
                    : nil
            }
        )
        let source = URL(fileURLWithPath: "/tmp/Main.java")

        _ = try debugManager.activate(
            for: source,
            rootURL: URL(fileURLWithPath: "/tmp/java-project")
        )
        #expect(runtime.debugAdapters.count == 1)
    }

    @Test
    func currentFileDebugStillUsesTheActiveEditorDocument() throws {
        let root = URL(fileURLWithPath: "/workspace/current-file", isDirectory: true)
        let current = root.appendingPathComponent("src/main/java/com/acme/Main.java")
        let other = root.appendingPathComponent("src/main/java/com/acme/Other.java")

        let source = DebugLaunchSourceResolver().resolve(
            configuration: .currentFile,
            activeDocumentURL: current,
            projectFiles: [other],
            workspaceURL: root
        )

        #expect(source == current)
    }

    @Test
    func sourceBreakpointRelocationUsesTheSharedRustCore() throws {
        let core = RustCoreBridge()
        guard core.isAvailable else { return }
        let source = "class Main {\n    void run() {}\n}\n"

        let breakpoints = try core.relocateDebugBreakpoints(
            source: source,
            edit: DebugSourceEdit(
                startUTF16Offset: 13,
                endUTF16Offset: 13,
                replacement: "\n"
            ),
            breakpoints: [DebugSourceBreakpoint(
                line: 2,
                condition: "ready",
                hitCondition: "3"
            )]
        )

        #expect(breakpoints == [DebugSourceBreakpoint(
            line: 3,
            condition: "ready",
            hitCondition: "3"
        )])
    }

    @Test
    func macToolDiscoveryReportsProjectHomebrewAndXcodeSources() {
        let root = URL(fileURLWithPath: "/tmp/mac-tool-project", isDirectory: true)
        let executablePaths: Set<String> = [
            root.appendingPathComponent(".lithe/toolchains/bin/dlv").path,
            "/custom/bin/dlv",
            "/opt/homebrew/bin/dlv",
            "/usr/bin/xcrun"
        ]
        let discovery = MacRuntimeToolDiscovery(
            homeDirectoryURL: URL(fileURLWithPath: "/tmp/home", isDirectory: true),
            isExecutable: { executablePaths.contains($0.path) }
        )

        let goCandidates = discovery.candidates(
            for: "dlv",
            projectURL: root,
            environment: ["PATH": "/custom/bin"]
        )
        #expect(goCandidates.map(\.source) == [.project, .path, .homebrew])
        #expect(goCandidates.map(\.executableURL.path) == [
            root.appendingPathComponent(".lithe/toolchains/bin/dlv").path,
            "/custom/bin/dlv",
            "/opt/homebrew/bin/dlv"
        ])

        let xcrunCandidates = discovery.candidates(
            for: "xcrun",
            projectURL: root,
            environment: [:]
        )
        #expect(xcrunCandidates.first?.source == .xcode)
    }

    @Test
    func macToolDiscoveryFindsGoLanguageServerInUserBin() {
        let discovery = MacRuntimeToolDiscovery(
            homeDirectoryURL: URL(fileURLWithPath: "/tmp/home", isDirectory: true),
            isExecutable: { $0.path == "/tmp/home/.go/bin/gopls" }
        )

        let candidates = discovery.candidates(
            for: "gopls",
            projectURL: nil,
            environment: ["PATH": "/usr/bin"]
        )

        #expect(candidates.first?.executableURL.path == "/tmp/home/.go/bin/gopls")
        #expect(candidates.first?.source == .environment)
    }

    @Test
    func dapBreakpointsCanBeStoredBeforeTheAdapterStarts() throws {
        let source = URL(fileURLWithPath: "/tmp/main.go")
        let manager = DebugAdapterSessionManager(
            providers: LanguageProviderCatalog.standard.debugProviders
        ) { _, _ in nil }

        try manager.setBreakpoints([DebugSourceBreakpoint(line: 1)], in: source)

        #expect(manager.provider(for: source)?.id == "go")
        #expect(manager.activeAdapterIDs.isEmpty)
    }

    @Test
    func restoredBreakpointInAnotherSourceIsSentWhenDebugStarts() throws {
        let root = URL(fileURLWithPath: "/tmp/restored-go-debug", isDirectory: true)
        let launchSource = root.appendingPathComponent("cmd/app/main.go")
        let breakpointSource = root.appendingPathComponent("internal/user/controller.go")
        let persistence = RestoredBreakpointPersistence(snapshot: DebugBreakpointSnapshot(
            breakpoints: [PersistedDebugBreakpoint(
                relativePath: "internal/user/controller.go",
                line: 23
            )]
        ))
        var adapter: TestDebugAdapterSession?
        let manager = DebugAdapterSessionManager(
            providers: LanguageProviderCatalog.standard.debugProviders,
            makeSession: { _, _ in
                let value = TestDebugAdapterSession()
                adapter = value
                return value
            }
        )
        let feature = GenericDebugFeatureModel(
            paging: RustCoreBridge(),
            sessions: manager,
            breakpointPersistence: persistence
        )
        feature.openWorkspace(at: root)

        let started = feature.start(
            fileURL: launchSource,
            rootURL: root,
            configuration: DebugLaunchConfiguration(
                name: "app",
                request: .launch,
                arguments: [:]
            )
        )

        #expect(started)
        let update = try #require(adapter?.breakpointUpdates.first(where: {
            $0.0 == breakpointSource.standardizedFileURL
        }))
        #expect(update.1 == [DebugSourceBreakpoint(line: 23)])
    }

    @Test
    func standardTestProvidersDiscoverFilesAndBuildLanguageNeutralPlans() throws {
        let root = URL(fileURLWithPath: "/tmp/polyglot-tests", isDirectory: true)
        let files = [
            root.appendingPathComponent("src/test/java/UserServiceTest.java"),
            root.appendingPathComponent("cmd/api/api_test.go"),
            root.appendingPathComponent("tests/test_api.py"),
            root.appendingPathComponent("web/src/app.spec.ts"),
            root.appendingPathComponent("tests/parser.rs"),
            root.appendingPathComponent("src/production.py")
        ]
        let registry = LanguageTestProviderRegistry.standard()

        for (providerID, source) in [
            ("go", files[1]), ("python", files[2]),
            ("node", files[3]), ("rust", files[4])
        ] {
            let provider = try #require(registry.provider(for: source))
            #expect(provider.descriptor.id == providerID)
            let items = provider.discoverTests(workspaceURL: root, files: files)
            #expect(items.first?.kind == .workspace)
            #expect(items.count == 2)
            #expect(items.last?.fileURL == source.standardizedFileURL)
        }

        let goProvider = try #require(registry.provider(id: "go"))
        let goPlan = try goProvider.testPlan(scope: .file(files[1]), workspaceURL: root)
        #expect(goPlan.launchPlan.toolchainID == "project-go")
        #expect(goPlan.launchPlan.arguments == ["test", "./cmd/api"])

        let pythonProvider = try #require(registry.provider(id: "python"))
        let pythonPlan = try pythonProvider.testPlan(
            scope: .testCase(identifier: "test_health", fileURL: files[2]),
            workspaceURL: root
        )
        #expect(pythonPlan.launchPlan.toolchainID == "project-python")
        #expect(pythonPlan.launchPlan.arguments == ["-m", "pytest", "tests/test_api.py::test_health"])

        let nodeProvider = try #require(registry.provider(id: "node"))
        let nodePlan = try nodeProvider.testPlan(scope: .workspace, workspaceURL: root)
        if case .command(let executable) = nodePlan.launchPlan.executable {
            #expect(executable == "npm")
        } else {
            Issue.record("Expected the Node test provider to use npm")
        }
        #expect(nodePlan.launchPlan.arguments == ["test", "--"])

        let pnpmPlan = try nodeProvider.testPlan(
            scope: .testCase(identifier: "parses", fileURL: files[3]),
            context: LanguageTestContext(
                workspaceURL: root,
                projectFiles: [root.appendingPathComponent("pnpm-lock.yaml")]
            )
        )
        #expect(pnpmPlan.frameworkID == "pnpm")
        #expect(pnpmPlan.launchPlan.arguments == ["test", "--", "web/src/app.spec.ts", "-t", "parses"])

        let rustProvider = try #require(registry.provider(id: "rust"))
        let rustPlan = try rustProvider.testPlan(scope: .file(files[4]), workspaceURL: root)
        #expect(rustPlan.launchPlan.toolchainID == "project-cargo")
        #expect(rustPlan.launchPlan.arguments == ["test", "--test", "parser"])
    }

    @Test
    func testProvidersRejectFilesOutsideTheWorkspace() throws {
        let provider = try #require(LanguageTestProviderRegistry.standard().provider(id: "python"))
        #expect(throws: LanguageTestPlanError.fileOutsideWorkspace(
            URL(fileURLWithPath: "/tmp/outside/test_api.py")
        )) {
            _ = try provider.testPlan(
                scope: .file(URL(fileURLWithPath: "/tmp/outside/test_api.py")),
                workspaceURL: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
            )
        }
    }

    @Test
    func languageTestServiceDiscoversWithoutStartingAndRunsOnDemand() async throws {
        let root = URL(fileURLWithPath: "/tmp/language-test-service", isDirectory: true)
        let source = root.appendingPathComponent("cmd/api/api_test.go")
        let manifest = root.appendingPathComponent("go.mod")
        let processFactory = RecordingProcessFactory()
        let resolver = RecordingRunExecutableResolver()
        let service = LanguageTestService(
            outcomeResolver: RustCoreBridge(),
            executableResolver: resolver,
            processFactory: { processFactory.make() }
        )

        service.discover(workspaceURL: root, files: [source, manifest])
        #expect(processFactory.processes.isEmpty)
        #expect(service.itemsByProviderID["go"]?.count == 2)

        let didStart = service.run(
            providerID: "go",
            scope: .file(source),
            workspaceURL: root,
            projectFiles: [source, manifest]
        )
        #expect(didStart)
        #expect(processFactory.processes.count == 1)
        #expect(resolver.resolveCalls == 1)
        #expect(service.state == .running)
        #expect(processFactory.processes[0].requests.first?.arguments == ["test", "./cmd/api"])

        processFactory.processes[0].onOutput?("ok\n")
        processFactory.processes[0].onTermination?(0)
        #expect(
            await awaitChange(on: service) { service.state == .passed },
            "Language test completion was not published before the local deadline"
        )

        #expect(service.state == .passed)
        #expect(service.output.contains("ok"))
    }

    @Test
    func javaTransportQueuesDAPBytesUntilJdtlsPortAndSocketAreReady() async throws {
        let portGate = JavaDebugPortGate()
        let socket = TestDebugSocketConnection()
        let endpointRecorder = DebugEndpointRecorder()
        let transport = MacHostedPortDebugAdapterTransport(
            portResolver: { rootURL in try await portGate.resolve(rootURL: rootURL) },
            core: RustCoreBridge(),
            socketFactory: { host, port in
                endpointRecorder.record(host: host, port: port)
                return socket
            }
        )
        let root = URL(fileURLWithPath: "/tmp/java-dap", isDirectory: true)
        let initializeFrame = Data("Content-Length: 2\r\n\r\n{}".utf8)

        try transport.start(rootURL: root)
        try transport.send(initializeFrame)
        #expect(socket.sent.isEmpty)
        #expect(await portGate.waitUntilRequested() == root.standardizedFileURL)

        portGate.succeed(port: 5005)
        let endpoint = await endpointRecorder.waitUntilRecorded()
        #expect(endpoint.host == "127.0.0.1")
        #expect(endpoint.port == 5005)
        #expect(socket.startCount == 1)
        #expect(socket.sent.isEmpty)

        socket.onReady?()
        #expect(socket.sent == [initializeFrame])
        transport.stop()
        #expect(socket.stopCount == 1)
    }

    @Test
    func stoppingJavaTransportCancelsPortDiscoveryWithoutOpeningSocket() async throws {
        let portGate = JavaDebugPortGate()
        let socket = TestDebugSocketConnection()
        let endpointRecorder = DebugEndpointRecorder()
        let transport = MacHostedPortDebugAdapterTransport(
            portResolver: { rootURL in try await portGate.resolve(rootURL: rootURL) },
            core: RustCoreBridge(),
            socketFactory: { host, port in
                endpointRecorder.record(host: host, port: port)
                return socket
            }
        )

        try transport.start(rootURL: URL(fileURLWithPath: "/tmp/java-dap-cancel"))
        _ = await portGate.waitUntilRequested()
        transport.stop()

        await portGate.waitUntilCancelled()
        #expect(!endpointRecorder.didRecord)
        #expect(socket.startCount == 0)
        #expect(!transport.isRunning)
    }

    @Test
    func editorDiagnosticsMapLanguageServerFilesAndSeverities() throws {
        let javaURL = URL(fileURLWithPath: "/tmp/mixed/src/Main.java")
        let pythonURL = URL(fileURLWithPath: "/tmp/mixed/api/main.py")
        let javaDiagnostic = LanguageServerDiagnostic(
            range: LanguageServerRange(
                start: LanguageServerPosition(line: 2, utf16Column: 4),
                end: LanguageServerPosition(line: 2, utf16Column: 8)
            ),
            severity: 2,
            message: "Java warning",
            source: "jdtls",
            code: "java-warning",
            tags: [],
            relatedInformation: []
        )
        let severities = [1, 2, 3, 4]
        let languageDiagnostics = severities.map { severity in
            LanguageServerDiagnostic(
                range: LanguageServerRange(
                    start: LanguageServerPosition(line: severity, utf16Column: 0),
                    end: LanguageServerPosition(line: severity, utf16Column: 3)
                ),
                severity: severity,
                message: "Python diagnostic \(severity)",
                source: "pyright",
                code: "python-\(severity)"
            )
        }

        let mapped = EditorDiagnostic.fromLanguageServerDiagnostics(
            [javaURL: [javaDiagnostic], pythonURL: languageDiagnostics]
        )

        let java = try #require(mapped[javaURL.standardizedFileURL])
        #expect(java.count == 1)
        #expect(java[0].severity == .warning)
        #expect(java[0].source == "jdtls")
        let python = try #require(mapped[pythonURL.standardizedFileURL])
        #expect(python.map(\.severity) == [.error, .warning, .information, .hint])
        #expect(python.allSatisfy { $0.source == "pyright" })
    }

    @Test
    func editorDiagnosticsPreserveTheAuthoritativeLanguageServerResult() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/mixed/src/Main.java")
        let lsp = LanguageServerDiagnostic(
            range: LanguageServerRange(
                start: LanguageServerPosition(line: 3, utf16Column: 7),
                end: LanguageServerPosition(line: 3, utf16Column: 10)
            ),
            severity: 1,
            message: "Cannot resolve symbol",
            source: "java",
            code: "resolve"
        )

        let mapped = EditorDiagnostic.fromLanguageServerDiagnostics(
            [fileURL: [lsp]]
        )

        let diagnostics = try #require(mapped[fileURL.standardizedFileURL])
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0] == EditorDiagnostic(languageServerDiagnostic: lsp, fileURL: fileURL))
    }

    @Test
    func executableResolverRejectsUnknownToolchainsInsteadOfUsingMaven() throws {
        let runtime = ProjectRuntimeService(runtimeLocator: RunTestRuntimeLocator())
        let resolver = RunExecutableResolver(runtimeService: runtime)
        let plan = SharedLaunchPlan(
            executable: .toolchain("project-unknown"),
            arguments: [],
            workingDirectory: "."
        )

        #expect(throws: RunExecutableResolutionError.self) {
            try resolver.resolve(
                plan,
                projectURL: URL(fileURLWithPath: "/tmp/lithe-toolchain-test"),
                options: RunOptions()
            )
        }
    }

    @Test
    func commandResolverLayersGenericEnvironmentWithoutJavaInjection() throws {
        let runtime = ProjectRuntimeService(runtimeLocator: RunTestRuntimeLocator())
        let resolver = RunExecutableResolver(runtimeService: runtime)
        let plan = SharedLaunchPlan(
            executable: .command("python3"),
            arguments: ["app.py"],
            workingDirectory: ".",
            environment: ["FROM_PLAN": "yes"]
        )
        let resolved = try resolver.resolve(
            plan,
            projectURL: URL(fileURLWithPath: "/tmp/lithe-command-test"),
            options: RunOptions(environment: ["APP_ENV": "test"])
        )

        #expect(resolved.executableURL.path == "/usr/bin/python3")
        #expect(resolved.environment["PATH"] == "/usr/bin")
        #expect(resolved.environment["FROM_PLAN"] == "yes")
        #expect(resolved.environment["APP_ENV"] == "test")
        #expect(resolved.environment["JAVA_HOME"] == nil)
    }

    @Test
    func registeredGoToolchainResolvesWithoutMavenFallback() throws {
        let runtime = ProjectRuntimeService(runtimeLocator: RunTestRuntimeLocator())
        let resolver = RunExecutableResolver(runtimeService: runtime)
        let resolved = try resolver.resolve(
            SharedLaunchPlan(
                executable: .toolchain("project-go"),
                arguments: ["run", "."],
                workingDirectory: "."
            ),
            projectURL: URL(fileURLWithPath: "/tmp/lithe-go-toolchain"),
            options: RunOptions(environment: ["GO_ENV": "test"])
        )

        #expect(resolved.executableURL.path == "/usr/bin/go")
        #expect(resolved.environment["GO_ENV"] == "test")
        #expect(resolved.environment["JAVA_HOME"] == nil)
    }

    @Test
    func genericToolchainVersionsAreProbedOffTheResolutionPathAndCachedPerAlias() async throws {
        let runtime = ProjectRuntimeService(runtimeLocator: RunTestRuntimeLocator())
        let runner = ToolchainVersionProcessRunner()
        let resolver = RunExecutableResolver(
            runtimeService: runtime,
            metadataResolver: ProcessRunToolchainMetadataResolver(processRunner: runner)
        )
        let root = URL(fileURLWithPath: "/tmp/lithe-version-probes")

        #expect(resolver.candidates(projectURL: root).first { $0.id == "project-go" }?.version == "")
        await resolver.refreshCandidates(projectURL: root)
        let candidates = Dictionary(uniqueKeysWithValues: resolver.candidates(projectURL: root).map {
            ($0.id, $0)
        })

        #expect(candidates["project-go"]?.version == "1.24.3")
        #expect(candidates["project-python"]?.version == "3.13.5")
        #expect(candidates["project-node"]?.version == "22.18.0")
        #expect(candidates["project-cargo"]?.version == "1.89.0")
        #expect(runner.executedCommands.sorted() == ["go", "node", "python3", "rustc"])
    }

    @Test
    func languageToolingSessionsKeepSwiftLSPAtTheRustHostBoundary() async throws {
        let descriptor = LanguageProviderDescriptor(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            capabilities: [.languageServer, .formatting],
            activationPolicy: .onDemand,
            languageIdentifier: "go",
            languageServerLaunch: LanguageServerLaunchDescriptor(
                executableNames: ["gopls"],
                arguments: []
            )
        )
        let runtimeService = ProjectRuntimeService(runtimeLocator: RunTestRuntimeLocator())
        let process = RecordingRawProcessSession()
        let core = TestLanguageServerRuntimeCore(providerID: "go")
        let runtime = StdioLanguageProviderRuntime(
            descriptor: descriptor,
            runtimeService: runtimeService,
            languageServerLaunch: descriptor.languageServerLaunch,
            languageServerCore: core
        )
        let manager = LanguageToolingSessionManager(
            catalog: LanguageProviderCatalog(descriptors: [descriptor]),
            runtimes: [runtime]
        )
        defer { manager.stopAll() }
        let root = URL(fileURLWithPath: "/tmp/go-project", isDirectory: true)
        let source = root.appendingPathComponent("main.go")

        #expect(manager.activeLanguageServerIDs.isEmpty)
        #expect(!manager.features(for: source).contains(.completion))
        #expect(!manager.supportsGenericEditing(for: source))
        try manager.synchronizeLanguageServer(
            for: source,
            text: "package main\nfunc main() {}\n",
            rootURL: root
        )
        #expect(process.requests.isEmpty)
        #expect(process.sentData.isEmpty)
        #expect(await Self.waitForMainActorCondition {
            core.startCalls.count == 1 && core.syncCalls.last?.fileURL == source.standardizedFileURL
        })
        #expect(core.startCalls.count == 1)
        #expect(core.syncCalls.last?.fileURL == source.standardizedFileURL)
        core.enqueueReady(capabilities: ["completion", "formatting"])
        try #require(await Self.waitForMainActorCondition { manager.languageServerStates["go"] == .ready })
        #expect(manager.features(for: source).contains(.completion))
        #expect(manager.supportsGenericEditing(for: source))

        var completionResult: Result<[LanguageServerCompletionItem], Error>?
        try manager.completions(
            fileURL: source,
            text: "fu",
            position: LanguageServerPosition(line: 0, utf16Column: 2),
            rootURL: root
        ) { result in
            completionResult = result
        }
        core.enqueueRequestSuccess(operation: .completion, result: [
            "isIncomplete": false, "items": [["label": "func", "insertText": "func"]]
        ])
        try #require(await Self.waitForMainActorCondition { completionResult != nil })
        #expect(try completionResult?.get().contains { $0.label == "func" } == true)

        #expect(throws: LanguageToolingSessionError.self) {
            try manager.hover(
                fileURL: source,
                text: "package main\n",
                position: LanguageServerPosition(line: 0, utf16Column: 1),
                rootURL: root
            ) { _ in }
        }
        var formatResult: Result<[LanguageServerTextEdit], Error>?
        try manager.format(fileURL: source, text: "package main\n", rootURL: root) { formatResult = $0 }
        core.enqueueRequestSuccess(operation: .formatting, result: ["edits": []])
        try #require(await Self.waitForMainActorCondition { formatResult != nil })
        #expect(try formatResult?.get().isEmpty == true)
        #expect(manager.activeLanguageServerIDs.contains("go"))
    }

    @Test
    func languageServerFailureClearsActiveSessionState() async throws {
        let descriptor = LanguageProviderDescriptor(
            id: "swift",
            displayName: "Swift",
            fileExtensions: ["swift"],
            capabilities: [.languageServer, .formatting],
            activationPolicy: .onDemand,
            languageIdentifier: "swift",
            languageServerLaunch: LanguageServerLaunchDescriptor(
                executableNames: ["sourcekit-lsp"]
            )
        )
        let runtimeService = ProjectRuntimeService(runtimeLocator: RunTestRuntimeLocator())
        let core = TestLanguageServerRuntimeCore()
        let source = URL(fileURLWithPath: "/tmp/swift-project/App.swift")
        let runtime = StdioLanguageProviderRuntime(
            descriptor: descriptor,
            runtimeService: runtimeService,
            languageServerLaunch: descriptor.languageServerLaunch,
            languageServerCore: core
        )
        let manager = LanguageToolingSessionManager(
            catalog: LanguageProviderCatalog(descriptors: [descriptor]),
            runtimes: [runtime]
        )

        try manager.synchronizeLanguageServer(
            for: source,
            text: "struct App {}\n",
            rootURL: source.deletingLastPathComponent()
        )
        #expect(manager.activeLanguageServerIDs.isEmpty)
        #expect(manager.languageServerStates["swift"] == .initializing)

        core.enqueueReady(capabilities: [])
        #expect(await Self.waitForMainActorCondition {
            manager.languageServerStates["swift"] == .ready
        })

        #expect(manager.activeLanguageServerIDs == ["swift"])
        #expect(manager.languageServerStates["swift"] == .ready)

        core.enqueueFailure(
            code: "serverExited",
            message: "Language server exited",
            underlyingMessage: "exit code 1",
            processExitCode: 1
        )
        #expect(await Self.waitForMainActorCondition {
            manager.activeLanguageServerIDs.isEmpty
        })

        #expect(manager.activeLanguageServerIDs.isEmpty)
        #expect(manager.languageServerFeatures["swift"] == nil)
        guard case .failed(let failure)? = manager.languageServerStates["swift"] else {
            Issue.record("Expected the Swift language server to fail after process termination")
            return
        }
        #expect(failure.exitCode == 1)
        #expect(failure.message?.contains("exit code 1") == true)
    }

    @Test
    func navigationResynchronizesAnOpenDocumentAfterLanguageServerRestart() async throws {
        let harness = makeLanguageServerHarness()
        let secondSource = harness.root.appendingPathComponent("Other.swift")

        try harness.manager.synchronizeLanguageServer(
            for: harness.source,
            text: "struct App {}\n",
            rootURL: harness.root
        )
        harness.core.enqueueReady(capabilities: ["definition"])
        #expect(await Self.waitForMainActorCondition {
            harness.manager.languageServerStates["swift"] == .ready
        })

        try harness.manager.navigate(
            method: "textDocument/definition",
            fileURL: secondSource,
            text: "struct Other {}\n",
            position: LanguageServerPosition(line: 0, utf16Column: 7),
            rootURL: harness.root
        ) { _ in }

        #expect(harness.core.syncCalls.map(\.fileURL) == [
            harness.source.standardizedFileURL,
            secondSource.standardizedFileURL
        ])
    }

    @Test
    func initializeErrorNeverActivatesLanguageServer() async throws {
        let harness = makeLanguageServerHarness()

        try harness.manager.synchronizeLanguageServer(
            for: harness.source,
            text: "struct App {}\n",
            rootURL: harness.root
        )
        #expect(harness.manager.languageServerStates["swift"] == .initializing)
        #expect(harness.manager.activeLanguageServerIDs.isEmpty)

        harness.core.enqueueFailure(
            code: "initializeFailed",
            message: "initialize failed",
            underlyingMessage: "initialize rejected"
        )
        #expect(await Self.waitForMainActorCondition {
            if case .failed = harness.manager.languageServerStates["swift"] { return true }
            return false
        })

        #expect(harness.manager.activeLanguageServerIDs.isEmpty)
        guard case .failed(let failure)? = harness.manager.languageServerStates["swift"] else {
            Issue.record("Expected initialize error to fail the language server")
            return
        }
        #expect(failure.message?.contains("initialize failed") == true)
        #expect(harness.core.destroyedSessionIDs.count == 1)
    }

    @Test
    func invalidInitializeResultNeverMarksLanguageServerReady() async throws {
        let harness = makeLanguageServerHarness()

        try harness.manager.synchronizeLanguageServer(
            for: harness.source,
            text: "struct App {}\n",
            rootURL: harness.root
        )
        harness.core.enqueueFailure(
            code: "invalidInitializeResult",
            message: "initialize returned an invalid result"
        )
        #expect(await Self.waitForMainActorCondition {
            if case .failed = harness.manager.languageServerStates["swift"] { return true }
            return false
        })

        #expect(harness.manager.activeLanguageServerIDs.isEmpty)
        guard case .failed(let failure)? = harness.manager.languageServerStates["swift"] else {
            Issue.record("Expected invalid initialize result to fail the language server")
            return
        }
        #expect(failure.message?.contains("invalid result") == true)
    }

    @Test
    func initializeTimeoutTransitionsInitializingSessionToFailed() async throws {
        let harness = makeLanguageServerHarness(initializeTimeoutNanoseconds: 2_000_000)

        try harness.manager.synchronizeLanguageServer(
            for: harness.source,
            text: "struct App {}\n",
            rootURL: harness.root
        )
        #expect(harness.manager.languageServerStates["swift"] == .initializing)
        #expect(harness.manager.activeLanguageServerIDs.isEmpty)
        #expect(harness.core.startCalls.first?.initializeTimeout == 0.002)

        harness.core.enqueueFailure(
            code: "initializeTimedOut",
            message: "initialize timed out"
        )

        let didFail = await Self.waitForMainActorCondition {
            if case .failed = harness.manager.languageServerStates["swift"] {
                return true
            }
            return false
        }

        #expect(didFail)
        #expect(harness.manager.activeLanguageServerIDs.isEmpty)
        guard case .failed(let failure)? = harness.manager.languageServerStates["swift"] else {
            Issue.record("Expected initialize timeout to fail the language server")
            return
        }
        #expect(failure.message?.contains("initialize timed out") == true)
    }

    @Test
    func pendingCompletionFailsExactlyOnceWhenServerTerminates() async throws {
        let harness = makeLanguageServerHarness()
        try harness.manager.synchronizeLanguageServer(
            for: harness.source,
            text: "struct App { let title = 1 }\n",
            rootURL: harness.root
        )
        harness.core.enqueueReady()
        #expect(await Self.waitForMainActorCondition {
            harness.manager.languageServerStates["swift"] == .ready
        })

        var completionResult: Result<[LanguageServerCompletionItem], Error>?
        var completionCount = 0
        try harness.manager.completions(
            fileURL: harness.source,
            text: "struct App { let ti = 1 }\n",
            position: LanguageServerPosition(line: 0, utf16Column: 19),
            rootURL: harness.root
        ) { result in
            completionCount += 1
            completionResult = result
        }

        harness.core.enqueueRequestFailure(
            operation: .completion,
            code: "serverExited",
            message: "Language server exited",
            underlyingMessage: "exit code 9",
            processExitCode: 9
        )
        harness.core.enqueueFailure(
            code: "serverExited",
            message: "Language server exited",
            underlyingMessage: "exit code 9",
            processExitCode: 9
        )
        #expect(await Self.waitForMainActorCondition { completionResult != nil })

        #expect(completionCount == 1)
        guard case .failure(let error)? = completionResult else {
            Issue.record("Expected pending completion to fail when the server terminates")
            return
        }
        #expect(error.localizedDescription.contains("exit code 9"))
        #expect(harness.manager.activeLanguageServerIDs.isEmpty)
        #expect(harness.core.requestCalls.last(where: { $0.operation == .completion })?.operationID != nil)
    }

    @Test
    func requestTimeoutSendsCancellationAndReturnsFailure() async throws {
        let harness = makeLanguageServerHarness(requestTimeoutNanoseconds: 2_000_000)
        try harness.manager.synchronizeLanguageServer(
            for: harness.source,
            text: "struct App { let title = 1 }\n",
            rootURL: harness.root
        )
        harness.core.enqueueReady()
        #expect(await Self.waitForMainActorCondition {
            harness.manager.languageServerStates["swift"] == .ready
        })
        #expect(harness.core.startCalls.first?.requestTimeout == 0.002)

        var completionResult: Result<[LanguageServerCompletionItem], Error>?
        try harness.manager.completions(
            fileURL: harness.source,
            text: "struct App { let ti = 1 }\n",
            position: LanguageServerPosition(line: 0, utf16Column: 19),
            rootURL: harness.root
        ) { completionResult = $0 }

        harness.core.enqueueRequestFailure(
            operation: .completion,
            code: "requestTimeout",
            message: "Language-server request timed out"
        )

        let didComplete = await Self.waitForMainActorCondition {
            completionResult != nil
        }

        #expect(didComplete)
        guard case .failure(let error)? = completionResult else {
            Issue.record("Expected completion timeout to return failure")
            return
        }
        #expect(error.localizedDescription.contains("timed out"))
        #expect(harness.core.cancelCalls.isEmpty)
        #expect(harness.manager.languageServerStates["swift"] == .ready)
        #expect(harness.core.requestCalls.last(where: { $0.operation == .completion })?.operationID != nil)
    }

    @Test
    func cancelledRequestCompletesWithItsCoreOperationID() async throws {
        let harness = makeLanguageServerHarness()
        try harness.manager.synchronizeLanguageServer(
            for: harness.source,
            text: "struct App { let title = 1 }\n",
            rootURL: harness.root
        )
        harness.core.enqueueReady()
        #expect(await Self.waitForMainActorCondition {
            harness.manager.languageServerStates["swift"] == .ready
        })

        var completionResult: Result<[LanguageServerCompletionItem], Error>?
        try harness.manager.completions(
            fileURL: harness.source,
            text: "struct App { let ti = 1 }\n",
            position: LanguageServerPosition(line: 0, utf16Column: 19),
            rootURL: harness.root
        ) { completionResult = $0 }
        #expect(harness.core.requestCalls.last(where: { $0.operation == .completion })?.operationID != nil)

        harness.core.enqueueRequestFailure(
            operation: .completion,
            code: "requestCancelled",
            message: "Language-server request was cancelled"
        )
        #expect(await Self.waitForMainActorCondition { completionResult != nil })

    }

    @Test
    func didOpenWriteFailureFailsSessionAndRetriesWithFullOpen() async throws {
        let harness = makeLanguageServerHarness()

        try harness.manager.synchronizeLanguageServer(
            for: harness.source,
            text: "struct App {}\n",
            rootURL: harness.root
        )
        harness.core.enqueueFailure(
            code: "transportFailed",
            message: "language-server transport failed",
            underlyingMessage: "didOpen write failed"
        )
        #expect(await Self.waitForMainActorCondition {
            if case .failed = harness.manager.languageServerStates["swift"] { return true }
            return false
        })

        #expect(harness.manager.activeLanguageServerIDs.isEmpty)
        guard case .failed(let failure)? = harness.manager.languageServerStates["swift"] else {
            Issue.record("Expected didOpen transport failure to fail the session")
            return
        }
        #expect(failure.message?.contains("transport failed") == true)

        try harness.manager.synchronizeLanguageServer(
            for: harness.source,
            text: "struct App { let retried = true }\n",
            rootURL: harness.root
        )
        harness.core.enqueueReady()
        #expect(await Self.waitForMainActorCondition {
            harness.manager.languageServerStates["swift"] == .ready
        })

        #expect(harness.core.startCalls.count == 2)
        #expect(harness.core.syncCalls.count == 2)
        #expect(harness.core.syncCalls.last?.text == "struct App { let retried = true }\n")
        #expect(harness.manager.languageServerStates["swift"] == .ready)
    }

    @Test
    func providerStopAndReconfigurationClearOnlyOwnedDiagnostics() async throws {
        let root = URL(fileURLWithPath: "/tmp/lithe-owned-diagnostics", isDirectory: true)
        let swiftSource = root.appendingPathComponent("App.swift")
        let goSource = root.appendingPathComponent("main.go")
        let swiftDescriptor = LanguageProviderDescriptor(
            id: "swift",
            displayName: "Swift",
            fileExtensions: ["swift"],
            capabilities: [.languageServer],
            activationPolicy: .onDemand,
            languageIdentifier: "swift"
        )
        let goDescriptor = LanguageProviderDescriptor(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            capabilities: [.languageServer],
            activationPolicy: .onDemand,
            languageIdentifier: "go"
        )
        let swiftCore = TestLanguageServerRuntimeCore(providerID: "swift")
        let goCore = TestLanguageServerRuntimeCore(providerID: "go")
        let swiftSession = StdioLanguageServerSession(
            providerID: "swift",
            executableURL: URL(fileURLWithPath: "/usr/bin/sourcekit-lsp"),
            arguments: [],
            environment: [:],
            core: swiftCore
        )
        let goSession = StdioLanguageServerSession(
            providerID: "go",
            executableURL: URL(fileURLWithPath: "/usr/bin/gopls"),
            arguments: [],
            environment: [:],
            core: goCore
        )
        let manager = LanguageToolingSessionManager(
            catalog: LanguageProviderCatalog(descriptors: [swiftDescriptor, goDescriptor]),
            runtimes: [
                TestLanguageServerRuntime(descriptor: swiftDescriptor, session: swiftSession),
                TestLanguageServerRuntime(descriptor: goDescriptor, session: goSession)
            ]
        )

        try manager.synchronizeLanguageServer(for: swiftSource, text: "struct App {}\n", rootURL: root)
        swiftCore.enqueueReady()
        try manager.synchronizeLanguageServer(for: goSource, text: "package main\n", rootURL: root)
        goCore.enqueueReady()
        #expect(await Self.waitForMainActorCondition {
            manager.activeLanguageServerIDs == ["swift", "go"]
        })
        swiftCore.enqueueDiagnostics(for: swiftSource, message: "Swift warning")
        goCore.enqueueDiagnostics(for: goSource, message: "Go warning")
        #expect(await Self.waitForMainActorCondition { manager.diagnostics.count == 2 })

        #expect(manager.diagnostics(for: "swift")[swiftSource]?.count == 1)
        #expect(manager.diagnostics(for: "go")[goSource]?.count == 1)
        #expect(manager.diagnostics.count == 2)

        manager.stopLanguageServer(providerID: "swift")
        #expect(manager.diagnostics(for: "swift").isEmpty)
        #expect(manager.diagnostics(for: "go")[goSource]?.count == 1)
        #expect(manager.diagnostics.count == 1)

        goCore.enqueueFailure(
            code: "serverExited",
            message: "Language server exited",
            processExitCode: 7
        )
        #expect(await Self.waitForMainActorCondition {
            manager.diagnostics(for: "go").isEmpty
        })
        #expect(manager.diagnostics(for: "go").isEmpty)
        #expect(manager.diagnostics.isEmpty)

        try manager.synchronizeLanguageServer(for: goSource, text: "package main\n", rootURL: root)
        goCore.enqueueReady()
        #expect(await Self.waitForMainActorCondition {
            manager.languageServerStates["go"] == .ready
        })
        goCore.enqueueDiagnostics(for: goSource, message: "Go warning")
        #expect(await Self.waitForMainActorCondition {
            manager.diagnostics(for: "go")[goSource]?.count == 1
        })
        #expect(manager.diagnostics(for: "go")[goSource]?.count == 1)

        let reconfiguredGo = LanguageProviderDescriptor(
            id: goDescriptor.id,
            displayName: "Go (workspace override)",
            fileExtensions: goDescriptor.fileExtensions,
            fileNames: goDescriptor.fileNames,
            fileNamePrefixes: goDescriptor.fileNamePrefixes,
            capabilities: goDescriptor.capabilities,
            activationPolicy: goDescriptor.activationPolicy,
            languageIdentifier: goDescriptor.languageIdentifier,
            languageIdentifiersByExtension: goDescriptor.languageIdentifiersByExtension,
            languageIdentifiersByFileName: goDescriptor.languageIdentifiersByFileName,
            languageServerLaunch: goDescriptor.languageServerLaunch,
            languageServerInstallation: goDescriptor.languageServerInstallation
        )
        manager.updateCatalog(LanguageProviderCatalog(descriptors: [swiftDescriptor, reconfiguredGo]))

        #expect(manager.diagnostics(for: "go").isEmpty)
        #expect(manager.diagnostics.isEmpty)
    }

    @Test
    func languageServerRuntimeStartsFromRustCatalogLaunchMetadata() async throws {
        let descriptor = LanguageProviderDescriptor(
            id: "swift",
            displayName: "Swift",
            fileExtensions: ["swift"],
            capabilities: [.languageServer, .formatting],
            activationPolicy: .onDemand,
            languageIdentifier: "swift",
            languageServerLaunch: LanguageServerLaunchDescriptor(
                executableNames: ["sourcekit-lsp"],
                arguments: [],
                environment: ["SOURCEKIT_TOOLCHAIN": "custom"],
                initializationOptions: .object(["indexing": .bool(true)])
            )
        )
        let runtimeService = ProjectRuntimeService(runtimeLocator: RunTestRuntimeLocator())
        let process = RecordingRawProcessSession()
        let core = TestLanguageServerRuntimeCore(providerID: "swift")
        let root = URL(fileURLWithPath: "/tmp/swift-project", isDirectory: true)
        let source = root.appendingPathComponent("App.swift")
        let runtime = StdioLanguageProviderRuntime(
            descriptor: descriptor,
            runtimeService: runtimeService,
            languageServerLaunch: descriptor.languageServerLaunch,
            languageServerCore: core
        )
        let manager = LanguageToolingSessionManager(
            catalog: LanguageProviderCatalog(descriptors: [descriptor]),
            runtimes: [runtime]
        )

        try manager.synchronizeLanguageServer(
            for: source,
            text: "struct App {}\n",
            rootURL: root
        )
        #expect(await Self.waitForMainActorCondition {
            core.startCalls.count == 1
                && core.syncCalls.last?.fileURL == source.standardizedFileURL
        })
        let startCall = try #require(core.startCalls.first)
        #expect(startCall.providerID == "swift")
        #expect(startCall.executableURL.path == "/usr/bin/sourcekit-lsp")
        #expect(startCall.arguments.isEmpty)
        #expect(startCall.environment["SOURCEKIT_TOOLCHAIN"] == "custom")
        #expect(startCall.rootURL == root.standardizedFileURL)
        #expect(startCall.initializationOptions == .object(["indexing": .bool(true)]))
        #expect(process.requests.isEmpty)
        #expect(process.sentData.isEmpty)
        #expect(manager.activeLanguageServerIDs.isEmpty)
        #expect(manager.languageServerStates["swift"] == .initializing)

        core.enqueueReady(
            capabilities: [
                "hover", "completion", "completionResolve", "rename", "formatting",
                "codeActions", "codeActionResolve", "executeCommand", "inlayHints"
            ],
            serverInfo: (name: "sourcekit-lsp", version: "6.2")
        )
        #expect(await Self.waitForMainActorCondition {
            manager.languageServerStates["swift"] == .ready
        })
        #expect(manager.activeLanguageServerIDs == ["swift"])
        #expect(manager.languageServerStates["swift"] == .ready)
        #expect(manager.languageServerInfos["swift"] == LanguageServerInfo(
            name: "sourcekit-lsp",
            version: "6.2"
        ))
        #expect(manager.languageServerFeatures["swift"]?.contains(.completion) == true)
        #expect(manager.languageServerFeatures["swift"]?.contains(.hover) == true)
        #expect(core.syncCalls.last?.text == "struct App {}\n")

        core.enqueueDiagnostics(for: source, message: "example warning")
        #expect(await Self.waitForMainActorCondition {
            manager.diagnostics[source.standardizedFileURL]?.first?.message == "example warning"
        })
        #expect(manager.diagnostics[source.standardizedFileURL]?.first?.message == "example warning")

        // Inline hints use the existing semantic request route and preserve UTF-16 coordinates.
        #expect(manager.languageServerFeatures["swift"]?.contains(.inlayHints) == true)
        var hintsResult: Result<[LanguageServerInlayHint], Error>?
        try manager.inlayHints(fileURL: source,
            range: LanguageServerRange(start: .init(line: 0, utf16Column: 0), end: .init(line: 1, utf16Column: 0))) {
                hintsResult = $0
            }
        core.enqueueRequestSuccess(operation: .inlayHints, result: ["hints": [[
            "position": ["line": 0, "utf16Column": 12], "label": "value:", "kind": 2,
            "tooltip": "Parameter name", "paddingLeft": true, "paddingRight": false,
            "textEdits": [["range": ["start": ["line": 0, "utf16Column": 12],
                                      "end": ["line": 0, "utf16Column": 12]], "newText": "value: "]]
        ]]])
        #expect(await Self.waitForMainActorCondition { hintsResult != nil })
        let hint = try #require(hintsResult?.get().first)
        #expect(hint.position.utf16Column == 12)
        #expect(hint.kind == 2 && hint.label == "value:")
        #expect(hint.tooltip == "Parameter name" && hint.paddingLeft && !hint.paddingRight)
        #expect(hint.textEdits.first?.newText == "value: ")

        var completionsResult: Result<LanguageServerCompletionList, Error>?
        try manager.completionList(
            fileURL: source,
            text: "struct App { let tit }\n",
            position: LanguageServerPosition(line: 0, utf16Column: 20),
            rootURL: root, completionContext: .init(triggerKind: 3)
        ) { result in
            completionsResult = result
        }
        core.enqueueRequestSuccess(operation: .completion, result: [
            "isIncomplete": true,
            "items": [[
                "label": "title",
                "insertText": "title",
                "kind": 6,
                "detail": "String"
            ]]
        ])
        #expect(await Self.waitForMainActorCondition { completionsResult != nil })
        #expect(try completionsResult?.get().items.first?.label == "title")
        #expect(try completionsResult?.get().isIncomplete == true)
        #expect(core.requestCalls.last?.completionContext?.triggerKind == 3)
        #expect(core.requestCalls.last(where: { $0.operation == .completion })?.operationID != nil)

        var completionResolveResult: Result<LanguageServerCompletionItem, Error>?
        try manager.resolveCompletion(
            LanguageServerCompletionItem(
                label: "title",
                detail: nil,
                documentation: nil,
                insertText: "title",
                sortText: nil,
                filterText: nil,
                kind: 6,
                textEdit: nil,
                additionalTextEdits: [],
                data: .object(["id": .string("completion-1")])
            ),
            fileURL: source,
            text: "struct App { let ti = 1 }\n",
            rootURL: root
        ) { result in
            completionResolveResult = result
        }
        core.enqueueRequestSuccess(operation: .resolveCompletion, result: [
            "item": [
                "label": "title",
                "insertText": "title",
                "kind": 6,
                "detail": "String",
                "documentation": "Resolved docs"
            ]
        ])
        #expect(await Self.waitForMainActorCondition { completionResolveResult != nil })
        #expect(try completionResolveResult?.get().documentation == "Resolved docs")

        var renameResult: Result<LanguageServerWorkspaceEdit, Error>?
        try manager.rename(
            fileURL: source,
            text: "struct App { let title = 1 }\n",
            position: LanguageServerPosition(line: 0, utf16Column: 17),
            newName: "headline",
            rootURL: root
        ) { result in
            renameResult = result
        }
        core.enqueueRequestSuccess(operation: .rename, result: [
            "changes": [
                source.standardizedFileURL.path: [[
                    "range": [
                        "start": ["line": 0, "utf16Column": 17],
                        "end": ["line": 0, "utf16Column": 22]
                    ],
                    "newText": "headline"
                ]]
            ]
        ])
        #expect(await Self.waitForMainActorCondition { renameResult != nil })
        #expect(try renameResult?.get().changes[source.standardizedFileURL]?.first?.newText == "headline")

        var formatResult: Result<[LanguageServerTextEdit], Error>?
        try manager.format(
            fileURL: source,
            text: "struct App{ }\n",
            rootURL: root
        ) { result in
            formatResult = result
        }
        core.enqueueRequestSuccess(operation: .formatting, result: [
            "edits": [[
                "range": [
                    "start": ["line": 0, "utf16Column": 10],
                    "end": ["line": 0, "utf16Column": 10]
                ],
                "newText": " "
            ]]
        ])
        #expect(await Self.waitForMainActorCondition { formatResult != nil })
        #expect(try formatResult?.get().first?.newText == " ")

        var actionsResult: Result<[LanguageServerCodeAction], Error>?
        try manager.codeActions(
            fileURL: source,
            text: "struct App{ }\n",
            range: LanguageServerRange(
                start: LanguageServerPosition(line: 0, utf16Column: 0),
                end: LanguageServerPosition(line: 0, utf16Column: 0)
            ),
            diagnostics: [
                LanguageServerDiagnostic(
                    range: LanguageServerRange(
                        start: LanguageServerPosition(line: 0, utf16Column: 7),
                        end: LanguageServerPosition(line: 0, utf16Column: 10)
                    ),
                    severity: 2,
                    message: "example warning",
                    source: "sourcekit-lsp",
                    code: nil
                )
            ],
            rootURL: root
        ) { result in
            actionsResult = result
        }
        core.enqueueRequestSuccess(operation: .codeActions, result: [
            "actions": [[
                "title": "Fix warning",
                "kind": "quickfix",
                "isPreferred": true,
                "command": [
                    "title": "Apply fix",
                    "command": "source.fix",
                    "arguments": [["uri": source.standardizedFileURL.absoluteString]]
                ],
                "data": ["token": "fix-1"]
            ]]
        ])
        #expect(await Self.waitForMainActorCondition { actionsResult != nil })
        let actions = try actionsResult?.get()
        #expect(actions?.first?.title == "Fix warning")
        #expect(actions?.first?.command?.command == "source.fix")

        var actionResolveResult: Result<LanguageServerCodeAction, Error>?
        try manager.resolveCodeAction(
            LanguageServerCodeAction(
                title: "Fix warning",
                kind: "quickfix",
                isPreferred: true,
                edit: nil,
                command: nil,
                data: .object(["token": .string("fix-1")])
            ),
            fileURL: source,
            text: "struct App{ }\n",
            rootURL: root
        ) { result in
            actionResolveResult = result
        }
        core.enqueueRequestSuccess(operation: .resolveCodeAction, result: [
            "action": [
                "title": "Fix warning",
                "kind": "quickfix",
                "isPreferred": true,
                "edit": [
                    "changes": [
                        source.standardizedFileURL.path: [[
                            "range": [
                                "start": ["line": 0, "utf16Column": 10],
                                "end": ["line": 0, "utf16Column": 10]
                            ],
                            "newText": " "
                        ]]
                    ]
                ],
                "data": ["token": "fix-1"]
            ]
        ])
        #expect(await Self.waitForMainActorCondition { actionResolveResult != nil })
        #expect(try actionResolveResult?.get().edit?.changes[source.standardizedFileURL]?.first?.newText == " ")

        var executeResult: Result<Void, Error>?
        try manager.execute(
            LanguageServerCommand(
                title: "Apply fix",
                command: "source.fix",
                arguments: [.object(["uri": .string(source.standardizedFileURL.absoluteString)])]
            ),
            fileURL: source,
            text: "struct App{ }\n",
            rootURL: root
        ) { result in
            executeResult = result
        }
        let executeCall = try #require(core.requestCalls.last)
        #expect(executeCall.operation == .executeCommand)
        #expect(executeCall.fileURL == nil)
        #expect(executeCall.command?.command == "source.fix")
        core.enqueueRequestSuccess(operation: .executeCommand, result: [
            "value": ["ok": true],
        ])
        #expect(await Self.waitForMainActorCondition { executeResult != nil })
        #expect(executeResult != nil)
        try executeResult?.get()

        manager.closeDocument(source)
        #expect(core.closeCalls.last?.fileURL == source.standardizedFileURL)
        manager.stopLanguageServer(providerID: "swift")
        #expect(core.stopCalls.count == 1)
        #expect(await Self.waitForMainActorCondition { core.destroyedSessionIDs.count == 1 })
    }

    @Test
    func repeatedStartupFailuresStopUntilExplicitRestart() async throws {
        let harness = makeLanguageServerHarness(policyCore: RustCoreBridge())
        var now: UInt64 = 0
        harness.manager.monotonicNowMs = { now }
        defer { harness.manager.stopAll() }
        for _ in 0..<3 {
            let failed = TestGate()
            harness.manager.onLanguageServerStateChange = { _, state, _ in
                if case .failed = state { failed.open() }
            }
            try harness.manager.synchronizeLanguageServer(for: harness.source, text: "struct App {}", rootURL: harness.root)
            harness.core.enqueueFailure(code: "serverExited", message: "startup failed")
            #expect(await failed.waitUntilOpen())
            now += 5_000
        }
        #expect(harness.core.startCalls.count == 3)
        for _ in 0..<5 {
            #expect(throws: LanguageServerSessionStartError.self) {
                try harness.manager.synchronizeLanguageServer(for: harness.source, text: "struct App {}", rootURL: harness.root)
            }
        }
        #expect(harness.core.startCalls.count == 3)
        harness.manager.stopLanguageServer(providerID: "swift")
        try harness.manager.synchronizeLanguageServer(for: harness.source, text: "struct App {}", rootURL: harness.root)
        #expect(harness.core.startCalls.count == 4)
    }

    @Test
    func virtualDocumentContentProjectsFromRustEvents() async throws {
        let core = TestLanguageServerRuntimeCore(providerID: "java")
        let session = StdioLanguageServerSession(
            providerID: "java",
            executableURL: URL(fileURLWithPath: "/test-tools/jdtls"),
            arguments: [],
            environment: [:],
            core: core
        )
        try session.start(rootURL: URL(fileURLWithPath: "/test-workspace", isDirectory: true))
        core.enqueueReady(capabilities: ["executeCommand"])
        #expect(await Self.waitForMainActorCondition {
            session.features.contains(.executeCommand)
        })

        let uri = "jdt://contents/java.base/java/lang/String.class"
        var result: Result<String, Error>?
        try session.resolveVirtualDocument(uri: uri) { result = $0 }
        let call = try #require(core.requestCalls.last)
        #expect(call.operation == .virtualDocument)
        #expect(call.fileURL == nil)
        #expect(call.virtualURI == uri)

        core.enqueueRequestSuccess(
            operation: .virtualDocument,
            result: ["text": "public final class String {}"]
        )
        #expect(await Self.waitForMainActorCondition { result != nil })
        #expect(try result?.get() == "public final class String {}")
        session.stop()
    }

    @Test
    func stoppingToolingSessionsClearsProjectScopedBreakpoints() throws {
        // Breakpoint cleanup must not depend on the product's installed debug providers.
        let descriptor = LanguageProviderDescriptor(
            id: "python", displayName: "Python", fileExtensions: ["py"],
            capabilities: [.debugAdapter], activationPolicy: .onDemand
        )
        let catalog = LanguageProviderCatalog(descriptors: [descriptor])
        let runtime = TestDebugLanguageProviderRuntime(descriptor: descriptor)
        let manager = DebugAdapterSessionManager(
            providers: catalog.debugProviders,
            makeSession: { descriptor, rootURL in
                descriptor.id == runtime.descriptor.id
                    ? runtime.makeSession()
                    : nil
            }
        )
        defer { manager.stopAll() }
        let firstRoot = URL(fileURLWithPath: "/tmp/first-python-project")
        let firstSource = firstRoot.appendingPathComponent("main.py")
        try manager.setBreakpoints([DebugSourceBreakpoint(line: 12)], in: firstSource)

        _ = try manager.activate(for: firstSource, rootURL: firstRoot)
        #expect(runtime.debugAdapters.first?.breakpointUpdates.count == 1)
        manager.stopAll()

        let secondRoot = URL(fileURLWithPath: "/tmp/second-python-project")
        _ = try manager.activate(
            for: secondRoot.appendingPathComponent("main.py"),
            rootURL: secondRoot
        )
        #expect(runtime.debugAdapters.count == 2)
        #expect(runtime.debugAdapters.last?.breakpointUpdates.isEmpty == true)
    }

    @Test
    func breakpointBindingUsesRequestedIdentityWhenTheAdapterMovesItsLocation() throws {
        let adapter = TestDebugAdapterSession()
        let manager = DebugAdapterSessionManager(providers: LanguageProviderCatalog.standard.debugProviders) { _, _ in adapter }
        defer { manager.stopAll() }
        let feature = GenericDebugFeatureModel(paging: RustCoreBridge(), sessions: manager)
        let root = URL(fileURLWithPath: "/workspace")
        let source = root.appendingPathComponent("example.go")
        feature.toggleBreakpoint(fileURL: source, line: 3)
        #expect(feature.start(fileURL: source, rootURL: root,
            configuration: DebugLaunchConfiguration(name: "example", request: .launch, arguments: [:])))
        adapter.onEvent?(.breakpoint(DebugBreakpoint(id: 41, verified: true, message: nil,
            sourceURL: source, line: 5, column: nil, requestedLine: 3)))
        let point = try #require(feature.breakpoints.first)
        #expect(point.line == 3 && point.resolvedLine == 5 && point.verified)
        feature.toggleBreakpoint(fileURL: source, line: 7)
        #expect(feature.breakpoints.first?.resolvedLine == 5)
        feature.toggleBreakpoint(fileURL: source, line: 5)
        #expect(feature.breakpoints.map(\.line) == [7])
        #expect(adapter.breakpointUpdates.last?.1.map(\.line) == [7])
    }

    @Test
    func generationSucceedsWithoutWritingTheWorkspace() throws {
        let core = RustCoreBridge()
        guard core.isAvailable else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-generation-read-only-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        let source = root.appendingPathComponent("src/App.java")
        try Data("class App { public static void main(String[] args) {} }".utf8).write(to: source)
        let storage = CountingFileStorage(root: root)
        storage.shouldFailWrites = true
        let store = MacRunConfigurationStore(
            core: core,
            storage: storage,
            preferences: RunTestKeyValueStore()
        )

        let result = try store.generate(at: root, providerRuns: nil)
        #expect(result.entryCount == 0)
        #expect(storage.writeCount == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".lithe").path))
        #expect(store.inspect(at: root).status == .ready)
    }

    @Test
    func unchangedLocalOptionsDoNotRewriteTheConfigurationFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-unchanged-write-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = CountingFileStorage(root: root)
        let store = MacRunConfigurationStore(
            core: RustCoreBridge(),
            storage: storage,
            preferences: RunTestKeyValueStore(),
            documentMutator: RunTestDocumentMutator()
        )
        let options = RunOptions(
            workingDirectoryPath: "backend app",
            programArguments: "--dev"
        )

        try store.saveOptions(
            options,
            configurationID: "spring:com.example.App",
            scope: .local,
            at: root
        )
        let writesAfterFirstSave = storage.writeCount
        try store.saveOptions(
            options,
            configurationID: "spring:com.example.App",
            scope: .local,
            at: root
        )

        #expect(writesAfterFirstSave == 1)
        #expect(storage.writeCount == writesAfterFirstSave)
    }

    @Test
    func failedAtomicWritePreservesExistingLocalConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-failed-write-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = CountingFileStorage(root: root)
        let localURL = root.appendingPathComponent(".lithe/run/local.json")
        let original = Data(#"{"version":1,"configurations":[]}"#.utf8)
        storage.seed(original, at: localURL)
        storage.shouldFailWrites = true
        let store = MacRunConfigurationStore(
            core: RustCoreBridge(),
            storage: storage,
            preferences: RunTestKeyValueStore(),
            documentMutator: RunTestDocumentMutator()
        )

        #expect(throws: (any Error).self) {
            try store.saveOptions(
                RunOptions(programArguments: "-Xmx2g"),
                configurationID: "current-file",
                scope: .local,
                at: root
            )
        }
        #expect(try storage.readData(from: localURL, options: []) == original)
    }

    @Test
    func inspectionErrorsMapToSafeRecoveryActionsAndFiles() {
        #expect(MacRunConfigurationStore.recoveryAction(for: "not_supported") == .upgradeApplication)
        #expect(MacRunConfigurationStore.recoveryAction(for: "parse_failed") == .editConfiguration)
        #expect(MacRunConfigurationStore.recoveryAction(for: "permission_denied") == .fixPermissions)
        #expect(MacRunConfigurationStore.recoveryPath(
            in: "Configuration JSON is invalid: .lithe/run/local.json: line 1"
        ) == ".lithe/run/local.json")
        #expect(MacRunConfigurationStore.recoveryPath(
            in: "Configuration JSON is invalid: .lithe/toolchains/local.json: line 1"
        ) == nil)
    }

    @Test
    func appOwnedFileEventSuppressionIsOneShotAndExpires() {
        let first = URL(fileURLWithPath: "/tmp/lithe-self-write-one.json")
        let second = URL(fileURLWithPath: "/tmp/lithe-self-write-two.json")
        let now = Date(timeIntervalSince1970: 1_000)

        MacFileWriteEventSuppression.markWritten(first, now: now)
        #expect(MacFileWriteEventSuppression.consume(first, now: now.addingTimeInterval(1)))
        #expect(!MacFileWriteEventSuppression.consume(first, now: now.addingTimeInterval(1)))

        MacFileWriteEventSuppression.markWritten(second, now: now)
        #expect(!MacFileWriteEventSuppression.consume(second, now: now.addingTimeInterval(3)))
    }

    private static func framedJSON(_ data: Data?) -> [String: Any]? {
        guard let data,
              let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let body = data.subdata(in: separator.upperBound..<data.endIndex)
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    private func makeLanguageServerHarness(
        initializeTimeoutNanoseconds: UInt64 = 10_000_000_000,
        requestTimeoutNanoseconds: UInt64 = 30_000_000_000,
        policyCore: (any LanguageToolingPolicyCore)? = nil
    ) -> LanguageServerReliabilityHarness {
        let descriptor = LanguageProviderDescriptor(
            id: "swift",
            displayName: "Swift",
            fileExtensions: ["swift"],
            capabilities: [.languageServer, .formatting],
            activationPolicy: .onDemand,
            languageIdentifier: "swift"
        )
        let root = URL(fileURLWithPath: "/tmp/lithe-lsp-reliability", isDirectory: true)
        let source = root.appendingPathComponent("App.swift")
        let core = TestLanguageServerRuntimeCore(providerID: "swift")
        let session = StdioLanguageServerSession(
            providerID: "swift",
            executableURL: URL(fileURLWithPath: "/usr/bin/sourcekit-lsp"),
            arguments: [],
            environment: [:],
            initializeTimeout: TimeInterval(initializeTimeoutNanoseconds) / 1_000_000_000,
            requestTimeout: TimeInterval(requestTimeoutNanoseconds) / 1_000_000_000,
            core: core
        )
        let runtime = TestLanguageServerRuntime(descriptor: descriptor, session: session)
        let manager = LanguageToolingSessionManager(
            catalog: LanguageProviderCatalog(descriptors: [descriptor]),
            runtimes: [runtime], policyCore: policyCore
        )
        return LanguageServerReliabilityHarness(
            root: root,
            source: source,
            core: core,
            session: session,
            manager: manager
        )
    }

    private static func debugRequest(named command: String, in frames: [Data]) -> [String: Any]? {
        frames.lazy
            .compactMap(framedJSON)
            .first { message in
                message["type"] as? String == "request" && message["command"] as? String == command
            }
    }

    private static func drainMainActorTasks() async {
        await Task.yield()
        await Task.yield()
    }

    private static func waitForMainActorCondition(
        attempts: Int = 100,
        _ condition: () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
            await Task.yield()
        }
        return condition()
    }
}

@MainActor
private struct LanguageServerReliabilityHarness {
    let root: URL
    let source: URL
    let core: TestLanguageServerRuntimeCore
    let session: StdioLanguageServerSession
    let manager: LanguageToolingSessionManager
}

private final class RecordingStreamingProcess: StreamingProcess, @unchecked Sendable {
    var isRunning = false
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (ProcessLifecycleEvent) -> Void)?
    private(set) var requests: [ProcessRequest] = []
    private(set) var stopCount = 0

    func start(_ request: ProcessRequest) throws {
        requests.append(request)
        isRunning = true
    }
    func send(_ input: Data) throws {}
    func stop() {
        stopCount += 1
        isRunning = false
    }
}

@MainActor
private final class RecordingRunExecutableResolver: RunExecutableResolving {
    private(set) var resolveCalls = 0

    func resolve(
        _ plan: SharedLaunchPlan,
        projectURL: URL,
        options: RunOptions
    ) throws -> ResolvedRunExecutable {
        resolveCalls += 1
        return ResolvedRunExecutable(
            executableURL: URL(fileURLWithPath: "/usr/bin/go"),
            environment: [:]
        )
    }
}

private final class TestLanguageServerRuntimeCore: LanguageServerRuntimeCore, @unchecked Sendable {
    struct StartCall {
        let providerID: String
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]
        let rootURL: URL
        let workingDirectoryURL: URL
        let initializationOptions: ToolingJSONValue?
        let initializeTimeout: TimeInterval
        let requestTimeout: TimeInterval
        let shutdownTimeout: TimeInterval
    }

    struct SyncCall {
        let sessionID: String
        let fileURL: URL
        let languageID: String
        let text: String
    }

    struct FileCall {
        let sessionID: String
        let fileURL: URL
    }

    struct RequestCall {
        let sessionID: String
        let operationID: String
        let operation: LanguageServerOperation
        let fileURL: URL?
        let virtualURI: String?
        let position: LanguageServerPosition?
        let newName: String?
        let range: LanguageServerRange?
        let diagnostics: [LanguageServerDiagnostic]
        let completionContext: LanguageServerCompletionContext?
        let completionItem: LanguageServerCompletionItem?
        let codeAction: LanguageServerCodeAction?
        let command: LanguageServerCommand?
    }

    struct CancelCall {
        let sessionID: String
        let operationID: String
    }

    private let providerID: String
    private let sessionID: String
    private var nextOperationNumber = 1
    private var events: [LanguageServerRuntimeEvent] = []

    private(set) var startCalls: [StartCall] = []
    private(set) var stopCalls: [String] = []
    private(set) var syncCalls: [SyncCall] = []
    private(set) var closeCalls: [FileCall] = []
    private(set) var requestCalls: [RequestCall] = []
    private(set) var cancelCalls: [CancelCall] = []
    private(set) var destroyedSessionIDs: [String] = []

    init(providerID: String = "swift", sessionID: String? = nil) {
        self.providerID = providerID
        self.sessionID = sessionID ?? "test-\(providerID)-session"
    }

    func requiresBackgroundLanguageServerStart(rootURL _: URL) -> Bool { false }

    func startLanguageServer(
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        workingDirectoryURL: URL,
        initializationOptions: ToolingJSONValue?,
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        startCalls.append(StartCall(
            providerID: providerID,
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            rootURL: rootURL,
            workingDirectoryURL: workingDirectoryURL,
            initializationOptions: initializationOptions,
            initializeTimeout: initializeTimeout,
            requestTimeout: requestTimeout,
            shutdownTimeout: shutdownTimeout
        ))
        return .success(LanguageServerRuntimeStart(
            sessionID: sessionID,
            state: "initializing",
            processID: nil
        ))
    }

    func stopLanguageServer(sessionID: String) {
        stopCalls.append(sessionID)
        enqueueEvent(type: "stateChanged", fields: ["state": "stopped"])
    }

    func syncLanguageServerDocument(
        sessionID: String,
        fileURL: URL,
        languageID: String,
        text: String
    ) -> Result<LanguageServerDocumentSync, LanguageServerRuntimeFailure> {
        syncCalls.append(SyncCall(
            sessionID: sessionID,
            fileURL: fileURL,
            languageID: languageID,
            text: text
        ))
        return .success(LanguageServerDocumentSync(
            documentVersion: syncCalls.count,
            changed: true
        ))
    }

    func closeLanguageServerDocument(sessionID: String, fileURL: URL) {
        closeCalls.append(FileCall(sessionID: sessionID, fileURL: fileURL))
    }

    func requestLanguageServerOperation(
        sessionID: String,
        operation: LanguageServerOperation,
        fileURL: URL?,
        virtualURI: String?,
        position: LanguageServerPosition?,
        newName: String?,
        range: LanguageServerRange?,
        diagnostics: [LanguageServerDiagnostic],
        completionContext: LanguageServerCompletionContext?, completionItem: LanguageServerCompletionItem?,
        codeAction: LanguageServerCodeAction?,
        command: LanguageServerCommand?
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        let operationID = "operation-\(nextOperationNumber)"
        nextOperationNumber += 1
        requestCalls.append(RequestCall(
            sessionID: sessionID,
            operationID: operationID,
            operation: operation,
            fileURL: fileURL,
            virtualURI: virtualURI,
            position: position,
            newName: newName,
            range: range,
            diagnostics: diagnostics,
            completionContext: completionContext,
            completionItem: completionItem,
            codeAction: codeAction,
            command: command
        ))
        return .success(LanguageServerRuntimeOperation(operationID: operationID))
    }

    func cancelLanguageServerOperation(sessionID: String, operationID: String) {
        cancelCalls.append(CancelCall(sessionID: sessionID, operationID: operationID))
    }

    func pollLanguageServerEvents(sessionID _: String) -> [LanguageServerRuntimeEvent] {
        defer { events.removeAll() }
        return events
    }

    func destroyLanguageServer(sessionID: String) {
        destroyedSessionIDs.append(sessionID)
    }

    func enqueueReady(
        capabilities: [String] = ["completion", "hover"],
        serverInfo: (name: String, version: String?)? = nil
    ) {
        if !capabilities.isEmpty {
            events.append(LanguageServerRuntimeEvent(
                type: "featuresChanged",
                capabilities: capabilities
            ))
        }
        if let serverInfo {
            events.append(LanguageServerRuntimeEvent(
                type: "serverInfoChanged",
                serverInfo: LanguageServerInfo(
                    name: serverInfo.name,
                    version: serverInfo.version
                )
            ))
        }
        events.append(LanguageServerRuntimeEvent(type: "stateChanged", state: "ready"))
    }

    func enqueueFailure(
        code: String,
        message: String,
        underlyingMessage: String? = nil,
        processExitCode: Int? = nil
    ) {
        events.append(LanguageServerRuntimeEvent(
            type: "stateChanged",
            state: "failed",
            error: runtimeError(
                code: code,
                message: message,
                underlyingMessage: underlyingMessage,
                processExitCode: processExitCode
            )
        ))
    }

    func enqueueRequestSuccess(operation: LanguageServerOperation, result: Any) {
        guard let call = requestCalls.last(where: { $0.operation == operation }) else {
            preconditionFailure("No recorded request for \(operation.rawValue)")
        }
        events.append(LanguageServerRuntimeEvent(
            type: "requestCompleted",
            operationID: call.operationID,
            result: Self.jsonValue(result)
        ))
    }

    func enqueueRequestFailure(
        operation: LanguageServerOperation,
        code: String,
        message: String,
        underlyingMessage: String? = nil,
        processExitCode: Int? = nil
    ) {
        guard let call = requestCalls.last(where: { $0.operation == operation }) else {
            preconditionFailure("No recorded request for \(operation.rawValue)")
        }
        events.append(LanguageServerRuntimeEvent(
            type: "requestCompleted",
            operationID: call.operationID,
            error: runtimeError(
                code: code,
                message: message,
                underlyingMessage: underlyingMessage,
                processExitCode: processExitCode
            )
        ))
    }

    func enqueueDiagnostics(for fileURL: URL, message: String) {
        events.append(LanguageServerRuntimeEvent(
            type: "diagnostics",
            uri: fileURL.standardizedFileURL.absoluteString,
            diagnostics: [LanguageServerDiagnostic(
                range: LanguageServerRange(
                    start: LanguageServerPosition(line: 0, utf16Column: 7),
                    end: LanguageServerPosition(line: 0, utf16Column: 10)
                ),
                severity: 2,
                message: message,
                source: "test-language-server",
                code: nil
            )]
        ))
    }

    private func enqueueEvent(type: String, fields: [String: Any]) {
        events.append(LanguageServerRuntimeEvent(
            type: type,
            state: fields["state"] as? String,
            operationID: fields["operationId"] as? String,
            uri: fields["uri"] as? String,
            result: fields["result"].flatMap(Self.jsonValue),
            capabilities: fields["capabilities"] as? [String],
            message: fields["message"] as? String,
            detail: fields["detail"] as? String
        ))
    }

    private func runtimeError(
        code: String,
        message: String,
        underlyingMessage: String?,
        processExitCode: Int?
    ) -> LanguageServerRuntimeError {
        return LanguageServerRuntimeError(
            code: code,
            stage: "test",
            message: message,
            underlyingMessage: underlyingMessage,
            processExitCode: processExitCode
        )
    }

    private static func jsonValue(_ object: Any) -> ToolingJSONValue? {
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(ToolingJSONValue.self, from: data)
        } catch {
            return nil
        }
    }
}

private final class RecordingRawProcessSession: RawProcessSession, @unchecked Sendable {
    var isRunning = false
    var onOutput: (@Sendable (Data) -> Void)?
    var onError: (@Sendable (Data) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (ProcessLifecycleEvent) -> Void)?
    private(set) var requests: [ProcessRequest] = []
    private(set) var sentData: [Data] = []
    var sendFailurePredicate: ((Data) -> Bool)?

    func start(_ request: ProcessRequest) throws {
        requests.append(request)
        isRunning = true
    }
    func send(_ input: Data) throws {
        if sendFailurePredicate?(input) == true {
            throw RecordingRawProcessSessionError.sendFailed
        }
        sentData.append(input)
    }
    func stop() { isRunning = false }

    func terminate(exitCode: Int32) {
        isRunning = false
        onStateChange?(ProcessLifecycleEvent(
            operationID: requests.last?.operationID,
            state: .finished,
            exitCode: exitCode,
            message: nil
        ))
        onTermination?(exitCode)
    }

    func emitJSON(_ object: [String: Any], splitAt: Int? = nil) {
        let body = try! JSONSerialization.data(withJSONObject: object)
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        if let splitAt, splitAt > 0, splitAt < framed.count {
            onOutput?(framed.subdata(in: 0..<splitAt))
            onOutput?(framed.subdata(in: splitAt..<framed.count))
        } else {
            onOutput?(framed)
        }
    }
}

private enum RecordingRawProcessSessionError: LocalizedError {
    case sendFailed

    var errorDescription: String? { "Injected language server transport write failure." }
}

private final class RecordingProcessFactory: @unchecked Sendable {
    private(set) var processes: [RecordingStreamingProcess] = []

    func make() -> RecordingStreamingProcess {
        let process = RecordingStreamingProcess()
        processes.append(process)
        return process
    }
}

private final class ToolchainVersionProcessRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []

    var executedCommands: [String] {
        lock.withLock { commands }
    }

    func run(_ request: ProcessRequest) -> ProcessResult {
        let command = URL(fileURLWithPath: request.executablePath).lastPathComponent
        lock.withLock { commands.append(command) }
        let output: String
        switch command {
        case "go": output = "go version go1.24.3 darwin/arm64"
        case "python3": output = "Python 3.13.5"
        case "node": output = "v22.18.0"
        case "rustc": output = "rustc 1.89.0 (29483883e 2025-08-04)"
        default: output = ""
        }
        return ProcessResult(output: output, exitCode: output.isEmpty ? 1 : 0)
    }
}

private struct RunTestRuntimeLocator: RuntimeLocator {
    func environment() -> [String: String] { ["PATH": "/usr/bin"] }
    func isExecutable(at url: URL) -> Bool { true }
}

private struct XcrunOnlyRuntimeLocator: RuntimeLocator {
    func environment() -> [String: String] { ["PATH": "/usr/bin"] }
    func isExecutable(at url: URL) -> Bool { url.path == "/usr/bin/xcrun" }
}

@MainActor
private final class TestDebugAdapterSession: DebugAdapterControllingSession {
    private(set) var isRunning = false
    var state: DebugAdapterState { isRunning ? .ready : .idle }
    var onStateChange: ((DebugAdapterState) -> Void)?
    var onEvent: ((DebugAdapterEvent) -> Void)?
    private(set) var breakpointUpdates: [(URL, [DebugSourceBreakpoint])] = []

    func start(rootURL: URL) throws { isRunning = true }
    func stop() { isRunning = false }
    func launch(_ configuration: DebugLaunchConfiguration) throws {}
    func setBreakpoints(_ breakpoints: [DebugSourceBreakpoint], in fileURL: URL) {
        breakpointUpdates.append((fileURL.standardizedFileURL, breakpoints))
    }
    func execute(_ command: DebugExecutionCommand, threadID: Int?) {}
    func requestThreads(_ completion: @escaping (Result<[DebugThread], Error>) -> Void) {
        completion(.success([]))
    }
    func requestStackTrace(
        threadID: Int,
        completion: @escaping (Result<[DebugStackFrame], Error>) -> Void
    ) { completion(.success([])) }
    func requestScopes(
        frameID: Int,
        completion: @escaping (Result<[DebugScope], Error>) -> Void
    ) { completion(.success([])) }
    func requestVariables(
        reference: Int,
        completion: @escaping (Result<[DebugVariable], Error>) -> Void
    ) { completion(.success([])) }
    func evaluate(
        _ expression: String,
        frameID: Int?,
        completion: @escaping (Result<DebugVariable, Error>) -> Void
    ) {}
}

private final class RestoredBreakpointPersistence: DebugBreakpointPersisting, @unchecked Sendable {
    private let snapshot: DebugBreakpointSnapshot

    init(snapshot: DebugBreakpointSnapshot) {
        self.snapshot = snapshot
    }

    func loadBreakpoints(for workspaceURL: URL) throws -> DebugBreakpointSnapshot? {
        snapshot
    }

    func saveBreakpoints(_ snapshot: DebugBreakpointSnapshot, for workspaceURL: URL) throws {}
}

@MainActor
private final class TestDebugLanguageProviderRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    private(set) var debugAdapters: [TestDebugAdapterSession] = []

    init(descriptor: LanguageProviderDescriptor, supportsDebugAdapter: Bool = false) {
        self.descriptor = descriptor
        _ = supportsDebugAdapter
    }

    func makeSession() -> (any DebugAdapterSession)? {
        let session = TestDebugAdapterSession()
        debugAdapters.append(session)
        return session
    }
}

@MainActor
private final class TestLanguageServerRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    let supportsLanguageServerSession = true
    private let session: any LanguageServerSession

    init(descriptor: LanguageProviderDescriptor, session: any LanguageServerSession) {
        self.descriptor = descriptor
        self.session = session
    }

    func makeLanguageServerSession() -> (any LanguageServerSession)? { session }
}

@MainActor
private final class TestLanguageProviderRuntimeFactory: LanguageProviderRuntimeFactory {
    private(set) var createdDescriptors: [LanguageProviderDescriptor] = []

    func makeRuntime(
        for descriptor: LanguageProviderDescriptor
    ) -> (any LanguageProviderRuntime)? {
        createdDescriptors.append(descriptor)
        return TestDebugLanguageProviderRuntime(
            descriptor: descriptor,
            supportsDebugAdapter: true
        )
    }
}

@MainActor
private final class TestDebugSocketConnection: DebugAdapterSocketConnection {
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onComplete: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var sent: [Data] = []

    func start() { startCount += 1 }
    func send(_ data: Data, completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        sent.append(data)
        completion(.success(()))
    }
    func stop() { stopCount += 1 }
}

@MainActor
private final class JavaDebugPortGate {
    private var requestedRoot: URL?
    private var requestWaiters: [CheckedContinuation<URL, Never>] = []
    private var portContinuation: CheckedContinuation<UInt16, Error>?
    private var cancelled = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func resolve(rootURL: URL) async throws -> UInt16 {
        requestedRoot = rootURL.standardizedFileURL
        let waiters = requestWaiters
        requestWaiters = []
        waiters.forEach { $0.resume(returning: rootURL.standardizedFileURL) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                portContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func waitUntilRequested() async -> URL {
        if let requestedRoot { return requestedRoot }
        return await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func succeed(port: UInt16) {
        let continuation = portContinuation
        portContinuation = nil
        continuation?.resume(returning: port)
    }

    func waitUntilCancelled() async {
        if cancelled { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    private func cancel() {
        guard !cancelled else { return }
        cancelled = true
        let portContinuation = portContinuation
        self.portContinuation = nil
        portContinuation?.resume(throwing: CancellationError())
        let waiters = cancellationWaiters
        cancellationWaiters = []
        waiters.forEach { $0.resume() }
    }
}

@MainActor
private final class DebugEndpointRecorder {
    struct Endpoint {
        let host: String
        let port: UInt16
    }

    private var endpoint: Endpoint?
    private var waiters: [CheckedContinuation<Endpoint, Never>] = []
    var didRecord: Bool { endpoint != nil }

    func record(host: String, port: UInt16) {
        let endpoint = Endpoint(host: host, port: port)
        self.endpoint = endpoint
        let waiters = waiters
        self.waiters = []
        waiters.forEach { $0.resume(returning: endpoint) }
    }

    func waitUntilRecorded() async -> Endpoint {
        if let endpoint { return endpoint }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private struct RunTestFileStorage: FileStorage {
    func homeDirectory() -> URL { URL(fileURLWithPath: "/tmp") }
    func cacheDirectory() -> URL { URL(fileURLWithPath: "/tmp") }
    func applicationSupportDirectory() -> URL { URL(fileURLWithPath: "/tmp") }
    func temporaryDirectory() -> URL { URL(fileURLWithPath: "/tmp") }
    func metadata(for url: URL) -> FileMetadata? {
        FileMetadata(byteCount: nil, modificationDate: nil, isRegularFile: false, isDirectory: true)
    }
    func fileExists(at url: URL) -> Bool { false }
    func isExecutable(at url: URL) -> Bool { false }
    func listDirectory(at url: URL) -> [URL] { [] }
    func readPrefix(from url: URL, byteCount: Int) throws -> Data { throw CocoaError(.fileNoSuchFile) }
    func readData(from url: URL, options: Data.ReadingOptions) throws -> Data { throw CocoaError(.fileNoSuchFile) }
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws {}
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {}
    func removeItem(at url: URL) throws {}
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {}
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {}
}

private final class CountingFileStorage: FileStorage, @unchecked Sendable {
    private let root: URL
    private var files: [String: Data] = [:]
    private(set) var writeCount = 0
    var shouldFailWrites = false
    var failOnWriteNumber: Int?
    private var writeAttempts = 0

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func seed(_ data: Data, at url: URL) {
        files[url.standardizedFileURL.path] = data
    }

    func homeDirectory() -> URL { root }
    func cacheDirectory() -> URL { root }
    func applicationSupportDirectory() -> URL { root }
    func temporaryDirectory() -> URL { root }
    func metadata(for url: URL) -> FileMetadata? {
        if url.standardizedFileURL == root {
            return FileMetadata(byteCount: nil, modificationDate: nil, isRegularFile: false, isDirectory: true)
        }
        guard let data = files[url.standardizedFileURL.path] else { return nil }
        return FileMetadata(byteCount: data.count, modificationDate: nil, isRegularFile: true, isDirectory: false)
    }
    func fileExists(at url: URL) -> Bool { files[url.standardizedFileURL.path] != nil }
    func isExecutable(at url: URL) -> Bool { false }
    func listDirectory(at url: URL) -> [URL] { [] }
    func readPrefix(from url: URL, byteCount: Int) throws -> Data {
        try readData(from: url, options: []).prefix(byteCount)
    }
    func readData(from url: URL, options: Data.ReadingOptions) throws -> Data {
        guard let data = files[url.standardizedFileURL.path] else { throw CocoaError(.fileNoSuchFile) }
        return data
    }
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        writeAttempts += 1
        if shouldFailWrites || writeAttempts == failOnWriteNumber {
            throw CocoaError(.fileWriteNoPermission)
        }
        files[url.standardizedFileURL.path] = data
        writeCount += 1
    }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {}
    func removeItem(at url: URL) throws { files.removeValue(forKey: url.standardizedFileURL.path) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        guard let data = files.removeValue(forKey: sourceURL.standardizedFileURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        files[destinationURL.standardizedFileURL.path] = data
    }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        guard let data = files[sourceURL.standardizedFileURL.path] else { throw CocoaError(.fileNoSuchFile) }
        files[destinationURL.standardizedFileURL.path] = data
    }
}

final class RunTestDocumentMutator: RunConfigurationDocumentMutating, @unchecked Sendable {
    private func documentURL(_ root: URL, scope: RunConfigurationSaveScope) -> URL {
        root.appendingPathComponent(scope == .local ? ".lithe/run/local.json" : ".lithe/run/configurations.json")
    }

    private func readDocument(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["version": 1, "configurations": []]
        }
        return value
    }

    private func encode(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    }

    func updateOptionsDocument(
        at projectURL: URL,
        configurationID: String,
        scope: RunConfigurationSaveScope,
        options: RunOptions
    ) throws -> RunConfigurationDocumentMutation {
        let url = documentURL(projectURL, scope: scope)
        var document = readDocument(url)
        var configurations = document["configurations"] as? [[String: Any]] ?? []
        let rootPath = projectURL.standardizedFileURL.path + "/"
        let workingDirectory = options.workingDirectoryPath.hasPrefix(rootPath)
            ? String(options.workingDirectoryPath.dropFirst(rootPath.count))
            : (options.workingDirectoryPath.isEmpty ? "." : options.workingDirectoryPath)
        guard !workingDirectory.split(separator: "/").contains("..") else {
            throw RunConfigurationOperationFailure(message: "Path leaves project")
        }
        let value: [String: Any] = [
            "id": configurationID,
            "workingDirectory": workingDirectory,
            "programArguments": split(options.programArguments)
        ]
        if let index = configurations.firstIndex(where: { $0["id"] as? String == configurationID }) {
            configurations[index].merge(value) { _, new in new }
        } else {
            configurations.append(value)
        }
        document["version"] = 1
        document["configurations"] = configurations.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
        return RunConfigurationDocumentMutation(configurationID: nil, document: try encode(document))
    }

    private func split(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for character in input {
            if character == "'" || character == "\"" {
                quote = quote == character ? nil : (quote == nil ? character : quote)
            } else if character.isWhitespace && quote == nil {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

private final class RunTestKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@Suite("Core payload decoding")
struct CorePayloadDecodingTests {
    /// Same root cause, quieter symptom: `hunkId` decoded as nil left every
    /// diff row unattached to its hunk instead of failing outright.
    @Test
    func gitDiffRowDecodesItsHunkIdentifier() throws {
        let json = """
        {"oldLine":1,"newLine":1,"left":"a","right":"b","kind":"changed","hunkId":"h1"}
        """

        let row = try JSONDecoder().decode(
            RustCoreBridge.GitDiffPayload.Row.self,
            from: Data(json.utf8)
        )

        #expect(row.hunkID == "h1")
    }
}
