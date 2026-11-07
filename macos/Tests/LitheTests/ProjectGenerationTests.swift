import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

@Suite("New project generation")
@MainActor
struct ProjectGenerationTests {
    /// The published projectGenerators 2 fixture: `python-app` asks for a
    /// `python` tool of at least 3.11, `node-app` for an optional `node` tool.
    private static let toolFieldPluginID = PluginID("dev.lithe.fixture.project-generator-tool-field")
    /// The published fixture that defines a tool, for tests where a generator
    /// points its tool field at a tool another plugin defines.
    private static let toolDefinitionPluginID = PluginID("dev.lithe.fixture.java-support")
    private static let python310 = ProjectToolInstallation(
        home: "/opt/python-3.10", executable: "/opt/python-3.10/bin/python3", version: "3.10.14"
    )
    private static let python312 = ProjectToolInstallation(
        home: "/opt/python-3.12", executable: "/opt/python-3.12/bin/python3", version: "3.12.4"
    )

    // MARK: Creating projects

    @Test
    func refusesAnExistingDestination() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let existing = directory.url.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: existing.appendingPathComponent("notes.txt"))

        await #expect(throws: ProjectGenerationError.self) {
            try await Self.service().createEmptyProject(named: "demo", in: directory.url, createGitRepository: false)
        }
        #expect(try String(contentsOf: existing.appendingPathComponent("notes.txt"), encoding: .utf8) == "keep")
        #expect(try Self.stagingEntries(in: directory.url).isEmpty)
    }

    // MARK: Downloading archives

    /// An oversized body is cut off while it streams, whether or not the
    /// server declares its length, and a small one is kept whole.
    @Test
    func downloadsStopAtTheBudgetWhileStreaming() async throws {
        let platform = Self.downloadPlatform(maximumBytes: 1024)
        let small = try await platform.download(GeneratorServerURLProtocol.url(status: 200, bytes: 512))
        defer { try? FileManager.default.removeItem(at: small) }
        #expect(try Data(contentsOf: small).count == 512)
        for declaresLength in [false, true] {
            let url = GeneratorServerURLProtocol.url(status: 200, bytes: 64 * 1024, declaresLength: declaresLength)
            await #expect(throws: ProjectGenerationError.self) { _ = try await platform.download(url) }
        }
    }

    /// A refused request shows a short JSON explanation, but a large error
    /// body is neither read whole nor shown.
    @Test
    func refusedDownloadsReadABoundedExplanation() async throws {
        let platform = Self.downloadPlatform(maximumBytes: 1024)
        do {
            _ = try await platform.download(GeneratorServerURLProtocol.url(status: 400, bytes: 0, json: true))
            Issue.record("A refused request must fail")
        } catch let error as ProjectGenerationError {
            #expect(error.message.contains("Invalid Java version"))
        }
        do {
            let huge = MacProjectGenerationPlatform.maximumErrorBodyBytes * 4
            _ = try await platform.download(GeneratorServerURLProtocol.url(status: 500, bytes: huge))
            Issue.record("A refused request must fail")
        } catch let error as ProjectGenerationError {
            #expect(error.message.hasSuffix("status 500. "))
        }
    }

    // MARK: Tool fields: Rust Core

    @Test
    func catalogNamesThePluginsThatDefineEachTool() throws {
        let catalog = try Self.planner.catalog([try Self.toolFieldSource(enabled: true)])
        #expect(catalog.generators.map(\.generator.id) == ["python-app", "node-app"])
        // Nothing installed defines either tool.
        #expect(catalog.generators[0].tools == [ProjectToolProviders(fieldID: "python", tool: "python", providers: [])])
        #expect(catalog.generators[1].tools == [ProjectToolProviders(fieldID: "node", tool: "node", providers: [])])
    }

    @Test
    func toolFieldListsTheInstallationsAndFlagsOldOnes() throws {
        let target = try Self.toolFieldTarget("python-app")
        var input = ProjectGeneratorFormInput(projectName: "demo")
        input.tools["python"] = [Self.python310, Self.python312]

        let form = try Self.planner.form(target, input: input)
        let python = try #require(form.field("python"))
        #expect(python.installations.map(\.home) == [Self.python310.home, Self.python312.home])
        #expect(python.installations.map(\.meetsMinimum) == [false, true])
        // Without a choice the field holds the newest installation.
        #expect(python.value == .string(Self.python312.home))
        #expect(form.valid)

        input.values["python"] = .string(Self.python310.home)
        let old = try Self.planner.form(target, input: input)
        #expect(old.field("python")?.problem == .toolTooOld)
        #expect(!old.valid)
    }

    @Test
    func aToolFieldWithoutInstallationsIsRequiredUnlessOptional() throws {
        let input = ProjectGeneratorFormInput(projectName: "demo")

        let required = try Self.planner.form(try Self.toolFieldTarget("python-app"), input: input)
        #expect(required.field("python")?.problem == .required)
        #expect(required.field("python")?.installations == [])
        #expect(!required.valid)

        let optional = try Self.planner.form(try Self.toolFieldTarget("node-app"), input: input)
        #expect(optional.field("node")?.problem == nil)
        #expect(optional.valid)
    }

    @Test
    func theCommandsGetTheChosenInstallationAndItIsPinned() throws {
        var input = ProjectGeneratorFormInput(projectName: "demo")
        input.tools["python"] = [Self.python312]

        let plan = try Self.planner.plan(try Self.toolFieldTarget("python-app"), input: input)

        #expect(plan.toolPins == [
            ProjectGenerationPlan.ToolPin(
                field: "python", tool: "python", pinAs: "project",
                home: Self.python312.home, executable: Self.python312.executable
            )
        ])
        let commands = plan.steps.compactMap { step -> ProjectGenerationPlan.Command? in
            if case .command(let command) = step { return command }
            return nil
        }
        let command = try #require(commands.first)
        #expect(command.arguments == ["venv", "--python", Self.python312.executable])
        #expect(command.environment["PYTHON_HOME"] == Self.python312.home)
    }

    @Test
    func anOptionalToolWithoutInstallationIsNotPinned() throws {
        let plan = try Self.planner.plan(
            try Self.toolFieldTarget("node-app"), input: ProjectGeneratorFormInput(projectName: "demo")
        )
        #expect(plan.toolPins.isEmpty)
    }

    // MARK: Tool fields: creating projects

    @Test
    func savesTheChosenToolInstallationInTheNewProject() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let pins = ToolPinRecorder()
        let runner = ScaffoldingRunner(creates: nil)
        let service = Self.service(runner: runner, saveToolPin: { root, pin in
            await pins.record(root: root, pin: pin)
        })
        var input = ProjectGeneratorFormInput(projectName: "demo")
        input.tools["python"] = [Self.python312]

        let project = try await service.create(
            try Self.toolFieldTarget("python-app"), input: input, in: directory.url, createGitRepository: false
        )

        #expect(project.toolPinWarning == nil)
        let saved = await pins.saved
        #expect(saved.map(\.root) == [project.url.path])
        #expect(saved.map(\.pin.tool) == ["python"])
        #expect(saved.map(\.pin.home) == [Self.python312.home])
        // The step that uses the tool ran with the chosen installation.
        let request = try #require(runner.requests.first)
        #expect(request.arguments == ["venv", "--python", Self.python312.executable])
        #expect(request.environment["PYTHON_HOME"] == Self.python312.home)
    }

    @Test
    func aFailedPinIsReportedWithoutUndoingTheProject() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let service = Self.service(saveToolPin: { _, _ in
            throw ProjectGenerationError(message: "local.json is locked")
        })
        var input = ProjectGeneratorFormInput(projectName: "demo")
        input.tools["python"] = [Self.python312]

        let project = try await service.create(
            try Self.toolFieldTarget("python-app"), input: input, in: directory.url, createGitRepository: false
        )

        #expect(project.toolPinWarning == "local.json is locked")
        #expect(FileManager.default.fileExists(atPath: project.url.appendingPathComponent("README.md").path))
    }

    // MARK: Tool fields: window

    @Test
    func aToolFieldOffersWhatTheHostFound() async throws {
        let requests = ToolListingRequests()
        let feature = NewProjectFeatureModel(environment: try Self.environment(
            plugins: PluginStates(enabled: [Self.toolFieldPluginID]),
            sources: [try Self.toolFieldSource(enabled: true)],
            toolInstallations: { tools in
                requests.record(tools)
                return ["python": [Self.python310, Self.python312]]
            }
        ))
        await feature.load()
        let python = try #require(feature.selectedEntry?.generator.fields.first { $0.id == "python" })
        await Self.waitUntil("the python installations") { feature.toolChoices(for: python).count == 2 }

        #expect(requests.requested.first == ["python"])
        #expect(feature.toolChoices(for: python).map(\.meetsMinimum) == [false, true])
        #expect(feature.value(of: python) == .string(Self.python312.home))
        #expect(feature.canCreate)
        // Both are listed; only the one new enough can be chosen.
        #expect(feature.toolOptions(for: python) == [Self.python310.home, Self.python312.home])
        #expect(!feature.isToolChoosable(Self.python310.home, for: python))
        #expect(feature.isToolChoosable(Self.python312.home, for: python))

        // The window does not offer an installation below the minimum; one set
        // anyway is still judged by Core and blocks creating.
        feature.setValue(.string(Self.python310.home), for: python)
        #expect(feature.problem(of: python) == .toolTooOld)
        #expect(!feature.canCreate)
    }

    @Test
    func anOptionalToolWithOnlyOldInstallationsOffersNone() async throws {
        let node16 = ProjectToolInstallation(home: "/opt/node-16", executable: "/opt/node-16/bin/node", version: "16.20.2")
        let feature = NewProjectFeatureModel(environment: try Self.environment(
            plugins: PluginStates(enabled: [Self.toolFieldPluginID]),
            sources: [try Self.toolFieldSource(enabled: true)],
            toolInstallations: { _ in ["node": [node16]] }
        ))
        await feature.load()
        let entry = try #require(feature.entries.first { $0.generator.id == "node-app" })
        feature.selection = .generator(entry.id)
        let node = try #require(entry.generator.fields.first { $0.id == "node" })
        await Self.waitUntil("the node installations") { feature.toolChoices(for: node).count == 1 }

        // Node.js is optional and 16 is below 18, so the project goes without it.
        #expect(feature.value(of: node) == .string(""))
        #expect(feature.toolOptions(for: node) == ["", node16.home])
        #expect(feature.isToolChoosable("", for: node))
        #expect(!feature.isToolChoosable(node16.home, for: node))
        #expect(feature.problem(of: node) == nil)
        #expect(feature.canCreate)
    }

    @Test
    func aToolNobodyDefinesSendsTheUserToTheMarketplace() async throws {
        let feature = NewProjectFeatureModel(environment: try Self.environment(
            plugins: PluginStates(enabled: [Self.toolFieldPluginID]),
            sources: [try Self.toolFieldSource(enabled: true)]
        ))
        await feature.load()
        let python = try #require(feature.selectedEntry?.generator.fields.first { $0.id == "python" })
        await Self.waitUntil("the tool lookup") { !feature.isListingTools }

        #expect(feature.toolChoices(for: python).isEmpty)
        #expect(feature.toolNoticeAction(for: python) == .findInMarketplace("python"))
        #expect(!feature.canCreate)
    }

    @Test
    func aDisabledPluginThatDefinesTheToolIsOfferedForEnabling() async throws {
        let plugins = PluginStates(enabled: [Self.toolFieldPluginID])
        let feature = NewProjectFeatureModel(environment: try Self.environment(
            plugins: plugins,
            sources: [try Self.toolFieldSource(tool: "java", enabled: true), try Self.toolDefinitionSource()],
            toolInstallations: { _ in [:] }
        ))
        await feature.load()
        let field = try #require(feature.selectedEntry?.generator.fields.first { $0.id == "python" })
        await Self.waitUntil("the tool lookup") { !feature.isListingTools }
        #expect(feature.toolNoticeAction(for: field)
            == .enable(Self.toolDefinitionPluginID, name: "Tool definition fixture"))

        // Once the defining plugin is on, the tool is merely not installed.
        plugins.enabled.insert(Self.toolDefinitionPluginID)
        feature.reloadCatalog()
        await Self.waitUntil("the tool lookup") { !feature.isListingTools }
        #expect(feature.toolNoticeAction(for: field) == nil)
    }

    @Test
    func aPluginChangeReloadsTheEntriesAndLooksForToolsAgain() async throws {
        let plugins = PluginStates(enabled: [])
        let changes = PassthroughSubject<Void, Never>()
        let requests = ToolListingRequests()
        let feature = NewProjectFeatureModel(environment: try Self.environment(
            plugins: plugins,
            sources: [try Self.toolFieldSource(enabled: true)],
            toolInstallations: { tools in
                requests.record(tools)
                return [:]
            },
            pluginChanges: changes.eraseToAnyPublisher()
        ))
        await feature.load()
        await Self.waitUntil("the first tool lookup") { requests.requested.count == 1 }
        #expect(feature.entries.first?.pluginEnabled == false)

        plugins.enabled.insert(Self.toolFieldPluginID)
        changes.send()
        await Self.mainQueueTurn()

        #expect(feature.entries.first?.pluginEnabled == true)
        await Self.waitUntil("the second tool lookup") { requests.requested.count == 2 }
    }

    @Test
    func aPluginChangeDropsTheToolsListedForOtherEntries() async throws {
        let plugins = PluginStates(enabled: [Self.toolFieldPluginID, Self.toolDefinitionPluginID])
        let changes = PassthroughSubject<Void, Never>()
        let requests = ToolListingRequests()
        let feature = NewProjectFeatureModel(environment: try Self.environment(
            plugins: plugins,
            sources: [try Self.toolFieldSource(tool: "java", enabled: true), try Self.toolDefinitionSource()],
            toolInstallations: { tools in
                requests.record(tools)
                // Like discovery, only an enabled definition finds anything.
                let defined = plugins.enabled.contains(Self.toolDefinitionPluginID)
                return Dictionary(uniqueKeysWithValues: tools.map { ($0, defined ? [Self.python312] : []) })
            },
            pluginChanges: changes.eraseToAnyPublisher()
        ))
        await feature.load()
        let entry = try #require(feature.selectedEntry)
        let field = try #require(entry.generator.fields.first { $0.id == "python" })
        await Self.waitUntil("the first tool lookup") { feature.toolChoices(for: field).count == 1 }

        // The definition goes away while another entry is selected.
        feature.selection = .empty
        plugins.enabled.remove(Self.toolDefinitionPluginID)
        changes.send()
        await Self.mainQueueTurn()
        feature.selection = .generator(entry.id)

        // The installation the removed definition found is not offered again.
        #expect(!feature.canCreate)
        await Self.waitUntil("the tools to be looked up again") {
            requests.requested.count == 2 && !feature.isListingTools
        }
        #expect(feature.toolChoices(for: field).isEmpty)
        #expect(feature.toolNoticeAction(for: field) == .enable(Self.toolDefinitionPluginID, name: "Tool definition fixture"))
        #expect(!feature.canCreate)
    }

    @Test
    func aFailedToolLookupIsShownAndCanBeRetried() async throws {
        let lookup = ToolLookupOutcome()
        let feature = NewProjectFeatureModel(environment: try Self.environment(
            plugins: PluginStates(enabled: [Self.toolFieldPluginID]),
            sources: [try Self.toolFieldSource(enabled: true)],
            toolInstallations: { _ in
                if lookup.fails { throw CocoaError(.fileWriteNoPermission) }
                return ["python": [Self.python312]]
            }
        ))
        await feature.load()
        let python = try #require(feature.selectedEntry?.generator.fields.first { $0.id == "python" })
        await Self.waitUntil("the failed tool lookup") { !feature.isListingTools }

        // A lookup that did not run is not "nothing installed".
        #expect(feature.toolListingError(for: python) != nil)
        #expect(feature.toolNoticeAction(for: python) == nil)
        #expect(!feature.canCreate)

        lookup.fails = false
        feature.retryToolListing()
        await Self.waitUntil("the retried tool lookup") { feature.toolChoices(for: python).count == 1 }
        #expect(feature.toolListingError(for: python) == nil)
        #expect(feature.canCreate)
    }

    // MARK: Helpers

    private static var planner: RustProjectGeneratorOperations {
        RustProjectGeneratorOperations(core: RustCoreBridge())
    }

    private static func downloadPlatform(maximumBytes: Int64) -> MacProjectGenerationPlatform {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeneratorServerURLProtocol.self]
        configuration.timeoutIntervalForRequest = 10
        return MacProjectGenerationPlatform(
            environment: { $0 },
            executable: { _ in nil },
            runner: ScaffoldingRunner(creates: nil),
            session: URLSession(configuration: configuration),
            maximumDownloadBytes: maximumBytes
        )
    }

    private static func platform(runner: any BuildCommandRunning = ScaffoldingRunner(creates: nil)) -> MacProjectGenerationPlatform {
        MacProjectGenerationPlatform(
            environment: { $0.merging(["PATH": "/usr/bin:/bin"]) { override, _ in override } },
            // The scaffolding tools the tests' generators run by name.
            executable: { ["mvn", "uv"].contains($0) ? URL(fileURLWithPath: "/usr/local/bin/\($0)") : nil },
            runner: runner
        )
    }

    private static func service(
        runner: any BuildCommandRunning = ScaffoldingRunner(creates: nil),
        saveToolPin: @escaping @Sendable (URL, ProjectGenerationPlan.ToolPin) async throws -> Void = { _, _ in }
    ) -> ProjectGenerationService {
        ProjectGenerationService(
            planner: planner,
            platform: platform(runner: runner),
            initializeGitRepository: { _ in nil },
            saveToolPin: saveToolPin
        )
    }

    /// The window's environment over the given plugin sources; `plugins`
    /// decides which of them count as enabled on each reload.
    private static func environment(
        plugins: PluginStates,
        sources: [ProjectGeneratorPluginSource],
        toolInstallations: @escaping @MainActor ([String]) async throws -> [String: [ProjectToolInstallation]] = { _ in [:] },
        pluginChanges: AnyPublisher<Void, Never> = Empty<Void, Never>().eraseToAnyPublisher()
    ) throws -> NewProjectEnvironment {
        NewProjectEnvironment(
            sources: {
                sources.map {
                    ProjectGeneratorPluginSource(
                        pluginID: $0.pluginID, manifest: $0.manifest, packageURL: $0.packageURL,
                        isEnabled: plugins.enabled.contains($0.pluginID)
                    )
                }
            },
            iconResources: [:],
            service: service(),
            setPluginEnabled: { _ = plugins.enabled.insert($0) },
            openMarketplace: { _ in },
            openProject: { _ in },
            store: InMemoryStore(),
            toolInstallations: toolInstallations,
            pluginChanges: pluginChanges
        )
    }

    // MARK: Tool field fixtures

    /// The project-generator fixtures. The tool-field manifest's
    /// `templates/tool-field` source resolves against this directory.
    private static var generatorFixturesURL: URL {
        DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/project-generators", isDirectory: true)
    }

    private static var toolchainFixturesURL: URL {
        DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/toolchains", isDirectory: true)
    }

    /// The tool-field fixture's `plugin.json`. `tool` points its `python` field
    /// at another tool, to test fields whose tool a different plugin defines.
    private static func toolFieldManifest(tool: String? = nil) throws -> Data {
        let text = try String(
            contentsOf: generatorFixturesURL.appendingPathComponent("project-generator-tool-field.plugin.json"),
            encoding: .utf8
        )
        guard let tool else { return Data(text.utf8) }
        return Data(text.replacingOccurrences(of: "\"tool\": \"python\"", with: "\"tool\": \"\(tool)\"").utf8)
    }

    private static func toolFieldSource(tool: String? = nil, enabled: Bool) throws -> ProjectGeneratorPluginSource {
        ProjectGeneratorPluginSource(
            pluginID: toolFieldPluginID, manifest: try toolFieldManifest(tool: tool),
            packageURL: generatorFixturesURL, isEnabled: enabled
        )
    }

    private static func toolFieldTarget(_ generatorID: String) throws -> ProjectGeneratorTarget {
        ProjectGeneratorTarget(
            pluginID: toolFieldPluginID, generatorID: generatorID,
            manifest: try toolFieldManifest(), packageURL: generatorFixturesURL
        )
    }

    /// A disabled plugin that only defines a tool.
    private static func toolDefinitionSource() throws -> ProjectGeneratorPluginSource {
        ProjectGeneratorPluginSource(
            pluginID: toolDefinitionPluginID,
            manifest: try Data(contentsOf: toolchainFixturesURL.appendingPathComponent("tool-definition.plugin.json")),
            packageURL: toolchainFixturesURL, isEnabled: false
        )
    }

    /// Waits for `condition` with a two second deadline and records an issue
    /// naming what never happened, instead of leaving a stuck test to the CI
    /// timeout.
    private static func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if condition() { return }
            await Task.yield()
        }
        if !condition() { Issue.record("Timed out after two seconds waiting for \(what).") }
    }

    /// Returns after the work already queued on the main queue, such as a
    /// Combine `receive(on: .main)` delivery sent just before.
    private static func mainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static func stagingEntries(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains(".lithe-creating-") }
    }
}

// MARK: - Test doubles

/// Serves `https://generator.invalid/<status>/<bytes>` as that many zero
/// bytes, optionally with a Content-Length header, or a Spring Initializr
/// style JSON error, so downloads are exercised without a network.
private final class GeneratorServerURLProtocol: URLProtocol {
    static func url(status: Int, bytes: Int, declaresLength: Bool = false, json: Bool = false) -> URL {
        let query = json ? "?json" : declaresLength ? "?length" : ""
        return URL(string: "https://generator.invalid/\(status)/\(bytes)\(query)")!
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "generator.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let parts = request.url?.pathComponents.dropFirst().compactMap { Int($0) } ?? []
        guard let url = request.url, parts.count == 2 else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = url.query == "json"
            ? Data(#"{"message":"Invalid Java version"}"#.utf8)
            : Data(count: parts[1])
        var headers: [String: String] = [:]
        if url.query == "length" { headers["Content-Length"] = String(body.count) }
        let response = HTTPURLResponse(url: url, statusCode: parts[0], httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Several chunks, like a real body.
        var offset = 0
        while offset < body.count {
            let end = min(offset + 4096, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension ProjectGeneratorPluginSource {
    func with(enabled: Bool) -> Self {
        Self(pluginID: pluginID, manifest: manifest, packageURL: packageURL, isEnabled: enabled)
    }
}

private struct SavedToolPin: Equatable, Sendable {
    let root: String
    let pin: ProjectGenerationPlan.ToolPin
}

private actor ToolPinRecorder {
    private(set) var saved: [SavedToolPin] = []

    func record(root: URL, pin: ProjectGenerationPlan.ToolPin) {
        saved.append(SavedToolPin(root: root.path, pin: pin))
    }
}

/// The tools the window asked the host to look up, one entry per request.
@MainActor
private final class ToolListingRequests {
    private(set) var requested: [[String]] = []

    func record(_ tools: [String]) { requested.append(tools) }
}

@MainActor
private final class PluginStates {
    var enabled: Set<PluginID>

    init(enabled: Set<PluginID>) { self.enabled = enabled }
}

/// Whether the stand-in tool lookup fails, switched by the test.
private final class ToolLookupOutcome {
    var fails = true
}

/// Stands in for a scaffolding tool: records the request and creates one
/// file in its working directory, as `mvn archetype:generate` creates the
/// project in a subdirectory.
private final class ScaffoldingRunner: BuildCommandRunning, @unchecked Sendable {
    private let creates: String?
    private let exitStatus: Int32
    private let lock = NSLock()
    private var recorded: [BuildCommandRequest] = []

    init(creates: String?, exitStatus: Int32 = 0) {
        self.creates = creates
        self.exitStatus = exitStatus
    }

    var requests: [BuildCommandRequest] { lock.withLock { recorded } }

    func run(_ request: BuildCommandRequest, onOutput: @escaping @Sendable (String) -> Void) async throws
        -> BuildCommandResult {
        lock.withLock { recorded.append(request) }
        if let creates {
            let file = request.workingDirectory.appendingPathComponent(creates)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("<project/>".utf8).write(to: file)
        }
        onOutput("[INFO] done\n")
        return BuildCommandResult(termination: .exited(exitStatus))
    }
}

/// Serves a local zip for an archive step instead of the network.
private final class DownloadStubPlatform: ProjectGenerationPlatform, @unchecked Sendable {
    private let base: MacProjectGenerationPlatform
    private let archive: URL
    private let lock = NSLock()
    private var requested: URL?
    private var copy: URL?

    init(base: MacProjectGenerationPlatform, archive: URL) {
        self.base = base
        self.archive = archive
    }

    var requestedURL: URL? { lock.withLock { requested } }
    var downloadedCopy: URL? { lock.withLock { copy } }

    func download(_ url: URL) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-project-test-\(UUID().uuidString).zip")
        try FileManager.default.copyItem(at: archive, to: destination)
        lock.withLock {
            requested = url
            copy = destination
        }
        return destination
    }

    func makeStagingDirectory(in parent: URL, for projectName: String) throws -> URL {
        try base.makeStagingDirectory(in: parent, for: projectName)
    }

    func writeFile(_ contents: String, to url: URL, executable: Bool) throws {
        try base.writeFile(contents, to: url, executable: executable)
    }

    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }

    func runCommand(
        _ command: ProjectGenerationPlan.Command,
        in directory: URL,
        environment: [String: String],
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        try await base.runCommand(command, in: directory, environment: environment, onOutput: onOutput)
    }

    func collect(_ subdirectory: URL, into root: URL) throws { try base.collect(subdirectory, into: root) }
    func moveItem(at source: URL, to destination: URL) throws { try base.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) { base.removeItem(at: url) }
    func itemExists(at url: URL) -> Bool { base.itemExists(at: url) }
}

private final class InMemoryStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

/// A directory below the system temporary directory, removed by `remove()`.
private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-new-project-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
