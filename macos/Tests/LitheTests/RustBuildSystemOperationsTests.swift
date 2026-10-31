import Foundation
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

/// The Swift side of the `build.*` commands against the real Rust Core and
/// the shared contract fixtures.
@Suite("Rust build system operations")
struct RustBuildSystemOperationsTests {
    private let operations = RustBuildSystemOperations(core: RustCoreBridge())

    @Test
    func providerReportsTravelInlineAndKeepRepeatedCasesInTheirProject() throws {
        let source = try Self.source("build-provider-reports")
        let target = BuildSystemTarget(manifest: source.manifest, buildSystemID: "gradle")
        #expect(source.buildSystems.first?.providerTestReports == true)
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("provider-reports-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let report = try JSONDecoder().decode(ToolingJSONValue.self, from: Data(#"{"format":"litheTestResults","version":1,"tests":[{"project":"a","suite":"Same","case":"checks","status":"failed"},{"project":"b","suite":"Same","case":"checks","status":"passed"}]}"#.utf8))
        let request = BuildTestResultsRequest(workspaceURL: workspace, root: ".", project: nil, projects: [],
            output: "", notBefore: nil, suite: nil, result: report)
        let result = try operations.decodeTestResults(target, request: request)
        #expect(result.summary.total == 2)
        #expect(result.summary.failed == 1)
        #expect(Set(result.tests.map(\.id)).count == 2)
        #expect(result.tests.map(\.project) == ["a", "b"])
        #expect(throws: (any Error).self) {
            try operations.decodeTestResults(target, request: BuildTestResultsRequest(workspaceURL: workspace,
                root: ".", project: nil, projects: [], output: "", notBefore: nil, suite: nil))
        }
    }

    @Test
    func descriptorDeclaresBuildSystemsAndTheirModule() throws {
        let descriptor = try Self.descriptor("build-static-file")
        let cargo = try #require(descriptor.buildSystems.first)

        #expect(cargo.id == "cargo")
        #expect(cargo.modelSource == .static)
        #expect(cargo.tasks.map(\.id) == ["build", "check", "clean", "example"])
        #expect(cargo.tasks.last?.scopes == [.target])
        #expect(cargo.tasks.last?.targetTags == ["example"])
        #expect(cargo.testScopes == [.project, .target])
        #expect(cargo.testTargetTags == ["test"])
        #expect(cargo.dependencyScopes.isEmpty)
        #expect(descriptor.pluginManifest.modules.map(\.manifest.id)
            .contains(.buildSystemsExtension(descriptor.id.rawValue)))

        let maven = try #require(Self.descriptor("build-host-integration").buildSystems.first)
        #expect(maven.modelSource == .hostIntegration)
        // A host-integration dependency source declares no scopes of its own.
        #expect(maven.dependencyScopes == [.workspace, .project])
    }

    @Test
    func detectionReadsStaticModelAndResolvesOptions() throws {
        let workspace = try Self.cargoWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try Self.source("build-static-file")

        let detection = try operations.detect(
            workspaceURL: workspace,
            sources: [source],
            options: ["cargo": ["release": .bool(true)]]
        )

        let instance = try #require(detection.instances.first)
        #expect(detection.rejected.isEmpty)
        #expect(instance.pluginID == source.pluginID)
        #expect(instance.buildSystemID == "cargo")
        #expect(instance.root == ".")
        let model = try #require(instance.model)
        #expect(model.projects.map(\.name) == ["demo"])
        #expect(model.targets.contains { $0.name == "demo" && $0.tags == ["application"] })
        #expect(model.optionValues["features"] == ["fast", "slow"])

        let target = BuildSystemTarget(manifest: source.manifest, buildSystemID: "cargo")
        let resolution = try operations.resolveOptions(
            target,
            options: ["features": .array([.string("fast"), .string("gone")])],
            modelValues: model.optionValues
        )
        let features = try #require(resolution.options.first { $0.id == "features" })
        #expect(features.value == .array([.string("fast")]))
        #expect(features.source == "user")
        #expect(features.kind == .multiSelect)
        #expect(features.choices.map(\.value) == ["fast", "slow"])
        #expect(resolution.dropped == ["features"])
    }

    @Test
    func invocationUsesTheGlobalExecutableSetting() throws {
        let target = try Self.target("build-tool-path", "fixture")
        let custom = try operations.invocationPlan(target, root: ".", settings: ["toolPath": .string("/opt/custom tools/build")])
        #expect(custom.executables.first == .setting(id: "toolPath", path: "/opt/custom tools/build"))
        #expect(try operations.invocationPlan(target, root: ".").executables.first == .setting(id: "toolPath", path: nil))
    }

    @Test
    func invocationAndVersionProbe() throws {
        let target = try Self.target("build-static-file", "cargo")

        let invocation = try operations.invocationPlan(target, root: ".")
        #expect(invocation.executables == [.command("cargo")])
        #expect(invocation.versionArguments == ["--version"])
        #expect(invocation.minimumVersion == "1.70")

        let current = try operations.checkToolVersion(target, runtime: nil, output: "cargo 1.80.1 (376290515 2024-07-16)\n")
        #expect(current == BuildVersionCheck(satisfied: true, version: "1.80.1"))
        let old = try operations.checkToolVersion(target, runtime: nil, output: "cargo 1.60.0 (d1fd9fe 2022-03-01)\n")
        #expect(old.satisfied == false)

        let go = try Self.target("build-command-stdout", "go")
        let goInvocation = try operations.invocationPlan(go, root: ".")
        #expect(goInvocation.executables == [.runtime("go")])
        #expect(goInvocation.runtimeDependencies.first?.hostManaged == true)
        #expect(goInvocation.runtimeDependencies.first?.versionArguments == ["version"])
        let goVersion = try operations.checkToolVersion(go, runtime: "go", output: "go version go1.22.3 darwin/arm64\n")
        #expect(goVersion.satisfied)
    }

    @Test
    func providerTaskPlanCarriesSelectionWithoutHostArguments() throws {
        let target = try Self.target("build-provider-execution", "gradle")
        let plan = try operations.taskPlan(
            target, context: BuildPlanContext(root: ".", options: ["offline": .bool(true)]),
            request: BuildTaskRequest(task: "build", project: BuildSelection(name: "app", path: "app"))
        )
        guard case .provider(let request) = plan, case .object(let params) = request.params else {
            Issue.record("Expected a typed provider execution plan")
            return
        }
        #expect(request.method == "lithe/build/execute")
        #expect(params["task"] == .string("build"))
        #expect(params["project"] == .object([
            "name": .string("app"), "path": .string("app"), "tags": .array([]), "properties": .object([:])
        ]))
        #expect(params["options"] == .object(["offline": .bool(true)]))
        #expect(request.executesProjectCode)
        #expect(request.mayUseNetwork)
    }

    @Test
    func providerServiceOptionsRoundTripThroughRealCoreAndRejectMissingChoices() throws {
        let descriptor = try Self.descriptor("build-provider-run-options")
        #expect(descriptor.buildSystems.first?.providerRuns.first?.execution == .service)
        let target = try Self.target("build-provider-run-options", "gradle")
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        for path in ["app", "tools"] { try FileManager.default.createDirectory(at: workspace.appendingPathComponent(path), withIntermediateDirectories: true) }
        struct Fixture: Decodable { let launchOptions: BuildLaunchOptions; let result: ToolingJSONValue }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/build-run-options.json")))
        let planner: any BuildSystemPlanning = operations
        let project = BuildSelection(name: "app", path: "app")
        let selected = BuildSelection(name: "Main", path: "app", tags: ["application"])
        let plan = try planner.prepareRunPlan(target, context: BuildPlanContext(root: "app", options: [:]), run: "service",
            project: project, selectedTarget: selected, userArguments: [], workspaceURL: workspace, launchOptions: fixture.launchOptions)
        guard case .object(let params) = plan.params else { Issue.record("Missing provider params"); return }
        let optionsJSON = try JSONDecoder().decode(ToolingJSONValue.self, from: JSONEncoder().encode(fixture.launchOptions))
        #expect(params["launchOptions"] == optionsJSON)
        let launch = try planner.decodeRunPreparation(target, workspaceURL: workspace, root: "app", result: fixture.result, launchOptions: fixture.launchOptions)
        #expect(launch.workingDirectory == "tools")
        #expect(launch.arguments == ["--file", "app/pom.xml", "framework:run"])
        #expect(throws: (any Error).self) {
            try planner.prepareRunPlan(target, context: BuildPlanContext(root: "app", options: [:]), run: "service",
                project: project, selectedTarget: selected, userArguments: [])
        }
        #expect(throws: (any Error).self) { try planner.decodeRunPreparation(target, workspaceURL: workspace, root: "app", result: fixture.result) }
        try FileManager.default.removeItem(at: workspace.appendingPathComponent("tools"))
        #expect(throws: (any Error).self) {
            try planner.decodeRunPreparation(target, workspaceURL: workspace, root: "app", result: fixture.result, launchOptions: fixture.launchOptions)
        }
    }

    @Test
    func providerRunPreparationRoundTripsThroughRealCore() throws {
        let descriptor = try Self.descriptor("build-provider-run-preparation")
        #expect(descriptor.buildSystems.first?.providerRuns.map(\.id) == ["application"])
        let target = try Self.target("build-provider-run-preparation", "gradle")
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("app"), withIntermediateDirectories: true)
        let plan = try operations.prepareRunPlan(target, context: BuildPlanContext(root: ".", options: ["offline": .bool(true)]),
            run: "application", project: BuildSelection(name: "app", path: "app"),
            selectedTarget: BuildSelection(name: "Main", path: "app", tags: ["application"]), userArguments: ["a b"])
        #expect(plan.method == "lithe/build/prepareRun")
        guard case .object(let params) = plan.params else { Issue.record("Missing provider params"); return }
        #expect(params["userArguments"] == .array([.string("a b")]))
        let result: ToolingJSONValue = .object(["executable": .object(["kind": .string("toolchain"), "value": .string("project-jdk")]),
            "arguments": .array([.string("Main"), .string("a b")]), "workingDirectory": .string("app"), "environment": .object([:])])
        let launch = try operations.decodeRunPreparation(target, workspaceURL: workspace, root: ".", result: result)
        #expect(launch.executable.kind == .toolchain)
        #expect(launch.executable.value == "project-jdk")
        #expect(launch.arguments == ["Main", "a b"])
        #expect(launch.workingDirectory == "app")
    }

    @Test
    func savedApplicationArgumentsKeepTheProtocolFourChannelThroughRealCore() throws {
        struct Fixture: Decodable {
            struct Expected: Decodable { let applicationReferenceUsesLaunchOptions: Bool }
            let reference: BuildProviderRunReference
            let expected: Expected
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/fixtures/run-configuration/build-provider.json")))
        let inputs = ProviderLaunchInputs(buildSystemID: fixture.reference.buildSystemID, provider: fixture.reference.run,
            projectPath: fixture.reference.root, launchOptions: BuildLaunchOptions(execution: .application, arguments: fixture.reference.userArguments),
            reference: fixture.reference)
        let arguments = try #require(inputs.opaqueReferenceArguments)
        let options = inputs.opaqueReferenceArguments == nil ? inputs.launchOptions : nil
        #expect((options != nil) == fixture.expected.applicationReferenceUsesLaunchOptions)
        let target = try Self.target("build-provider-run-preparation", "gradle")
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("app"), withIntermediateDirectories: true)
        let plan = try operations.prepareRunPlan(target, context: BuildPlanContext(root: "app", options: [:]),
            run: "application", project: BuildSelection(name: "app", path: "app"),
            selectedTarget: BuildSelection(name: "Main", path: "app", tags: ["application"]),
            userArguments: arguments, workspaceURL: workspace, launchOptions: options)
        guard case .object(let params) = plan.params else { Issue.record("Missing provider params"); return }
        #expect(params["userArguments"] == .array(fixture.reference.userArguments.map(ToolingJSONValue.string)))
        #expect(params["launchOptions"] == nil)
    }

    @Test
    func typedSavedApplicationOverridesRemainVersionGatedByRealCore() throws {
        let reference = BuildProviderRunReference(pluginID: "dev.example.gradle", buildSystemID: "gradle", root: ".",
            run: "application", projectID: "app", targetID: "main", userArguments: ["a b"])
        let inputs = ProviderLaunchInputs(buildSystemID: "gradle", provider: "application", projectPath: "app",
            launchOptions: BuildLaunchOptions(execution: .application, runtimeArguments: ["-Xmx64m"], arguments: reference.userArguments), reference: reference)
        #expect(inputs.opaqueReferenceArguments == nil)
        let target = try Self.target("build-provider-run-preparation", "gradle")
        #expect(throws: (any Error).self) {
            try operations.prepareRunPlan(target, context: BuildPlanContext(root: ".", options: [:]), run: "application",
                project: BuildSelection(name: "app", path: "app"), selectedTarget: BuildSelection(name: "Main", path: "app", tags: ["application"]),
                userArguments: inputs.opaqueReferenceArguments ?? [], launchOptions: inputs.launchOptions)
        }
    }

    @Test
    func providerDebugPreparationRoundTripsThroughRealCore() throws {
        let descriptor = try Self.descriptor("build-provider-debug-preparation")
        #expect(descriptor.buildSystems.first?.providerRuns.first?.debugAdapter == "native")
        let target = try Self.target("build-provider-debug-preparation", "gradle")
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let directory = workspace.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("native program".utf8).write(to: directory.appendingPathComponent("main"))
        let plan = try operations.prepareDebugPlan(target, context: BuildPlanContext(root: ".", options: ["offline": .bool(true)]),
            run: "application", project: BuildSelection(name: "app", path: "app"),
            selectedTarget: BuildSelection(name: "Main", path: "app", tags: ["application"]), userArguments: ["a b"])
        #expect(plan.method == "lithe/build/prepareDebug")
        guard case .object(let params) = plan.params else { Issue.record("Missing provider params"); return }
        #expect(params["userArguments"] == .array([.string("a b")]))
        let result: ToolingJSONValue = .object(["program": .string("app/main"), "arguments": .array([.string("a b")]),
            "workingDirectory": .string("app"), "environment": .object(["MODE": .string("debug")])])
        let prepared = try operations.decodeDebugPreparation(target, workspaceURL: workspace, root: "app", run: "application", result: result)
        #expect(prepared.adapter == "native")
        #expect(prepared.root == "app")
        #expect(prepared.program == "app/main")
        #expect(prepared.arguments == ["a b"])
        #expect(prepared.environment == ["MODE": "debug"])
    }

    @Test
    func providerTestPlanKeepsTypedFiltersAndReportPatterns() throws {
        let target = try Self.target("build-provider-tests", "gradle")
        let plan = try operations.testPlan(
            target, context: BuildPlanContext(root: ".", options: ["offline": .bool(true)]),
            request: BuildTestRequest(project: BuildSelection(name: "app", path: "app"),
                                      suite: "Suite", testCase: "case with spaces", userArguments: ["--rerun-tasks"])
        )
        guard case .provider(let request) = plan.execution, case .object(let params) = request.params else {
            Issue.record("Expected a provider test plan"); return
        }
        #expect(request.method == "lithe/build/test")
        #expect(params["suite"] == .string("Suite"))
        #expect(params["case"] == .string("case with spaces"))
        #expect(params["userArguments"] == .array([.string("--rerun-tasks")]))
        #expect(plan.results == .reports(decoder: "junitXml", patterns: ["app/build/test-results/**/*.xml"]))
    }

    @Test
    func discoveredSelectorsRoundTripThroughTheRealCore() throws {
        let descriptor = try Self.descriptor("build-provider-tests")
        #expect(descriptor.buildSystems.first?.testDiscovery == true)
        #expect(try Self.descriptor("build-static-file").buildSystems.first?.testDiscovery == false)
        let target = try Self.target("build-provider-tests", "gradle")
        let context = BuildPlanContext(root: ".", options: ["offline": .bool(true)])
        let plan = try operations.testDiscoveryPlan(target, context: context)
        #expect(plan.method == "lithe/build/discoverTests")
        let fixture = try JSONDecoder().decode(ToolingJSONValue.self, from: Data(contentsOf:
            DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/contracts/plugins/v1/fixtures/build-test-discovery.json")))
        guard case .object(let object) = fixture, let result = object["result"] else {
            Issue.record("Missing discovery result"); return
        }
        let discovery = try operations.decodeTestDiscovery(target, context: context, result: result)
        #expect(discovery.tests.count == 2)
        #expect(Set(discovery.tests.map(\.id)).count == 2)
        for test in discovery.tests {
            let execution = try operations.testPlan(target, context: context, request: test.request)
            guard case .provider(let request) = execution.execution, case .object(let params) = request.params else {
                Issue.record("Discovery selector must remain a provider test"); return
            }
            #expect(params["suite"] == .string(test.suite))
            #expect(params["case"] == .string(test.testCase))
        }
    }

    @Test
    func taskAndTestPlansCarryOptionsAndSelection() throws {
        let target = try Self.target("build-static-file", "cargo")
        let project = BuildModel.Project(id: "cargo:demo", path: "crates/demo", name: "demo")
        let context = BuildPlanContext(root: "crates/demo", options: ["release": .bool(true)])

        let build = try operations.taskPlan(
            target,
            context: context,
            request: BuildTaskRequest(task: "build", project: BuildSelection(project: project))
        )
        guard case .process(let build) = build else { Issue.record("Expected a command plan"); return }
        #expect(build.arguments == ["build", "--message-format=short", "--release"])
        #expect(build.workingDirectory == "crates/demo")
        #expect(build.output == nil)

        let tests = try operations.testPlan(
            target,
            context: context,
            request: BuildTestRequest(
                project: BuildSelection(project: project),
                target: BuildSelection(name: "integration", path: "crates/demo", tags: ["test"]),
                projects: ["crates/demo"]
            )
        )
        guard case .process(let process) = tests.execution else {
            Issue.record("Expected a command test plan"); return
        }
        #expect(process.arguments == ["test", "--release", "--test", "integration"])

        #expect(throws: DeclarativePluginRejection.self) {
            try operations.taskPlan(target, context: context, request: BuildTaskRequest(task: "missing"))
        }
        // `example` runs on a target only.
        #expect(throws: DeclarativePluginRejection.self) {
            try operations.taskPlan(
                target,
                context: context,
                request: BuildTaskRequest(task: "example", project: BuildSelection(project: project))
            )
        }
    }

    /// The bridge encodes the reload reason and the resolved tool as the
    /// `refresh` and `tool` fields Core copies into the provider params.
    @Test
    func providerPlansCarryTheReloadReasonAndTheResolvedTool() throws {
        let target = try Self.target("build-provider", "gradle")
        let context = BuildPlanContext(root: ".", options: [:])
        let executable = URL(fileURLWithPath: "/opt/tools/gradle/bin/gradle")

        let initial = try operations.modelPlan(
            target, context: context, outputFile: nil, providerHints: BuildProviderHints()
        )
        let reload = try operations.dependencyPlan(
            target, context: context, project: nil, outputFile: nil,
            providerHints: BuildProviderHints(reason: .refresh, toolExecutable: executable)
        )

        guard case .provider(let first) = initial, case .object(let firstParams) = first.params,
              case .provider(let second) = reload, case .object(let secondParams) = second.params else {
            Issue.record("Expected provider plans, got \(initial) and \(reload)")
            return
        }
        #expect(firstParams["refresh"] == nil)
        #expect(firstParams["tool"] == nil)
        #expect(secondParams["refresh"] == .bool(true))
        #expect(secondParams["tool"] == .object(["executable": .string(executable.path)]))
    }

    @Test
    func commandModelPlansAndDecodesStandardOutput() throws {
        let target = try Self.target("build-command-stdout", "go")
        let workspace = URL(fileURLWithPath: "/tmp/lithe-go-workspace")

        let plan = try operations.modelPlan(
            target, context: BuildPlanContext(root: ".", options: [:]), outputFile: nil,
            providerHints: BuildProviderHints()
        )
        guard case .process(let process) = plan else {
            Issue.record("Expected a process plan, got \(plan)")
            return
        }
        #expect(process.arguments == ["list", "-json", "./..."])
        #expect(process.output == .stdout)
        #expect(process.mayUseNetwork)

        let output = """
        {"Dir": "\(workspace.path)", "ImportPath": "example.com/app", "Name": "main",
         "Module": {"Path": "example.com/app", "Dir": "\(workspace.path)", "GoVersion": "1.22"}}
        """
        let model = try operations.decodeModel(
            target, workspaceURL: workspace, root: ".", output: .stdout(output), options: [:]
        )
        #expect(model.projects.map(\.name) == ["example.com/app"])
        #expect(model.targets.map(\.tags) == [["application"]])
    }

    @Test
    func diagnosticsAndSyncFingerprint() throws {
        let workspace = try Self.cargoWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let target = try Self.target("build-static-file", "cargo")

        let diagnostics = try operations.decodeDiagnostics(
            target,
            workspaceURL: workspace,
            root: ".",
            output: "   Compiling demo v0.1.0\nsrc/main.rs:3:5: error[E0425]: cannot find value `x` in this scope\n"
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.path == "src/main.rs")
        #expect(diagnostics.first?.line == 3)
        #expect(diagnostics.first?.column == 5)
        #expect(diagnostics.first?.severity == "error")

        let first = try operations.syncFingerprint(target, workspaceURL: workspace, root: ".", projects: ["."], options: [:])
        #expect(first.watch.contains("Cargo.toml"))
        #expect(first.watch.contains("Cargo.lock"))
        try Data("[package]\nname = \"demo\"\nversion = \"0.2.0\"\n".utf8)
            .write(to: workspace.appendingPathComponent("Cargo.toml"))
        let changed = try operations.syncFingerprint(target, workspaceURL: workspace, root: ".", projects: ["."], options: [:])
        #expect(changed.fingerprint != first.fingerprint)
    }

    @Test
    func languageImportMapsPluginOptionIDsWithoutBuildSystemNameAssumptions() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("gradle/wrapper"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Data("distributionUrl=fixture".utf8).write(
            to: workspace.appendingPathComponent("gradle/wrapper/gradle-wrapper.properties")
        )
        for kind in ["maven", "gradle"] {
            var manifest = try #require(JSONSerialization.jsonObject(with: Self.fixtureData("build-host-integration")) as? [String: Any])
            var systems = try #require(manifest["buildSystems"] as? [[String: Any]])
            systems[0]["languageImport"] = kind == "maven"
                ? ["kind": kind, "options": ["profiles": "profiles", "settingsFile": "settingsFile", "localRepository": "localRepository"]]
                : ["kind": kind, "options": ["offline": "offline", "gradleUserHome": "localRepository"]]
            manifest["buildSystems"] = systems
            let target = BuildSystemTarget(manifest: try JSONSerialization.data(withJSONObject: manifest), buildSystemID: "maven")
            let value = try operations.languageImport(
                target, workspaceURL: workspace, root: ".",
                options: ["profiles": .array([.string("dev")]), "settingsFile": .string("/settings.xml"),
                          "localRepository": .string("/cache"), "offline": .bool(true)],
                executableURL: URL(fileURLWithPath: "/tool/bin/mvn")
            )
            switch value {
            case .maven(let context):
                #expect(kind == "maven")
                #expect(context.profiles == ["dev"])
                #expect(context.settingsPath == "/settings.xml")
                #expect(context.localRepositoryPath == "/cache")
                #expect(context.mavenExecutablePath == "/tool/bin/mvn")
                #expect(!context.skipTests)
            case .gradle(let context):
                #expect(kind == "gradle")
                #expect(context == JavaGradleImportConfiguration(wrapperPresent: true, offline: true, userHome: "/cache"))
            case nil: Issue.record("Expected the declared language import")
            }
        }
        #expect(try operations.languageImport(
            Self.target("build-static-file", "cargo"), workspaceURL: workspace, root: ".", options: [:], executableURL: nil
        ) == nil)
    }

    @Test
    func modelInputsCrossTheRealCoreBridgeWithoutPrivatePlans() throws {
        let producer = try Self.source("build-model-producer")
        let consumer = try Self.source("build-model-consumer")
        #expect(producer.buildSystems.first?.sharesModel == true)
        #expect(consumer.buildSystems.first?.modelInputs == [.init(pluginID: producer.pluginID, buildSystemID: "source")])
        let model = try JSONDecoder().decode(BuildModel.self, from: Data("""
        {"projects":[{"id":"source:app/demo","path":"app","name":"demo","properties":{"group":"org.example"}}],
         "targets":[], "contentRoots":[], "tasks":[], "run":[{"command":"private"}], "optionValues":{}}
        """.utf8))
        let target = BuildSystemTarget(manifest: consumer.manifest, buildSystemID: "gradle")
        let snapshot = try operations.resolveModelInputs(target, revision: 9, sources: [
            BuildModelInputSource(manifest: producer.manifest, instances: [
                .init(buildSystemID: "source", root: "app", state: "ready", model: model, options: ["offline": .bool(true)])
            ])
        ])
        let context = BuildPlanContext(root: "app", options: [:], modelInputs: snapshot)
        guard case .provider(let request) = try operations.taskPlan(target, context: context, request: BuildTaskRequest(task: "build")),
              case .object(let params) = request.params, case .object(let wire)? = params["modelInputs"],
              case .array(let slots)? = wire["inputs"], case .object(let slot)? = slots.first,
              case .array(let instances)? = slot["instances"], case .object(let instance)? = instances.first,
              case .object(let shared)? = instance["model"] else {
            Issue.record("Expected the shared snapshot in the typed provider request"); return
        }
        #expect(params["modelInputs"] == snapshot)
        #expect(instance["options"] == .object(["offline": .bool(true)]))
        #expect(Set(shared.keys) == ["projects", "targets", "contentRoots"])
        #expect(shared["run"] == nil)
        #expect(throws: (any Error).self) {
            try operations.taskPlan(target, context: BuildPlanContext(root: "app", options: [:]), request: BuildTaskRequest(task: "build"))
        }
        let unavailable = try operations.resolveModelInputs(target, revision: 10, sources: [])
        guard case .object(let value) = unavailable, case .array(let slots)? = value["inputs"],
              case .object(let missing)? = slots.first else { Issue.record("Missing slot"); return }
        #expect(missing["state"] == .string("unavailable"))
        #expect(missing["instances"] == .array([]))
    }

    // MARK: Fixtures

    private static func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/\(name).plugin.json"))
    }

    private static func descriptor(_ name: String) throws -> DeclarativePluginDescriptor {
        try DeclarativePluginTestSupport.operations.validate(manifest: fixtureData(name))
    }

    private static func source(_ name: String) throws -> BuildSystemPluginSource {
        let descriptor = try descriptor(name)
        return BuildSystemPluginSource(
            pluginID: descriptor.id.rawValue,
            manifest: descriptor.normalizedManifest,
            packageURL: URL(fileURLWithPath: "/tmp/\(name)"),
            buildSystems: descriptor.buildSystems
        )
    }

    private static func target(_ name: String, _ buildSystemID: String) throws -> BuildSystemTarget {
        BuildSystemTarget(manifest: try descriptor(name).normalizedManifest, buildSystemID: buildSystemID)
    }

    private static func cargoWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-cargo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("""
        [package]
        name = "demo"
        version = "0.1.0"
        edition = "2021"

        [features]
        fast = []
        slow = []
        """.utf8).write(to: root.appendingPathComponent("Cargo.toml"))
        try Data("fn main() {}\n".utf8).write(to: root.appendingPathComponent("src/main.rs"))
        return root
    }
}
