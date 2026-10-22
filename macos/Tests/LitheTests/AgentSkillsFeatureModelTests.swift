import AppKit
import SwiftUI
import Combine
import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

@MainActor
struct AgentSkillsFeatureModelTests {
    @Test nonisolated func sharedFixtureDecodesNativeAndConfiguredVisibility() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/agent/skills-management-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decode: (String) throws -> AgentSkillListing = { key in
            try JSONDecoder().decode(AgentSkillListing.self, from: JSONSerialization.data(withJSONObject: fixture[key] as Any))
        }
        let native = try decode("normalizedCodex"), inventory = try decode("claudeInventory")
        #expect(native.skills.map(\.scope) == ["user", "repo", "user"])
        #expect(native.skills[1].enabled == false)
        #expect(native.skills.first(where: { $0.pluginId != nil })?.pluginId == "helper@example")
        #expect(inventory.skills.first?.enabled == false)
        #expect(inventory.source == "directory")
    }

    @Test func scopeIsPrimaryAndSourceFilteringPreservesNativeProvenance() async {
        let service = SkillsTestService()
        let feature = AgentSkillsFeatureModel(service: service)
        await feature.refresh(.init(workspace: service.firstProject))
        #expect(feature.phase == .ready)
        #expect(feature.count(in: "user") == 2)
        #expect(feature.count(in: "repo") == 2)
        #expect(feature.visibleItems.map(\.agentName) == ["Claude", "Codex"])
        feature.scope = "repo"
        #expect(feature.visibleItems.allSatisfy { $0.skill.scope == "repo" })
        feature.agentFilter = "claude-acp"
        #expect(feature.visibleItems.count == 1)
        #expect(feature.visibleItems.first?.skill.enabled == true)
        feature.query = "no-match"
        #expect(feature.visibleItems.isEmpty)
        feature.query = "PROJECT"
        #expect(feature.visibleItems.count == 1)
        feature.cancel()
    }

    @Test func noProjectNeverReclassifiesTheHomeDirectoryAsAProject() async {
        let feature = AgentSkillsFeatureModel(service: SkillsTestService())
        await feature.refresh(.init(workspace: nil))
        #expect(feature.count(in: "user") == 2)
        #expect(feature.count(in: "repo") == 0)
        feature.scope = "repo"
        #expect(feature.visibleItems.isEmpty)
        feature.cancel()
    }

    @Test func independentFailuresKeepPreviousRowsAndDoNotHideTheOtherAgent() async {
        let service = SkillsTestService()
        let feature = AgentSkillsFeatureModel(service: service)
        let context = AgentSkillsFeatureModel.Context(workspace: service.firstProject)
        await feature.refresh(context)
        let previous = feature.listings["codex-acp"]
        service.failCodex = true
        await feature.refresh(context)
        #expect(feature.phase == .ready)
        #expect(feature.listings["codex-acp"] == previous)
        #expect(feature.discoveryErrors["codex-acp"] != nil)
        #expect(feature.discoveryErrors["claude-acp"] == nil)
        #expect(feature.directory(agentID: "codex-acp", scope: "repo") != nil)
        feature.cancel()
    }

    @Test func oldProjectResultsCannotReplaceTheNewProjectsSkills() async {
        let service = SkillsTestService()
        let feature = AgentSkillsFeatureModel(service: service)
        service.holdFirstProject = true
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await feature.refresh(.init(workspace: service.firstProject)) }
            #expect(await awaitChange(on: service) { service.held.count == 2 }, "both old requests reached the controlled gate")
            await feature.refresh(.init(workspace: service.secondProject))
            let selected = feature.listings
            service.releaseLists()
            await group.waitForAll()
            #expect(feature.listings == selected)
            #expect(feature.visibleItems.allSatisfy { $0.skill.path.contains("second") })
        }
        feature.cancel()
    }

    @Test func writeRunsOnceWithCapturedScopeAndRefreshesOnlyAfterSuccess() async {
        let service = SkillsTestService()
        let feature = AgentSkillsFeatureModel(service: service)
        let context = AgentSkillsFeatureModel.Context(workspace: service.firstProject)
        await feature.refresh(context)
        service.holdWrite = true
        let request = AgentSkillWrite(agentID: "claude-acp", workspace: context.workspace, scope: "repo",
                                     name: "new-skill", description: "Use for testing", instructions: "Inspect the files")
        feature.write(request, context: context)
        feature.write(request, context: context)
        #expect(await awaitChange(on: service) { service.writeRequests.count == 1 })
        #expect(feature.isWriting)
        let payload = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(service.writeRequests[0])) as? [String: Any]
        #expect(payload?["workspace"] as? String == service.firstProject.path)
        #expect(payload?["scope"] as? String == "repo")
        service.releaseWrite()
        #expect(await awaitChange(on: feature) { !feature.isWriting && feature.savedURL != nil && feature.phase == .ready })
        #expect(service.listRequests == 4)
        #expect(service.writeRequests.count == 1)
        feature.cancel()
    }

    @Test func leavingThePageRejectsLateWriteFeedback() async {
        let service = SkillsTestService()
        let feature = AgentSkillsFeatureModel(service: service)
        let context = AgentSkillsFeatureModel.Context(workspace: service.firstProject)
        await feature.refresh(context)
        service.holdWrite = true
        feature.write(.init(agentID: "codex-acp", workspace: context.workspace, scope: "repo", name: "new-skill",
                            description: "Testing", instructions: "Inspect"), context: context)
        #expect(await awaitChange(on: service) { service.writeRequests.count == 1 })
        feature.cancel()
        service.releaseWrite()
        #expect(await awaitChange(on: service) { service.finishedWrites == 1 })
        #expect(feature.savedURL == nil)
        #expect(!feature.isWriting)
    }

    @Test func toggleImmediatelyShowsTheChoiceAndSerializesNativeConfirmation() async throws {
        let service = SkillsTestService()
        let feature = AgentSkillsFeatureModel(service: service)
        let context = AgentSkillsFeatureModel.Context(workspace: service.firstProject)
        defer { service.releaseWrite(); feature.cancel() }
        await feature.refresh(context)
        let item = try #require(feature.visibleItems.first)
        service.holdWrite = true
        feature.setEnabled(false, for: item, context: context)
        #expect(feature.displayedEnablement(for: item) == false)
        #expect(!feature.didChangeEnablement, "the immediate display is not a native confirmation")
        feature.setEnabled(false, for: item, context: context)
        #expect(await awaitChange(on: service) { service.toggleRequests.count == 1 })
        #expect(feature.isWriting && feature.pendingEnablements.first?.itemID == item.id)
        #expect(feature.visibleItems.first?.skill.enabled == true, "pending writes do not invent native state")
        await feature.refresh(context)
        #expect(feature.isWriting, "manual refresh cannot invalidate the write")
        let request = try #require(service.toggleRequests.first)
        #expect(request.workspace == context.workspace?.path && request.source == item.skill.path && !request.enabled)
        service.releaseWrite()
        #expect(await awaitChange(on: feature) { feature.didChangeEnablement && !feature.isWriting })
        #expect(feature.visibleItems.first?.skill.enabled == false)
        #expect(feature.pendingEnablements.isEmpty)
        #expect(service.toggleRequests.count == 1)
    }

    @Test func failedToggleRestoresConfirmedStateAndUnknownStateCannotBeChanged() async throws {
        let service = SkillsTestService()
        let feature = AgentSkillsFeatureModel(service: service)
        let context = AgentSkillsFeatureModel.Context(workspace: service.firstProject)
        defer { service.releaseWrite(); feature.cancel() }
        await feature.refresh(context)
        let item = try #require(feature.visibleItems.first)
        service.failToggle = true
        service.holdWrite = true
        feature.setEnabled(false, for: item, context: context)
        #expect(feature.displayedEnablement(for: item) == false)
        #expect(await awaitChange(on: service) { service.toggleRequests.count == 1 })
        service.releaseWrite()
        #expect(await awaitChange(on: feature) { feature.error != nil && !feature.isWriting })
        #expect(feature.visibleItems.first?.skill.enabled == true)
        #expect(feature.displayedEnablement(for: item) == true && feature.pendingEnablements.isEmpty)
        #expect(!feature.didChangeEnablement)
        service.unknownEnablement = true
        await feature.refresh(context)
        let unknown = try #require(feature.visibleItems.first)
        feature.setEnabled(true, for: unknown, context: context)
        #expect(!feature.isWriting && service.toggleRequests.count == 1)
    }

    @Test func otherRowsQueueTheirOwnChoiceWithoutOverwritingEarlierConfirmation() async throws {
        let service = SkillsTestService()
        service.additionalCodexSkill = true
        let feature = AgentSkillsFeatureModel(service: service)
        feature.agentFilter = "codex-acp"
        let context = AgentSkillsFeatureModel.Context(workspace: service.firstProject)
        defer { service.releaseWrite(); feature.cancel() }
        await feature.refresh(context)
        let first = try #require(feature.visibleItems.first), second = try #require(feature.visibleItems.last)
        service.holdWrite = true
        feature.setEnabled(false, for: first, context: context)
        try #require(await awaitChange(on: service) { service.toggleRequests.count == 1 })
        #expect(!feature.canChangeEnablement(for: first) && feature.canChangeEnablement(for: second))
        #expect(feature.displayedEnablement(for: second) == true)
        feature.setEnabled(false, for: second, context: context)
        feature.setEnabled(false, for: second, context: context)
        #expect(feature.pendingEnablements.count == 2 && service.toggleRequests.count == 1)
        #expect(feature.displayedEnablement(for: second) == false)

        service.releaseWrite(holdingNext: true)
        try #require(await awaitChange(on: service) { service.toggleRequests.count == 2 })
        #expect(feature.visibleItems.first?.skill.enabled == false)
        #expect(feature.visibleItems.last?.skill.enabled == true, "the queued row still awaits native confirmation")
        #expect(feature.canChangeEnablement(for: first) && !feature.canChangeEnablement(for: second))
        #expect(feature.isWriting && !feature.didChangeEnablement)
        let confirmedFirst = try #require(feature.visibleItems.first)
        feature.setEnabled(true, for: confirmedFirst, context: context)
        #expect(feature.displayedEnablement(for: confirmedFirst) == true)
        service.releaseWrite(holdingNext: true)
        try #require(await awaitChange(on: service) { service.toggleRequests.count == 3 })
        #expect(feature.visibleItems.allSatisfy { $0.skill.enabled == false })
        service.releaseWrite()
        try #require(await awaitChange(on: feature) { !feature.isWriting })
        #expect(feature.visibleItems.first?.skill.enabled == true && feature.visibleItems.last?.skill.enabled == false)
        #expect(feature.pendingEnablements.isEmpty && feature.didChangeEnablement)
        #expect(service.toggleRequests.map(\.source) == [first.skill.path, second.skill.path, first.skill.path])
    }

    @Test func aFailedRowRollsBackWhileTheNextQueuedRowCanStillSave() async throws {
        let service = SkillsTestService()
        let feature = AgentSkillsFeatureModel(service: service)
        let context = AgentSkillsFeatureModel.Context(workspace: service.firstProject)
        defer { service.releaseWrite(); feature.cancel() }
        await feature.refresh(context)
        let first = try #require(feature.visibleItems.first), second = try #require(feature.visibleItems.last)
        service.holdWrite = true; service.failToggle = true
        feature.setEnabled(false, for: first, context: context)
        try #require(await awaitChange(on: service) { service.toggleRequests.count == 1 })
        feature.setEnabled(false, for: second, context: context)
        service.releaseWrite(holdingNext: true)
        try #require(await awaitChange(on: service) { service.toggleRequests.count == 2 })
        #expect(feature.error != nil && feature.visibleItems.first?.skill.enabled == true)
        #expect(feature.displayedEnablement(for: first) == true && feature.displayedEnablement(for: second) == false)
        service.failToggle = false
        service.releaseWrite()
        try #require(await awaitChange(on: feature) { !feature.isWriting })
        #expect(feature.visibleItems.first?.skill.enabled == true && feature.visibleItems.last?.skill.enabled == false)
        #expect(feature.error != nil && !feature.didChangeEnablement, "a later success must not hide an earlier failure")
    }

    @Test(arguments: [false, true])
    func leavingTheContextDropsQueuedWritesAndRejectsLateConfirmation(switchProject: Bool) async throws {
        let service = SkillsTestService()
        let feature = AgentSkillsFeatureModel(service: service)
        let context = AgentSkillsFeatureModel.Context(workspace: service.firstProject)
        defer { service.releaseWrite(); feature.cancel() }
        await feature.refresh(context)
        service.holdWrite = true
        let first = try #require(feature.visibleItems.first), second = try #require(feature.visibleItems.last)
        feature.setEnabled(false, for: first, context: context)
        try #require(await awaitChange(on: service) { service.toggleRequests.count == 1 })
        feature.setEnabled(false, for: second, context: context)
        if switchProject { await feature.refresh(.init(workspace: service.secondProject)) }
        else { feature.cancel() }
        let selected = feature.listings
        service.releaseWrite()
        try #require(await awaitChange(on: service) { service.finishedToggles == 1 })
        #expect(service.toggleRequests.count == 1, "a queued write cannot start after leaving its project or page")
        #expect(feature.listings == selected && !feature.didChangeEnablement)
        #expect(feature.pendingEnablements.isEmpty && !feature.isWriting)
    }

    @Test func oldToggleCannotReplaceAnotherProjectsState() async throws {
        let service = SkillsTestService()
        let feature = AgentSkillsFeatureModel(service: service)
        let context = AgentSkillsFeatureModel.Context(workspace: service.firstProject)
        defer { service.releaseWrite(); feature.cancel() }
        await feature.refresh(context)
        let item = try #require(feature.visibleItems.first)
        service.holdWrite = true
        feature.setEnabled(false, for: item, context: context)
        #expect(await awaitChange(on: service) { service.toggleRequests.count == 1 })
        await feature.refresh(.init(workspace: service.secondProject))
        let selected = feature.listings
        service.releaseWrite()
        #expect(await awaitChange(on: service) { service.finishedToggles == 1 })
        #expect(feature.listings == selected && !feature.didChangeEnablement)
        #expect(feature.pendingEnablements.isEmpty && !feature.isWriting)
    }
}

@MainActor
private final class SkillsTestService: ObservableObject, AgentManagementService {
    let firstProject = URL(fileURLWithPath: "/fixture/first")
    let secondProject = URL(fileURLWithPath: "/fixture/second")
    var failCodex = false
    var additionalCodexSkill = false
    var holdFirstProject = false
    var holdWrite = false
    @Published var held: [String: CheckedContinuation<Void, Never>] = [:]
    @Published var writeRequests: [AgentSkillWrite] = []
    @Published var finishedWrites = 0
    @Published var readRequests = 0
    @Published var toggleRequests: [AgentSkillEnablement] = []
    @Published var finishedToggles = 0
    var failToggle = false
    var unknownEnablement = false
    private var enablements: [String: Bool] = [:]
    var listRequests = 0
    private var writeGate: CheckedContinuation<Void, Never>?

    func listSkills(agentID: String, workspace: URL?) async throws -> AgentSkillListing {
        listRequests += 1
        if holdFirstProject && workspace == firstProject {
            await withCheckedContinuation { held[agentID] = $0 }
        }
        if failCodex && agentID == "codex-acp" { throw Failure() }
        let root = workspace?.path ?? "/fixture/global"
        var skills: [AgentSkill] = [
            .init(name: agentID + "-global", description: "Global test", path: root + "/user/" + agentID + "/SKILL.md", scope: "user", enabled: unknownEnablement ? nil : (enablements[root + "/user/" + agentID + "/SKILL.md"] ?? true)),
            .init(name: agentID + "-project", description: "Project test", path: root + "/project/" + agentID + "/SKILL.md", scope: "repo", enabled: unknownEnablement ? nil : (enablements[root + "/project/" + agentID + "/SKILL.md"] ?? true))
        ]
        if additionalCodexSkill && agentID == "codex-acp" {
            let path = root + "/user/codex-secondary/SKILL.md"
            skills.append(.init(name: "codex-secondary", description: "Another skill in the same native settings",
                                path: path, scope: "user", enabled: enablements[path] ?? true))
        }
        return .init(skills: skills, source: agentID == "codex-acp" ? "agent" : "directory")
    }
    func skillDirectories(agentID: String, workspace: URL?) async throws -> [String: String] {
        ["user": "/fixture/user/skills", "repo": (workspace?.path ?? "") + "/skills"]
    }
    func writeSkill(_ request: AgentSkillWrite) async throws -> URL {
        writeRequests.append(request)
        if holdWrite { await withCheckedContinuation { writeGate = $0 } }
        finishedWrites += 1
        return URL(fileURLWithPath: "/fixture/saved/SKILL.md")
    }
    func setSkillEnabled(_ request: AgentSkillEnablement) async throws -> AgentSkillListing {
        toggleRequests.append(request)
        if holdWrite { await withCheckedContinuation { writeGate = $0 } }
        defer { finishedToggles += 1 }
        if failToggle { throw Failure() }
        enablements[request.source] = request.enabled
        return try await listSkills(agentID: request.agentId, workspace: request.workspace.map { URL(fileURLWithPath: $0) })
    }
    func readSkill(at url: URL, agentID: String) async throws -> String {
        readRequests += 1
        return "---\nname: example\ndescription: A skill for testing\n---\n\n# Workflow\n\n1. Inspect the project.\n2. Explain the result."
    }
    func releaseLists() { let gates = held.values; held = [:]; for gate in gates { gate.resume() } }
    func releaseWrite(holdingNext: Bool = false) {
        holdWrite = holdingNext
        let gate = writeGate; writeGate = nil; gate?.resume()
    }
    func status(dataDirectory: URL) async throws -> AgentManagementStatus { throw Failure() }
    func install(agentID: String, dataDirectory: URL) async throws -> String { throw Failure() }
    func uninstall(agentID: String, dataDirectory: URL) async throws { throw Failure() }
    func installCli(agentID: String, dataDirectory: URL) async throws -> AgentCliUpdateResult { throw Failure() }
    private struct Failure: LocalizedError { var errorDescription: String? { "Controlled skill failure" } }
}

struct AgentSkillsRustBridgeTests {
    @Test func nativeCreateReadAndConflictUseTheRealCoreBridgeInAnIsolatedProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-skills-bridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RustAgentManagementService(core: RustCoreBridge())
        let request = AgentSkillWrite(agentID: "claude-acp", workspace: root, scope: "repo", name: "bridge-skill",
                                      description: "Verify the native bridge", instructions: "Read the project files.")
        let result = try await service.writeSkill(request)
        #expect(result.path.hasSuffix(".claude/skills/bridge-skill/SKILL.md"))
        let content = try await service.readSkill(at: result, agentID: "claude-acp")
        #expect(content.contains("Read the project files."))
        let directories = try await service.skillDirectories(agentID: "claude-acp", workspace: root)
        #expect(directories["repo"]?.hasSuffix(".claude/skills") == true)
        do { _ = try await service.writeSkill(request); Issue.record("Existing skill must not be overwritten") }
        catch { #expect(!error.localizedDescription.isEmpty) }
        #expect(try await service.readSkill(at: result, agentID: "claude-acp") == content)
        let skill = AgentSkill(name: "bridge-skill", description: "Verify the native bridge", path: result.path, scope: "repo", enabled: true)
        let toggled = try await service.setSkillEnabled(.init(agentID: "claude-acp", workspace: root, skill: skill, enabled: false))
        #expect(toggled.skills.first(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == result.resolvingSymlinksInPath() })?.enabled == false)
        let nativeSettings = try Data(contentsOf: root.appendingPathComponent(".claude/settings.local.json"))
        let json = try #require(JSONSerialization.jsonObject(with: nativeSettings) as? [String: Any])
        #expect((json["skillOverrides"] as? [String: String])?["bridge-skill"] == "off")
        #expect(try await service.readSkill(at: result, agentID: "claude-acp") == content)
    }
}


@MainActor
struct AgentSkillsAppearanceTests {
    @Test(arguments: [false, true], [500, 760])
    func toggleFeedbackKeepsRowsInPlace(dark: Bool, width: Int) async throws {
        let service = SkillsTestService()
        let feature = AgentSkillsFeatureModel(service: service)
        let context = AgentSkillsFeatureModel.Context(workspace: service.firstProject)
        await feature.refresh(context)
        let host = NSHostingView(rootView: SettingsAppearanceContainer(themePreference: dark ? .dark : .light) {
            ScrollView {
                AgentSkillsSettingsView(feature: feature, workspace: service.firstProject,
                    onOpen: { _ in }, onReveal: { _ in }, onCopy: { _ in }, onChooseImport: { _, _, _ in nil })
                    .padding(16)
            }
        }.environment(\.locale, Locale(identifier: "zh-Hans")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(width), height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { service.releaseWrite(); feature.cancel(); window.contentView = nil; window.close() }
        layout(host)
        try #require(await awaitChange(on: feature) { feature.phase == .ready && service.listRequests >= 4 })
        let initial = try await renderedSwitches(host, state: .on, enabled: true)
        let originalFrames = initial.map { $0.convert($0.bounds, to: host) }
        let name = "skills-stable-feedback-\(dark ? "dark" : "light")-\(width)"
        try capture(host, name: name + "-initial")

        // Hold each native write so both the first save and the next click are observable.
        for (index, enabled) in [false, true].enumerated() {
            service.holdWrite = true
            let item = try #require(feature.visibleItems.first)
            feature.setEnabled(enabled, for: item, context: context)
            try #require(await awaitChange(on: service) { service.toggleRequests.count == index + 1 })
            #expect(!feature.didChangeEnablement, "success is hidden until native confirmation")
            let pending = try await renderedSwitches(host, state: enabled ? .on : .off, enabled: false)
            #expect(pending.map { $0.convert($0.bounds, to: host) } == originalFrames,
                    "starting another save must not collapse the success message's space")
            try capture(host, name: name + "-\(index)-pending")
            service.releaseWrite()
            try #require(await awaitChange(on: feature) { !feature.isWriting && feature.didChangeEnablement })
            let saved = try await renderedSwitches(host, state: enabled ? .on : .off, enabled: true)
            #expect(saved.map { $0.convert($0.bounds, to: host) } == originalFrames,
                    "showing save confirmation must not shift any skill row")
            try capture(host, name: name + "-\(index)-saved")
        }
    }

    @Test func openingAnActionMenuPreservesTheNativeSwitchStateAndAppearance() async throws {
        let service = SkillsTestService()
        let feature = AgentSkillsFeatureModel(service: service)
        await feature.refresh(.init(workspace: service.firstProject))
        let host = NSHostingView(rootView: SettingsAppearanceContainer(themePreference: .dark) {
            AgentSkillsSettingsView(feature: feature, workspace: service.firstProject,
                onOpen: { _ in }, onReveal: { _ in }, onCopy: { _ in }, onChooseImport: { _, _, _ in nil })
                .padding(16)
        })
        let window = SkillMenuFocusWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 500),
                              styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        let presenter = LitheContextMenuPresenter()
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { presenter.dismiss(); service.releaseWrite(); feature.cancel(); window.contentView = nil; window.close() }
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            layout(host)
            if dropdownAnchors(host).count >= 4 && feature.phase == .ready { break }
            await Task.yield()
        }
        func switches(_ view: NSView) -> [NSSwitch] {
            if let control = view as? NSSwitch { return [control] }
            return view.subviews.flatMap(switches)
        }
        func pixels(_ control: NSView) throws -> Data {
            let bitmap = try #require(control.bitmapImageRepForCachingDisplay(in: control.bounds))
            control.cacheDisplay(in: control.bounds, to: bitmap)
            let bytes = try #require(bitmap.bitmapData)
            return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let control = try #require(switches(host).first)
        let otherControl = try #require(switches(host).last)
        #expect(control.state == .on && control.isEnabled)
        let originalPixels = try pixels(control)
        let otherPixels = try pixels(otherControl)
        try capture(host, name: "skills-menu-before")
        let before = feature.listings
        var copies = 0
        presenter.show(items: [.action("Copy path") { copies += 1 }], at: NSPoint(x: 800, y: 500),
                       appearance: NSAppearance(named: .darkAqua), locale: Locale(identifier: "en"), parentWindow: window)
        layout(host)
        #expect(window.isKeyWindow, "an action menu must retain the settings window's key appearance")
        #expect(window.childWindows?.contains(where: { $0.isVisible && !$0.canBecomeKey }) == true)
        #expect(feature.listings == before && !feature.isWriting)
        #expect(service.toggleRequests.isEmpty, "menu presentation never writes native skill settings")
        #expect(control.state == .on && control.isEnabled)
        #expect(try pixels(control) == originalPixels, "key-window transfer must not gray an enabled skill")
        try capture(host, name: "skills-menu-open")
        for code in [UInt16(125), UInt16(36)] {
            NSApp.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code)))
        }
        #expect(copies == 1, "arrow and Return navigation still execute the action once")
        #expect(window.childWindows?.contains(where: { $0.isVisible }) != true)
        window.resignKey()
        layout(host)
        #expect(control.state == .on && otherControl.state == .on, "inactive window styling does not turn skills off")
        #expect(feature.listings == before && service.toggleRequests.isEmpty)
        window.makeKey()
        layout(host)
        #expect(try pixels(otherControl) == otherPixels, "reactivation restores the original native appearance")
        service.holdWrite = true
        let item = try #require(feature.visibleItems.first)
        feature.setEnabled(false, for: item, context: .init(workspace: service.firstProject))
        #expect(await awaitChange(on: service) { service.toggleRequests.count == 1 })
        layout(host)
        let pendingControl = try #require(switches(host).first)
        #expect(pendingControl.state == .off, "the native switch reflects the choice before saving finishes")
        #expect(!pendingControl.isEnabled, "a real pending write must still disable the control")
        #expect(otherControl.state == .on && otherControl.isEnabled, "saving one row must not disable another skill")
        #expect(try pixels(otherControl) == otherPixels, "an unrelated enabled switch must keep its appearance")
        func progressIndicators(_ view: NSView) -> [NSProgressIndicator] {
            if let indicator = view as? NSProgressIndicator { return [indicator] }
            return view.subviews.flatMap(progressIndicators)
        }
        #expect(progressIndicators(host).isEmpty, "a skill toggle does not add a loading spinner")
        try capture(host, name: "skills-toggle-pending")
    }

    @Test func scopedListsAndNativeDropdownAnchorsFitNarrowAndWideSettings() async throws {
        let service = SkillsTestService()
        let feature = AgentSkillsFeatureModel(service: service)
        await feature.refresh(.init(workspace: service.firstProject))
        for scheme in [ColorScheme.dark, .light] {
            for width in [CGFloat(500), CGFloat(760)] {
                feature.scope = "user"
                let root = SettingsAppearanceContainer(themePreference: scheme == .dark ? .dark : .light) {
                    ScrollView {
                        AgentSkillsSettingsView(feature: feature, workspace: service.firstProject,
                            openProjects: [service.firstProject, service.secondProject], preferredAgentID: "codex-acp",
                            onOpen: { _ in }, onReveal: { _ in }, onCopy: { _ in }, onChooseImport: { _, _, _ in nil })
                            .padding(16)
                    }
                }.environment(\.locale, Locale(identifier: "zh-Hans"))
                let host = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 640),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFront(nil)
                defer { feature.cancel(); window.contentView = nil; window.close() }
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(2))
                var anchors: [NSView] = []
                while clock.now < deadline {
                    layout(host)
                    anchors = dropdownAnchors(host)
                    if anchors.count >= 5 && feature.phase == .ready { break }
                    await Task.yield()
                }
                #expect(anchors.count >= 5, "project, source, import and each row keep native dropdown anchors")
                for anchor in anchors {
                    let rect = anchor.convert(anchor.bounds, to: host)
                    #expect(rect.minX >= -1 && rect.maxX <= width + 1, "dropdown stays inside a narrow settings page")
                }
                try capture(host, name: "skills-\(scheme)-\(Int(width))")
                feature.scope = "repo"
                host.layoutSubtreeIfNeeded()
                #expect(feature.visibleItems.count == 2)
            }
        }
    }

    @Test func detailsAndCreationUseExistingSettingsChrome() async throws {
        let service = SkillsTestService()
        let feature = AgentSkillsFeatureModel(service: service)
        let context = AgentSkillsFeatureModel.Context(workspace: service.firstProject)
        await feature.refresh(context)
        let item = try #require(feature.visibleItems.first)
        for scheme in [ColorScheme.dark, .light] {
            let views: [(String, AnyView)] = [
                ("detail", AnyView(AgentSkillDetailSheet(item: item, feature: feature, onOpen: {}, onReveal: {}))),
                ("create", AnyView(AgentSkillCreateSheet(feature: feature, context: context, scope: "repo", initialAgentID: "codex-acp", source: nil)))
            ]
            for (name, view) in views {
                let host = NSHostingView(rootView: SettingsAppearanceContainer(themePreference: scheme == .dark ? .dark : .light) {
                    view.environment(\.locale, Locale(identifier: "zh-Hans"))
                })
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 570), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
                defer { window.contentView = nil; window.close() }
                host.layoutSubtreeIfNeeded()
                if name == "detail" {
                    #expect(await awaitChange(on: service) { service.readRequests > (scheme == .dark ? 0 : 1) })
                    host.layoutSubtreeIfNeeded()
                }
                #expect(host.fittingSize.width <= 560)
                try capture(host, name: "skill-\(name)-\(scheme)")
            }
        }
        feature.cancel()
    }

    private func renderedSwitches(_ host: NSView, state: NSControl.StateValue, enabled: Bool) async throws -> [NSSwitch] {
        func switches(_ view: NSView) -> [NSSwitch] {
            if let control = view as? NSSwitch { return [control] }
            return view.subviews.flatMap(switches)
        }
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(2))
        var controls: [NSSwitch] = []
        while clock.now < deadline {
            layout(host)
            controls = switches(host)
            if controls.count == 2 && controls.first?.state == state && controls.first?.isEnabled == enabled && controls.dropFirst().allSatisfy({ $0.isEnabled }) { return controls }
            await Task.yield()
        }
        Issue.record("Native skill switches did not render the expected state before the local deadline")
        throw CancellationError()
    }

    private func layout(_ host: NSView) {
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0, true)
        host.layoutSubtreeIfNeeded()
    }
    private func dropdownAnchors(_ view: NSView) -> [NSView] {
        // Selectors have their own shared native owner; menus use the general dropdown owner.
        if view is LitheDropdownAnchorView || String(describing: type(of: view)) == "LitheSettingsSelectAnchorNSView" { return [view] }
        return view.subviews.flatMap(dropdownAnchors)
    }
    private func capture(_ host: NSView, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["LITHE_AGENT_SKILLS_SCREENSHOTS"] else { return }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }
}

@MainActor
private final class SkillMenuFocusWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}
