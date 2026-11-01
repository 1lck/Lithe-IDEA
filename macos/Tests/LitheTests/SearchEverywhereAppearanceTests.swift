import AppKit
import SwiftUI
import Testing
import LitheSearchModule
@testable import Lithe

@MainActor
@Suite("Search Everywhere appearance", .serialized)
struct SearchEverywhereAppearanceTests {
    @Test
    func reopenedQueryIsRestoredAndNativelySelectedBeforeTyping() async throws {
        let feature = SearchFeatureModel(operations: ControlledEverywhereOperations())
        let session = SearchSessionFeatureModel()
        session.beginSearchEverywhere(query: "name")
        session.endSearchEverywhere()
        session.beginSearchEverywhere()
        let view = SearchEverywhereView(feature: feature, session: session, settings: AppSettings(store: MacUserDefaultsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)), actionMatches: { _ in [] },
            search: { _, _ in }, dismiss: { session.endSearchEverywhere() }, openResult: { _ in },
            performAction: { _ in }, revealInFinder: { _ in }, copyPath: { _, _ in },
            relativePath: { _ in "" }, moduleLabel: { _ in "" })
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            session.endSearchEverywhere()
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(2))
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        var input: NSTextField?
        repeat {
            await Task.yield()
            if let content = window.childWindows?.first?.contentView { input = field(in: content) }
        } while input?.currentEditor() == nil && clock.now < deadline
        let inputField = try #require(input)
        let editor = try #require(inputField.currentEditor())
        #expect(inputField.stringValue == "name")
        #expect(editor.selectedRange == NSRange(location: 0, length: 4))
        editor.insertText("next")
        #expect(inputField.stringValue == "next", "Typing replaces the restored selection")
        session.endSearchEverywhere()
        session.beginSearchEverywhere()
        #expect(session.everywhereQuery == "next", "The input binding saves before the search debounce")
    }

    @Test(arguments: [ColorScheme.dark, .light], [CGFloat(520), 1000])
    func searchFitsWindowAndSharesPopupSurface(scheme: ColorScheme, width: CGFloat) async throws {
        let operations = ControlledEverywhereOperations()
        let feature = SearchFeatureModel(operations: operations)
        let session = SearchSessionFeatureModel()
        session.isSearchEverywhereVisible = true
        session.everywhereScope = .text
        let view = SearchEverywhereView(feature: feature, session: session, settings: AppSettings(store: MacUserDefaultsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)), actionMatches: { _ in [] },
            search: { _, _ in }, dismiss: {}, openResult: { _ in }, performAction: { _ in },
            revealInFinder: { _ in }, copyPath: { _, _ in }, relativePath: { _ in "" }, moduleLabel: { _ in "" })
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer {
            session.isSearchEverywhereVisible = false
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(1))
        while window.childWindows?.first?.contentView == nil, clock.now < deadline { await Task.yield() }
        let panel = try #require(window.childWindows?.first as? NSPanel)
        let content = try #require(panel.contentView)
        #expect(panel.hasShadow)
        #expect(panel.colorSpace == .sRGB)
        #expect(panel.styleMask == .borderless)
        #expect(panel.frame.height == 84)
        #expect(panel.frame.minX >= window.frame.minX + 16)
        #expect(panel.frame.maxX <= window.frame.maxX - 16)
        #expect(abs(window.frame.maxY - panel.frame.maxY - 84) < 1)
        host.layoutSubtreeIfNeeded()
        content.layoutSubtreeIfNeeded()
        func dragAreas(in view: NSView) -> [LithePopupDragArea.DragView] {
            (view as? LithePopupDragArea.DragView).map { [$0] } ?? view.subviews.flatMap { dragAreas(in: $0) }
        }
        let drag = try #require(dragAreas(in: content).first)
        #expect(panel.isMovable)
        #expect(drag.bounds.width >= 12)
        #expect(drag.bounds.height >= 24)
        let dragPoint = drag.convert(NSPoint(x: drag.bounds.midX, y: drag.bounds.midY), to: content.superview)
        #expect(content.hitTest(dragPoint) === drag, "The real header spacer must route mouse-down to the drag view")
        func textFields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
        }
        let field = try #require(textFields(in: content).first { $0.isEditable })
        #expect(panel.initialFirstResponder === field)
        let focusDeadline = clock.now.advanced(by: .seconds(1))
        while field.currentEditor() == nil, clock.now < focusDeadline { await Task.yield() }
        #expect(field.currentEditor() is NSTextView)
        #expect(panel.firstResponder === field.currentEditor())
        let rect = field.convert(field.bounds, to: content)
        #expect(rect.minX > 0)
        #expect(rect.maxX < content.bounds.width)
        #expect(field.font?.pointSize == 13)

        // The header and input must share the Islands popup surface, including in light mode.
        content.layoutSubtreeIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / content.bounds.width
        func pixel(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
            try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
        }
        let header = try pixel(content.bounds.width / 2, 4)
        let input = try pixel(content.bounds.width / 2, 75)
        #expect(abs(header.redComponent - input.redComponent) < 0.01)
        #expect(abs(header.greenComponent - input.greenComponent) < 0.01)
        #expect(abs(header.blueComponent - input.blueComponent) < 0.01)
        let output = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent(".artifacts/search-everywhere")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to:
            output.appendingPathComponent("empty-\(scheme == .dark ? "dark" : "light")-\(Int(width)).png"))

        let originalWidth = panel.frame.width
        let resizedWidth: CGFloat = width == 520 ? 1000 : 520
        window.setContentSize(NSSize(width: resizedWidth, height: 700))
        let resizeDeadline = clock.now.advanced(by: .seconds(1))
        while panel.frame.width == originalWidth, clock.now < resizeDeadline { await Task.yield() }
        #expect(panel.frame.width != originalWidth)
        #expect(panel.frame.width <= resizedWidth - 32)
        #expect(panel.parent === window)

        let editor = try #require(field.currentEditor() as? NSTextView)
        panel.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12)))
        let expandDeadline = clock.now.advanced(by: .seconds(1))
        while panel.frame.height <= 84, clock.now < expandDeadline { await Task.yield() }
        #expect(panel.frame.height > 84)
        #expect(field.stringValue == "q", "Typing immediately after opening must reach the query without a click")

        let searchTask = Task {
            await feature.searchEverywhere(at: URL(fileURLWithPath: "/fixture"), query: "q", options: .default,
                visibilityRules: .init(hiddenDirectoryNames: [], hiddenFilePatterns: []), isCurrent: { true })
        }
        defer { operations.finished.open(); searchTask.cancel() }
        #expect(await operations.started.waitUntilOpen())
        func indicators(in view: NSView) -> [NSProgressIndicator] {
            (view as? NSProgressIndicator).map { [$0] } ?? view.subviews.flatMap { indicators(in: $0) }
        }
        let loadingDeadline = clock.now.advanced(by: .seconds(1))
        while indicators(in: content).isEmpty, clock.now < loadingDeadline { await Task.yield() }
        let progress = try #require(indicators(in: content).first)
        content.layoutSubtreeIfNeeded()
        let progressRect = progress.convert(progress.bounds, to: content)
        let queryRect = field.convert(field.bounds, to: content)
        #expect(progressRect.minX >= queryRect.maxX)
        #expect(abs(progressRect.midY - queryRect.midY) < 6,
                "Search progress belongs in the query row, not the category toolbar")
        operations.finished.open()
        await searchTask.value
        let finishedDeadline = clock.now.advanced(by: .seconds(1))
        while !indicators(in: content).isEmpty, clock.now < finishedDeadline { await Task.yield() }
        #expect(indicators(in: content).isEmpty)
        #expect(feature.searchEverywhereResults.contentMatches.first?.preview == "let query = searchEverywhere(query)")
        content.layoutSubtreeIfNeeded()
        // Each result's native context-menu target spans its complete visible row.
        // Inspect their placement so a single-line outer list cannot squeeze two-line results.
        func resultTargets(in view: NSView) -> [NSView] {
            if String(describing: type(of: view)) == "LitheRightClickCaptureView" { return [view] }
            return view.subviews.flatMap { resultTargets(in: $0) }
        }
        var targets = resultTargets(in: content)
        let rowsDeadline = clock.now.advanced(by: .seconds(1))
        while targets.count < 2, clock.now < rowsDeadline {
            await Task.yield()
            content.layoutSubtreeIfNeeded()
            targets = resultTargets(in: content)
        }
        #expect(targets.count == 2)
        let firstRow = try #require(targets.first).convert(targets[0].bounds, to: content)
        let secondTarget = try #require(targets.dropFirst().first)
        let secondRow = secondTarget.convert(secondTarget.bounds, to: content)
        #expect(abs(firstRow.midY - secondRow.midY) >= 40,
                "Two-line content results must retain their full row height without overlapping adjacent results")
        let resultsBitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: resultsBitmap)
        try #require(resultsBitmap.representation(using: .png, properties: [:])).write(to:
            output.appendingPathComponent("text-\(scheme == .dark ? "dark" : "light")-\(Int(width)).png"))
        func handles(in view: NSView) -> [ProjectReplaceCornerHandleView] {
            (view as? ProjectReplaceCornerHandleView).map { [$0] } ?? view.subviews.flatMap { handles(in: $0) }
        }
        content.layoutSubtreeIfNeeded()
        let handle = try #require(handles(in: content).first)
        let originalFrame = panel.frame
        let point = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        handle.mouseDown(with: try mouse(.leftMouseDown, point))
        let destination = NSPoint(x: point.x - 80, y: point.y + 100)
        handle.mouseDragged(with: try mouse(.leftMouseDragged, destination))
        handle.mouseUp(with: try mouse(.leftMouseUp, destination))
        let dragDeadline = clock.now.advanced(by: .seconds(1))
        while panel.frame.height == originalFrame.height, clock.now < dragDeadline { await Task.yield() }
        #expect(panel.frame.height < originalFrame.height)
        #expect(panel.frame.width <= resizedWidth - 32)
        #expect(abs(panel.frame.minX - originalFrame.minX) < 1)
        #expect(abs(panel.frame.maxY - originalFrame.maxY) < 1)
        #expect(field.stringValue == "q", "Resizing must preserve the query and input focus")

        editor.insertText("", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        let compactDeadline = clock.now.advanced(by: .seconds(1))
        while panel.frame.height != 84, clock.now < compactDeadline { await Task.yield() }
        #expect(panel.frame.height == 84)

        session.isSearchEverywhereVisible = false
        let closeDeadline = clock.now.advanced(by: .seconds(1))
        while panel.isVisible, clock.now < closeDeadline { await Task.yield() }
        #expect(!panel.isVisible)
        #expect(panel.parent == nil)
    }
}

private struct ControlledEverywhereOperations: SearchOperations {
    let started = TestGate()
    let finished = TestGate()
    func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> [FileSearchResult]? { [] }
    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules, includeGeneratedFileNames: Bool, kinds: Set<SearchResultKind>) -> SearchEverywhereResults? {
        started.open()
        _ = finished.waitSynchronously()
        return .init(contentMatches: [
            FileSearchResult(url: rootURL.appendingPathComponent("Search.swift"),
                line: 42, preview: "let query = searchEverywhere(query)", kind: .content),
            FileSearchResult(url: rootURL.appendingPathComponent("Search.swift"),
                line: 43, preview: "return query.results", kind: .content),
        ])
    }
    func previewReplacement(at rootURL: URL, query: String, replacement: String, options: ProjectSearchOptions, paths: [String], textOverrides: [String: String], visibilityRules: SearchVisibilityRules) -> [ProjectReplacementFile]? { [] }
    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}
