import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

@Suite("LSP project usage")
struct LSPProjectUsageTests {
    @Test func indexedMatchingPreservesProviderAndPluginSemantics() throws {
        let providers = [
            provider("source", extensions: ["JAVA", "py"]),
            provider("named", names: ["Makefile", "文档 % #.txt", ".toolrc"]),
            provider("prefix", prefixes: ["Dockerfile", ".env."]),
            provider("missing", extensions: ["absent"]),
            provider("emptyExtension", extensions: [""])
        ]
        let files = ["中文/Foo.JAVA", "a/test.PY", "b/Makefile", "c/文档 % #.txt", "d/.toolrc",
                     "e/Dockerfile.prod", "f/.ENV.local", "g/README", "h/unrelated.bin"]
            .map { URL(fileURLWithPath: "/fixture/" + $0) }
        let rules = providers.map {
            LSPProjectUsageRequest.Rule(target: .provider($0.id), fileExtensions: $0.fileExtensions,
                                       fileNames: $0.fileNames, fileNamePrefixes: $0.fileNamePrefixes)
        } + pluginRules()
        let summary = try #require(LSPProjectUsageScanner.scan(files: files, rules: rules))
        #expect(summary.providerIDs == Set(providers.filter { p in files.contains { p.handles(fileURL: $0) } }.map(\.id)))
        #expect(summary.pluginIDs == expectedPluginIDs(files))
    }

    @Test func pluginProjectNamesAndSourceExtensionsShareTheSamePass() throws {
        let files = ["pom.xml", "build.gradle.kts", "GO.MOD", "composer.json", "view.PHTML"]
            .map { URL(fileURLWithPath: "/fixture/" + $0) }
        let summary = try #require(LSPProjectUsageScanner.scan(files: files, rules: pluginRules()))
        #expect(summary.pluginIDs == expectedPluginIDs(files))
        #expect(summary.pluginIDs.count == 3)
    }

    @Test func emptyAndUnmatchedInventoriesProduceACompletedEmptySummary() {
        #expect(LSPProjectUsageScanner.scan(files: [], rules: pluginRules()) == LSPProjectUsageSummary())
        #expect(LSPProjectUsageScanner.scan(files: [URL(fileURLWithPath: "/fixture/a.bin")], rules: pluginRules())
                == LSPProjectUsageSummary())
    }

    @Test func requestIdentityUsesSnapshotAndNormalizedRulesRatherThanFileCount() {
        let snapshot = UUID()
        let a = LSPProjectUsageRequest.Rule(target: .provider("a"), fileExtensions: ["JAVA"], fileNamePrefixes: ["Dockerfile"])
        let b = LSPProjectUsageRequest.Rule(target: .plugin("b"), fileExtensions: [], fileNames: ["Makefile"])
        let first = request(snapshot: snapshot, rules: [a, b])
        #expect(first == request(snapshot: snapshot, rules: [b, a]))
        #expect(first != request(rules: [a, b]))
        #expect(first != request(snapshot: snapshot, rules: [b]))
        #expect(first != LSPProjectUsageRequest(workspaceURL: URL(fileURLWithPath: "/other"), snapshotID: snapshot, rules: [a, b]))
    }

    @Test @MainActor func reopeningAndPresentationChangesReuseTheCompletedSummary() async {
        let probe = UsageScanProbe()
        let model = LSPProjectUsageModel(scanner: { files, rules in await probe.scan(files, rules) })
        let input = request(rules: pluginRules())
        let files = [URL(fileURLWithPath: "/fixture/go.mod")]
        for _ in 0..<10 { await model.load(input, files: files) }
        #expect(await probe.calls == 1)
        #expect(model.state == .ready)
        #expect(model.summary(for: input)?.pluginIDs == [OfficialPluginCatalog.goPluginID.rawValue])
        model.reset()
        #expect(model.summary(for: input) == nil)
        #expect(model.state == .idle)
    }

    @Test @MainActor func warmLoadsDoNotInvalidateTheVisibleSummaryAgain() async {
        let model = LSPProjectUsageModel(scanner: { _, _ in LSPProjectUsageSummary() })
        let input = request(rules: [])
        await model.load(input, files: [])
        var states: [LSPProjectUsageModel.State] = []
        let observation = model.$state.dropFirst().sink { states.append($0) }
        defer { observation.cancel(); model.reset() }

        // SwiftUI observes this publisher. Reopening a ready page must not
        // schedule another render, but a different snapshot must still notify.
        for _ in 0..<10 { await model.load(input, files: []) }
        #expect(states.isEmpty)
        await model.load(request(rules: []), files: [])
        #expect(states == [.loading, .ready])
    }

    @Test @MainActor func changedSnapshotRulesAndWorkspaceInvalidateTheCache() async {
        let probe = UsageScanProbe()
        let model = LSPProjectUsageModel(scanner: { files, rules in await probe.scan(files, rules) })
        let rule = LSPProjectUsageRequest.Rule(target: .provider("custom"), fileExtensions: ["first"])
        let initial = request(rules: [rule])
        await model.load(initial, files: [URL(fileURLWithPath: "/fixture/a.first")])
        #expect(model.summary(for: initial)?.providerIDs == ["custom"])
        let renamed = request(rules: [rule])
        await model.load(renamed, files: [URL(fileURLWithPath: "/fixture/a.second")])
        #expect(model.summary(for: renamed)?.providerIDs.isEmpty == true)
        let newRules = request(snapshot: renamed.snapshotID!, rules: [
            .init(target: .provider("custom"), fileExtensions: ["second"])
        ])
        await model.load(newRules, files: [URL(fileURLWithPath: "/fixture/a.second")])
        #expect(model.summary(for: newRules)?.providerIDs == ["custom"])
        let otherWorkspace = LSPProjectUsageRequest(workspaceURL: URL(fileURLWithPath: "/other"),
                                                  snapshotID: newRules.snapshotID, rules: newRules.rules)
        await model.load(otherWorkspace, files: [])
        #expect(model.summary(for: otherWorkspace) == LSPProjectUsageSummary())
        #expect(await probe.calls == 4)
        model.reset()
    }

    @Test @MainActor func closingDuringScanCancelsWithoutPublishingAnEmptyResultAndCanRetry() async {
        let entered = TestGate()
        let release = TestGate()
        let probe = UsageScanProbe(entered: entered, release: release)
        let model = LSPProjectUsageModel(scanner: { files, rules in await probe.scan(files, rules) })
        let input = request(rules: pluginRules())
        let task = Task { await model.load(input, files: [URL(fileURLWithPath: "/fixture/go.mod")]) }
        defer { task.cancel(); release.open(); model.reset() }
        #expect(await entered.waitUntilOpen())
        #expect(model.state == .loading)
        task.cancel()
        await task.value
        #expect(model.summary(for: input) == nil)
        #expect(model.state == .idle)
        release.open()
        await model.load(input, files: [URL(fileURLWithPath: "/fixture/go.mod")])
        #expect(model.summary(for: input)?.pluginIDs == [OfficialPluginCatalog.goPluginID.rawValue])
        #expect(await probe.calls == 2)
    }

    @Test @MainActor func replacementFinishesBeforeAnUncooperativeOldScannerIsReleased() async {
        let entered = TestGate()
        let release = TestGate()
        let returned = TestGate()
        let firstFinished = TestGate()
        // This independent, bounded wait deliberately does not inherit worker
        // cancellation. Releasing it is cleanup, never a prerequisite for B.
        let releaseWait = Task { await release.waitUntilOpen() }
        let probe = UsageScanProbe(entered: entered, uncooperativeRelease: releaseWait, returned: returned)
        let model = LSPProjectUsageModel(scanner: { files, rules in await probe.scan(files, rules) })
        let old = request(rules: pluginRules())
        let newest = request(rules: pluginRules())
        let first = Task {
            await model.load(old, files: [URL(fileURLWithPath: "/fixture/go.mod")])
            firstFinished.open()
        }
        defer { first.cancel(); release.open(); releaseWait.cancel(); model.reset() }
        #expect(await entered.waitUntilOpen())
        await model.load(newest, files: [URL(fileURLWithPath: "/fixture/pom.xml")])
        #expect(await firstFinished.waitUntilOpen())
        #expect(!release.isOpen)
        #expect(!returned.isOpen)
        await first.value
        #expect(model.summary(for: old) == nil)
        #expect(model.summary(for: newest)?.pluginIDs == [OfficialPluginCatalog.javaPluginID.rawValue])
        #expect(await probe.maximumActive == 2)
        release.open()
        #expect(await releaseWait.value)
        #expect(await returned.waitUntilOpen())
        await model.load(newest, files: [])
        #expect(model.summary(for: old) == nil)
        #expect(model.summary(for: newest)?.pluginIDs == [OfficialPluginCatalog.javaPluginID.rawValue])
        #expect(await probe.calls == 2)
    }

    @Test @MainActor func cancellingTheLastConsumerReturnsBeforeScannerExitAndCanRetry() async {
        let entered = TestGate()
        let release = TestGate()
        let finished = TestGate()
        let releaseWait = Task { await release.waitUntilOpen() }
        let probe = UsageScanProbe(entered: entered, uncooperativeRelease: releaseWait)
        let model = LSPProjectUsageModel(scanner: { files, rules in await probe.scan(files, rules) })
        let input = request(rules: pluginRules())
        let task = Task {
            await model.load(input, files: [URL(fileURLWithPath: "/fixture/go.mod")])
            finished.open()
        }
        defer { task.cancel(); release.open(); releaseWait.cancel(); model.reset() }
        #expect(await entered.waitUntilOpen())
        task.cancel()
        #expect(await finished.waitUntilOpen())
        #expect(!release.isOpen)
        #expect(model.state == .idle)
        #expect(model.summary(for: input) == nil)
        await model.load(input, files: [URL(fileURLWithPath: "/fixture/pom.xml")])
        #expect(model.summary(for: input)?.pluginIDs == [OfficialPluginCatalog.javaPluginID.rawValue])
        await task.value
        release.open()
        #expect(await releaseWait.value)
    }

    @Test @MainActor func cancellingOneOfTwoConsumersKeepsTheirSharedScannerAlive() async {
        let entered = TestGate()
        let release = TestGate()
        let secondStarted = TestGate()
        let firstFinished = TestGate()
        let secondFinished = TestGate()
        let probe = UsageScanProbe(entered: entered, release: release)
        let model = LSPProjectUsageModel(scanner: { files, rules in await probe.scan(files, rules) })
        let input = request(rules: pluginRules())
        let files = [URL(fileURLWithPath: "/fixture/go.mod")]
        let first = Task { await model.load(input, files: files); firstFinished.open() }
        let second = Task {
            secondStarted.open()
            await model.load(input, files: files)
            secondFinished.open()
        }
        defer { first.cancel(); second.cancel(); release.open(); model.reset() }
        #expect(await entered.waitUntilOpen())
        #expect(await secondStarted.waitUntilOpen())
        first.cancel()
        #expect(await firstFinished.waitUntilOpen())
        #expect(model.state == .loading)
        #expect(!secondFinished.isOpen)
        #expect(await probe.calls == 1)
        release.open()
        #expect(await secondFinished.waitUntilOpen())
        await first.value
        await second.value
        #expect(model.summary(for: input)?.pluginIDs == [OfficialPluginCatalog.goPluginID.rawValue])
        #expect(await probe.calls == 1)
    }

    @Test @MainActor func resetReleasesConsumersAndTheModelWhileCancelledScannerDrains() async {
        let entered = TestGate()
        let release = TestGate()
        let returned = TestGate()
        let finished = TestGate()
        let releaseWait = Task { await release.waitUntilOpen() }
        let probe = UsageScanProbe(entered: entered, uncooperativeRelease: releaseWait, returned: returned)
        var model: LSPProjectUsageModel? = LSPProjectUsageModel(scanner: { files, rules in await probe.scan(files, rules) })
        weak var released = model
        let input = request(rules: pluginRules())
        let task = Task { [weak model] in
            await model?.load(input, files: [URL(fileURLWithPath: "/fixture/go.mod")])
            finished.open()
        }
        defer { task.cancel(); release.open(); releaseWait.cancel(); model?.reset() }
        #expect(await entered.waitUntilOpen())
        model?.reset()
        #expect(await finished.waitUntilOpen())
        await task.value
        #expect(!release.isOpen)
        #expect(model?.state == .idle)
        #expect(model?.summary(for: input) == nil)
        model = nil
        #expect(released == nil)
        release.open()
        #expect(await releaseWait.value)
        #expect(await returned.waitUntilOpen())
    }

    @Test @MainActor func workspaceResetRejectsAnInFlightResult() async {
        let entered = TestGate()
        let release = TestGate()
        let probe = UsageScanProbe(entered: entered, release: release)
        let model = LSPProjectUsageModel(scanner: { files, rules in await probe.scan(files, rules) })
        let input = request(rules: pluginRules())
        let task = Task { await model.load(input, files: [URL(fileURLWithPath: "/fixture/go.mod")]) }
        defer { task.cancel(); release.open(); model.reset() }
        #expect(await entered.waitUntilOpen())
        model.reset()
        await task.value
        #expect(model.summary(for: input) == nil)
        #expect(model.state == .idle)
    }

    private func provider(_ id: String, extensions: Set<String> = [], names: Set<String> = [],
                          prefixes: Set<String> = []) -> LanguageProviderDescriptor {
        LanguageProviderDescriptor(id: id, displayName: id, fileExtensions: extensions, fileNames: names,
                                   fileNamePrefixes: prefixes, capabilities: [.languageServer], activationPolicy: .onDemand)
    }

    private func request(snapshot: UUID = UUID(), rules: [LSPProjectUsageRequest.Rule]) -> LSPProjectUsageRequest {
        LSPProjectUsageRequest(workspaceURL: URL(fileURLWithPath: "/fixture"), snapshotID: snapshot, rules: rules)
    }

    private func pluginRules() -> [LSPProjectUsageRequest.Rule] {
        OfficialPluginCatalog.entries.map {
            .init(target: .plugin($0.id.rawValue), fileExtensions: Set($0.fileExtensions), fileNames: Set($0.projectFileNames))
        }
    }

    private func expectedPluginIDs(_ files: [URL]) -> Set<String> {
        Set(OfficialPluginCatalog.entries.filter { entry in
            files.contains { entry.fileExtensions.contains($0.pathExtension.lowercased())
                || entry.projectFileNames.contains($0.lastPathComponent.lowercased()) }
        }.map { $0.id.rawValue })
    }
}

private actor UsageScanProbe {
    private(set) var calls = 0
    private(set) var maximumActive = 0
    private var active = 0
    let entered: TestGate?
    let release: TestGate?
    let uncooperativeRelease: Task<Bool, Never>?
    let returned: TestGate?

    init(entered: TestGate? = nil, release: TestGate? = nil,
         uncooperativeRelease: Task<Bool, Never>? = nil, returned: TestGate? = nil) {
        self.entered = entered
        self.release = release
        self.uncooperativeRelease = uncooperativeRelease
        self.returned = returned
    }

    func scan(_ files: [URL], _ rules: [LSPProjectUsageRequest.Rule]) async -> LSPProjectUsageSummary? {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        let isFirst = calls == 1
        defer { active -= 1; if isFirst { returned?.open() } }
        if isFirst {
            entered?.open()
            if let uncooperativeRelease { #expect(await uncooperativeRelease.value) }
            if let release { _ = await release.waitUntilOpen() }
        }
        // Ignore the worker's cancelled flag to exercise the model's stale guard.
        var result = LSPProjectUsageSummary()
        for rule in rules where files.contains(where: { file in
            rule.fileExtensions.contains(file.pathExtension.lowercased())
                || rule.fileNames.contains(file.lastPathComponent.lowercased())
                || rule.fileNamePrefixes.contains { file.lastPathComponent.lowercased().hasPrefix($0) }
        }) {
            switch rule.target {
            case .provider(let id): result.providerIDs.insert(id)
            case .plugin(let id): result.pluginIDs.insert(id)
            }
        }
        return result
    }
}
