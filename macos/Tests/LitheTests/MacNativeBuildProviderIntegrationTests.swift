import CryptoKit
import Foundation
import LitheCoreContracts
import LitheExecutionModule
import LitheLanguageIntelligenceModule
import Testing
@testable import Lithe

/// Explicit tool integration: the production macOS session table, linked Core,
/// real Java SDK backend and Maven reactor. No page or scripted runtime Core.
@Suite("Native macOS build Provider integration", .serialized)
@MainActor
struct MacNativeBuildProviderIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_STAGE_D_MAVEN_PACKAGE"] != nil,
                   "Requires the stage D Maven package and selected Java/Maven"), arguments: [false, true], [false, true])
    func installedDefinitionsResolveTheRealBuildAndRuntimeThroughSavedChoices(projectWrapper: Bool, consumerDefaults: Bool) async throws {
        let environment = ProcessInfo.processInfo.environment
        let package = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_D_MAVEN_PACKAGE"]))
        let javaPath = try #require(environment["LITHE_STAGE_C_JAVA"])
        let mavenPath = try #require(environment["LITHE_STAGE_C_MAVEN"])
        let java = try #require(MacToolchainDiscovery.realpath(javaPath))
        let maven = try #require(MacToolchainDiscovery.realpath(mavenPath))
        let javaHome = URL(fileURLWithPath: java).deletingLastPathComponent().deletingLastPathComponent().path
        let mavenHome = URL(fileURLWithPath: maven).deletingLastPathComponent().deletingLastPathComponent().path
        let files = FileManager.default
        let workspace = files.temporaryDirectory.appendingPathComponent("lithe-native-defined-tools-\(UUID().uuidString)")
        try files.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: workspace) }
        let manifest = try Data(contentsOf: package.appendingPathComponent("plugin.json"))
        let javaPackage = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("Plugins/mac/Official/JavaSupport")
        let sources: [ToolchainSettingsPluginSource] = [
            .init(pluginID: "io.github.lithe-idea.maven-build", name: "Maven", manifest: manifest, isEnabled: true),
            .init(pluginID: "dev.lithe.plugin.java-support", name: "Java", manifest: try Data(contentsOf: javaPackage.appendingPathComponent("plugin.json")),
                  isEnabled: true, verifiedOfficial: true)
        ]
        let before = try Self.inventory(package), javaBefore = try Self.inventory(javaPackage)
        var pins = ["java": ["home": javaHome, "version": "selected", "provider": "host:manual"]]
        if projectWrapper {
            // A fixture launcher delegates to the explicit real Maven without a
            // download. Opening the workspace cannot execute this project code.
            let wrapper = workspace.appendingPathComponent("mvnw")
            let escapedMaven = maven.replacingOccurrences(of: "'", with: "'\"'\"'")
            try Data("#!/bin/sh\nexec '\(escapedMaven)' \"$@\"\n".utf8).write(to: wrapper)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
            try files.createDirectory(at: workspace.appendingPathComponent(".mvn/wrapper"), withIntermediateDirectories: true)
            try Data("# fixture launcher needs no distribution\n".utf8)
                .write(to: workspace.appendingPathComponent(".mvn/wrapper/maven-wrapper.properties"))
        } else {
            pins["io.github.lithe-idea.maven-build:maven"] = ["home": mavenHome, "version": "selected", "provider": "host:manual"]
        }
        if consumerDefaults {
            let store = MacToolchainPreferencesStore(core: RustCoreBridge(), storage: MacFileStorage(), immutableRoots: { [package, javaPackage] })
            var baseline = try await store.load(workspace: workspace)
            baseline = try await store.save(.object(["home": .string(javaHome)]),
                at: .init(directory: ".", consumer: nil, tool: "java"), expecting: baseline)
            baseline = try await store.save(.object(["inherit": .string("tool")]),
                at: .init(directory: ".", consumer: "io.github.lithe-idea.maven-build/maven", tool: "java"), expecting: baseline)
            if !projectWrapper {
                _ = try await store.save(.object(["home": .string(mavenHome)]),
                    at: .init(directory: ".", consumer: "io.github.lithe-idea.maven-build/maven", tool: "io.github.lithe-idea.maven-build:maven"), expecting: baseline)
            }
            #expect(!files.fileExists(atPath: workspace.appendingPathComponent(".lithe/toolchains/local.json").path))
        } else {
            try files.createDirectory(at: workspace.appendingPathComponent(".lithe/toolchains"), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["version": 1, "toolchains": [:], "pins": [".": pins]])
                .write(to: workspace.appendingPathComponent(".lithe/toolchains/local.json"))
        }
        let defined = MacDefinedToolchainResolver()
        defined.sources = { sources }
        let runtime = ProjectRuntimeService(runtimeLocator: MacRuntimeLocator(), store: NativeDefinedToolPreferences())
        runtime.openProject(at: workspace)
        defer { runtime.closeProject() }
        let resolver = MacBuildToolResolver(runtime: runtime, processRunner: MacProcessRunner(), fileStorage: MacFileStorage(), definedTools: defined)
        let core = RustBuildSystemOperations(core: RustCoreBridge())
        let target = BuildSystemTarget(manifest: manifest, buildSystemID: "maven")
        let invocation = try core.invocationPlan(target, root: ".", settings: [:])
        #expect(resolver.languageImportExecutable(invocation, workspaceURL: workspace) == nil)
        let selected = try await resolver.resolve(invocation, displayName: "Maven", workspaceURL: workspace) { runtime, output in
            try core.checkToolVersion(target, runtime: runtime, output: output)
        }
        let expected = projectWrapper ? try #require(MacToolchainDiscovery.realpath(workspace.appendingPathComponent("mvnw").path)) : maven
        #expect(selected.executableURL.path == expected)
        #expect(selected.environment["JAVA_HOME"] == javaHome)
        #expect(selected.executesProjectCode == projectWrapper)
        if !projectWrapper { #expect(selected.version != nil) }
        #expect(selected.providerEnvironment["JAVA_HOME"] == javaHome)
        #expect(try Self.inventory(package) == before)
        #expect(try Self.inventory(javaPackage) == javaBefore)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_STAGE_D_MAVEN_PACKAGE"] != nil,
                   "Requires the stage D Maven package and selected Java/Maven"),
          .enabled(if: ProcessInfo.processInfo.environment["LITHE_STAGE_D_ALTERNATE_JAVA"] != nil,
                   "Requires an explicitly selected second compatible JDK"))
    func consumerDefaultChangesReachTheRealMavenProcessWhileExplicitRunsStayFixed() async throws {
        let environment = ProcessInfo.processInfo.environment
        let package = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_D_MAVEN_PACKAGE"]))
        let primaryPath = try #require(environment["LITHE_STAGE_C_JAVA"])
        let alternatePath = try #require(environment["LITHE_STAGE_D_ALTERNATE_JAVA"])
        let mavenPath = try #require(environment["LITHE_STAGE_C_MAVEN"])
        let primary = try #require(MacToolchainDiscovery.realpath(primaryPath))
        let alternate = try #require(MacToolchainDiscovery.realpath(alternatePath))
        let maven = try #require(MacToolchainDiscovery.realpath(mavenPath))
        let homes = [primary, alternate].map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path }
        try #require(homes[0] != homes[1])
        let mavenHome = URL(fileURLWithPath: maven).deletingLastPathComponent().deletingLastPathComponent().path
        let javaPackage = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("Plugins/mac/Official/JavaSupport")
        let manifest = try Data(contentsOf: package.appendingPathComponent("plugin.json"))
        let sources: [ToolchainSettingsPluginSource] = [
            .init(pluginID: "io.github.lithe-idea.maven-build", name: "Maven", manifest: manifest, isEnabled: true),
            .init(pluginID: "dev.lithe.plugin.java-support", name: "Java", manifest: try Data(contentsOf: javaPackage.appendingPathComponent("plugin.json")),
                  isEnabled: true, verifiedOfficial: true)
        ]
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-real-default-change-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let before = try Self.inventory(package), javaBefore = try Self.inventory(javaPackage)
        let store = MacToolchainPreferencesStore(core: RustCoreBridge(), storage: MacFileStorage(), immutableRoots: { [package, javaPackage] })
        var baseline = try await store.load(workspace: workspace)
        baseline = try await store.save(.object(["home": .string(mavenHome)]),
            at: .init(directory: ".", consumer: "io.github.lithe-idea.maven-build/maven", tool: "io.github.lithe-idea.maven-build:maven"), expecting: baseline)
        _ = try await store.save(.object(["inherit": .string("tool")]),
            at: .init(directory: ".", consumer: "io.github.lithe-idea.maven-build/maven", tool: "java"), expecting: baseline)
        let defined = MacDefinedToolchainResolver(); defined.sources = { sources }
        let runtime = ProjectRuntimeService(runtimeLocator: MacRuntimeLocator(), store: NativeDefinedToolPreferences())
        runtime.openProject(at: workspace)
        defer { runtime.closeProject() }
        let resolver = MacBuildToolResolver(runtime: runtime, processRunner: MacProcessRunner(), fileStorage: MacFileStorage(), definedTools: defined)
        let core = RustBuildSystemOperations(core: RustCoreBridge())
        let target = BuildSystemTarget(manifest: manifest, buildSystemID: "maven")
        let invocation = try core.invocationPlan(target, root: ".", settings: [:])
        for (index, home) in homes.enumerated() {
            baseline = try await store.load(workspace: workspace)
            _ = try await store.save(.object(["home": .string(home)]), at: .init(directory: ".", consumer: nil, tool: "java"), expecting: baseline)
            let selected = try await resolver.resolve(invocation, displayName: "Maven", workspaceURL: workspace) { runtime, output in
                try core.checkToolVersion(target, runtime: runtime, output: output)
            }
            #expect(selected.environment["JAVA_HOME"] == home)
            let result = try await MacBuildCommandRunner().run(.init(executableURL: selected.executableURL, arguments: ["--version"],
                workingDirectory: workspace, environment: selected.environment, capturesStandardOutput: true, timeout: .seconds(5))) { _ in }
            #expect(result.termination == .exited(0))
            #expect(result.standardOutput?.contains(home) == true)
            if index == homes.count - 1 {
                var explicit = invocation; explicit.toolSelections["java"] = .installation(home: homes[0])
                let fixed = try await resolver.resolve(explicit, displayName: "Maven", workspaceURL: workspace) { runtime, output in
                    try core.checkToolVersion(target, runtime: runtime, output: output)
                }
                #expect(fixed.environment["JAVA_HOME"] == homes[0])
            }
        }
        #expect(try Self.inventory(package) == before)
        #expect(try Self.inventory(javaPackage) == javaBefore)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_STAGE_D_MAVEN_PACKAGE"] != nil,
                   "Requires the stage D Maven package and selected Java/Maven"))
    func runProfileUsesOneMavenModelAndSavedGenerationTracksDefaultProfileChanges() async throws {
        try await verifyRunConfigurationPreparation(savedTaskOnly: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_STAGE_D_MAVEN_PACKAGE"] != nil,
                   "Requires the stage D Maven package and selected Java/Maven"))
    func savedProviderTaskUsesCurrentTypedInputsWithoutChangingBuildDefaults() async throws {
        try await verifyRunConfigurationPreparation(savedTaskOnly: true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_STAGE_D_MAVEN_PACKAGE"] != nil,
                   "Requires the stage D Maven package and selected Java/Maven"))
    func legacyRunTaskMigratesToTheCurrentMavenTargetWithoutLosingItsStableID() async throws {
        try await verifyRunConfigurationPreparation(savedTaskOnly: true, migrateLegacy: true)
    }

    private func verifyRunConfigurationPreparation(savedTaskOnly: Bool, migrateLegacy: Bool = false) async throws {
        let environment = ProcessInfo.processInfo.environment
        let package = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_D_MAVEN_PACKAGE"]))
        let java = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_C_JAVA"]))
        let maven = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_C_MAVEN"]))
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("lithe-native-run-profile-\(UUID().uuidString)")
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace")
        for path in ["nested/checks", "nested/test inputs"] {
            try files.createDirectory(at: workspace.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("class Main { public static void main(String[] args) {} }".utf8).write(to: workspace.appendingPathComponent("nested/checks/Main.java"))
        try Data("selected=${selected.value}".utf8).write(to: workspace.appendingPathComponent("nested/test inputs/runtime.properties"))
        try Data("""
        <project><modelVersion>4.0.0</modelVersion><groupId>smoke</groupId><artifactId>app</artifactId><version>1</version>
        <properties><selected.sources>checks</selected.sources><selected.checks>inactive-checks</selected.checks></properties>
        <build><sourceDirectory>${selected.sources}</sourceDirectory><testSourceDirectory>${selected.checks}</testSourceDirectory><testResources><testResource><directory>test inputs</directory>
          <filtering>true</filtering></testResource></testResources></build>
        <profiles><profile><id>run-only</id><properties><selected.value>current-profile</selected.value>
          <selected.sources>inactive-sources</selected.sources><selected.checks>checks</selected.checks></properties>
        </profile><profile><id>additional</id></profile></profiles></project>
        """.utf8).write(to: workspace.appendingPathComponent("nested/pom.xml"))
        let before = try Self.inventory(package)
        let core = RustCoreBridge(), storage = MacFileStorage()
        let planner = RustBuildSystemOperations(core: core), declarations = RustDeclarativePluginOperations(core: core)
        let descriptor = try declarations.validate(manifest: Data(contentsOf: package.appendingPathComponent("plugin.json")))
        let source = BuildSystemPluginSource(pluginID: descriptor.id.rawValue, manifest: descriptor.normalizedManifest,
            packageURL: package, buildSystems: descriptor.buildSystems)
        let runtime = ExplicitProviderRuntime(java: java, environment: environment), released = TestGate()
        let directories = MacPluginStateDirectories(rootURL: scratch.appendingPathComponent("state"))
        let sessions = MacBuildProviderSessions(launchResolver: MacPluginLanguageServerLaunchResolver(planner: declarations,
            directories: directories, settings: InMemoryPluginSettings()), tools: runtime, versionChecker: declarations,
            runtime: runtime, core: core, processRegistry: nil, endBackendProcesses: { token, _ in
                MacPluginBackendProcesses.end(token: token, gracePeriod: 0); released.open()
            })
        let domain = "lithe.native-run-profile.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let options = MacBuildOptionsStore(store: MacUserDefaultsStore(defaults: defaults))
        let build = BuildSystemService(planner: planner, tools: ExplicitNativeConfigurationTool(maven: maven), optionsStore: options,
            stateLocator: MacBuildSystemStateLocator(directories: directories, fileStorage: storage),
            runner: MacBuildCommandRunner(), providers: sessions, sources: { [source] })
        let outcome: Result<Void, Error>
        do {
            build.reset(workspaceURL: workspace)
            let baseline = try await build.prepareLanguageImport(workspaceURL: workspace)
            if migrateLegacy {
                try await build.prepareLanguageTestModels(allModels: true, workspace: workspace)
                _ = try await build.prepareLanguageImport(workspaceURL: workspace)
                let store = MacRunConfigurationStore(core: core, storage: storage, preferences: MacUserDefaultsStore(defaults: defaults))
                let legacyID = "user:legacy-validate"
                let url = workspace.appendingPathComponent(".lithe/run/local.json")
                try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: ["version": 2, "configurations": [["id": legacyID, "name": "Saved validate",
                    "provider": "maven.module", "execution": "task", "cwd": "nested", "args": ["validate"],
                    "env": ["LITHE_RUN_VALUE": "雪"], "extensions": ["maven": ["module": ".", "profiles": ["run-only"]]]]]], options: [.sortedKeys]).write(to: url)
                _ = try store.generate(at: workspace, files: [], modulePaths: [], javaEntrypoints: nil,
                    projectOwnership: build.runProjectOwnership(), providerRuns: build.providerRunConfigurations(),
                    models: build.entries.compactMap(\.model), lease: RunConfigurationGenerationLease())
                let resolution = try store.resolve(at: workspace, toolchainCandidates: [])
                #expect(resolution.configurations.count == 1)
                #expect(resolution.configurations.first?.configuration.id == legacyID)
                let inputs = try store.providerLaunchInputs(at: workspace, configurationID: legacyID, providerRoot: "nested")
                #expect(inputs.reference?.run == "module")
                #expect(inputs.launchOptions.arguments == ["validate"])
                #expect(inputs.optionOverrides["profiles"] == .array([.string("run-only")]))
                let prepared = try await build.prepareConfigurationRun(inputs: inputs, instanceRoot: "nested", workspace: workspace,
                    tool: BuildProviderHints(), isCurrent: { true }, progress: { _ in })
                #expect(prepared.arguments.last == "validate")
                #expect(prepared.arguments.contains("-Prun-only"))
                #expect(prepared.environment["LITHE_RUN_VALUE"] == "雪")
                #expect(try build.languageImport(workspaceURL: workspace, root: nil) == baseline)
                #expect(try options.instanceOptions(workspaceURL: workspace, buildSystemID: "maven")["nested"]?["profiles"] == nil)
            } else if savedTaskOnly {
                try await build.prepareLanguageTestModels(allModels: true, workspace: workspace)
                let taskPreparation = try await build.prepareConfigurationRun(inputs: ProviderLaunchInputs(
                    buildSystemID: "maven", provider: "maven.module", projectPath: "nested",
                    launchOptions: BuildLaunchOptions(execution: .task, arguments: ["validate"], environment: ["LITHE_RUN_VALUE": "雪"], workingDirectory: "."),
                    optionOverrides: ["profiles": .array([.string("run-only")])]), instanceRoot: "nested", workspace: workspace,
                    tool: BuildProviderHints(toolExecutable: maven, toolEnvironment: ["JAVA_HOME": java.deletingLastPathComponent().deletingLastPathComponent().path]),
                    isCurrent: { true }, progress: { _ in })
                #expect(taskPreparation.executable.value == "io.github.lithe-idea.maven-build:maven")
                #expect(taskPreparation.arguments.contains("validate"))
                #expect(taskPreparation.arguments.contains("-Prun-only"))
                #expect(taskPreparation.workingDirectory == ".")
                #expect(taskPreparation.environment["LITHE_RUN_VALUE"] == "雪")
                #expect(try build.languageImport(workspaceURL: workspace, root: nil) == baseline)
                let store = MacRunConfigurationStore(core: core, storage: storage, preferences: MacUserDefaultsStore(defaults: defaults))
                let moduleTarget = try #require(build.entries.first?.model?.targets.first { $0.name == "maven.module" })
                let reference = BuildProviderRunReference(pluginID: source.pluginID, buildSystemID: "maven", root: "nested",
                    run: "module", projectID: moduleTarget.projectID, targetID: moduleTarget.id, userArguments: ["validate"], execution: .task)
                let savedID = try store.saveBuildProviderConfiguration(reference, name: "Validate module", at: workspace)
                try store.saveOptions(RunOptions(programArguments: "validate", providerRunOptions: BuildProviderRunOptions(
                    options: ["profiles": .array([.string("run-only"), .string("additional")])])), configurationID: savedID, scope: .local, at: workspace)
                let savedInputs = try store.providerLaunchInputs(at: workspace, configurationID: savedID, providerRoot: "nested")
                let savedPreparation = try await build.prepareConfigurationRun(inputs: savedInputs, instanceRoot: "nested", workspace: workspace,
                    tool: BuildProviderHints(), isCurrent: { true }, progress: { _ in })
                #expect(savedPreparation.arguments.last == "validate")
                #expect(savedPreparation.arguments.contains("-Padditional,run-only"))
                #expect(savedInputs.optionOverrides["profiles"] == .array([.string("run-only"), .string("additional")]))
                #expect(try build.languageImport(workspaceURL: workspace, root: nil) == baseline)
                #expect(try options.instanceOptions(workspaceURL: workspace, buildSystemID: "maven")["nested"]?["profiles"] == nil)
                #expect(try store.resolve(at: workspace, toolchainCandidates: []).configurations.first?.configuration.execution == .task)
                #expect(build.configurationRunSource(inputs: savedInputs, instanceRoot: "nested") == source)
            } else {
                let prepared = try await build.prepareLanguageRun(fileURL: workspace.appendingPathComponent("nested/checks/Main.java"),
                    workspace: workspace, purpose: "run",
                    optionOverrides: ["profiles": .array([.string("run-only")])],
                    tool: { _ in BuildProviderHints(toolExecutable: maven,
                        toolEnvironment: runtime.environment.filter { $0.key == "JAVA_HOME" || $0.key == "PATH" }) }, isCurrent: { true })
                guard case .maven(let context)? = prepared else { throw NativeProviderIntegrationError.unexpectedCommand }
                #expect(context.profiles == ["run-only"])
                #expect(context.mavenExecutablePath == maven.path)
                #expect(context.reactorPath == "nested")
                #expect(try String(contentsOf: workspace.appendingPathComponent("nested/target/test-classes/runtime.properties"), encoding: .utf8) == "selected=current-profile")
                #expect(build.entries.first?.model?.contentRoots.contains { $0.path == "nested/checks" && $0.kind == "source" } == true)
                #expect(try build.languageImport(workspaceURL: workspace, root: nil) == baseline)
                #expect(try options.instanceOptions(workspaceURL: workspace, buildSystemID: "maven")["nested"]?["profiles"] == nil)
                let ownership = try build.runProjectOwnership()
                #expect(ownership.first?.build?.root == "nested")
                #expect(ownership.first?.contentRoots.contains { $0.path == "nested/checks" && $0.kind == "source" } == true)
                let store = MacRunConfigurationStore(core: core, storage: storage, preferences: MacUserDefaultsStore(defaults: defaults))
                let runs = try build.providerRunConfigurations()
                #expect(runs.contains { $0.reference.run == "module" && $0.reference.execution == .task })
                _ = try store.generate(at: workspace, files: [workspace.appendingPathComponent("nested/checks/Main.java")], modulePaths: [],
                    javaEntrypoints: JavaEntrypoints(entries: [JavaEntrypoint(sourcePath: "nested/checks/Main.java", mainClass: "Main")]),
                    projectOwnership: ownership, providerRuns: runs)
                let resolvedRuns = try store.resolve(at: workspace, toolchainCandidates: []).configurations.compactMap { $0.configuration.buildProvider }
                #expect(Set(resolvedRuns.map(\.targetID)) == Set(runs.map { $0.reference.targetID }))
                #expect(!store.inspectProviderGeneration(at: workspace, projectOwnership: ownership, providerRuns: runs).diagnostics.contains { $0.code == "staleProviderModel" })
                let entryID = try #require(build.entries.first?.id)
                func currentOwnership() async throws -> [LitheCoreContracts.RunProjectOwnership] {
                    _ = try await build.prepareLanguageImport(workspaceURL: workspace)
                    try await build.prepareLanguageTestModels(allModels: true, workspace: workspace)
                    _ = try await build.prepareLanguageImport(workspaceURL: workspace)
                    return try build.runProjectOwnership()
                }
                // These are explicit edits of Build defaults after the temporary Run
                // has completed. POM bytes stay unchanged throughout A → B → A.
                build.setOption(entryID, optionID: "profiles", value: .array([.string("run-only")]))
                let changed = try await currentOwnership()
                #expect(changed.first?.contentRoots.contains { $0.path == "nested/checks" && $0.kind == "testSource" } == true)
                #expect(store.inspectProviderGeneration(at: workspace, projectOwnership: changed, providerRuns: try build.providerRunConfigurations()).diagnostics.contains { $0.code == "staleProviderModel" })
                build.setOption(entryID, optionID: "profiles", value: .array([]))
                let restored = try await currentOwnership()
                #expect(restored == ownership)
                #expect(!store.inspectProviderGeneration(at: workspace, projectOwnership: restored, providerRuns: try build.providerRunConfigurations()).diagnostics.contains { $0.code == "staleProviderModel" })
            }
            outcome = .success(())
        } catch { outcome = .failure(error) }
        build.stop(); sessions.retainProviders { _ in false }
        #expect(await released.waitUntilOpen(timeout: .seconds(5)))
        #expect(try Self.inventory(package) == before)
        try outcome.get()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_STAGE_D_MAVEN_PACKAGE"] != nil,
                   "Requires the stage D native-configuration development package"))
    func savingNativeSettingsKeepsTheOtherReactorIndependent() async throws {
        try await nativeSettingsStayIndependentAcrossReactorRoots(replaceSource: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_STAGE_D_MAVEN_PACKAGE"] != nil,
                   "Requires the stage D native-configuration development package"))
    func replacingNativeSettingsSourceKeepsTheOtherReactorIndependent() async throws {
        try await nativeSettingsStayIndependentAcrossReactorRoots(replaceSource: true)
    }

    private func nativeSettingsStayIndependentAcrossReactorRoots(replaceSource: Bool) async throws {
        let environment = ProcessInfo.processInfo.environment
        let package = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_D_MAVEN_PACKAGE"]))
        let java = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_C_JAVA"]))
        let maven = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_C_MAVEN"]))
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("lithe-native-reactor-settings-\(UUID().uuidString)")
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace")
        for root in ["a", "b"] {
            let directory = workspace.appendingPathComponent(root)
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("<broken>".utf8).write(to: directory.appendingPathComponent("pom.xml"))
        }
        let a = scratch.appendingPathComponent("a settings.xml")
        let b = scratch.appendingPathComponent("b settings.xml")
        let replacement = scratch.appendingPathComponent("replacement.xml")
        for (url, name) in [(a, "a"), (b, "b"), (replacement, "replacement")] {
            try Data("<settings><localRepository>\(scratch.appendingPathComponent(name + "-repository").path)</localRepository></settings>".utf8).write(to: url)
        }
        // Each reactor has an independent pin. Maven receives its canonical
        // selection as environment rather than inferring the backend's java.home.
        let javaHome = java.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        var pins: [String: [String: [String: String]]] = [:]
        let mavenPath = try #require(MacToolchainDiscovery.realpath(maven.path))
        let mavenHome = URL(fileURLWithPath: mavenPath).deletingLastPathComponent().deletingLastPathComponent().path
        for root in ["a", "b"] {
            let alias = scratch.appendingPathComponent("runtime-\(root)")
            try files.createSymbolicLink(at: alias, withDestinationURL: javaHome)
            pins[root] = ["java": ["home": alias.path, "version": "selected", "provider": "host:manual"],
                          "io.github.lithe-idea.maven-build:maven": ["home": mavenHome, "version": "selected", "provider": "host:manual"]]
        }
        try files.createDirectory(at: workspace.appendingPathComponent(".lithe/toolchains"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 1, "toolchains": [:], "pins": pins])
            .write(to: workspace.appendingPathComponent(".lithe/toolchains/local.json"))
        let bSettings = "<settings><localRepository>\(scratch.appendingPathComponent("b-repository").path)</localRepository><activeProfiles><activeProfile>${env.JAVA_HOME}</activeProfile></activeProfiles></settings>"
        try Data(bSettings.utf8).write(to: b)
        let before = try Self.inventory(package)
        let core = RustCoreBridge()
        let planner = RustBuildSystemOperations(core: core)
        let declarations = RustDeclarativePluginOperations(core: core)
        let descriptor = try declarations.validate(manifest: Data(contentsOf: package.appendingPathComponent("plugin.json")))
        let source = BuildSystemPluginSource(pluginID: descriptor.id.rawValue, manifest: descriptor.normalizedManifest,
            packageURL: package, buildSystems: descriptor.buildSystems)
        let runtime = ExplicitProviderRuntime(java: java, environment: environment)
        let released = TestGate()
        let directories = MacPluginStateDirectories(rootURL: scratch.appendingPathComponent("state"))
        let sessions = MacBuildProviderSessions(
            launchResolver: MacPluginLanguageServerLaunchResolver(planner: declarations, directories: directories,
                settings: InMemoryPluginSettings()), tools: runtime, versionChecker: declarations,
            runtime: runtime, core: core, processRegistry: nil, endBackendProcesses: { token, _ in
                MacPluginBackendProcesses.end(token: token, gracePeriod: 0); released.open()
            })
        let domain = "lithe.native-reactor-settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let options = MacBuildOptionsStore(store: MacUserDefaultsStore(defaults: defaults))
        try options.setInstanceOptions(["a": ["settingsFile": .string(a.path)], "b": ["settingsFile": .string(b.path)]],
            workspaceURL: workspace, buildSystemID: "maven")
        let storage = MacFileStorage()
        let defined = MacDefinedToolchainResolver()
        let javaManifest = try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("Plugins/mac/Official/JavaSupport/plugin.json"))
        let toolSources: [ToolchainSettingsPluginSource] = [
            .init(pluginID: descriptor.id.rawValue, name: "Maven", manifest: descriptor.normalizedManifest, isEnabled: true),
            .init(pluginID: "dev.lithe.plugin.java-support", name: "Java", manifest: javaManifest, isEnabled: true, verifiedOfficial: true)
        ]
        defined.sources = { toolSources }
        let projectRuntime = ProjectRuntimeService(runtimeLocator: CanonicalToolchainRuntimeLocator(), store: NativeDefinedToolPreferences())
        projectRuntime.openProject(at: workspace)
        defer { projectRuntime.closeProject() }
        let build = BuildSystemService(planner: planner,
            tools: MacBuildToolResolver(runtime: projectRuntime, processRunner: MacProcessRunner(), fileStorage: storage, definedTools: defined), optionsStore: options,
            stateLocator: MacBuildSystemStateLocator(directories: directories, fileStorage: storage),
            runner: MacBuildCommandRunner(), providers: sessions,
            nativeConfigurationFiles: MacBuildNativeConfigurationStore(storage: storage, planner: planner,
                immutableRoots: [package, Bundle.main.bundleURL]), sources: { [source] })
        let outcome: Result<Void, Error>
        do {
            build.reset(workspaceURL: workspace)
            _ = try await build.prepareLanguageImport(workspaceURL: workspace)
            #expect(build.entries.map(\.id) == ["maven:a", "maven:b"])
            // Saving a source and selecting another source are independent
            // workflows. Each keeps both reactors live but owns one mutation,
            // without reading an unchanged fixture through Maven twice.
            if replaceSource {
                let originalA = try Data(contentsOf: a)
                _ = try build.configureOption("maven:a", optionID: "settingsFile", value: .string(replacement.path))
                _ = try await build.prepareLanguageImport(workspaceURL: workspace)
                let changedA = try await build.readNativeConfiguration("maven:a")
                #expect(changedA.sources.first { $0.id == "user" }?.uri == replacement.absoluteString)
                #expect(try Data(contentsOf: a) == originalA)
            } else {
                let firstA = try await build.readNativeConfiguration("maven:a")
                let userA = try #require(firstA.sources.first { $0.id == "user" })
                #expect(userA.uri == a.absoluteString)
                let savedPath = scratch.appendingPathComponent("saved-a-repository").path
                // The production save already reads back from the provider.
                let changedA = try await build.saveNativeConfiguration("maven:a", snapshot: firstA,
                    edits: BuildNativeConfigurationEdits(sourceID: userA.id, revision: userA.revision,
                        values: ["localRepository": .string(savedPath)]))
                #expect(changedA.sources.first { $0.id == "user" }?.fields.first { $0.id == "localRepository" }?.effectiveValue == .string(savedPath))
            }
            let unchangedB = try await build.readNativeConfiguration("maven:b")
            let userB = try #require(unchangedB.sources.first { $0.id == "user" })
            #expect(userB.uri == b.absoluteString)
            #expect(userB.fields.first { $0.id == "localRepository" }?.effectiveValue
                == .string(scratch.appendingPathComponent("b-repository").path))
            #expect(userB.fields.first { $0.id == "activeProfiles" }?.effectiveValue
                == .array([.string(try #require(MacToolchainDiscovery.realpath(javaHome.path)))]))
            #expect(try String(contentsOf: b, encoding: .utf8) == bSettings)
            #expect(try options.instanceOptions(workspaceURL: workspace, buildSystemID: "maven")["b"]?["settingsFile"] == .string(b.path))
            #expect(!files.fileExists(atPath: workspace.appendingPathComponent("a/target").path))
            #expect(!files.fileExists(atPath: workspace.appendingPathComponent("b/target").path))
            for path in ["a-repository", "b-repository", "saved-a-repository", "replacement-repository"] {
                #expect(!files.fileExists(atPath: scratch.appendingPathComponent(path).path))
            }
            outcome = .success(())
        } catch { outcome = .failure(error) }
        build.stop(); sessions.retainProviders { _ in false }
        #expect(await released.waitUntilOpen(timeout: .seconds(5)))
        #expect(try Self.inventory(package) == before)
        try outcome.get()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_STAGE_D_MAVEN_PACKAGE"] != nil,
                   "Requires the stage D native-configuration development package"))
    func nativeSettingsUseProductionStorageReadBackAndRejectExternalChanges() async throws {
        let environment = ProcessInfo.processInfo.environment
        let package = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_D_MAVEN_PACKAGE"]))
        let java = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_C_JAVA"]))
        let maven = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_C_MAVEN"]))
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("lithe-native-settings-workflow-\(UUID().uuidString)")
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace")
        try files.createDirectory(at: workspace.appendingPathComponent(".mvn"), withIntermediateDirectories: true)
        try Data("<broken>".utf8).write(to: workspace.appendingPathComponent("pom.xml"))
        let user = scratch.appendingPathComponent("user settings.xml")
        let global = scratch.appendingPathComponent("global.xml")
        let inheritedRepository = scratch.appendingPathComponent("inherited-repository").path
        let selectedRepository = scratch.appendingPathComponent("saved-repository").path
        let original = "<settings><!--keep--><servers><server><password>test-secret-preserved</password></server></servers><activeProfiles><activeProfile>ci</activeProfile></activeProfiles></settings>"
        try Data(original.utf8).write(to: user)
        try Data("<settings><localRepository>\(inheritedRepository)</localRepository></settings>".utf8).write(to: global)
        try Data("--global-settings=\(global.path)\n".utf8).write(to: workspace.appendingPathComponent(".mvn/maven.config"))
        let before = try Self.inventory(package)
        let core = RustCoreBridge()
        let planner = RustBuildSystemOperations(core: core)
        let declarations = RustDeclarativePluginOperations(core: core)
        let descriptor = try declarations.validate(manifest: Data(contentsOf: package.appendingPathComponent("plugin.json")))
        let source = BuildSystemPluginSource(pluginID: descriptor.id.rawValue, manifest: descriptor.normalizedManifest,
            packageURL: package, buildSystems: descriptor.buildSystems)
        let selectedRuntime = ExplicitProviderRuntime(java: java, environment: environment)
        let released = TestGate()
        let directories = MacPluginStateDirectories(rootURL: scratch.appendingPathComponent("state"))
        let sessions = MacBuildProviderSessions(
            launchResolver: MacPluginLanguageServerLaunchResolver(planner: declarations, directories: directories,
                settings: InMemoryPluginSettings()), tools: selectedRuntime, versionChecker: declarations,
            runtime: selectedRuntime, core: core, processRegistry: nil, endBackendProcesses: { token, _ in
                MacPluginBackendProcesses.end(token: token, gracePeriod: 0); released.open()
            })
        let preferenceDomain = "lithe.native-settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: preferenceDomain))
        defer { defaults.removePersistentDomain(forName: preferenceDomain) }
        let options = MacBuildOptionsStore(store: MacUserDefaultsStore(defaults: defaults))
        try options.setOptions(["settingsFile": .string(user.path)], workspaceURL: workspace, buildSystemID: "maven")
        let storage = MacFileStorage()
        func service() -> BuildSystemService {
            BuildSystemService(planner: planner, tools: ExplicitNativeConfigurationTool(maven: maven), optionsStore: options,
                stateLocator: MacBuildSystemStateLocator(directories: directories, fileStorage: storage),
                runner: MacBuildCommandRunner(), providers: sessions,
                nativeConfigurationFiles: MacBuildNativeConfigurationStore(storage: storage, planner: planner,
                    immutableRoots: [package, Bundle.main.bundleURL]), sources: { [source] })
        }
        let build = service()
        var reopened: BuildSystemService?
        let outcome: Result<Void, Error>
        do {
            build.reset(workspaceURL: workspace)
            _ = try await build.prepareLanguageImport(workspaceURL: workspace)
            let entry = try #require(build.entries.first)
            let first = try await build.readNativeConfiguration(entry.id)
            let userSource = try #require(first.sources.first { $0.id == "user" })
            let repository = try #require(userSource.fields.first { $0.id == "localRepository" })
            #expect(repository.value == .null)
            #expect(repository.effectiveValue == .string(inheritedRepository))
            #expect(try String(contentsOf: user, encoding: .utf8) == original)
            var draft = BuildNativeConfigurationDraft(source: userSource)
            #expect(!draft.isDirty)
            draft.setOverride(true, fieldID: repository.id)
            draft.setValue(.string(selectedRepository), fieldID: repository.id)
            let saved = try await build.saveNativeConfiguration(entry.id, snapshot: first, edits: draft.edits)
            #expect(saved.sources.first { $0.id == "user" }?.fields.first { $0.id == "localRepository" }?.effectiveValue == .string(selectedRepository))
            let savedText = try String(contentsOf: user, encoding: .utf8)
            #expect(savedText.contains("<!--keep-->"))
            #expect(savedText.contains("<password>test-secret-preserved</password>"))
            #expect(!String(decoding: try JSONEncoder().encode(saved), as: UTF8.self).contains("test-secret-preserved"))
            let current = try #require(saved.sources.first { $0.id == "user" })
            let external = savedText + "\n<!-- external save -->"
            try Data(external.utf8).write(to: user)
            await #expect(throws: (any Error).self) {
                try await build.saveNativeConfiguration(entry.id, snapshot: saved, edits: BuildNativeConfigurationEdits(
                    sourceID: current.id, revision: current.revision, values: ["localRepository": .string("/obsolete")]))
            }
            #expect(try String(contentsOf: user, encoding: .utf8) == external)
            build.stop()
            let next = service(); reopened = next
            next.reset(workspaceURL: workspace)
            _ = try await next.prepareLanguageImport(workspaceURL: workspace)
            let nextEntry = try #require(next.entries.first)
            let fresh = try await next.readNativeConfiguration(nextEntry.id)
            #expect(fresh.sources.first { $0.id == "user" }?.fields.first { $0.id == "localRepository" }?.value == .string(selectedRepository))
            #expect(!files.fileExists(atPath: workspace.appendingPathComponent("target").path))
            #expect(!files.fileExists(atPath: inheritedRepository))
            #expect(!files.fileExists(atPath: selectedRepository))
            outcome = .success(())
        } catch { outcome = .failure(error) }
        build.stop(); reopened?.stop(); sessions.retainProviders { _ in false }
        #expect(await released.waitUntilOpen(timeout: .seconds(5)))
        #expect(try Self.inventory(package) == before)
        try outcome.get()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_STAGE_C_MAVEN_PACKAGE"] != nil,
                   "Requires an explicit development Maven package and tool paths"))
    func realMavenProviderBuildsAndTestsWithoutAPluginPage() async throws {
        let environment = ProcessInfo.processInfo.environment
        let package = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_C_MAVEN_PACKAGE"]))
        let fixture = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_C_MAVEN_FIXTURE"]))
        let java = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_C_JAVA"]))
        let maven = URL(fileURLWithPath: try #require(environment["LITHE_STAGE_C_MAVEN"]))
        try #require(RustCoreBridge().isAvailable)
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("lithe-native-provider-\(UUID().uuidString)")
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        let workspace = scratch.appendingPathComponent("workspace")
        try files.createDirectory(at: workspace, withIntermediateDirectories: true)
        try files.copyItem(at: fixture, to: workspace.appendingPathComponent("nested"))
        let before = try Self.inventory(package)
        let core = RustCoreBridge()
        let operations = RustBuildSystemOperations(core: core)
        let declarations = RustDeclarativePluginOperations(core: core)
        let descriptor = try declarations.validate(manifest: Data(contentsOf: package.appendingPathComponent("plugin.json")))
        let target = BuildSystemTarget(manifest: descriptor.normalizedManifest, buildSystemID: "maven")
        let provider = BuildProviderTarget(pluginID: descriptor.id.rawValue, manifest: descriptor.normalizedManifest,
            packageURL: package, buildSystemID: "maven", workspaceURL: workspace)
        let released = TestGate()
        let selectedTools = ExplicitProviderRuntime(java: java, environment: environment)
        let sessions = MacBuildProviderSessions(
            launchResolver: MacPluginLanguageServerLaunchResolver(planner: declarations,
                directories: MacPluginStateDirectories(rootURL: scratch.appendingPathComponent("state")), settings: InMemoryPluginSettings()),
            tools: selectedTools, versionChecker: declarations, runtime: selectedTools, core: core, processRegistry: nil,
            endBackendProcesses: { token, _ in
                MacPluginBackendProcesses.end(token: token, gracePeriod: 0)
                released.open()
            })
        let context = BuildPlanContext(root: "nested", options: ["profiles": .array([.string("ci")])],
            pluginDirectory: package, workspaceStateDirectory: scratch.appendingPathComponent("workspace-state"))
        let outcome: Result<Void, Error>
        do {
            let plan = try operations.modelPlan(target, context: context, outputFile: nil,
                providerHints: BuildProviderHints(toolExecutable: maven))
            guard case .provider(let request) = plan else { throw NativeProviderIntegrationError.unexpectedCommand }
            let raw = try await sessions.send(request, to: provider, timeout: .seconds(20))
            let model = try operations.decodeModel(target, workspaceURL: workspace, root: context.root,
                output: .providerResult(raw), options: context.options)
            #expect(Set(model.projects.map(\.name)) == ["reactor", "core", "app"])
            #expect(try #require(sessions.processID(for: provider)) > 0)
            let project = try #require(model.projects.first { $0.name == "core" })
            let taskPlan = try operations.taskPlan(target, context: context,
                request: BuildTaskRequest(task: "compile", project: BuildSelection(project: project)))
            guard case .provider(let build) = taskPlan else { throw NativeProviderIntegrationError.unexpectedCommand }
            let progress = NativeProviderProgress()
            let built = try await sessions.execute(Self.withTool(build, maven: maven), on: provider, timeout: .seconds(20)) {
                progress.output += $0.output ?? ""
            }
            #expect(built.exitCode == 0)
            #expect(built.output == progress.output)
            #expect(files.fileExists(atPath: workspace.appendingPathComponent("nested/core/target/classes/demo/core/Greeter.class").path))
            let testPlan = try operations.testPlan(target, context: context,
                request: BuildTestRequest(project: BuildSelection(project: project), selectorKind: "java.test.fullName", selectors: ["demo.core.GreeterTest#greetsByName()"]))
            guard case .provider(let test) = testPlan.execution else { throw NativeProviderIntegrationError.unexpectedCommand }
            let tested = try await sessions.execute(Self.withTool(test, maven: maven), on: provider, timeout: .seconds(20)) { _ in }
            #expect(tested.exitCode == 0)
            let results = try operations.decodeTestResults(target, request: BuildTestResultsRequest(workspaceURL: workspace,
                root: context.root, project: project.path, projects: model.projects.map(\.path), output: tested.output,
                notBefore: nil, suite: "demo.core.GreeterTest", result: tested.testResults))
            #expect(results.summary.total == 1)
            #expect(results.summary.failed == 0)
            #expect(results.tests.first?.name == "greetsByName")
            #expect(try await sessions.pluginFunctions(of: provider).isEmpty)
            outcome = .success(())
        } catch { outcome = .failure(error) }
        // Shutdown is observed through the production session's release callback,
        // including after failed assertions/requests; the scratch workspace outlives it.
        sessions.retainProviders { _ in false }
        #expect(await released.waitUntilOpen(timeout: .seconds(5)))
        #expect(try Self.inventory(package) == before)
        try outcome.get()
    }

    private static func withTool(_ request: BuildProviderRequest, maven: URL) -> BuildProviderRequest {
        guard case .object(var params) = request.params else { return request }
        params["tool"] = .object(["executable": .string(maven.path)])
        return BuildProviderRequest(method: request.method, params: .object(params), optionFingerprint: request.optionFingerprint,
            executesProjectCode: request.executesProjectCode, mayUseNetwork: request.mayUseNetwork)
    }

    static func inventory(_ root: URL) throws -> [String: String] {
        let files = FileManager.default
        let paths = try files.subpathsOfDirectory(atPath: root.path).sorted()
        return try Dictionary(uniqueKeysWithValues: paths.map { relative in
            let path = root.appendingPathComponent(relative)
            let attributes = try files.attributesOfItem(atPath: path.path)
            let type = attributes[.type] as? FileAttributeType
            let digest = type == .typeRegular ? SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined() : "directory"
            return (relative, "\(attributes[.posixPermissions] ?? ""):\(digest)")
        })
    }
}

private enum NativeProviderIntegrationError: Error { case unexpectedCommand }
@MainActor
private final class ExplicitNativeConfigurationTool: BuildToolResolving {
    let maven: URL
    init(maven: URL) { self.maven = maven }
    func resolve(_ invocation: BuildInvocation, displayName: String, workspaceURL: URL,
                 checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck) async throws -> ResolvedBuildTool {
        ResolvedBuildTool(executableURL: maven, environment: [:], executesProjectCode: false, version: nil)
    }
}
@MainActor private final class NativeProviderProgress { var output = "" }

/// Explicit test-selected executable paths. All process/RPC execution is real;
/// this port avoids reading or modifying the user's runtime preferences.
@MainActor
final class ExplicitProviderRuntime: BuildToolResolving, LanguageToolRuntimePort {
    let java: URL
    let environment: [String: String]
    init(java: URL, environment: [String: String]) {
        self.java = java
        var values = environment
        values["JAVA_HOME"] = java.deletingLastPathComponent().deletingLastPathComponent().path
        self.environment = values
    }
    func resolve(_ invocation: BuildInvocation, displayName: String, workspaceURL: URL,
                 checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck) async throws -> ResolvedBuildTool {
        ResolvedBuildTool(executableURL: java, environment: environment, executesProjectCode: false, version: nil)
    }
    func executableOnPath(_ name: String) -> URL? { name == "java" ? java : nil }
    func executableURL(at path: String) -> URL? { path == java.path ? java : nil }
    func executableCandidates(_ command: String) -> [RuntimeToolCandidate] { [] }
    func languageToolProcessEnvironment(runtimeTools: [String]) -> [String: String] { environment }
    func missingLanguageToolMessage(_ name: String) -> String { name }
}

/// This integration never reads or writes the user's saved runtime preferences.
private struct NativeDefinedToolPreferences: KeyValueStore {
    func data(forKey key: String) -> Data? { nil }
    func object(forKey key: String) -> Any? { nil }
    func string(forKey key: String) -> String? { nil }
    func stringArray(forKey key: String) -> [String]? { nil }
    func set(_ value: Any?, forKey key: String) {}
}
