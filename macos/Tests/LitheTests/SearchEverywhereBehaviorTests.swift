import AppKit
import Combine
import SwiftUI
import Testing
import os
import LitheSearchModule
import LitheAgentConversationModule
import LitheGitModule
@testable import Lithe

@MainActor
@Suite("Search Everywhere matching and preview", .serialized)
struct SearchEverywhereBehaviorTests {
    @Test(arguments: ["clean", "dirty", "replacement", "problems", "problemsOnly"])
    func dismissingSearchReleasesOnlyUnownedCleanPreviewDocuments(ending: String) async throws {
        let suite = "lithe-search-preview-cleanup-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Name.txt")
        try "initial".write(to: file, atomically: true, encoding: .utf8)
        model.documentFeature.configure(workspaceURLProvider: { root }, autoSaveEnabledProvider: { false },
            autoSaveDelayProvider: { 0 }, notify: { _ in }, onDocumentOpened: { _ in },
            onDocumentChanged: { _ in }, onDocumentClosed: { _ in }, onRecordSave: { _, _ in },
            onRecordDiscard: { _ in }, onRecordExternalChanges: { _ in },
            onDocumentCollectionChanged: {}, onProjectCloseReady: {})
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { scope in
            var loaded: EditorDocument?
            try await scope.run("load search preview") { loaded = await model.documentFeature.previewDocument(at: file, owner: ending == "problemsOnly" ? .problems : .searchEverywhere) }
            let document = try #require(loaded)
            #expect(model.documentFeature.openDocuments.isEmpty)
            if ending == "dirty" { document.applyLiveEditorText("unsaved") }
            if ending == "replacement" || ending == "problems" {
                let shared = await model.documentFeature.previewDocument(at: file,
                    owner: ending == "replacement" ? .projectReplacement : .problems)
                #expect(shared === document)
            }
            model.searchSessionFeature.isProjectReplaceVisible = ending == "replacement"
            model.searchSessionFeature.beginSearchEverywhere(query: "name")
            model.dismissSearchEverywhere()
            #expect(!model.isSearchEverywhereVisible)
            #expect(model.documentFeature.editorDocuments.contains { $0 === document } == (ending != "clean"))
            if ending == "dirty" {
                #expect(model.documentFeature.openDocuments.contains { $0 === document })
                #expect(document.text == "unsaved")
            }
            if ending == "replacement" || ending.hasPrefix("problems") {
                try "external update".write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: file.path)
                try await scope.run("refresh retained preview") { await model.documentFeature.reconcileExternalChanges([file]) }
                #expect(document.text == "external update")
                model.documentFeature.discardPreviewDocuments(owner: ending == "replacement" ? .projectReplacement : .problems)
                #expect(!model.documentFeature.editorDocuments.contains { $0 === document })
            }
            if ending == "clean" {
                var otherPreview: EditorDocument?
                try await scope.run("load another feature's preview") {
                    otherPreview = await model.documentFeature.previewDocument(at: file)
                }
                let other = try #require(otherPreview)
                model.dismissSearchEverywhere() // A duplicate dismissal must not clear another owner's preview.
                #expect(model.documentFeature.editorDocuments.contains { $0 === other })
                model.documentFeature.discardPreviewDocuments()
            }
        }
    }

    @Test(arguments: ["clean", "dirty", "shared"])
    func navigatingAndHidingSourcePreviewReleasesOnlyItsCurrentRequest(ownership: String) async throws {
        let suite = "lithe-search-navigation-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        model.documentFeature.configure(workspaceURLProvider: { root }, autoSaveEnabledProvider: { false },
            autoSaveDelayProvider: { 0 }, notify: { _ in }, onDocumentOpened: { _ in },
            onDocumentChanged: { _ in }, onDocumentClosed: { _ in }, onRecordSave: { _, _ in },
            onRecordDiscard: { _ in }, onRecordExternalChanges: { _ in },
            onDocumentCollectionChanged: {}, onProjectCloseReady: {})
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 250),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { scope in
            var rendered: EditorDocument?
            var first: EditorDocument?
            var firstRequest: UUID?
            @MainActor func waitUntil(_ name: String, _ condition: @MainActor () -> Bool) async throws {
                let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(2))
                while !condition(), clock.now < deadline {
                    host.layoutSubtreeIfNeeded()
                    await Task.yield()
                }
                guard condition() else { throw WorkbenchTestScope.DeadlineExceeded(operation: name) }
            }
            for name in ["A", "B", "C"] {
                let url = root.appendingPathComponent(name + ".txt")
                try "initial".write(to: url, atomically: true, encoding: .utf8)
                rendered = nil
                host.rootView = AnyView(SearchEverywhereSourcePreview(
                    result: .init(url: url, line: nil, preview: "", kind: .file), query: "initial",
                    loadDocument: { url, requestID in
                        if name == "A" { firstRequest = requestID }
                        return await model.documentFeature.previewDocument(at: url, owner: .searchEverywhere, requestID: requestID)
                    }, releaseDocument: { url, requestID in
                        model.documentFeature.releasePreviewDocument(at: url, owner: .searchEverywhere, requestID: requestID)
                    }, makeEditor: { doc, _ in
                        rendered = doc
                        return AnyView(Text(doc.text))
                    }).frame(width: 500, height: 250))
                try await waitUntil("render selected preview") { rendered?.url == url }
                if name == "A" {
                    first = rendered
                    if ownership == "dirty" { first?.applyLiveEditorText("unsaved") }
                    if ownership == "shared" {
                        _ = await model.documentFeature.previewDocument(at: url, owner: .problems)
                    }
                }
                let expected = ownership == "clean" || name == "A" ? 1 : 2
                try await waitUntil("release previous preview") { model.documentFeature.editorDocuments.count == expected }
            }
            // Removing the preview models collapse, empty results and search-window dismissal.
            host.rootView = AnyView(EmptyView())
            try await waitUntil("release hidden preview") {
                model.documentFeature.editorDocuments.count == (ownership == "clean" ? 0 : 1)
            }
            if ownership == "dirty" {
                #expect(model.documentFeature.openDocuments.first === first)
                #expect(first?.text == "unsaved")
            }
            if ownership == "shared" {
                #expect(model.documentFeature.editorDocuments.first === first)
                model.documentFeature.discardPreviewDocuments(owner: .problems)
                #expect(model.documentFeature.editorDocuments.isEmpty)
            }
            // A late old release of the same path cannot discard a newly acquired preview.
            let url = root.appendingPathComponent("A.txt"), currentID = UUID()
            _ = await model.documentFeature.previewDocument(at: url, owner: .searchEverywhere, requestID: currentID)
            model.documentFeature.releasePreviewDocument(at: url, owner: .searchEverywhere,
                requestID: try #require(firstRequest))
            #expect(model.documentFeature.editorDocuments.contains { $0.url == url })
            model.documentFeature.releasePreviewDocument(at: url, owner: .searchEverywhere, requestID: currentID)
            #expect(model.documentFeature.editorDocuments.isEmpty == (ownership != "dirty"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_RUN_GIT_EXECUTION_INTEGRATION"] == "1"))
    func searchUsesSelectedGitWithoutAnInteractiveConsoleOperation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-search-git-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initResult = try await TestProcess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["init", "--template=", "-q"], currentDirectoryURL: root)
        try #require(initResult.terminationStatus == 0)
        try "*.log\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("Name.log"), atomically: true, encoding: .utf8)
        let executable = root.appendingPathComponent("selected-git")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$0.calls\"\nexec /usr/bin/git \"$@\"\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let preferences = GitExecutionPreferences()
        var options = GitExecutionOptions()
        options.executable = executable.path
        preferences.update(options)
        let journal = GitExecutionJournal()
        let core = RustCoreBridge(gitPreferences: preferences, gitExecutionJournal: journal)
        let response = try #require(core.searchEverywhere(at: root, query: "name", caseSensitive: false,
            wholeWords: false, regularExpression: false, maxContentResults: 0, maxSymbolResults: 0))
        #expect(response.matches.first { $0.path == "Name.log" }?.isIgnored == true)
        let calls = try String(contentsOfFile: executable.path + ".calls", encoding: .utf8)
        #expect(calls.contains("check-ignore"))
        #expect(journal.snapshot.isEmpty && journal.runningOperationIDs.isEmpty)
    }

    @Test
    func searchExclusionsPersistWithoutHidingProjectFiles() throws {
        let suite = "lithe-search-exclusions-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        #expect(settings.searchExcludedPathPatterns.isEmpty)
        settings.searchExcludedPathPatterns = ["*.log", "**/.*/", ".*", "cache/"]
        let restored = AppSettings(store: store)
        #expect(restored.searchExcludedPathPatterns == settings.searchExcludedPathPatterns)
        let root = URL(fileURLWithPath: "/fixture")
        for path in ["Name.log", "src/Name.log", ".hidden/Name.swift", "src/.hidden/Name.swift", "src/.env", "cache/Name.swift"] {
            let url = root.appendingPathComponent(path)
            #expect(settings.searchEverywhereVisibilityRules.isHidden(url, relativeTo: root, isDirectory: false), "\(path)")
            #expect(!settings.fileVisibilityRules.isHidden(url, relativeTo: root, isDirectory: false), "\(path)")
        }
        #expect(!settings.searchEverywhereVisibilityRules.isHidden(root.appendingPathComponent("src/Name.swift"), relativeTo: root, isDirectory: false))
        settings.searchExclusionsEnabled = false
        #expect(settings.searchEverywhereVisibilityRules == settings.fileVisibilityRules)
        let disabled = AppSettings(store: store)
        #expect(!disabled.searchExclusionsEnabled)
        #expect(disabled.searchExcludedPathPatterns == settings.searchExcludedPathPatterns)
        settings.searchExclusionsEnabled = true
        #expect(AppSettings(store: store).searchExclusionsEnabled)
        settings.searchExcludedPathPatterns = []
        #expect(AppSettings(store: store).searchExcludedPathPatterns.isEmpty)
        #expect(settings.searchEverywhereVisibilityRules == settings.fileVisibilityRules)
        #expect(!SettingsSearchVocabulary.matches(query: "Search exclusions", category: .general))
    }

    @Test
    func directoryExclusionsFollowTheSharedPruningContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("shared/fixtures/search/exclusions.json"))) as? [String: Any])
        let patterns = try #require(fixture["hiddenFilePatterns"] as? [String])
        let rules = FileVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: patterns)
        let workspace = URL(fileURLWithPath: "/fixture")
        for item in try #require(fixture["cases"] as? [[String: Any]]) {
            let path = try #require(item["path"] as? String)
            let directory = try #require(item["isDirectory"] as? Bool)
            let hidden = try #require(item["hidden"] as? Bool)
            #expect(rules.isHidden(workspace.appendingPathComponent(path), relativeTo: workspace, isDirectory: directory) == hidden, "\(path)")
        }
    }

    @Test
    func everywhereExclusionsDoNotChangeSidebarReplacementOrAgentMentions() async throws {
        let suite = "lithe-agent-search-scope-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults), settings = AppSettings(store: store)
        settings.searchExcludedPathPatterns = ["*.log"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/fixtures/search/path-fallback.json"))) as? [String: Any])
        let unicodeFixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/fixtures/search/unicode-contiguous.json"))) as? [String: Any])
        let unicodeCases = try #require(unicodeFixture["cases"] as? [[String: Any]])
        let unicodeFiles = try Set(unicodeCases.map { try #require($0["path"] as? String) })
        let pathFiles = try #require(fixture["files"] as? [String])
        for path in ["Name.txt", "Name.log", ".build/NameGenerated.txt", "node_modules/NameDependency.txt"] + pathFiles + unicodeFiles.sorted() {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "name".write(to: file, atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        let feature = SearchFeatureModel(operations: RustWorkspaceOperations(core: RustCoreBridge()))
        let loaded = TestGate()
        let observation = model.workspaceFeature.$projectFiles.sink { files in
            if files.contains(where: { $0.lastPathComponent == "Name.log" }) { loaded.open() }
        }
        defer { observation.cancel(); feature.reset() }
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { scope in
            model.openProjectDirectly(root)
            try #require(await loaded.waitUntilOpen())
            model.cacheModuleCapability(SearchModuleCapability(feature: feature), id: .searchWorkspace, moduleID: .search)
            var bare: [AgentFileMention] = [], named: [AgentFileMention] = []
            try await scope.run("bare and named agent mentions", timeout: .seconds(5)) {
                bare = await model.agentFileMentions(matching: "")
                named = await model.agentFileMentions(matching: "Name")
            }
            #expect(Set(bare.map(\.path)) == Set(["Name.txt", "Name.log"] + pathFiles + unicodeFiles.sorted()))
            #expect(Set(named.map(\.path)) == ["Name.txt", "Name.log"])
            for item in try #require(fixture["cases"] as? [[String: Any]]) {
                let query = try #require(item["query"] as? String)
                let paths = try #require(item["paths"] as? [String])
                var mentions: [AgentFileMention] = []
                try await scope.run("Agent @ path fallback") { mentions = await model.agentFileMentions(matching: query) }
                #expect(mentions.map(\.path).filter { !unicodeFiles.contains($0) } == paths)
            }
            for item in unicodeCases {
                let query = try #require(item["query"] as? String)
                let path = try #require(item["path"] as? String)
                var mentions: [AgentFileMention] = []
                try await scope.run("Agent Unicode lowercase expansion") { mentions = await model.agentFileMentions(matching: query) }
                #expect(mentions.contains { $0.path == path })
            }
            model.searchSessionFeature.beginSearchEverywhere(query: "Name")
            try await scope.run("global generated-name search", timeout: .seconds(5)) { await model.searchEverywhere(query: "Name") }
            let paths = feature.searchEverywhereResults.fileMatches.map { $0.url.lastPathComponent }
            #expect(paths.contains("NameGenerated.txt") && paths.contains("NameDependency.txt"))
            #expect(!paths.contains("Name.log"))
            settings.searchExclusionsEnabled = false
            try await scope.run("disabled exclusions restore global results", timeout: .seconds(5)) {
                await model.searchEverywhere(query: "Name")
            }
            #expect(feature.searchEverywhereResults.fileMatches.contains { $0.url.lastPathComponent == "Name.log" })
            #expect(settings.searchExcludedPathPatterns == ["*.log"])
            settings.searchExclusionsEnabled = true
            model.searchSessionFeature.query = "name"
            model.openProjectReplace()
            try await scope.run("sidebar and replacement ignore Everywhere exclusions", timeout: .seconds(5)) {
                await model.searchProject()
                await model.previewProjectReplacement(query: "name", replacement: "updated", options: .default)
            }
            #expect(feature.searchResults.contains { $0.url.lastPathComponent == "Name.log" })
            #expect(feature.projectReplacementFiles.contains { $0.relativePath == "Name.log" })
            #expect(try String(contentsOf: root.appendingPathComponent("Name.log"), encoding: .utf8) == "name")
            settings.searchExcludedPathPatterns = []
            try await scope.run("cleared exclusions restore global results", timeout: .seconds(5)) {
                await model.searchEverywhere(query: "Name")
            }
            #expect(feature.searchEverywhereResults.fileMatches.contains { $0.url.lastPathComponent == "Name.log" })
            model.dismissSearchEverywhere()
            let snapshotID = model.workspaceSnapshotID
            let invalidated = TestGate()
            let observedFeature = SearchFeatureModel(operations: PreviewSelectionOperations(onInvalidate: { invalidated.open() }))
            defer { observedFeature.reset() }
            model.cacheModuleCapability(SearchModuleCapability(feature: observedFeature), id: .searchWorkspace, moduleID: .search)
            settings.searchExcludedPathPatterns = ["cache/", "*.log"]
            #expect(await invalidated.waitUntilOpen(), "Settings did not invalidate the active search cache")
            try await scope.run("join search invalidation") {
                _ = await observedFeature.findFiles(at: root, query: "Name", visibilityRules: settings.fileVisibilityRules.searchRules)
            }
            #expect(model.workspaceSnapshotID == snapshotID, "Search exclusions must not rebuild the project tree")
            #expect(Set(model.projectFiles.map(\.lastPathComponent)) == Set((["Name.txt", "Name.log"] + pathFiles + unicodeFiles.sorted()).map { URL(fileURLWithPath: $0).lastPathComponent }))
        }
    }

    @Test
    func queryDraftPreservesExplicitClearingWithoutSharingSidebarOrWorkspaceState() {
        let session = SearchSessionFeatureModel()
        session.query = "sidebar"
        session.beginSearchEverywhere()
        session.everywhereQuery = "name"
        session.endSearchEverywhere()
        session.endSearchEverywhere() // Native dismissal may be delivered twice.
        session.beginSearchEverywhere()
        #expect(session.everywhereQuery == "name")
        #expect(session.query == "sidebar")
        session.everywhereQuery = ""
        session.endSearchEverywhere()
        session.beginSearchEverywhere()
        #expect(session.everywhereQuery.isEmpty, "Explicit clearing must survive reopening")
        session.endSearchEverywhere()
        session.beginSearchEverywhere(scope: .files, query: "explicit")
        #expect(session.everywhereQuery == "explicit")
        session.endSearchEverywhere()
        session.beginSearchEverywhere(scope: .classes)
        #expect(session.everywhereQuery.isEmpty)
        session.endSearchEverywhere()
        session.beginSearchEverywhere()
        #expect(session.everywhereQuery.isEmpty, "All resumes the last draft, not an older nonempty history item")
        session.everywhereQuery = "fresh"
        session.endSearchEverywhere()
        session.beginSearchEverywhere()
        #expect(session.everywhereQuery == "fresh")
        session.reset()
        session.beginSearchEverywhere()
        #expect(session.everywhereQuery.isEmpty)
    }

    @Test
    func queryHistoryDeduplicatesPerContributorAndBoundsEachSource() {
        let session = SearchSessionFeatureModel()
        for index in 0..<51 {
            session.beginSearchEverywhere(scope: .files, query: "name-\(index)")
            session.endSearchEverywhere()
        }
        #expect(session.everywhereHistoryItems(for: .files).count == 50)
        #expect(session.everywhereHistoryItems(for: .files).first == "name-1")
        session.beginSearchEverywhere(scope: .files, query: "name-1")
        session.endSearchEverywhere()
        #expect(session.everywhereHistoryItems(for: .files).count == 50)
        #expect(session.everywhereHistoryItems(for: .files).last == "name-1")
        session.beginSearchEverywhere(scope: .classes, query: "name-1")
        session.endSearchEverywhere()
        #expect(session.everywhereHistoryItems(for: .classes) == ["name-1"])
        #expect(session.everywhereHistoryItems(for: .all).count == 50)
    }

    @Test
    func fileStatusForegroundDoesNotReplaceSelectedMatchBackground() throws {
        func channels(_ color: Color?) throws -> [CGFloat] {
            let value = try #require(color)
            let rgb = try #require(NSColor(value).usingColorSpace(.sRGB))
            return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
        }
        let change = GitChange(repositoryRoot: URL(fileURLWithPath: "/fixture"), path: "name.swift",
            originalPath: nil, indexStatus: "?", workTreeStatus: "?")
        #expect(try channels(change.fileNameColor) == channels(LitheTheme.Commit.fileUntracked))
        let session = SearchSessionFeatureModel()
        session.everywhereGitStatus = GitTreeStatusProjection(changes: [change], absolutePaths: true)
        #expect(session.everywhereGitStatus.change(relativePath: change.url.path) == change)
        session.reset()
        #expect(session.everywhereGitStatus.change(relativePath: change.url.path) == nil)
        let result = FileSearchResult(url: change.url, line: nil, preview: "", kind: .file,
            nameMatchRanges: [.init(start: 0, length: 4)])
        let normal = SearchEverywhereNameText.highlighted(result, selected: false, foreground: change.fileNameColor)
        for run in normal.runs {
            #expect(try channels(run.foregroundColor) == channels(change.fileNameColor))
            #expect(run.backgroundColor == nil)
        }
        let selected = SearchEverywhereNameText.highlighted(result, selected: true, foreground: change.fileNameColor)
        let fragments = selected.runs.filter { $0.backgroundColor != nil }
        #expect(fragments.count == 1)
        for run in fragments {
            #expect(try channels(run.foregroundColor) == channels(LitheTheme.SearchEverywhere.matchForeground))
        }
        #expect(try channels(selected.runs.last?.foregroundColor) == channels(change.fileNameColor))
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func ignoredNamesUseIdeaStatusForegroundAndKeepMatchFragments(scheme: ColorScheme) throws {
        let appearance = try #require(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
        let payload = """
        {"matches":[{"kind":"file","path":".build/Name.swift","line":null,"preview":"",
        "nameMatchRanges":[{"start":0,"length":4}],"isIgnored":true}]}
        """
        let response = try JSONDecoder().decode(RustCoreBridge.SearchResponsePayload.self, from: Data(payload.utf8))
        let result = try #require(response.makeResults(at: URL(fileURLWithPath: "/fixture")).first)
        #expect(result.isIgnored == true)
        let normal = SearchEverywhereNameText.highlighted(result, selected: false)
        let color = try #require(normal.runs.first?.foregroundColor)
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = NSColor(color).usingColorSpace(.sRGB) }
        let rgb = try #require(resolved)
        let hex: UInt32 = scheme == .dark ? 0xD69A6B : 0x8C4F00
        let expected = [CGFloat((hex >> 16) & 255), CGFloat((hex >> 8) & 255), CGFloat(hex & 255)]
        let actual = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        #expect(zip(actual, expected).allSatisfy { abs($0.0 - $0.1 / 255) < 0.01 })
        let selected = SearchEverywhereNameText.highlighted(result, selected: true)
        #expect(selected.runs.filter { $0.backgroundColor != nil }.map { String(selected[$0.range].characters) } == ["Name"])
        let legacy = try JSONDecoder().decode(RustCoreBridge.SearchResponsePayload.self,
            from: Data("{\"matches\":[{\"kind\":\"file\",\"path\":\"Name.swift\",\"preview\":\"\"}]}".utf8))
        #expect(legacy.makeResults(at: URL(fileURLWithPath: "/fixture")).first?.isIgnored == nil)
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func filterRowsAndBulkButtonsKeepTheirCheckedState(scheme: ColorScheme) async throws {
        let session = SearchSessionFeatureModel()
        let host = NSHostingView(rootView: ProviderFilterHarness(session: session).environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 238, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.colorSpace = .sRGB
        window.acceptsMouseMovedEvents = true
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize == NSSize(width: 238, height: 200))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        // cacheDisplay labels painted channel values calibrated RGB; do not convert them a second time.
        let background = try #require(bitmap.colorAt(x: Int(118 * scale), y: Int(130 * scale)))
        let expected: [CGFloat] = scheme == .dark ? [25 / 255, 26 / 255, 28 / 255] : [1, 1, 1]
        for (value, target) in zip([background.redComponent, background.greenComponent, background.blueComponent], expected) {
            #expect(abs(value - target) < 0.01, "Chooser tables use the Islands tool-window surface")
        }
        func color(at top: CGFloat) throws -> NSColor {
            host.layoutSubtreeIfNeeded()
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try #require(bitmap.colorAt(x: Int(180 * scale), y: Int(top * scale)))
        }
        func matches(_ color: NSColor, _ hex: UInt32) -> Bool {
            let actual = [color.redComponent, color.greenComponent, color.blueComponent]
            let expected = [CGFloat((hex >> 16) & 255), CGFloat((hex >> 8) & 255), CGFloat(hex & 255)]
            return zip(actual, expected).allSatisfy { pair in abs(pair.0 - pair.1 / 255) < 0.01 }
        }
        #expect(matches(try color(at: 161.5), scheme == .dark ? 0x26282C : 0xD1D3D9),
            "The line above the footer is the one-point scroll-pane border")
        func expectRowColor(_ hex: UInt32, top: CGFloat) async throws {
            let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(2))
            repeat {
                await Task.yield()
                if matches(try color(at: top), hex) { return }
            } while clock.now < deadline
            #expect(matches(try color(at: top), hex), "Unexpected hovered/selected chooser row color")
        }
        func click(x: CGFloat, top: CGFloat) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try #require(NSEvent.mouseEvent(with: type,
                    location: NSPoint(x: x, y: 200 - top), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
        }
        try click(x: 118, top: 181) // None
        #expect(session.enabledEverywhereProviders.isEmpty)
        try click(x: 195, top: 181) // Invert
        #expect(session.enabledEverywhereProviders == Set(SearchEverywhereProvider.allCases))
        try click(x: 80, top: 42) // Classes: blue selected row, independent of its checkbox.
        #expect(!session.enabledEverywhereProviders.contains(.classes))
        #expect(session.enabledEverywhereProviders.count == 3)
        // Real hover enters/exits are checked in the packaged app; synthetic mouseMoved does not drive Window Server tracking.
        try await expectRowColor(scheme == .dark ? 0x2A4371 : 0xD0DFFE, top: 42)
        try click(x: 41, top: 181) // All
        #expect(session.enabledEverywhereProviders == Set(SearchEverywhereProvider.allCases))
        for name in ["checkBox", "checkBoxSelected"] {
            for suffix in ["", "_dark"] {
                let url = DeclarativePluginTestSupport.repositoryRoot
                    .appendingPathComponent("macos/Resources/IDEAIcons/commit/\(name)\(suffix).svg")
                #expect(try #require(NSImage(contentsOf: url)).size == NSSize(width: 24, height: 24))
            }
        }
        await Task.yield()
        #expect(window.isVisible)
    }

    @Test
    func requestedSourcesReachTheCorePortWithoutSearchingForActions() async throws {
        let requests = OSAllocatedUnfairLock(initialState: [Set<SearchResultKind>]())
        let feature = SearchFeatureModel(operations: PreviewSelectionOperations(onSearch: { kinds in
            requests.withLock { $0.append(kinds) }
        }))
        defer { feature.reset() }
        let session = SearchSessionFeatureModel()
        session.beginSearchEverywhere(query: "name")
        let suite = "lithe-search-sources-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(store: MacUserDefaultsStore(defaults: defaults))
        let coordinator = SearchWorkflowCoordinator(session: session, settings: settings, activate: { feature },
            workspace: { URL(fileURLWithPath: "/fixture") }, notify: { Issue.record("Unexpected failure: \($0)") }, markIdle: {})
        let cases: [(SearchEverywhereScope, Set<SearchEverywhereProvider>, Set<SearchResultKind>)] = [
            (.files, [.actions], [.file]), (.text, [], [.content]),
            (.classes, [], [.type]), (.symbols, [], [.symbol]),
            (.all, [.files, .symbols], [.file, .symbol]),
            (.actions, Set(SearchEverywhereProvider.allCases), []), (.all, [.actions], [])
        ]
        for (scope, providers, expected) in cases {
            session.everywhereScope = scope
            session.enabledEverywhereProviders = providers
            let before = requests.withLock { $0.count }
            await coordinator.searchEverywhere(query: "name", options: .default)
            #expect(session.everywhereResultKinds == expected)
            #expect(requests.withLock { $0.count } == before + (expected.isEmpty ? 0 : 1))
            if !expected.isEmpty { #expect(requests.withLock { $0.last } == expected) }
            else { #expect(feature.searchEverywhereResults.allMatches.isEmpty) }
        }
        _ = await coordinator.findFiles(query: "src")
        #expect(requests.withLock { $0.last } == [.file], "Agent completion needs only the name index")
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func previewSelectionKeepsFocusColorAndMouseScrollPosition(scheme: ColorScheme) async throws {
        let operations = PreviewSelectionOperations()
        let feature = SearchFeatureModel(operations: operations)
        await feature.searchEverywhere(at: URL(fileURLWithPath: "/fixture"), query: "name", options: .default,
            visibilityRules: .init(hiddenDirectoryNames: [], hiddenFilePatterns: []), isCurrent: { true })
        let session = SearchSessionFeatureModel()
        session.everywhereQuery = "name"
        session.isEverywherePreviewVisible = true
        session.isSearchEverywhereVisible = true
        var previewedURL: URL?
        var openedURL: URL?
        let view = SearchEverywhereView(feature: feature, session: session, settings: AppSettings(store: MacUserDefaultsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)), actionMatches: { _ in [] },
            search: { _, _ in }, dismiss: {}, openResult: { openedURL = $0.url },
            performAction: { _ in }, revealInFinder: { _ in }, copyPath: { _, _ in },
            relativePath: { $0.lastPathComponent }, moduleLabel: { _ in "" },
            loadPreviewDocument: { url, _ in EditorDocument(url: url, text: "preview", modificationDate: nil) },
            makePreviewEditor: { document, _ in
                previewedURL = document.url
                return AnyView(TextField("Preview fixture", text: .constant(document.text)))
            })
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).frame(width: 1000, height: 800))
        parent.contentView = host
        parent.makeKeyAndOrderFront(nil)
        defer {
            session.isSearchEverywhereVisible = false
            parent.contentView = nil
            parent.close()
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func settle(_ label: String = "state", until condition: () -> Bool) async {
            let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(2))
            repeat {
                host.layoutSubtreeIfNeeded()
                parent.childWindows?.first?.contentView?.layoutSubtreeIfNeeded()
                if condition() { return }
                await Task.yield()
            } while clock.now < deadline
            Issue.record("Native Search Everywhere did not settle: \(label), preview=\(previewedURL?.lastPathComponent ?? "nil")")
        }
        await settle { previewedURL != nil }
        let popup = try #require(parent.childWindows?.first)
        let content = try #require(popup.contentView)
        let scroll = try #require(descendants(content).compactMap { $0 as? NSScrollView }
            .first { ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height })
        let document = try #require(scroll.documentView)
        // Isolated tests deliver the native key callback without activating the desktop app.
        let presenter = try #require(popup.delegate as? LitheCenteredPopupPresenter)
        presenter.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: popup))
        let originalOffset = scroll.contentView.bounds.origin
        let originalFrame = popup.frame
        let point = document.convert(NSPoint(x: 100, y: 4 + 7 * 24 + 12), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: popup.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        await settle("mouse selection") { previewedURL?.lastPathComponent == "name07.swift" }
        #expect(openedURL == nil, "A single mouse click must only preview")
        let previewField = try #require(descendants(content).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "preview" })
        #expect(popup.makeFirstResponder(previewField))
        await settle { previewField.currentEditor() != nil }
        #expect(scroll.contentView.bounds.origin == originalOffset, "Mouse selection must not recenter the list")
        #expect(popup.frame == originalFrame, "Selecting a file must not move or resize the popup")
        func selectedColor() throws -> NSColor {
            content.layoutSubtreeIfNeeded()
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let sample = document.convert(NSPoint(x: 400, y: 4 + 7 * 24 + 12), to: content)
            let scale = CGFloat(bitmap.pixelsWide) / content.bounds.width
            let y = content.isFlipped ? sample.y : content.bounds.height - sample.y
            return try #require(bitmap.colorAt(x: Int(sample.x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
        }
        await settle("focused color") { (try? selectedColor()).map { $0.blueComponent > $0.redComponent + 0.1 } == true }
        let color = try selectedColor()
        #expect(color.blueComponent > color.redComponent + 0.1, "Preview focus keeps the active selection color")

        let searchField = try #require(popup.initialFirstResponder as? NSTextField)
        #expect(popup.makeFirstResponder(searchField))
        for _ in 0..<20 {
            NSApp.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: popup.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 125)))
            await Task.yield()
        }
        await settle { scroll.contentView.bounds.origin.y > originalOffset.y }
        #expect(scroll.contentView.bounds.origin.y > originalOffset.y, "Keyboard navigation must still reveal offscreen rows")
        #expect(popup.frame == originalFrame)
        let editor = try #require(searchField.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("name0", replacementRange: editor.selectedRange())
        // The first row begins after the list's 4pt vertical padding.
        let firstRow = NSRect(x: 0, y: 4, width: 1, height: 24)
        await settle("new query starts at the first result") {
            previewedURL?.lastPathComponent == "name00.swift" && scroll.contentView.bounds.contains(firstRow)
        }
        #expect(scroll.contentView.bounds.contains(firstRow))
        // Non-mouse activation must open even while the preview is visible.
        NSApp.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: popup.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)))
        #expect(openedURL?.lastPathComponent == "name00.swift", "Return must open the selected result with preview enabled")
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func providerAndExclusionChangesKeepTheNativeFilterAnchorAlive(scheme: ColorScheme) async throws {
        let feature = SearchFeatureModel(operations: RustWorkspaceOperations(core: RustCoreBridge()))
        let session = SearchSessionFeatureModel()
        session.everywhereQuery = "name"
        session.isSearchEverywhereVisible = true
        let suite = "lithe-funnel-exclusions-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(store: MacUserDefaultsStore(defaults: defaults))
        var searchedPatterns: [[String]] = []
        var filteredProviderWasRead = false
        let action = LitheAction(id: "fixture.name", title: "Name command", subtitle: "", group: .window, perform: {})
        let view = SearchEverywhereView(feature: feature, session: session, settings: settings, actionMatches: { _ in
            if session.enabledEverywhereProviders == [.actions] { filteredProviderWasRead = true }
            return [action]
        }, search: { _, _ in searchedPatterns.append(settings.searchExcludedPathPatterns) }, dismiss: {}, openResult: { _ in }, performAction: { _ in },
            revealInFinder: { _ in }, copyPath: { _, _ in }, relativePath: { _ in "" }, moduleLabel: { _ in "" })
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).frame(width: 1000, height: 800))
        parent.contentView = host
        parent.makeKeyAndOrderFront(nil)
        defer {
            session.isSearchEverywhereVisible = false
            parent.contentView = nil
            parent.close()
        }
        let clock = ContinuousClock()
        var deadline = clock.now.advanced(by: .seconds(1))
        while (parent.childWindows?.first?.frame.height ?? 0) <= 84, clock.now < deadline {
            host.layoutSubtreeIfNeeded()
            parent.childWindows?.first?.contentView?.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        var popup = try #require(parent.childWindows?.first)
        #expect(popup.frame.height > 84)
        let point = NSPoint(x: popup.frame.width - 50, y: popup.frame.height - 21)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: popup.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        deadline = clock.now.advanced(by: .seconds(1))
        while popup.childWindows?.first == nil, clock.now < deadline { await Task.yield() }
        var filter = try #require(popup.childWindows?.first)
        session.enabledEverywhereProviders = [.actions]
        deadline = clock.now.advanced(by: .seconds(1))
        while !filteredProviderWasRead, clock.now < deadline { await Task.yield() }
        #expect(filteredProviderWasRead)
        parent.contentView?.layoutSubtreeIfNeeded()
        await Task.yield()
        #expect(filter.parent === popup, "Updating sources must not dismantle the filter anchor")
        session.enabledEverywhereProviders = [.files, .actions] // Exclusion edits below exercise a workspace source.
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func click(_ window: NSWindow, point: NSPoint) throws {
            // A reopened hosting view can be attached before its hit-test frames are laid out.
            window.contentView?.layoutSubtreeIfNeeded()
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
        }
        // Custom popup AX nodes are ignored in the isolated runner; exercise native hit-testing.
        func clickControl(_ identifier: String, in window: NSWindow) async throws {
            let point: NSPoint
            switch identifier {
            case "search-everywhere-filter":
                point = NSPoint(x: window.frame.width - 50, y: window.frame.height - 21)
            case "search-exclusions-toggle":
                point = NSPoint(x: 60, y: window.frame.height - LitheDropdownMetrics.popupPadding - 12)
            case "search-exclusions-edit":
                point = NSPoint(x: window.frame.width - LitheDropdownMetrics.popupPadding - 11,
                    y: window.frame.height - LitheDropdownMetrics.popupPadding - 12)
            default:
                let buttonWidth = LitheTheme.ActionButton.minimumWidth
                point = NSPoint(x: window.frame.width - 17 - buttonWidth / 2
                    - (identifier == "search-exclusions-cancel" ? buttonWidth + LitheTheme.ActionButton.spacing : 0),
                    y: 12 + LitheTheme.ActionButton.height / 2)
            }
            try click(window, point: point)
        }
        func openEditor() async throws -> NSWindow {
            let enabled = settings.searchExclusionsEnabled
            try await clickControl("search-exclusions-edit", in: filter)
            let deadline = clock.now.advanced(by: .seconds(1))
            while popup.childWindows?.first(where: { $0.styleMask.contains(.titled) }) == nil,
                  clock.now < deadline { await Task.yield() }
            #expect(settings.searchExclusionsEnabled == enabled, "Editing must not toggle the exclusion checkbox")
            return try #require(popup.childWindows?.first(where: { $0.styleMask.contains(.titled) }))
        }
        // Saving an expression must not turn a disabled rule back on.
        try await clickControl("search-exclusions-toggle", in: filter)
        #expect(!settings.searchExclusionsEnabled)
        await Task.yield()
        let filterContent = try #require(filter.contentView)
        filterContent.layoutSubtreeIfNeeded()
        let rowBitmap = try #require(filterContent.bitmapImageRepForCachingDisplay(in: filterContent.bounds))
        filterContent.cacheDisplay(in: filterContent.bounds, to: rowBitmap)
        let rowScale = CGFloat(rowBitmap.pixelsWide) / filterContent.bounds.width
        let rowY = LitheDropdownMetrics.popupPadding + LitheDropdownMetrics.rowHeight / 2
        var rowColor: NSColor?
        filter.effectiveAppearance.performAsCurrentDrawingAppearance {
            rowColor = NSColor(LitheTheme.settingsSelection).usingColorSpace(.sRGB)
        }
        let expectedRowColor = try #require(rowColor)
        // Sample blank space and the pencil's trailing inset, not its glyph or hover overlay.
        for x in [CGFloat(160), filterContent.bounds.width - LitheDropdownMetrics.popupPadding - 1] {
            let color = try #require(rowBitmap.colorAt(x: Int(x * rowScale), y: Int(rowY * rowScale)))
            #expect(abs(color.redComponent - expectedRowColor.redComponent) < 0.02)
            #expect(abs(color.greenComponent - expectedRowColor.greenComponent) < 0.02)
            #expect(abs(color.blueComponent - expectedRowColor.blueComponent) < 0.02,
                "Selection must extend behind the edit button to the common row edge")
        }
        var saved: [String] = []
        for draft in ["  *.log  \n**/.*/\n\n", ""] {
            #expect(descendants(try #require(filter.contentView)).compactMap { $0 as? NSTextView }.isEmpty,
                "The funnel contains a top-level option, not an inline editor")
            var dialog = try await openEditor()
            let content = try #require(dialog.contentView)
            content.layoutSubtreeIfNeeded()
            var editor = try #require(descendants(content).compactMap { $0 as? NSTextView }.first)
            #expect(editor.string == saved.joined(separator: "\n"))
            deadline = clock.now.advanced(by: .seconds(1))
            while dialog.firstResponder !== editor, clock.now < deadline { await Task.yield() }
            #expect(dialog.firstResponder === editor, "The rules editor must own native focus when opened")
            let range = NSRange(location: 0, length: min(2, editor.string.utf16.count))
            editor.setSelectedRange(range)
            // Exercise outer padding and the blank footer beside the buttons.
            for blank in [NSPoint(x: 8, y: 12), NSPoint(x: 130, y: 29)] {
                try click(dialog, point: blank)
                deadline = clock.now.advanced(by: .seconds(1))
                while dialog.firstResponder !== editor, clock.now < deadline { await Task.yield() }
                #expect(dialog.firstResponder === editor)
                #expect(editor.selectedRange() == range, "Blank clicks must preserve the caret/selection")
            }
            // Shared chrome expands its focused border outward: both the outer and inner pixels are accent.
            let scroll = try #require(editor.enclosingScrollView)
            let point = scroll.convert(NSPoint(x: scroll.bounds.minX - 6, y: scroll.bounds.midY), to: content)
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / content.bounds.width
            let y = content.isFlipped ? point.y : content.bounds.height - point.y
            var accent: NSColor?
            dialog.effectiveAppearance.performAsCurrentDrawingAppearance {
                accent = NSColor(LitheTheme.settingsControlAccent).usingColorSpace(.sRGB)
            }
            let expected = try #require(accent)
            for offset in [CGFloat(0), 1] {
                let actual = try #require(bitmap.colorAt(x: Int((point.x + offset) * scale), y: Int(y * scale)))
                #expect(abs(actual.redComponent - expected.redComponent) < 0.02)
                #expect(abs(actual.greenComponent - expected.greenComponent) < 0.02)
                #expect(abs(actual.blueComponent - expected.blueComponent) < 0.02)
            }
            if !draft.isEmpty {
                editor.selectAll(nil)
                editor.insertText("discarded", replacementRange: editor.selectedRange())
                try await clickControl("search-exclusions-cancel", in: dialog)
                #expect(settings.searchExcludedPathPatterns.isEmpty && session.isSearchEverywhereVisible)
                try await clickControl("search-everywhere-filter", in: popup)
                deadline = clock.now.advanced(by: .seconds(1))
                while popup.childWindows?.first == nil, clock.now < deadline { await Task.yield() }
                filter = try #require(popup.childWindows?.first)
                dialog = try await openEditor()
                editor = try #require(dialog.contentView.flatMap { descendants($0).compactMap { $0 as? NSTextView }.first })
            }
            #expect(dialog.makeFirstResponder(editor))
            editor.selectAll(nil)
            editor.insertText(draft, replacementRange: editor.selectedRange())
            searchedPatterns = []
            try await clickControl("search-exclusions-apply", in: dialog)
            saved = draft.isEmpty ? [] : ["*.log", "**/.*/"]
            deadline = clock.now.advanced(by: .seconds(2))
            while !searchedPatterns.contains(saved), clock.now < deadline { await Task.yield() }
            #expect(searchedPatterns.contains(saved))
            #expect(AppSettings(store: MacUserDefaultsStore(defaults: defaults)).searchExcludedPathPatterns == saved)
            #expect(session.isSearchEverywhereVisible)
            if !draft.isEmpty {
                #expect(!settings.searchExclusionsEnabled)
                #expect(settings.searchEverywhereVisibilityRules == settings.fileVisibilityRules)
                try await clickControl("search-everywhere-filter", in: popup)
                deadline = clock.now.advanced(by: .seconds(1))
                while popup.childWindows?.first == nil, clock.now < deadline { await Task.yield() }
                filter = try #require(popup.childWindows?.first)
                try await clickControl("search-exclusions-toggle", in: filter)
                #expect(settings.searchExclusionsEnabled)
                #expect(settings.searchEverywhereVisibilityRules.hiddenFilePatterns.contains("*.log"))
            }
            session.endSearchEverywhere()
            deadline = clock.now.advanced(by: .seconds(1))
            while parent.childWindows?.isEmpty == false, clock.now < deadline { await Task.yield() }
            #expect(parent.childWindows?.isEmpty != false)
            session.beginSearchEverywhere()
            deadline = clock.now.advanced(by: .seconds(1))
            while parent.childWindows?.first == nil, clock.now < deadline { await Task.yield() }
            popup = try #require(parent.childWindows?.first)
            try await clickControl("search-everywhere-filter", in: popup)
            deadline = clock.now.advanced(by: .seconds(1))
            while popup.childWindows?.first == nil, clock.now < deadline { await Task.yield() }
            filter = try #require(popup.childWindows?.first)
        }
        let finalDialog = try await openEditor()
        let finalEditor = try #require(finalDialog.contentView.flatMap { descendants($0).compactMap { $0 as? NSTextView }.first })
        #expect(finalEditor.string.isEmpty, "Clearing and applying must remain empty after reopening")
        try await clickControl("search-exclusions-cancel", in: finalDialog)

    }

    @Test
    func selectedNamesPaintTheSameUtf16FragmentsAsTheCoreMatcher() throws {
        struct Fixture: Decodable {
            struct Case: Decodable { let path: String; let ranges: [SearchNameRange] }
            let cases: [Case]
        }
        let url = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/fixtures/search/name-matching.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        for item in fixture.cases {
            let result = FileSearchResult(url: URL(fileURLWithPath: "/fixture").appendingPathComponent(item.path),
                line: nil, preview: "", kind: .file, nameMatchRanges: item.ranges, matchingDegree: 123)
            let selected = SearchEverywhereNameText.highlighted(result, selected: true)
            let fragments = selected.runs.filter { $0.backgroundColor != nil }
                .map { String(selected[$0.range].characters) }.joined()
            #expect(fragments.lowercased() == "name", "\(item.path)")
            #expect(String(selected.characters) == result.url.lastPathComponent)
            #expect(!SearchEverywhereNameText.highlighted(result, selected: false).runs.contains { $0.backgroundColor != nil })
            #expect(SearchRelevance.score(result, query: "name") == 123)
        }
    }

    @Test
    func malformedOrSurrogateSplittingFragmentsCannotCorruptTheName() {
        let result = FileSearchResult(url: URL(fileURLWithPath: "/fixture/name.swift"), line: nil, preview: "",
            kind: .file, nameMatchRanges: [.init(start: -1, length: 2), .init(start: Int.max, length: 4),
                .init(start: 0, length: 4), .init(start: 2, length: 4)])
        let value = SearchEverywhereNameText.highlighted(result, selected: true)
        #expect(String(value.characters) == "name.swift")
        #expect(value.runs.filter { $0.backgroundColor != nil }.count == 1)
    }

    @Test(arguments: [false, true])
    func sourcePreviewOwnsAnIndependentReadOnlyEditorPresentation(customOptions: Bool) async throws {
        let document = EditorDocument(url: URL(fileURLWithPath: "/fixture/NativeMenu.ts"),
            text: "export interface NativeMenu {}", modificationDate: nil)
        let result = FileSearchResult(url: document.url, line: 7, preview: "", kind: .symbol, symbolName: "NativeMenu")
        var rendered: MonacoPreviewConfiguration?
        let view = SearchEverywhereSourcePreview(result: result, query: "name",
            options: .init(caseSensitive: customOptions, wholeWords: customOptions, regularExpression: customOptions),
            loadDocument: { _, _ in document },
            makeEditor: { doc, configuration in
                rendered = configuration
                return AnyView(Text(doc.text))
            })
        let host = NSHostingView(rootView: view.frame(width: 500, height: 250))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 250),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(1))
        while rendered == nil, clock.now < deadline { await Task.yield() }
        let configuration = try #require(rendered)
        let previewID = try #require(configuration.presentationID)
        #expect(configuration.line == 7)
        #expect(configuration.query == "name")
        #expect(configuration.matchCase == customOptions)
        #expect(configuration.wholeWord == customOptions)
        #expect(configuration.regex == customOptions)
        // The same production session route used by Problems previews enforces read-only,
        // without setting the live document itself read-only or taking its save barrier.
        let session = MonacoWorkbenchSession.forModel(UUID(), documentID: document.id, previewID: previewID)
        #expect(session.isReadOnlyPreview)
        #expect(!document.isReadOnly)
        #expect(!document.isDirty)
    }
}

private struct PreviewSelectionOperations: SearchOperations {
    var onInvalidate: @Sendable () -> Void = {}
    var onSearch: @Sendable (Set<SearchResultKind>) -> Void = { _ in }
    func invalidateSearchIndex(at rootURL: URL, visibilityRules: SearchVisibilityRules) { onInvalidate() }
    func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> [FileSearchResult]? { [] }
    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules, includeGeneratedFileNames: Bool, kinds: Set<SearchResultKind>) -> SearchEverywhereResults? {
        onSearch(kinds)
        return .init(fileMatches: (0..<40).map { index in
            FileSearchResult(url: rootURL.appendingPathComponent(String(format: "name%02d.swift", index)),
                line: nil, preview: "", kind: .file, matchingDegree: 100)
        }, contentMatches: [])
    }
    func previewReplacement(at rootURL: URL, query: String, replacement: String, options: ProjectSearchOptions, paths: [String], textOverrides: [String: String], visibilityRules: SearchVisibilityRules) -> [ProjectReplacementFile]? { [] }
    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}

private struct ProviderFilterHarness: View {
    @ObservedObject var session: SearchSessionFeatureModel
    var body: some View {
        SearchEverywhereProviderFilter(selection: $session.enabledEverywhereProviders).litheContextMenuSurface()
    }
}
