import Foundation
@testable import Lithe
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import LitheModuleAPI
import Testing

/// A server whose plugin backend names the process (`serverProcess` 3). The
/// plugin is a Metals stub: Rust Core builds the question and bounds the
/// answer, the host runs the backend call, resolves the program, and keeps
/// every file outside the package.
@MainActor
struct PluginBackendLaunchTests {
    // MARK: Resolver: the question

    @Test
    func theQuestionNamesTheBackendFunctionAndCreatesThisStartsDirectories() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }

        let question = try fixture.resolver.backendLaunchQuestion(
            for: fixture.source, workspaceRootURL: fixture.workspaceURL
        )

        #expect(question.function == "metals.resolveLaunch")
        #expect(question.timeoutMilliseconds == 30_000)
        #expect(question.resolveParams["serverID"] == .string("scala"))
        #expect(question.resolveParams["temporaryDirectory"] == .string(question.scratchDirectory.path))
        #expect(question.request.temporaryDirectory == question.scratchDirectory)
        #expect(isDirectory(question.scratchDirectory))
        #expect(isDirectory(question.request.stateDirectory))
        #expect(question.request.workspaceStateDirectory.map(isDirectory) == true)
        #expect(!question.scratchDirectory.path.hasPrefix(fixture.source.packageURL.path + "/"))
    }

    @Test
    func everyStartGetsItsOwnScratchDirectory() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }

        let first = try fixture.resolver.backendLaunchQuestion(for: fixture.source, workspaceRootURL: fixture.workspaceURL)
        let second = try fixture.resolver.backendLaunchQuestion(for: fixture.source, workspaceRootURL: fixture.workspaceURL)

        #expect(first.scratchDirectory != second.scratchDirectory)
    }

    @Test
    func aServerTheBackendDoesNotResolveGetsNoQuestionAndLeavesNoScratch() throws {
        let fixture = try Fixture.make(manifest: "language-packaged-server.plugin.json", languageID: "php")
        defer { fixture.remove() }

        let code = rejectionCode {
            _ = try fixture.resolver.backendLaunchQuestion(for: fixture.source, workspaceRootURL: fixture.workspaceURL)
        }

        #expect(code == "plugin.launch.notBackend")
        #expect(fixture.scratchEntries().isEmpty)
    }

    // MARK: Resolver: the answer

    @Test
    func aPackagedAnswerBecomesAFileProgramWithItsSessionPolicy() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let question = try fixture.question()
        let cache = question.scratchDirectory.appendingPathComponent("coursier/cache")

        let process = try fixture.resolver.backendLaunchProcess(
            for: fixture.source,
            question: question,
            answer: Fixture.packagedAnswer(writing: cache)
        )

        #expect(process.program == .file(fixture.metalsURL))
        #expect(process.environment == ["COURSIER_CACHE": cache.path])
        #expect(process.launch.arguments == ["-Dmetals.client=lithe"])
        #expect(process.launch.initializationOptions == .object(["isHttpEnabled": .bool(false)]))
        let policy = try #require(process.launch.sessionPolicy)
        guard case .object(let fields) = policy else { throw PolicyShapeError() }
        #expect(fields["serverID"] == .string("scala"))
        #expect(fields["gates"] != nil)
        // The host makes the place the server writes to, never the files in it.
        #expect(isDirectory(cache.deletingLastPathComponent()))
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test
    func aToolAnswerStaysANameForTheHostToResolve() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let question = try fixture.question()

        let process = try fixture.resolver.backendLaunchProcess(
            for: fixture.source, question: question, answer: Fixture.toolAnswer("coursier")
        )

        #expect(process.program == .tool("coursier"))
    }

    @Test
    func aPathOutsideThePackageIsRejectedByCore() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let question = try fixture.question()

        let code = rejectionCode {
            _ = try fixture.resolver.backendLaunchProcess(
                for: fixture.source, question: question, answer: Fixture.packagedAnswer(path: "../outside")
            )
        }

        #expect(code == "plugin.launch.outsidePackage")
    }

    @Test
    func aToolThePluginDoesNotDefineIsRejectedByCore() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let question = try fixture.question()

        let code = rejectionCode {
            _ = try fixture.resolver.backendLaunchProcess(
                for: fixture.source, question: question, answer: Fixture.toolAnswer("ghost")
            )
        }

        #expect(code == "plugin.launch.undeclaredTool")
    }

    @Test
    func aWritablePathOutsideTheHostDirectoriesIsRejectedByCore() throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let question = try fixture.question()

        let code = rejectionCode {
            _ = try fixture.resolver.backendLaunchProcess(
                for: fixture.source,
                question: question,
                answer: Fixture.packagedAnswer(writing: URL(fileURLWithPath: "/etc/metals"))
            )
        }

        #expect(code == "plugin.launch.unwritablePath")
    }

    @Test
    func aPackagedFileThatIsNotExecutableIsNotStarted() throws {
        let fixture = try Fixture.make(executable: false)
        defer { fixture.remove() }
        let question = try fixture.question()

        #expect(throws: MacPluginLanguageServerLaunchResolver.ResolutionError.packagedExecutableNotRunnable("bin/metals")) {
            _ = try fixture.resolver.backendLaunchProcess(
                for: fixture.source, question: question, answer: Fixture.packagedAnswer()
            )
        }
    }

    // MARK: Preparer

    @Test
    func aPackagedAnswerPreparesTheProcessAndTheReleaseRemovesTheScratch() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let window = NSObject()
        let context = fixture.contexts.open(owner: window, rootURL: fixture.workspaceURL, remote: nil)
        let backends = ScriptedBackends { params in
            Fixture.packagedAnswer(writing: Fixture.scratch(of: params).appendingPathComponent("coursier"))
        }
        let tools = ScriptedTools()
        let preparer = fixture.preparer(backends: backends, tools: tools)

        let prepared = try await preparer.prepare(fixture.source, workspaceURL: fixture.workspaceURL)

        let call = try #require(backends.calls.first)
        #expect(backends.calls.count == 1)
        #expect(call.function == "metals.resolveLaunch")
        #expect(call.pluginID == fixture.source.pluginID)
        #expect(call.context == context.reference)
        #expect(call.timeout == .milliseconds(30_000))
        #expect(prepared.executableURL == fixture.metalsURL)
        #expect(prepared.launch.arguments == ["-Dmetals.client=lithe"])
        #expect(prepared.environment["COURSIER_CACHE"] != nil)
        #expect(tools.invocations.isEmpty)
        #expect(fixture.scratchEntries().count == 1)

        await prepared.release()

        #expect(fixture.scratchEntries().isEmpty)
        fixture.contexts.close(owner: window)
    }

    @Test
    func aToolAnswerIsResolvedAsTheToolchainOfTheOpenedRoot() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let window = NSObject()
        fixture.contexts.open(owner: window, rootURL: fixture.workspaceURL, remote: nil)
        let backends = ScriptedBackends { _ in Fixture.toolAnswer("coursier") }
        let tools = ScriptedTools(result: ResolvedBuildTool(
            executableURL: URL(fileURLWithPath: "/host/bin/cs"), environment: ["PATH": "/host/bin"],
            executesProjectCode: false, version: "2.1.0"
        ))
        let preparer = fixture.preparer(backends: backends, tools: tools)

        let prepared = try await preparer.prepare(fixture.source, workspaceURL: fixture.workspaceURL)

        #expect(tools.invocations.map(\.executables) == [[.toolchain(id: "coursier", root: ".")]])
        #expect(prepared.executableURL == URL(fileURLWithPath: "/host/bin/cs"))
        #expect(prepared.environment["PATH"] == "/host/bin")
        await prepared.release()
        fixture.contexts.close(owner: window)
    }

    @Test
    func aToolInsideTheProjectIsRefusedAndTheScratchGoes() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let window = NSObject()
        fixture.contexts.open(owner: window, rootURL: fixture.workspaceURL, remote: nil)
        let backends = ScriptedBackends { _ in Fixture.toolAnswer("coursier") }
        let tools = ScriptedTools(result: ResolvedBuildTool(
            executableURL: fixture.workspaceURL.appendingPathComponent("cs"), environment: [:],
            executesProjectCode: true, version: nil
        ))
        let preparer = fixture.preparer(backends: backends, tools: tools)

        await #expect(throws: MacPluginBackendLaunchPreparer.PrepareError.toolRunsProjectCode("coursier")) {
            _ = try await preparer.prepare(fixture.source, workspaceURL: fixture.workspaceURL)
        }

        #expect(fixture.scratchEntries().isEmpty)
        fixture.contexts.close(owner: window)
    }

    @Test
    func aFailingBackendEndsTheStartAndTheScratchGoes() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let window = NSObject()
        fixture.contexts.open(owner: window, rootURL: fixture.workspaceURL, remote: nil)
        let backends = ScriptedBackends(failure: BackendFailure())
        let preparer = fixture.preparer(backends: backends, tools: ScriptedTools())

        await #expect(throws: BackendFailure.self) {
            _ = try await preparer.prepare(fixture.source, workspaceURL: fixture.workspaceURL)
        }

        #expect(fixture.scratchEntries().isEmpty)
        fixture.contexts.close(owner: window)
    }

    @Test
    func aRejectedAnswerEndsTheStartWithCoresCode() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let window = NSObject()
        fixture.contexts.open(owner: window, rootURL: fixture.workspaceURL, remote: nil)
        let backends = ScriptedBackends { _ in Fixture.toolAnswer("ghost") }
        let preparer = fixture.preparer(backends: backends, tools: ScriptedTools())

        do {
            _ = try await preparer.prepare(fixture.source, workspaceURL: fixture.workspaceURL)
            Issue.record("An undeclared tool must not start")
        } catch let rejection as DeclarativePluginRejection {
            #expect(rejection.code == "plugin.launch.undeclaredTool")
        }

        #expect(fixture.scratchEntries().isEmpty)
        fixture.contexts.close(owner: window)
    }

    @Test
    func aWorkspaceThatChangedWhileTheBackendWorkedDoesNotStartTheProcess() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let window = NSObject()
        fixture.contexts.open(owner: window, rootURL: fixture.workspaceURL, remote: nil)
        let backends = ScriptedBackends { _ in Fixture.packagedAnswer() }
        // The window moves to another workspace while the backend answers.
        backends.onInvoke = { [contexts = fixture.contexts] in
            contexts.open(owner: window, rootURL: URL(fileURLWithPath: "/tmp/other-workspace"), remote: nil)
        }
        let preparer = fixture.preparer(backends: backends, tools: ScriptedTools())

        await #expect(throws: CancellationError.self) {
            _ = try await preparer.prepare(fixture.source, workspaceURL: fixture.workspaceURL)
        }

        #expect(fixture.scratchEntries().isEmpty)
        fixture.contexts.close(owner: window)
    }

    @Test
    func aFolderNoWindowShowsIsRefusedBeforeAnythingStarts() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let backends = ScriptedBackends { _ in Fixture.packagedAnswer() }
        let preparer = fixture.preparer(backends: backends, tools: ScriptedTools())

        await #expect(throws: MacPluginBackendLaunchPreparer.PrepareError.workspaceNotOpen) {
            _ = try await preparer.prepare(fixture.source, workspaceURL: fixture.workspaceURL)
        }

        #expect(backends.calls.isEmpty)
        #expect(fixture.scratchEntries().isEmpty)
    }

    // MARK: Context lookup

    @Test
    func aLocalContextIsFoundByItsFolderAndARemoteOneIsNot() {
        let contexts = PluginWorkspaceContexts()
        let local = NSObject()
        let remote = NSObject()
        let opened = contexts.open(owner: local, rootURL: URL(fileURLWithPath: "/tmp/orders"), remote: nil)
        contexts.open(
            owner: remote, rootURL: URL(fileURLWithPath: "/tmp/remote-mirror"),
            remote: (connectionID: "c-1", remoteRoot: "/srv/app")
        )

        #expect(contexts.localContext(forFolder: URL(fileURLWithPath: "/tmp/orders/")) == opened)
        #expect(contexts.localContext(forFolder: URL(fileURLWithPath: "/tmp/remote-mirror")) == nil)
        #expect(contexts.localContext(forFolder: URL(fileURLWithPath: "/tmp/other")) == nil)
        contexts.close(owner: local)
        contexts.close(owner: remote)
    }

    // MARK: Helpers

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func rejectionCode(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let rejection as DeclarativePluginRejection {
            return rejection.code
        } catch {
            return "other: \(error)"
        }
    }
}

private struct PolicyShapeError: Error {}
private struct BackendFailure: Error {}

// MARK: Fixture

/// The Metals stub: an installed package with a launcher script, a state
/// root, and a workspace folder, all in one temporary directory.
@MainActor
private struct Fixture {
    let root: URL
    let source: DeclarativeLanguageServerLaunchSource
    let directories: MacPluginStateDirectories
    let resolver: MacPluginLanguageServerLaunchResolver
    let workspaceURL: URL
    let contexts = PluginWorkspaceContexts()

    var metalsURL: URL { source.packageURL.appendingPathComponent("bin/metals").standardizedFileURL }

    static func make(
        manifest: String = "language-server-backend-launch.plugin.json",
        languageID: String = "scala",
        executable: Bool = true
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-backend-launch-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("package", isDirectory: true)
        let launcher = package.appendingPathComponent("bin/metals")
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: launcher.path)

        let operations = DeclarativePluginTestSupport.operations
        let manifestData = try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/languages")
            .appendingPathComponent(manifest))
        let descriptor = try operations.validate(manifest: manifestData)
        let directories = MacPluginStateDirectories(
            rootURL: root.appendingPathComponent("state", isDirectory: true),
            temporaryRootURL: root.appendingPathComponent("scratch", isDirectory: true)
        )
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return Fixture(
            root: root,
            source: DeclarativeLanguageServerLaunchSource(
                pluginID: descriptor.id.rawValue, languageID: languageID,
                manifest: descriptor.normalizedManifest, packageURL: package,
                resolvesLaunchWithBackend: true
            ),
            directories: directories,
            resolver: MacPluginLanguageServerLaunchResolver(
                planner: operations, directories: directories, settings: InMemoryPluginSettings(),
                logDirectory: { _ in logs }
            ),
            workspaceURL: workspace.standardizedFileURL
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func question() throws -> MacPluginLanguageServerLaunchResolver.BackendLaunchQuestion {
        try resolver.backendLaunchQuestion(for: source, workspaceRootURL: workspaceURL)
    }

    /// Directories a start left in the scratch area.
    func scratchEntries() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directories.temporaryRootURL.path)) ?? []
    }

    func preparer(backends: ScriptedBackends, tools: ScriptedTools) -> MacPluginBackendLaunchPreparer {
        MacPluginBackendLaunchPreparer(
            backends: backends, contexts: contexts, resolver: resolver, tools: tools,
            runtime: NoToolRuntime(), core: RustCoreBridge()
        )
    }

    /// The scratch directory the host named in the function's params.
    static func scratch(of params: ToolingJSONValue) -> URL {
        guard case .object(let fields) = params, case .string(let path)? = fields["temporaryDirectory"] else {
            return URL(fileURLWithPath: "/missing-scratch")
        }
        return URL(fileURLWithPath: path)
    }

    /// What the stub's `metals.resolveLaunch` answers for a packaged start.
    static func packagedAnswer(path: String = "bin/metals", writing writable: URL? = nil) -> ToolingJSONValue {
        var fields: [String: ToolingJSONValue] = [
            "executable": .object(["kind": .string("packaged"), "path": .string(path)]),
            "arguments": .array([.string("-Dmetals.client=lithe")]),
            "initializationOptions": .object(["isHttpEnabled": .bool(false)])
        ]
        if let writable {
            fields["environment"] = .object(["COURSIER_CACHE": .string(writable.path)])
            fields["writablePaths"] = .array([.string(writable.path)])
        }
        return .object(fields)
    }

    static func toolAnswer(_ tool: String) -> ToolingJSONValue {
        .object(["executable": .object(["kind": .string("tool"), "tool": .string(tool)])])
    }
}

// MARK: Doubles

@MainActor
private final class ScriptedBackends: PluginBackendRequesting {
    struct Call {
        let function: String
        let params: ToolingJSONValue
        let pluginID: String
        let context: PluginWorkspaceContextReference?
        let timeout: Duration
    }

    private let answer: (ToolingJSONValue) -> ToolingJSONValue
    private let failure: (any Error)?
    private(set) var calls: [Call] = []
    var onInvoke: (() -> Void)?

    init(answer: @escaping (ToolingJSONValue) -> ToolingJSONValue) {
        self.answer = answer
        failure = nil
    }

    init(failure: any Error) {
        answer = { _ in .null }
        self.failure = failure
    }

    func declaresBackend(_: String) -> Bool { true }
    func pluginFunctions(ofPlugin _: String) async throws -> [String] { ["metals.resolveLaunch"] }

    func invokePluginFunction(
        _: String, params _: ToolingJSONValue, ofPlugin _: String, timeout _: Duration,
        progress _: @escaping @MainActor @Sendable (PluginFunctionProgress) -> Void
    ) async throws -> ToolingJSONValue {
        throw BackendFailure()
    }

    func invokePluginFunction(
        _ functionID: String, params: ToolingJSONValue, ofPlugin pluginID: String,
        context: PluginWorkspaceContextReference?, timeout: Duration,
        progress _: @escaping @MainActor @Sendable (PluginFunctionProgress) -> Void
    ) async throws -> ToolingJSONValue {
        calls.append(Call(function: functionID, params: params, pluginID: pluginID, context: context, timeout: timeout))
        onInvoke?()
        if let failure { throw failure }
        return answer(params)
    }
}

@MainActor
private final class ScriptedTools: BuildToolResolving {
    private let result: ResolvedBuildTool
    private(set) var invocations: [BuildInvocation] = []

    init(result: ResolvedBuildTool = ResolvedBuildTool(
        executableURL: URL(fileURLWithPath: "/host/bin/unused"), environment: [:], executesProjectCode: false, version: nil
    )) {
        self.result = result
    }

    func resolve(
        _ invocation: BuildInvocation, displayName _: String, workspaceURL _: URL,
        checkVersion _: @escaping @Sendable (String?, String) throws -> BuildVersionCheck
    ) async throws -> ResolvedBuildTool {
        invocations.append(invocation)
        return result
    }
}

@MainActor
private final class NoToolRuntime: LanguageToolRuntimePort {
    func executableOnPath(_: String) -> URL? { nil }
    func executableURL(at path: String) -> URL? { URL(fileURLWithPath: path) }
    func executableCandidates(_: String) -> [RuntimeToolCandidate] { [] }
    func languageToolProcessEnvironment(runtimeTools _: [String]) -> [String: String] { [:] }
    func missingLanguageToolMessage(_ name: String) -> String { "\(name) is missing." }
}
