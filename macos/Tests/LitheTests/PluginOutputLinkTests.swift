import Foundation
@testable import Lithe
import LitheCoreContracts
import LitheModuleAPI
import Testing

/// Console links from the output link matchers of plugins. The matching itself is tested in Rust
/// Core; these tests cover how the host cuts console text into requests and what it keeps.
@Suite("Plugin output links")
@MainActor
struct PluginOutputLinkTests {
    private static let fixtures = DeclarativePluginTestSupport.repositoryRoot
        .appendingPathComponent("shared/contracts/plugins/v1/fixtures", isDirectory: true)

    private static let traceback = DeclarativeOutputLinkMatcher(
        id: "traceback", pattern: #"File "(?P<path>[^"]+)", line (?P<line>\d+)"#, scope: "run")
    private static let panic = DeclarativeOutputLinkMatcher(
        id: "panic", pattern: #"(?P<symbol>[\w./]+)\((?P<file>[\w.]+):(?P<line>\d+)\)"#, resolveFunction: "links.resolve")
    private static let roots = [URL(fileURLWithPath: "/work/app")]

    // MARK: Manifest

    @Test
    func aPluginWithOnlyLocationMatchersDeclaresAnOutputLinksModuleThatActivatesLive() throws {
        let descriptor = try Self.descriptor(Self.matcherOnlyManifest(id: "dev.example.links", matchers: [
            ["id": "traceback", "pattern": #"File "(?P<path>[^"]+)", line (?P<line>\d+)"#, "scope": "run"],
            ["id": "assertion", "pattern": #"(?P<path>\S+\.script):(?P<line>\d+)"#],
        ]))
        // Core sorts matchers by ID.
        #expect(descriptor.outputLinkMatchers.map(\.id) == ["assertion", "traceback"])
        #expect(descriptor.outputLinkMatchers.map(\.scope) == [nil, "run"])
        #expect(descriptor.outputLinkMatchers.allSatisfy { $0.resolveFunction == nil })
        #expect(descriptor.pluginManifest.modules.map(\.manifest.id) == [.outputLinksExtension(descriptor.id.rawValue)])
        #expect(descriptor.canActivateWithoutRestart)
    }

    @Test
    func aResolveMatcherNeedsABackendSoItWaitsForARestart() throws {
        var object = try Self.editorActionsManifest(id: "dev.example.resolver")
        object["outputLinkMatchers"] = [[
            "id": "frame", "pattern": #"(?P<symbol>\w+)\((?P<file>\w+\.script):(?P<line>\d+)\)"#,
            "resolve": ["function": "links.resolve"],
        ] as [String: Any]]
        let descriptor = try Self.descriptor(object)
        #expect(descriptor.outputLinkMatchers == [
            DeclarativeOutputLinkMatcher(id: "frame", pattern: #"(?P<symbol>\w+)\((?P<file>\w+\.script):(?P<line>\d+)\)"#,
                                         resolveFunction: "links.resolve")
        ])
        let moduleIDs = descriptor.pluginManifest.modules.map(\.manifest.id)
        #expect(moduleIDs.contains(.outputLinksExtension(descriptor.id.rawValue)))
        #expect(moduleIDs.contains(.backendExtension(descriptor.id.rawValue)))
        #expect(!descriptor.canActivateWithoutRestart)
    }

    @Test
    func aPluginWithoutMatchersGetsNoOutputLinksModule() throws {
        let descriptor = try Self.descriptor(try Self.editorActionsManifest(id: "dev.example.plain", requiresMatchers: false))
        #expect(descriptor.outputLinkMatchers.isEmpty)
        #expect(!descriptor.pluginManifest.modules.map(\.manifest.id).contains(.outputLinksExtension(descriptor.id.rawValue)))
    }

    @Test
    func sourcesListEnabledPluginsInIDOrderAndALivePluginReplacesItsLaunchCopy() throws {
        let alpha = try Self.package(id: "dev.example.alpha", matchers: [["id": "one", "pattern": #"(?P<path>\S+):(?P<line>\d+)"#]])
        let beta = try Self.package(id: "dev.example.beta", matchers: [["id": "two", "pattern": #"(?P<path>\S+):(?P<line>\d+)"#]])
        let betaUpdated = try Self.package(id: "dev.example.beta", matchers: [["id": "three", "pattern": #"(?P<path>\S+):(?P<line>\d+)"#]])
        let plain = try Self.package(from: DeclarativePluginTestSupport.manifestObject(
            id: "dev.example.plain", version: PluginVersion(major: 1, minor: 0, patch: 0)))

        let sources = PluginOutputLinkSource.sources(launchRegistered: [beta, alpha, plain], live: [betaUpdated])
        #expect(sources.map(\.pluginID) == ["dev.example.alpha", "dev.example.beta"])
        #expect(sources.last?.matchers.map(\.id) == ["three"])
    }

    // MARK: Cutting text into requests

    @Test
    func aConsoleWithoutMatchersNeverReachesCore() {
        let matcher = StubMatching()
        let service = PluginOutputLinkService(matching: matcher, sources: { [] })
        #expect(service.marks(in: "anything\n", scope: .run, workspaceRoots: Self.roots, fileExists: { _ in true }).isEmpty)
        #expect(matcher.requests.isEmpty)
    }

    @Test
    func emptyLinesAreSkippedAndLinksKeepTheirOffsetInTheWholeText() {
        let matcher = StubMatching(links: [
            PluginOutputLink(line: 1, start: 2, length: 4, pluginID: "dev.example.tb", matcherID: "traceback",
                             target: .location(paths: ["/work/app/a.py"], line: 3, column: nil))
        ])
        let service = Self.service(matcher)
        let text = "ok\n\n  File a.py\n"
        let marks = service.marks(in: text, scope: .run, workspaceRoots: Self.roots, fileExists: { _ in true })
        #expect(matcher.requests.map(\.lines) == [["ok", "  File a.py"]])
        #expect(matcher.requests.first?.scope == "run")
        #expect(matcher.requests.first?.workspaceRoots == ["/work/app"])
        // Line one starts after "ok\n\n"; the link starts two units into it.
        #expect(marks == [.init(range: NSRange(location: 6, length: 4), destination: .file(path: "/work/app/a.py", line: 3, column: nil))])
    }

    @Test
    func aLocationLinkKeepsTheFirstCandidateThatExistsAndNoneMeansNoLink() {
        let link = PluginOutputLink(line: 0, start: 0, length: 3, pluginID: "dev.example.tb", matcherID: "traceback",
                                    target: .location(paths: ["/work/app/x.py", "/work/lib/x.py"], line: nil, column: 5))
        let service = Self.service(StubMatching(links: [link]))
        let found = service.marks(in: "x.py", scope: .test, workspaceRoots: Self.roots) { $0.path == "/work/lib/x.py" }
        #expect(found.map(\.destination) == [.file(path: "/work/lib/x.py", line: nil, column: 5)])
        #expect(service.marks(in: "x.py", scope: .test, workspaceRoots: Self.roots, fileExists: { _ in false }).isEmpty)
    }

    @Test
    func aResolveLinkCarriesTheQuestionWithoutCheckingAnyFile() {
        let link = PluginOutputLink(line: 0, start: 0, length: 9, pluginID: "dev.example.tb", matcherID: "panic",
                                    target: .resolve(function: "links.resolve", groups: ["symbol": "main.run", "line": "7"]))
        let service = Self.service(StubMatching(links: [link]))
        let marks = service.marks(in: "main.run:7", scope: .run, workspaceRoots: Self.roots, fileExists: { _ in false })
        let question = PluginOutputLinkService.Question(pluginID: "dev.example.tb", function: "links.resolve",
                                                        groups: ["symbol": "main.run", "line": "7"])
        #expect(marks == [.init(range: NSRange(location: 0, length: 9), destination: .ask(question))])
    }

    @Test
    func longOutputGoesToCoreInRequestsOfAtMost256Lines() {
        let lines = (0..<600).map { "line \($0)" }
        let matcher = StubMatching(linksForRequest: { index in
            // A link on the last line of every request.
            [PluginOutputLink(line: index == 2 ? 87 : 255, start: 0, length: 4, pluginID: "dev.example.tb", matcherID: "traceback",
                              target: .location(paths: ["/work/app/f.py"], line: 1, column: nil))]
        })
        let service = Self.service(matcher)
        let text = lines.joined(separator: "\n")
        let marks = service.marks(in: text, scope: .run, workspaceRoots: Self.roots, fileExists: { _ in true })
        #expect(matcher.requests.map(\.lines.count) == [256, 256, 88])
        let nsText = text as NSString
        #expect(marks.count == 3)
        #expect(marks.map { nsText.substring(with: $0.range) } == ["line", "line", "line"])
        #expect(marks.map { nsText.substring(with: NSRange(location: $0.range.location, length: 8)) } == ["line 255", "line 511", "line 599"])
    }

    @Test
    func aLongLineIsCutBeforeCoreWithoutSplittingACharacter() throws {
        let matcher = StubMatching()
        let service = Self.service(matcher)
        let emoji = String(repeating: "😀", count: 3000)
        _ = service.marks(in: emoji + "\n" + String(repeating: "a", count: 5000), scope: .run,
                          workspaceRoots: Self.roots, fileExists: { _ in true })
        let sent = try #require(matcher.requests.first?.lines)
        #expect(sent.count == 2)
        #expect(sent[0].utf16.count == 4096)
        #expect(sent[0].allSatisfy { $0 == "😀" })
        #expect(sent[1].utf16.count == 4096)
    }

    @Test
    func aFailingMatchLeavesTheConsolePlain() {
        let service = Self.service(StubMatching(failure: DeclarativePluginRejection(code: "plugin.core.failed", message: "no")))
        #expect(service.marks(in: "text", scope: .run, workspaceRoots: Self.roots, fileExists: { _ in true }).isEmpty)
    }

    // MARK: Link URLs

    @Test
    func aQuestionSurvivesItsURL() throws {
        let question = PluginOutputLinkService.Question(
            pluginID: "dev.example.tb", function: "links.resolve",
            groups: ["symbol": "pkg.Type&Name = ?", "file": "dir with space/ü.go", "line": "12"])
        #expect(PluginOutputLinkService.Question(url: question.url) == question)
        #expect(question.url.scheme == PluginOutputLinkService.linkScheme)
    }

    @Test
    func onlyAPluginLinkURLIsAQuestion() {
        let located = OutputTextView.locationURL(path: "/work/app/a.py", line: 3, column: nil)
        #expect(PluginOutputLinkService.Question(url: located) == nil)
        #expect(PluginOutputLinkService.Question(url: URL(string: "lithe-plugin-link://other?plugin=a&function=b&groups=%7B%7D")!) == nil)
        #expect(PluginOutputLinkService.Question(url: URL(string: "lithe-plugin-link://resolve?plugin=a&function=b&groups=nope")!) == nil)
    }

    // MARK: Answering a click

    @Test
    func aClickAsksThePluginsFunctionForTheLocation() async throws {
        let backends = StubBackends(reply: .object(["uri": .string("file:///work/app/main.go"), "range": .null]))
        let matcher = StubMatching(location: PluginOutputLinkLocation(path: "/work/app/main.go", line: 7, column: nil))
        let service = Self.service(matcher, matchers: [Self.panic])
        let context = PluginWorkspaceContextReference(contextID: "ctx", generation: 2)
        let question = PluginOutputLinkService.Question(pluginID: "dev.example.tb", function: "links.resolve",
                                                        groups: ["symbol": "main.run", "line": "7"])

        let location = try await service.location(answering: question, backends: backends, context: context)

        #expect(location == PluginOutputLinkLocation(path: "/work/app/main.go", line: 7, column: nil))
        #expect(backends.calls.count == 1)
        #expect(backends.calls.first?.pluginID == "dev.example.tb")
        #expect(backends.calls.first?.function == "links.resolve")
        #expect(backends.calls.first?.context == context)
        #expect(backends.calls.first?.params == .object(["groups": .object(["symbol": .string("main.run"), "line": .string("7")])]))
        #expect(matcher.resolutions == [backends.reply])
    }

    @Test
    func aClickOnAMatcherThePluginNoLongerDeclaresCallsNothing() async throws {
        let backends = StubBackends(reply: .null)
        let question = PluginOutputLinkService.Question(pluginID: "dev.example.tb", function: "links.resolve", groups: [:])
        // Another function, another plugin, and no plugin at all.
        for sources in [[Self.source(matchers: [Self.traceback])],
                        [PluginOutputLinkSource(pluginID: "dev.example.other", matchers: [Self.panic])],
                        []] {
            let service = PluginOutputLinkService(matching: StubMatching(), sources: { sources })
            let location = try await service.location(answering: question, backends: backends, context: nil)
            #expect(location == nil)
        }
        #expect(backends.calls.isEmpty)
    }

    // MARK: Support

    private static func service(_ matching: StubMatching, matchers: [DeclarativeOutputLinkMatcher]? = nil) -> PluginOutputLinkService {
        let source = source(matchers: matchers ?? [traceback])
        return PluginOutputLinkService(matching: matching, sources: { [source] })
    }

    private static func source(matchers: [DeclarativeOutputLinkMatcher]) -> PluginOutputLinkSource {
        PluginOutputLinkSource(pluginID: "dev.example.tb", matchers: matchers)
    }

    /// A plugin whose only contribution is console links, so it needs no backend and no restart.
    private static func matcherOnlyManifest(id: String, matchers: [[String: Any]]) -> [String: Any] {
        [
            "schemaVersion": 2,
            "id": id,
            "displayName": "Script Links",
            "version": "1.0.0",
            "pluginAPIVersion": 4,
            "requires": ["outputLinkMatchers": 1],
            "vendor": ["id": "org.example", "displayName": "Example", "signatureRequirement": "publisherPackage"],
            "permissions": [],
            "activationEvents": [],
            "languages": [],
            "outputLinkMatchers": matchers,
        ]
    }

    /// The editor actions fixture: a backend 2 plugin that matchers with a `resolve` function can join.
    private static func editorActionsManifest(id: String, requiresMatchers: Bool = true) throws -> [String: Any] {
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            fixtures.appendingPathComponent("editor/editor-actions.plugin.json"))) as? [String: Any])
        object["id"] = id
        if requiresMatchers {
            object["pluginAPIVersion"] = 4
            var requires = try #require(object["requires"] as? [String: Any])
            requires["outputLinkMatchers"] = 1
            object["requires"] = requires
        }
        return object
    }

    private static func descriptor(_ manifest: [String: Any]) throws -> DeclarativePluginDescriptor {
        try DeclarativePluginTestSupport.descriptor(manifest)
    }

    private static func package(id: String, matchers: [[String: Any]]) throws -> InstalledPluginPackage {
        try package(from: matcherOnlyManifest(id: id, matchers: matchers))
    }

    private static func package(from manifest: [String: Any]) throws -> InstalledPluginPackage {
        let descriptor = try descriptor(manifest)
        return InstalledPluginPackage(
            descriptor: descriptor,
            installation: PluginInstallationRecord(
                pluginID: descriptor.id, activeVersion: descriptor.pluginManifest.version, origin: .marketplace),
            packageURL: URL(fileURLWithPath: "/tmp/\(descriptor.id.rawValue)", isDirectory: true))
    }
}

/// Answers `outputLinks.match` with canned links and records what the host asked.
private final class StubMatching: PluginOutputLinkMatching, @unchecked Sendable {
    struct Request: Equatable {
        let scope: String
        let workspaceRoots: [String]
        let lines: [String]
    }

    private let lock = NSLock()
    private var recordedRequests: [Request] = []
    private var recordedResolutions: [ToolingJSONValue] = []
    private let linksForRequest: @Sendable (Int) -> [PluginOutputLink]
    private let failure: (any Error)?
    private let location: PluginOutputLinkLocation?

    init(links: [PluginOutputLink] = [], linksForRequest: (@Sendable (Int) -> [PluginOutputLink])? = nil,
         failure: (any Error)? = nil, location: PluginOutputLinkLocation? = nil) {
        self.linksForRequest = linksForRequest ?? { _ in links }
        self.failure = failure
        self.location = location
    }

    var requests: [Request] { lock.withLock { recordedRequests } }
    var resolutions: [ToolingJSONValue] { lock.withLock { recordedResolutions } }

    func links(scope: String, workspaceRoots: [String], sources: [PluginOutputLinkSource],
               lines: [String]) throws -> [PluginOutputLink] {
        let index = lock.withLock {
            recordedRequests.append(Request(scope: scope, workspaceRoots: workspaceRoots, lines: lines))
            return recordedRequests.count - 1
        }
        if let failure { throw failure }
        return linksForRequest(index)
    }

    func location(ofResolution reply: ToolingJSONValue) throws -> PluginOutputLinkLocation? {
        lock.withLock { recordedResolutions.append(reply) }
        return location
    }
}

/// Answers every plugin function with one reply and records the calls.
@MainActor
private final class StubBackends: PluginBackendRequesting {
    struct Call: Equatable {
        let function: String
        let pluginID: String
        let params: ToolingJSONValue
        let context: PluginWorkspaceContextReference?
    }

    let reply: ToolingJSONValue
    private(set) var calls: [Call] = []

    init(reply: ToolingJSONValue) { self.reply = reply }

    func declaresBackend(_ pluginID: String) -> Bool { true }
    func pluginFunctions(ofPlugin _: String) async throws -> [String] { [] }

    func invokePluginFunction(
        _ functionID: String, params: ToolingJSONValue, ofPlugin pluginID: String, timeout _: Duration,
        progress _: @escaping @MainActor @Sendable (PluginFunctionProgress) -> Void
    ) async throws -> ToolingJSONValue {
        try await invokePluginFunction(functionID, params: params, ofPlugin: pluginID, context: nil, timeout: .seconds(1), progress: { _ in })
    }

    func invokePluginFunction(
        _ functionID: String, params: ToolingJSONValue, ofPlugin pluginID: String,
        context: PluginWorkspaceContextReference?, timeout _: Duration,
        progress _: @escaping @MainActor @Sendable (PluginFunctionProgress) -> Void
    ) async throws -> ToolingJSONValue {
        calls.append(Call(function: functionID, pluginID: pluginID, params: params, context: context))
        return reply
    }
}
