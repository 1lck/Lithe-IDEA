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
    func descriptorDeclaresBuildSystemsAndTheirModule() throws {
        let descriptor = try Self.descriptor("cargo-build")
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

        let maven = try #require(Self.descriptor("maven-build").buildSystems.first)
        #expect(maven.modelSource == .hostIntegration)
        // A host-integration dependency source declares no scopes of its own.
        #expect(maven.dependencyScopes == [.workspace, .project])
    }

    @Test
    func detectionReadsStaticModelAndResolvesOptions() throws {
        let workspace = try Self.cargoWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = try Self.source("cargo-build")

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
    func invocationAndVersionProbe() throws {
        let target = try Self.target("cargo-build", "cargo")

        let invocation = try operations.invocationPlan(target, root: ".")
        #expect(invocation.executables == [.command("cargo")])
        #expect(invocation.versionArguments == ["--version"])
        #expect(invocation.minimumVersion == "1.70")

        let current = try operations.checkToolVersion(target, runtime: nil, output: "cargo 1.80.1 (376290515 2024-07-16)\n")
        #expect(current == BuildVersionCheck(satisfied: true, version: "1.80.1"))
        let old = try operations.checkToolVersion(target, runtime: nil, output: "cargo 1.60.0 (d1fd9fe 2022-03-01)\n")
        #expect(old.satisfied == false)

        let go = try Self.target("go-build", "go")
        let goInvocation = try operations.invocationPlan(go, root: ".")
        #expect(goInvocation.executables == [.runtime("go")])
        #expect(goInvocation.runtimeDependencies.first?.hostManaged == true)
        #expect(goInvocation.runtimeDependencies.first?.versionArguments == ["version"])
        let goVersion = try operations.checkToolVersion(go, runtime: "go", output: "go version go1.22.3 darwin/arm64\n")
        #expect(goVersion.satisfied)
    }

    @Test
    func taskAndTestPlansCarryOptionsAndSelection() throws {
        let target = try Self.target("cargo-build", "cargo")
        let project = BuildModel.Project(id: "cargo:demo", path: "crates/demo", name: "demo")
        let context = BuildPlanContext(root: "crates/demo", options: ["release": .bool(true)])

        let build = try operations.taskPlan(
            target,
            context: context,
            request: BuildTaskRequest(task: "build", project: BuildSelection(project: project))
        )
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
        #expect(tests.process.arguments == ["test", "--release", "--test", "integration"])

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

    @Test
    func commandModelPlansAndDecodesStandardOutput() throws {
        let target = try Self.target("go-build", "go")
        let workspace = URL(fileURLWithPath: "/tmp/lithe-go-workspace")

        let plan = try operations.modelPlan(target, context: BuildPlanContext(root: ".", options: [:]), outputFile: nil)
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
        let target = try Self.target("cargo-build", "cargo")

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
            var manifest = try #require(JSONSerialization.jsonObject(with: Self.fixtureData("maven-build")) as? [String: Any])
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
            Self.target("cargo-build", "cargo"), workspaceURL: workspace, root: ".", options: [:], executableURL: nil
        ) == nil)
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
