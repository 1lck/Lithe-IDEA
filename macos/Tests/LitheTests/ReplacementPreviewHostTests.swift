import AppKit
import SwiftUI
import LitheSearchModule
import Testing
@testable import Lithe

/// Native replacement UI owns invalidation and mounting. The injected surface
/// exercises document events; real editing/undo/navigation belongs to the
/// shared Monaco WebKit integration suite.
@MainActor
@Suite("Replacement preview host")
struct ReplacementPreviewHostTests {
    @Test
    func previewEditorEditInvalidatesResultSnapshot() async throws {
        let store = PreviewHostTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services
        let model = AppModel(settings: settings, services: services)
        let document = EditorDocument(url: URL(fileURLWithPath: "/fixture/Preview.xml"),
                                      text: "foo\nfoo", modificationDate: nil)
        let file = ProjectReplacementFile(url: document.url, relativePath: "Preview.xml", matches: [
            .init(line: 1, before: "foo", after: "bar", occurrenceCount: 1),
            .init(line: 2, before: "foo", after: "bar", occurrenceCount: 1)
        ])
        var invalidated = false
        let hosting = NSHostingView(rootView:
            ProjectReplacementSourcePreview(file: file, line: 1, query: "foo", options: .default,
                loadDocument: { _ in document }, onEdit: { invalidated = true },
                makeEditor: { document, configuration in
                    AnyView(PreviewHostTestEditor(document: document))
                })
                .environmentObject(model).environmentObject(settings))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = hosting
        func editor(in view: NSView) -> PreviewHostTestSurface? {
            if let text = view as? PreviewHostTestSurface { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        // Mounting follows the asynchronous load; poll only the native view boundary with a local deadline.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while editor(in: hosting) == nil && clock.now < deadline {
            hosting.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        let textView = try #require(editor(in: hosting))
        #expect(!invalidated)
        textView.applyEdit("\n\n", range: NSRange(location: 0, length: 3))
        #expect(document.text == "\n\n\nfoo")
        #expect(invalidated, "Do not allow another click on obsolete match lines after an edit")
    }

    @Test
    func replacementDialogKeepsEditorMountedAfterInvalidatingResults() async throws {
        let store = PreviewHostTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services
        let model = AppModel(settings: settings, services: services)
        let document = EditorDocument(url: URL(fileURLWithPath: "/fixture/Preview.xml"),
                                      text: "foo\nfoo", modificationDate: nil)
        let file = ProjectReplacementFile(url: document.url, relativePath: "Preview.xml", matches: [
            .init(line: 1, before: "foo", after: "bar", occurrenceCount: 1)
        ])
        let feature = SearchFeatureModel(operations: PreviewEditorSearchOperations(file: file))
        let session = SearchSessionFeatureModel()
        await feature.previewProjectReplacement(
            at: document.url.deletingLastPathComponent(), query: "foo", replacement: "bar",
            paths: [file.relativePath], textOverrides: [:],
            visibilityRules: .init(hiddenDirectoryNames: [], hiddenFilePatterns: []), isCurrent: { true })
        let hosting = NSHostingView(rootView:
            ProjectReplaceView(feature: feature, session: session,
                previewReplacement: { _, _, _ in }, loadPreviewDocument: { _ in document },
                close: {}, openFile: { _, _ in }, revealInFinder: { _ in }, copyPath: { _, _ in },
                makePreviewEditor: { document, configuration in
                    AnyView(PreviewHostTestEditor(document: document))
                })
                .environmentObject(model).environmentObject(settings))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 614),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); feature.reset(); model.documentFeature.reset() }
        window.contentView = hosting
        func editor(in view: NSView) -> PreviewHostTestSurface? {
            if let text = view as? PreviewHostTestSurface { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        // Await the native mounting boundary with a deadline, never a fixed rendering delay.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while editor(in: hosting) == nil && clock.now < deadline {
            hosting.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        let originalEditor = try #require(editor(in: hosting))
        originalEditor.applyEdit("x", range: NSRange(location: 0, length: 0))
        #expect(feature.projectReplacementFiles.isEmpty)
        // Flush the parent view update: testing the child alone misses its removal by results.
        hosting.layoutSubtreeIfNeeded()
        let retainedEditor = try #require(editor(in: hosting))
        #expect(retainedEditor === originalEditor)
        retainedEditor.applyEdit("y", range: NSRange(location: 1, length: 0))
        hosting.layoutSubtreeIfNeeded()
        #expect(editor(in: hosting) === originalEditor)
        #expect(document.text == "xyfoo\nfoo")
        #expect(document.isDirty)
        #expect(feature.projectReplacementFiles.isEmpty)
    }

}

@MainActor
private struct PreviewHostTestEditor: NSViewRepresentable {
    let document: EditorDocument
    func makeNSView(context: Context) -> PreviewHostTestSurface {
        PreviewHostTestSurface(document: document)
    }
    func updateNSView(_ view: PreviewHostTestSurface, context: Context) {}
}

@MainActor
private final class PreviewHostTestSurface: NSView {
    let document: EditorDocument
    init(document: EditorDocument) {
        self.document = document
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    func applyEdit(_ text: String, range: NSRange) {
        document.applyLiveEditorEdit(replacedRange: range, replacement: text)
    }
}

private final class PreviewHostTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private struct PreviewEditorSearchOperations: SearchOperations {
    let file: ProjectReplacementFile
    func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> [FileSearchResult]? { [] }
    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> SearchEverywhereResults? { .init() }
    func previewReplacement(at rootURL: URL, query: String, replacement: String, options: ProjectSearchOptions, paths: [String], textOverrides: [String: String], visibilityRules: SearchVisibilityRules) -> [ProjectReplacementFile]? { [file] }
    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}
