import Foundation
import Testing
@testable import Lithe
import LitheCoreContracts
import LitheModuleAPI

/// `requires.serverProcess` 4: a server process that names a tool definition.
/// Rust Core plans the launch, the host resolves the tool through its four
/// layers or runs the runtime the plugin ships, and the definition's `launch`
/// template alone places every argument.
@Suite("Plugin server process tool reference")
struct PluginServerProcessToolReferenceTests {
    private static let fixtureURL = DeclarativePluginTestSupport.repositoryRoot
        .appendingPathComponent("shared/contracts/plugins/v1/fixtures/run/tool-reference-launch.plugin.json")
    private static let pluginDirectory = URL(fileURLWithPath: "/plugins/tool-reference")

    @Test func theHostAdvertisesToolReferenceServerProcesses() {
        #expect(PluginManifest.hostCapabilities["serverProcess"]?.contains(4) == true)
    }

    @Test func aToolLaunchPlanDecodesWithoutAnExecutableOrPackageEntry() throws {
        let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: Data(contentsOf: Self.fixtureURL))
        let plan = try DeclarativePluginTestSupport.operations.languageServerLaunchPlan(
            manifest: descriptor.normalizedManifest,
            languageID: "script",
            request: DeclarativeLanguageServerLaunchRequest(
                pluginDirectory: Self.pluginDirectory,
                stateDirectory: URL(fileURLWithPath: "/state"),
                workspaceStateDirectory: URL(fileURLWithPath: "/state/workspace"),
                architecture: MacPluginLanguageServerLaunchResolver.hostArchitecture
            )
        )

        let launch = try #require(plan.toolLaunch)
        #expect(launch.tool == "interpreter")
        #expect(launch.entry == Self.pluginDirectory.path + "/language-server/server.script")
        #expect(launch.runtimeArguments == ["-X", "utf8"])
        #expect(launch.minimumVersion == "3.9")
        #expect(launch.packagedRuntime == nil)
        // The plan's own arguments fill `${arguments}` only; the entry and
        // runtime arguments stay out of them.
        #expect(plan.arguments == ["--stdio"])
        #expect(plan.executable == nil)
        #expect(plan.entryPath == nil)
        #expect(plan.runtimeRequirements.contains {
            $0.tool == "interpreter" && $0.resolvesThroughDefinition
        })
    }

    @MainActor @Test func anUnresolvedToolIsReportedAsToolUnresolved() async throws {
        let workspace = try Self.temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let resolver = MacDefinedToolchainResolver()
        resolver.sources = { [] }

        do {
            _ = try await resolver.command(
                for: Self.process(packagedRuntimeURL: nil), arguments: ["--stdio"], workspace: workspace,
                environment: [:], projectCodeAllowed: false
            )
            Issue.record("A tool no layer resolves must not start.")
        } catch let rejection as DeclarativePluginRejection {
            #expect(rejection.code == "plugin.host.toolUnresolved")
            #expect(rejection.message.contains("interpreter"))
        }
    }

    @MainActor @Test func anUnresolvedRequirementStopsEvenAPackagedRuntime() async throws {
        let workspace = try Self.temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let resolver = MacDefinedToolchainResolver()
        let source = try Self.source(template: nil)
        resolver.sources = { [source] }
        let process = Self.process(
            packagedRuntimeURL: Self.pluginDirectory.appendingPathComponent("runtime/bin/interpreter"),
            requirements: [.init(tool: "formatter", minimumVersion: nil, resolvesThroughDefinition: true)]
        )

        do {
            _ = try await resolver.command(
                for: process, arguments: ["--stdio"], workspace: workspace, environment: [:], projectCodeAllowed: false
            )
            Issue.record("A requirement no layer resolves must not start.")
        } catch let rejection as DeclarativePluginRejection {
            #expect(rejection.code == "plugin.host.toolUnresolved")
            #expect(rejection.message.contains("formatter"))
        }
    }

    /// The packaged runtime runs as the tool without any lookup, and the
    /// template decides where the entry, runtime arguments and plan arguments
    /// go. The host adds nothing of its own.
    @MainActor @Test(arguments: [
        (
            nil as [String]?,
            ["-X", "utf8", "/plugins/tool-reference/language-server/server.script", "--stdio"]
        ),
        (
            ["${executable}", "${arguments}", "${runtimeArguments}", "${entry}"],
            ["--stdio", "-X", "utf8", "/plugins/tool-reference/language-server/server.script"]
        )
    ])
    func aPackagedRuntimeStartsDirectlyWithTheTemplateOrder(template: [String]?, expected: [String]) async throws {
        let workspace = try Self.temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let resolver = MacDefinedToolchainResolver()
        let source = try Self.source(template: template)
        resolver.sources = { [source] }
        let runtime = Self.pluginDirectory.appendingPathComponent("runtime/bin/interpreter")

        let command = try await resolver.command(
            for: Self.process(packagedRuntimeURL: runtime), arguments: ["--stdio"], workspace: workspace,
            environment: ["FIXTURE_SETTING": "kept"], projectCodeAllowed: false
        )

        #expect(command.executableURL.path == runtime.path)
        #expect(command.arguments == expected)
        #expect(command.environment["FIXTURE_SETTING"] == "kept")
    }

    @MainActor @Test func aTemplateThatCannotPlaceTheEntryRefusesTheLaunch() async throws {
        let workspace = try Self.temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let resolver = MacDefinedToolchainResolver()
        let source = try Self.source(template: ["${executable}", "${arguments}"])
        resolver.sources = { [source] }

        do {
            _ = try await resolver.command(
                for: Self.process(packagedRuntimeURL: Self.pluginDirectory.appendingPathComponent("runtime/bin/interpreter")),
                arguments: ["--stdio"], workspace: workspace, environment: [:], projectCodeAllowed: false
            )
            Issue.record("A template without `${entry}` must not drop the entry.")
        } catch let rejection as DeclarativePluginRejection {
            #expect(rejection.code != "plugin.host.toolUnresolved")
        }
    }

    // MARK: - Fixtures

    private static func process(
        packagedRuntimeURL: URL?,
        requirements: [DeclarativeLanguageServerLaunchPlan.RuntimeRequirement] = []
    ) -> DefinedToolProcessLaunch {
        DefinedToolProcessLaunch(
            launch: .init(
                tool: "interpreter",
                entry: pluginDirectory.path + "/language-server/server.script",
                runtimeArguments: ["-X", "utf8"],
                minimumVersion: "3.9",
                packagedRuntime: packagedRuntimeURL.map { _ in "runtime/bin/interpreter" }
            ),
            packagedRuntimeURL: packagedRuntimeURL,
            requirements: requirements
        )
    }

    /// The contract fixture as an installed plugin, with its definition's
    /// `launch` template replaced when one is given.
    private static func source(template: [String]?) throws -> ToolchainSettingsPluginSource {
        var manifest = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        if let template {
            var definitions = try #require(manifest["toolDefinitions"] as? [[String: Any]])
            definitions[0]["launch"] = template
            manifest["toolDefinitions"] = definitions
        }
        return ToolchainSettingsPluginSource(
            pluginID: "dev.lithe.fixture.tool-reference-launch", name: "Tool reference",
            manifest: try JSONSerialization.data(withJSONObject: manifest), isEnabled: true
        )
    }

    private static func temporaryWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-tool-reference-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
