import AppKit
import Testing
@testable import Lithe

@MainActor
@Suite("Java editor viewport rendering")
struct EditorJavaViewportTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    @Test
    func semanticIndexMatchesOverlappingSpansInProducerOrder() {
        let highlights = (0..<2_000).reversed().map { offset in
            JavaSyntaxHighlight(
                range: NSRange(location: offset * 3, length: offset % 37 + 1), role: "field"
            )
        } + [JavaSyntaxHighlight(range: NSRange(location: 0, length: 6_040), role: "comment")]
        let index = JavaSemanticHighlightIndex(highlights, documentLength: 6_040)
        for location in stride(from: 0, through: 6_040, by: 101) {
            let range = NSRange(location: location, length: 23)
            #expect(index.intersecting(range) == highlights.filter {
                NSIntersectionRange($0.range, range).length > 0
            })
        }
        #expect(index.intersecting(NSRange(location: 30, length: 0)).isEmpty)
    }

    @Test
    func semanticIndexRejectsInvalidUtf16Ranges() {
        let valid = JavaSyntaxHighlight(range: NSRange(location: 2, length: 3), role: "field")
        let index = JavaSemanticHighlightIndex([
            valid,
            JavaSyntaxHighlight(range: NSRange(location: NSNotFound, length: 1), role: "field"),
            JavaSyntaxHighlight(range: NSRange(location: -1, length: 2), role: "field"),
            JavaSyntaxHighlight(range: NSRange(location: 4, length: 2), role: "field"),
            JavaSyntaxHighlight(range: NSRange(location: 1, length: 0), role: "field")
        ], documentLength: 5)
        #expect(index.intersecting(NSRange(location: 0, length: 5)) == [valid])
        #expect(index.intersecting(NSRange(location: 5, length: 1)).isEmpty)
    }

    @Test
    func scrollingClipsMultilineSemanticColorsAndPreservesCachedColors() throws {
        let storage = NSTextStorage(string: "😀first\nsecond\nthird")
        let full = NSRange(location: 0, length: storage.length)
        var state = EditorSyntaxHighlightState()
        state.replaceJavaHighlights([
            JavaSyntaxHighlight(range: full, role: "comment")
        ], documentLength: storage.length)
        let top = NSRange(location: 0, length: 8)
        paint(&state, storage, range: top)
        let semanticColor = try #require(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(storage.attribute(.foregroundColor, at: 8, effectiveRange: nil) == nil)

        let middle = NSRange(location: 8, length: 7)
        paint(&state, storage, range: middle)
        #expect(storage.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor == semanticColor)
        #expect(storage.attribute(.foregroundColor, at: 15, effectiveRange: nil) == nil)
        paint(&state, storage, range: top)
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == semanticColor)
    }

    @Test
    func editsAndFailedAnalysisDiscardSemanticColorsWhenTheViewportIsRevisited() throws {
        let storage = NSTextStorage(string: "first\nsecond")
        let full = NSRange(location: 0, length: storage.length)
        var state = EditorSyntaxHighlightState()
        state.replaceJavaHighlights([
            JavaSyntaxHighlight(range: full, role: "comment")
        ], documentLength: storage.length)
        paint(&state, storage, range: full)
        let comment = try #require(storage.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor)

        // Same-length changes must invalidate semantic meaning, not just offsets.
        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "F")
        state.applyEdit(replacedRange: NSRange(location: 0, length: 1), replacementLength: 1, isJava: true)
        paint(&state, storage, range: NSRange(location: 0, length: 6))
        paint(&state, storage, range: NSRange(location: 6, length: 6))
        #expect(storage.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor != comment)

        state.replaceJavaHighlights([
            JavaSyntaxHighlight(range: NSRange(location: 6, length: 6), role: "field")
        ], documentLength: storage.length)
        paint(&state, storage, range: full)
        let field = try #require(storage.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor)
        state.invalidateText() // Programmatic replacement or failed analysis.
        paint(&state, storage, range: full)
        #expect(storage.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor != field)
    }

    @Test
    func shiftedUtf16TokensAndAppearanceRefreshUseTheLatestSnapshot() throws {
        let storage = NSTextStorage(string: "name")
        var state = EditorSyntaxHighlightState()
        state.replaceJavaHighlights([
            JavaSyntaxHighlight(range: NSRange(location: 0, length: 4), role: "field")
        ], documentLength: storage.length)
        paint(&state, storage, range: NSRange(location: 0, length: 4))
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "😀 ")
        state.applyEdit(replacedRange: NSRange(location: 0, length: 0), replacementLength: 3, isJava: true)
        let full = NSRange(location: 0, length: storage.length)
        state.replaceJavaHighlights([
            JavaSyntaxHighlight(range: NSRange(location: 3, length: 4), role: "field")
        ], documentLength: storage.length)
        paint(&state, storage, range: full)
        state.invalidateAppearance()
        state.apply(to: storage, font: font, fileExtension: "java", isDark: false, range: full)
        let reference = NSTextStorage(string: storage.string)
        SyntaxHighlighter.applyJavaSemanticHighlights([
            JavaSyntaxHighlight(range: NSRange(location: 3, length: 4), role: "field")
        ], to: reference, isDark: false)
        #expect(storage.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor
            == reference.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor)
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            != reference.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor)
    }

    @Test
    func unchangedFoldGeometryDoesNotForceLayoutAfterAnEditBelowTheFold() throws {
        let (view, layout) = makeTextView("import a;\nimport b;\nclass Demo {}\n")
        let source = view.string as NSString
        let fold = JavaFoldRegion(kind: .imports, startLine: 0, endLine: 1,
                                  hiddenRange: source.range(of: "import b;\n"))
        view.updateFolds(regions: [fold], collapsedIDs: [fold.id], onToggle: { _ in })
        let edit = NSRange(location: source.length, length: 0)
        view.textStorage?.replaceCharacters(in: edit, with: "\n")
        view.applyLineIndexEdit(replacedRange: edit, replacement: "\n")
        layout.containerLayoutRequests = 0
        let expanded = JavaFoldRegion(kind: .type, startLine: 2, endLine: 3,
                                      hiddenRange: NSRange(location: source.length - 1, length: 1))
        view.updateFolds(regions: [expanded, fold], collapsedIDs: [fold.id], onToggle: { _ in })
        #expect(layout.containerLayoutRequests == 0)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: fold.hiddenRange.location,
                                         effectiveRange: nil) as? NSColor == .clear)
        view.updateFolds(regions: [expanded, fold], collapsedIDs: [], onToggle: { _ in })
        #expect(layout.containerLayoutRequests > 0)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: fold.hiddenRange.location,
                                         effectiveRange: nil) == nil)
    }

    @Test
    func editsInsideFoldAndFullTextReplacementRefreshTemporaryAttributes() throws {
        let (view, layout) = makeTextView("start\nhidden\nend")
        let fold = JavaFoldRegion(kind: .block, startLine: 0, endLine: 2,
                                  hiddenRange: NSRange(location: 6, length: 7))
        view.updateFolds(regions: [fold], collapsedIDs: [fold.id], onToggle: { _ in })
        let edit = NSRange(location: 6, length: 1)
        view.textStorage?.replaceCharacters(in: edit, with: "H")
        view.applyLineIndexEdit(replacedRange: edit, replacement: "H")
        layout.containerLayoutRequests = 0
        view.updateFolds(regions: [fold], collapsedIDs: [fold.id], onToggle: { _ in })
        #expect(layout.containerLayoutRequests > 0)
        view.string = "start\nHidden\nend"
        view.rebuildLineIndex()
        layout.containerLayoutRequests = 0
        view.updateFolds(regions: [fold], collapsedIDs: [fold.id], onToggle: { _ in })
        #expect(layout.containerLayoutRequests > 0)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 7,
                                         effectiveRange: nil) as? NSColor == .clear)
    }

    @Test
    func nestedFoldsExcludeOnlyTheirHalfOpenHiddenRangesFromHighlighting() {
        let (view, _) = makeTextView("start\nfirst\nsecond\nend")
        let outer = JavaFoldRegion(kind: .type, startLine: 0, endLine: 3,
                                   hiddenRange: NSRange(location: 6, length: 13))
        let inner = JavaFoldRegion(kind: .method, startLine: 1, endLine: 3,
                                   hiddenRange: NSRange(location: 12, length: 7))
        view.updateFolds(regions: [inner, outer], collapsedIDs: [inner.id, outer.id], onToggle: { _ in })
        #expect(view.unfoldedRanges(in: NSRange(location: 0, length: 22)) == [
            NSRange(location: 0, length: 6), NSRange(location: 19, length: 3)
        ])
        view.updateFolds(regions: [inner, outer], collapsedIDs: [inner.id], onToggle: { _ in })
        #expect(view.unfoldedRanges(in: NSRange(location: 0, length: 22)) == [
            NSRange(location: 0, length: 12), NSRange(location: 19, length: 3)
        ])
    }

    @Test
    func lexicalEditsRepaintPreviouslyCachedLines() throws {
        let storage = NSTextStorage(string: "clas")
        var state = EditorSyntaxHighlightState()
        state.apply(to: storage, font: font, fileExtension: "swift", isDark: true,
                    range: NSRange(location: 0, length: 4))
        let before = try #require(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        storage.replaceCharacters(in: NSRange(location: 4, length: 0), with: "s")
        state.applyEdit(replacedRange: NSRange(location: 4, length: 0), replacementLength: 1, isJava: false)
        state.apply(to: storage, font: font, fileExtension: "swift", isDark: true,
                    range: NSRange(location: 0, length: 5), force: true)
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor != before)
    }

    @Test
    func fullTextReplacementClearsOldFoldsBeforeFreshStructureArrives() throws {
        let source = "start\nhidden\nend"
        let (view, layout) = makeTextView(source)
        let gutter = LineNumberGutterView(frame: .zero)
        try withCoordinator(source: source) { coordinator in
            coordinator.textView = view
            coordinator.gutter = gutter
            let fold = JavaFoldRegion(kind: .imports, startLine: 0, endLine: 2,
                                      hiddenRange: NSRange(location: 6, length: 7))
            coordinator.primeJavaImportFold(fold)
            #expect(view.isCharacterHiddenByFold(6))

            // Inspect the synchronous replacement boundary without delivering any
            // Java structure result; unrelated text now occupies the old offsets.
            coordinator.replaceText("class New {\nint visible;\n}\n")

            let storage = try #require(view.textStorage)
            let full = NSRange(location: 0, length: storage.length)
            #expect(coordinator.foldRegions.isEmpty)
            #expect(coordinator.collapsedFoldIDs.isEmpty)
            #expect(view.unfoldedRanges(in: full) == [full])
            let reference = NSTextStorage(string: view.string)
            SyntaxHighlighter.apply(to: reference, font: font, fileExtension: "java", isDark: true, range: full)
            for location in 0..<storage.length {
                #expect(!view.isCharacterHiddenByFold(location))
                #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: location,
                                                 effectiveRange: nil) as? NSColor != .clear)
                #expect(storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
                    == reference.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor)
            }
            coordinator.replaceText("")
            #expect(view.unfoldedRanges(in: NSRange(location: 0, length: 0)).isEmpty)
            #expect(view.selectedRange() == NSRange(location: 0, length: 0))
        }
    }

    @Test(arguments: ["swift", "json", "md"])
    func nonJavaFoldRefreshPreservesEditedLineColorsAndViewportCache(fileExtension: String) throws {
        let source = "name\nsecond\nthird\n"
        let (view, layout) = makeTextView(source)
        try withCoordinator(source: source, fileExtension: fileExtension) { coordinator in
            coordinator.textView = view
            coordinator.highlight()
            let storage = try #require(view.textStorage)
            let recorder = ViewportAttributeRecorder()
            storage.delegate = recorder
            defer { storage.delegate = nil }
            coordinator.scheduleFoldRefresh()
            coordinator.highlight()
            #expect(recorder.attributeEdits == 0)

            let edit = NSRange(location: 0, length: 4)
            storage.replaceCharacters(in: edit, with: "type")
            view.applyLineIndexEdit(replacedRange: edit, replacement: "type")
            coordinator.highlight(in: edit, replacedLength: edit.length)
            #expect(recorder.attributeEdits > 0)
            recorder.attributeEdits = 0

            // The non-Java branch finishes synchronously; no debounce or external
            // analysis is needed to discover that there is no Java state to clear.
            coordinator.scheduleFoldRefresh()
            #expect(recorder.attributeEdits == 0)

            layout.containerLayoutRequests = 0
            coordinator.replaceText("other\ntext\n")
            #expect(layout.containerLayoutRequests == 0)
        }
    }

    @Test
    func initialImportFoldUsesLightColorsBeforeAnyStructureResult() throws {
        let source = "import a;\nimport b;\nclass Demo {}\n"
        let (view, _) = makeTextView(source)
        try withCoordinator(source: source, isDark: false) { coordinator in
            coordinator.textView = view
            let fold = JavaFoldRegion(kind: .imports, startLine: 0, endLine: 1,
                                      hiddenRange: (source as NSString).range(of: "import b;\n"))
            coordinator.primeJavaImportFold(fold)
            coordinator.highlight()
            let storage = try #require(view.textStorage)
            let full = NSRange(location: 0, length: storage.length)
            let reference = NSTextStorage(string: source)
            SyntaxHighlighter.apply(to: reference, font: font, fileExtension: "java", isDark: false, range: full)
            for keyword in ["import", "class"] {
                let location = (source as NSString).range(of: keyword).location
                #expect(storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
                    == reference.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor)
            }
        }
    }

    @Test(arguments: [0, 5, 13])
    func equalLengthEditsOutsideFoldDoNotForceLayout(location: Int) {
        let (view, layout) = makeTextView("start\nhidden\nend")
        let fold = JavaFoldRegion(kind: .block, startLine: 0, endLine: 2,
                                  hiddenRange: NSRange(location: 6, length: 7))
        view.updateFolds(regions: [fold], collapsedIDs: [fold.id], onToggle: { _ in })
        let edit = NSRange(location: location, length: 1)
        view.textStorage?.replaceCharacters(in: edit, with: "X")
        view.applyLineIndexEdit(replacedRange: edit, replacement: "X")
        layout.containerLayoutRequests = 0
        view.updateFolds(regions: [fold], collapsedIDs: [fold.id], onToggle: { _ in })
        #expect(layout.containerLayoutRequests == 0)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 6,
                                         effectiveRange: nil) as? NSColor == .clear)
    }

    @Test(arguments: [NSRange(location: 6, length: 1), NSRange(location: 12, length: 1),
                      NSRange(location: 5, length: 2)])
    func editsTouchingFoldBoundariesStillRefreshAttributes(edit: NSRange) {
        let (view, layout) = makeTextView("start\nhidden\nend")
        let fold = JavaFoldRegion(kind: .block, startLine: 0, endLine: 2,
                                  hiddenRange: NSRange(location: 6, length: 7))
        view.updateFolds(regions: [fold], collapsedIDs: [fold.id], onToggle: { _ in })
        let replacement = String(repeating: "X", count: edit.length)
        view.textStorage?.replaceCharacters(in: edit, with: replacement)
        view.applyLineIndexEdit(replacedRange: edit, replacement: replacement)
        layout.containerLayoutRequests = 0
        view.updateFolds(regions: [fold], collapsedIDs: [fold.id], onToggle: { _ in })
        #expect(layout.containerLayoutRequests > 0)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 6,
                                         effectiveRange: nil) as? NSColor == .clear)
    }

    @Test
    func shiftingAnExistingFoldReplacesItsGeometryAndTemporaryAttributes() {
        let (view, layout) = makeTextView("start\nhidden\nend")
        let original = JavaFoldRegion(kind: .block, startLine: 0, endLine: 2,
                                       hiddenRange: NSRange(location: 6, length: 7))
        view.updateFolds(regions: [original], collapsedIDs: [original.id], onToggle: { _ in })
        let edit = NSRange(location: 0, length: 0)
        view.textStorage?.replaceCharacters(in: edit, with: "😀")
        view.applyLineIndexEdit(replacedRange: edit, replacement: "😀")
        let shifted = JavaFoldRegion(kind: .block, startLine: 0, endLine: 2,
                                      hiddenRange: NSRange(location: 8, length: 7))
        view.updateFolds(regions: [shifted], collapsedIDs: [shifted.id], onToggle: { _ in })
        #expect(!view.isCharacterHiddenByFold(7))
        #expect(view.isCharacterHiddenByFold(8))
        #expect(!view.isCharacterHiddenByFold(15))
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 8,
                                         effectiveRange: nil) as? NSColor == .clear)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 7,
                                         effectiveRange: nil) == nil)
    }

    @Test
    func gutterDoesNotRequestOffscreenFoldGeometry() throws {
        let source = String(repeating: "void method() {}\n", count: 1_000)
        let (view, layout) = makeTextView(source)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 160))
        scroll.documentView = view
        let gutter = LineNumberGutterView(frame: NSRect(x: 0, y: 0, width: 80, height: 160))
        gutter.attach(textView: view, scrollView: scroll)
        // No timer/window is needed: drive the native drawing entry synchronously.
        defer { gutter.removeFromSuperview(); scroll.documentView = nil }
        let folds = (0..<1_000).map { line in
            JavaFoldRegion(kind: .method, startLine: line, endLine: line,
                           hiddenRange: NSRange(location: line * 17, length: 0))
        }
        gutter.updateFoldRegions(folds, collapsedIDs: [], onToggle: { _ in })
        let container = try #require(view.textContainer)
        layout.ensureLayout(for: container)
        layout.requestedLineGlyphs = []
        let bitmap = NSImage(size: gutter.bounds.size)
        bitmap.lockFocus()
        defer { bitmap.unlockFocus() }
        gutter.draw(gutter.bounds)
        #expect(!layout.requestedLineGlyphs.isEmpty)
        #expect(layout.requestedLineGlyphs.allSatisfy { $0 < 17 * 30 })
    }

    private func paint(_ state: inout EditorSyntaxHighlightState, _ storage: NSTextStorage, range: NSRange) {
        state.apply(to: storage, font: font, fileExtension: "java", isDark: true, range: range)
    }

    private func makeTextView(_ source: String) -> (CodeTextView, ViewportLayoutRecorder) {
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 20_000))
        let layout = ViewportLayoutRecorder()
        view.textContainer?.replaceLayoutManager(layout)
        layout.delegate = view
        view.font = font
        view.string = source
        view.rebuildLineIndex()
        return (view, layout)
    }

    private func withCoordinator(
        source: String,
        fileExtension: String = "java",
        isDark: Bool = true,
        body: (CodeEditorView.Coordinator) throws -> Void
    ) rethrows {
        let store = ViewportTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services
        let model = AppModel(settings: settings, services: services)
        let document = EditorDocument(url: URL(fileURLWithPath: "/fixture/Viewport.\(fileExtension)"),
                                      text: source, modificationDate: nil)
        let coordinator = CodeEditorView.Coordinator(
            document: document, model: model, isDarkAppearance: isDark, colorTheme: .lithe,
            markdownScrollPosition: nil, viewportStore: EditorViewportStore()
        )
        try withExtendedLifetime((model, document)) { try body(coordinator) }
    }
}

private final class ViewportAttributeRecorder: NSObject, NSTextStorageDelegate {
    var attributeEdits = 0

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedAttributes) { attributeEdits += 1 }
    }
}

private final class ViewportTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private final class ViewportLayoutRecorder: NSLayoutManager {
    var containerLayoutRequests = 0
    var requestedLineGlyphs: [Int] = []

    override func ensureLayout(for container: NSTextContainer) {
        containerLayoutRequests += 1
        super.ensureLayout(for: container)
    }

    override func lineFragmentRect(forGlyphAt glyphIndex: Int, effectiveRange: NSRangePointer?) -> NSRect {
        requestedLineGlyphs.append(glyphIndex)
        return super.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: effectiveRange)
    }
}
