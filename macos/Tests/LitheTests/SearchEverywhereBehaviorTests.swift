import AppKit
import SwiftUI
import Testing
import LitheSearchModule
import LitheGitModule
@testable import Lithe

@MainActor
@Suite("Search Everywhere matching and preview", .serialized)
struct SearchEverywhereBehaviorTests {
    @Test(arguments: ["clean", "dirty", "replacement"])
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
            try await scope.run("load search preview") { loaded = await model.documentFeature.previewDocument(at: file) }
            let document = try #require(loaded)
            #expect(model.documentFeature.openDocuments.isEmpty)
            if ending == "dirty" { document.applyLiveEditorText("unsaved") }
            model.searchSessionFeature.isProjectReplaceVisible = ending == "replacement"
            model.searchSessionFeature.beginSearchEverywhere(query: "name")
            model.dismissSearchEverywhere()
            #expect(!model.isSearchEverywhereVisible)
            #expect(model.documentFeature.editorDocuments.contains { $0 === document } == (ending != "clean"))
            if ending == "dirty" {
                #expect(model.documentFeature.openDocuments.contains { $0 === document })
                #expect(document.text == "unsaved")
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 236, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.colorSpace = .sRGB
        window.acceptsMouseMovedEvents = true
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize == NSSize(width: 236, height: 200))
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
        let view = SearchEverywhereView(feature: feature, session: session, actionMatches: { _ in [] },
            search: { _, _ in }, dismiss: {}, openResult: { _ in Issue.record("A single click must only preview") },
            performAction: { _ in }, revealInFinder: { _ in }, copyPath: { _, _ in },
            relativePath: { $0.lastPathComponent }, moduleLabel: { _ in "" },
            loadPreviewDocument: { EditorDocument(url: $0, text: "preview", modificationDate: nil) },
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
    }

    @Test
    func providerChangesKeepTheNativeFilterAnchorAlive() async throws {
        let feature = SearchFeatureModel(operations: RustWorkspaceOperations(core: RustCoreBridge()))
        let session = SearchSessionFeatureModel()
        session.everywhereQuery = "name"
        session.isSearchEverywhereVisible = true
        var filteredProviderWasRead = false
        let action = LitheAction(id: "fixture.name", title: "Name command", subtitle: "", group: .window, perform: {})
        let view = SearchEverywhereView(feature: feature, session: session, actionMatches: { _ in
            if session.enabledEverywhereProviders == [.actions] { filteredProviderWasRead = true }
            return [action]
        }, search: { _, _ in }, dismiss: {}, openResult: { _ in }, performAction: { _ in },
            revealInFinder: { _ in }, copyPath: { _, _ in }, relativePath: { _ in "" }, moduleLabel: { _ in "" })
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.frame(width: 1000, height: 800))
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
        let popup = try #require(parent.childWindows?.first)
        #expect(popup.frame.height > 84)
        let point = NSPoint(x: popup.frame.width - 50, y: popup.frame.height - 21)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: popup.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        deadline = clock.now.advanced(by: .seconds(1))
        while popup.childWindows?.first == nil, clock.now < deadline { await Task.yield() }
        let filter = try #require(popup.childWindows?.first)
        session.enabledEverywhereProviders = [.actions]
        deadline = clock.now.advanced(by: .seconds(1))
        while !filteredProviderWasRead, clock.now < deadline { await Task.yield() }
        #expect(filteredProviderWasRead)
        parent.contentView?.layoutSubtreeIfNeeded()
        await Task.yield()
        #expect(filter.parent === popup, "Updating sources must not dismantle the filter anchor")
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
            loadDocument: { _ in document },
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
    func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> [FileSearchResult]? { [] }
    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> SearchEverywhereResults? {
        .init(fileMatches: (0..<40).map { index in
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
