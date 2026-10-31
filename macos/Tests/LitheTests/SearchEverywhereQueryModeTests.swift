import AppKit
import Foundation
import SwiftUI
import LitheSearchModule
import Testing
@testable import Lithe

@Suite("Search Everywhere query mode", .serialized)
struct SearchEverywhereQueryModeTests {
    @Test @MainActor
    func findActionDispatchSeedsAndReplacesTheVisibleQuery() async throws {
        let suite = "lithe-find-action-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .normal)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { _ in
            #expect(!model.canPerformShortcutCommand(id: "find-action"))
            model.performShortcutCommand(id: "find-action")
            #expect(!model.isSearchEverywhereVisible)

            model.workspaceSessionCoordinator.beginWorkspace(at: URL(fileURLWithPath: "/projects/find-action"))
            let feature = SearchFeatureModel(operations: RustWorkspaceOperations(core: RustCoreBridge()))
            model.cacheModuleCapability(SearchModuleCapability(feature: feature), id: .searchWorkspace, moduleID: .search)
            let session = model.searchSessionFeature
            let host = NSHostingView(rootView: SearchEverywhereView(feature: feature, session: session,
                settings: settings, actionMatches: model.searchEverywhereActionMatches,
                search: { _, _ in }, dismiss: model.dismissSearchEverywhere,
                openResult: { _ in }, performAction: model.performSearchEverywhereAction,
                revealInFinder: { _ in }, copyPath: { _, _ in }, relativePath: { _ in "" }, moduleLabel: { _ in "" }))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer {
                model.dismissSearchEverywhere()
                window.makeFirstResponder(nil)
                window.contentView = nil
                window.close()
            }
            #expect(model.canPerformShortcutCommand(id: "find-action"))
            model.performShortcutCommand(id: "find-action")
            #expect(model.isSearchEverywhereVisible)
            #expect(model.searchSessionFeature.everywhereQuery == "/")
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while !(window.childWindows?.first?.firstResponder is NSTextView), clock.now < deadline {
                host.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            let panel = try #require(window.childWindows?.first)
            let editor = try #require(panel.firstResponder as? NSTextView)
            #expect(editor.string == "/")
            let caretDeadline = clock.now.advanced(by: .seconds(2))
            while editor.selectedRange() != NSRange(location: 1, length: 0), clock.now < caretDeadline { await Task.yield() }
            #expect(editor.selectedRange() == NSRange(location: 1, length: 0))
            editor.insertText("run")
            #expect(session.everywhereQuery == "/run")
            editor.selectAll(nil)
            editor.insertText("workspace query")
            #expect(session.everywhereQuery == "workspace query")
            panel.makeFirstResponder(nil)
            model.performShortcutCommand(id: "find-action")
            #expect(model.isSearchEverywhereVisible)
            #expect(model.searchSessionFeature.everywhereQuery == "/")
            let refocusDeadline = clock.now.advanced(by: .seconds(2))
            while (!(panel.firstResponder is NSTextView) || editor.string != "/"), clock.now < refocusDeadline {
                host.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            #expect(panel.firstResponder is NSTextView)
            #expect(editor.string == "/")
            model.dismissSearchEverywhere()
            #expect(model.searchSessionFeature.everywhereQuery.isEmpty)
            try await container.services.moduleRuntime.setEnabled(false, for: .search)
            #expect(!model.canPerformShortcutCommand(id: "find-action"))
            model.performShortcutCommand(id: "find-action")
            #expect(!model.isSearchEverywhereVisible)
            // Both entry points share activation failure cleanup; a disabled module
            // supplies a deterministic failure without another module test double.
            model.toggleSearchEverywhere()
            let failureDeadline = clock.now.advanced(by: .seconds(2))
            while model.isSearchEverywhereVisible, clock.now < failureDeadline { await Task.yield() }
            #expect(!model.isSearchEverywhereVisible)
        }
    }

    @Test @MainActor
    func switchingProjectsClosesSearchEverywhereSoFindActionReactivates() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-find-action-switch-\(UUID().uuidString)")
        let first = base.appendingPathComponent("first")
        let second = base.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let suite = "lithe-find-action-switch-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .normal)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { _ in
            model.openProjectDirectly(first)
            model.performShortcutCommand(id: "find-action")
            #expect(model.isSearchEverywhereVisible)
            // Switch before the first project's activation task runs.
            model.openProjectDirectly(second)
            #expect(!model.isSearchEverywhereVisible)
            model.performShortcutCommand(id: "find-action")
            #expect(model.isSearchEverywhereVisible)
            #expect(model.searchSessionFeature.everywhereQuery == "/")
            model.dismissSearchEverywhere()
        }
    }

    @Test
    func ordinaryTextSearchesTheWorkspaceWithoutEnteringCommandMode() {
        let mode = SearchEverywhereQueryMode(query: "l")

        #expect(mode.workspaceQuery == "l")
        #expect(mode.workspaceSearchTaskID == "workspace:l")
        #expect(mode.commandQuery == nil)
        #expect(SearchEverywhereResultSource(queryMode: mode, scope: .all) == .combinedWorkspaceNames)
    }

    @Test
    func slashListsAllCommandsWithoutSearchingTheWorkspace() {
        let mode = SearchEverywhereQueryMode(query: "/")

        #expect(mode.workspaceQuery.isEmpty)
        #expect(mode.workspaceSearchTaskID == "commands")
        #expect(mode.commandQuery == "")
        #expect(SearchEverywhereResultSource(queryMode: mode, scope: .files) == .commands(""))
    }

    @Test
    func slashPrefixIsRemovedBeforeFilteringCommands() {
        let mode = SearchEverywhereQueryMode(query: "/run")

        #expect(mode.workspaceQuery.isEmpty)
        #expect(mode.workspaceSearchTaskID == "commands")
        #expect(mode.commandQuery == "run")
        #expect(SearchEverywhereResultSource(queryMode: mode, scope: .symbols) == .commands("run"))
    }

    @Test
    func commandModeUsesCommandSpecificEmptyStateRegardlessOfSelectedScope() {
        let source = SearchEverywhereResultSource(
            queryMode: SearchEverywhereQueryMode(query: "/missing"),
            scope: .files
        )

        #expect(source.emptyResultsMessage == "No matching commands")
    }

    @Test
    func actionsScopeUsesTheOrdinaryQueryOutsideCommandMode() {
        let source = SearchEverywhereResultSource(
            queryMode: SearchEverywhereQueryMode(query: "run"),
            scope: .actions
        )

        #expect(source == .actions("run"))
        #expect(source.emptyResultsMessage == "No matches in Actions")
    }
}
