import AppKit
import Testing
@testable import Lithe

@Suite("Editor gutter layout")
struct EditorGutterLayoutTests {
    @Test
    func debugHoverResolvesOnlyJavaIdentifierTokens() throws {
        let source = "userService.login(userName)" as NSString

        let service = try #require(DebugHoverExpressionResolver.expression(at: 5, in: source))
        let argument = try #require(DebugHoverExpressionResolver.expression(at: 22, in: source))

        #expect(service.0 == "userService")
        #expect(source.substring(with: service.1) == "userService")
        #expect(argument.0 == "userName")
        #expect(DebugHoverExpressionResolver.expression(at: 11, in: source) == nil)
    }

    @Test
    func editorBreakpointLinesConvertToOneBasedProductLines() {
        #expect(EditorDebugBreakpointLocation.productLine(forEditorLine: 0) == 1)
        #expect(EditorDebugBreakpointLocation.productLine(forEditorLine: 7) == 8)
    }

    @MainActor
    @Test
    func breakpointContextMenuOffersEditingAndDispatchesTheEditorLine() throws {
        let gutter = LineNumberGutterView(frame: NSRect(x: 0, y: 0, width: 80, height: 200))
        var editedLine: Int?
        gutter.updateDebugBreakpointLines(
            [7: EditorDebugBreakpointState(enabled: true, verified: false)],
            onToggle: { _ in },
            onEdit: { editedLine = $0 }
        )

        let menu = try #require(gutter.debugBreakpointContextMenu(forLine: 6))
        #expect(menu.items.map(\.title) == [
            "Edit Breakpoint…",
            "Disable Breakpoint",
            "Remove Breakpoint"
        ])

        gutter.editDebugBreakpointFromMenu()
        #expect(editedLine == 6)
    }

    @MainActor
    @Test
    func foldingLinesChangesTheOverlayTargetGeometry() throws {
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.string = "package demo\nimport one\nimport two\nclass Example {\n    void run() {}\n}"
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        layoutManager.delegate = textView
        layoutManager.ensureLayout(for: textContainer)
        let targetLocation = (textView.string as NSString).range(of: "void run").location
        let targetGlyph = layoutManager.glyphIndexForCharacter(at: targetLocation)
        let unfoldedRect = layoutManager.lineFragmentRect(forGlyphAt: targetGlyph, effectiveRange: nil)

        let importsRange = (textView.string as NSString).range(of: "import one\nimport two\n")
        let importFold = JavaFoldRegion(
            kind: .imports,
            startLine: 1,
            endLine: 2,
            hiddenRange: importsRange
        )
        textView.updateFolds(
            regions: [importFold],
            collapsedIDs: [importFold.id],
            onToggle: { _ in }
        )

        let foldedTargetGlyph = layoutManager.glyphIndexForCharacter(at: targetLocation)
        let foldedRect = layoutManager.lineFragmentRect(forGlyphAt: foldedTargetGlyph, effectiveRange: nil)
        #expect(foldedRect.minY < unfoldedRect.minY)
    }

    @Test
    func collapsedFoldKeepsItsBoundaryLinesAndHidesItsContents() {
        let source = """
        void run() {
            execute();
            finish();
        }
        """ as NSString
        let hiddenRange = source.range(of: "    execute();\n    finish();\n")
        let region = JavaFoldRegion(
            kind: .method,
            startLine: 0,
            endLine: 3,
            hiddenRange: hiddenRange
        )
        let collapsedIDs: Set<String> = [region.id]

        #expect(!EditorFoldVisibility.isLineHidden(
            0,
            in: source,
            regions: [region],
            collapsedIDs: collapsedIDs
        ))
        #expect(EditorFoldVisibility.isLineHidden(
            1,
            in: source,
            regions: [region],
            collapsedIDs: collapsedIDs
        ))
        #expect(EditorFoldVisibility.isLineHidden(
            2,
            in: source,
            regions: [region],
            collapsedIDs: collapsedIDs
        ))
        #expect(!EditorFoldVisibility.isLineHidden(
            3,
            in: source,
            regions: [region],
            collapsedIDs: collapsedIDs
        ))
    }

    @Test
    func expandedFoldDoesNotHideAnyLines() {
        let source = "class Example {\n    void run() {}\n}" as NSString
        let region = JavaFoldRegion(
            kind: .type,
            startLine: 0,
            endLine: 2,
            hiddenRange: source.range(of: "    void run() {}\n")
        )

        #expect(!EditorFoldVisibility.isLineHidden(
            1,
            in: source,
            regions: [region],
            collapsedIDs: []
        ))
    }

    @Test
    func codeVisionExcludesHintsInsideCollapsedFolds() {
        let source = """
        class Example {
            void run() {}
        }
        class After {}
        """ as NSString
        let region = JavaFoldRegion(
            kind: .type,
            startLine: 0,
            endLine: 2,
            hiddenRange: source.range(of: "    void run() {}\n")
        )
        let hints = [
            JavaCodeVisionHint(
                line: 0,
                utf16Column: 6,
                symbol: "Example",
                usageCount: 1,
                implementationCount: 0,
                authorName: "Ada"
            ),
            JavaCodeVisionHint(
                line: 1,
                utf16Column: 9,
                symbol: "run",
                usageCount: 2,
                implementationCount: 1,
                authorName: "Grace"
            ),
            JavaCodeVisionHint(
                line: 3,
                utf16Column: 4,
                symbol: "After",
                usageCount: 3,
                implementationCount: 0,
                authorName: nil
            )
        ]

        let visibleHints = EditorFoldVisibility.visibleCodeVisionHints(
            hints,
            in: source,
            regions: [region],
            collapsedIDs: [region.id]
        )

        #expect(visibleHints.map(\.symbol) == ["Example", "After"])
    }

    @Test
    func collapsedFoldKeepsCodeVisionOnItsClosingLine() {
        let source = """
        void first() {
            execute();
        } void next() {
        }
        """ as NSString
        let region = JavaFoldRegion(
            kind: .method,
            startLine: 0,
            endLine: 2,
            hiddenRange: source.range(of: "    execute();\n")
        )
        let hints = [
            JavaCodeVisionHint(
                line: 1,
                utf16Column: 4,
                symbol: "execute",
                usageCount: 1,
                implementationCount: 0,
                authorName: nil
            ),
            JavaCodeVisionHint(
                line: 2,
                utf16Column: 7,
                symbol: "next",
                usageCount: 2,
                implementationCount: 0,
                authorName: "Ada"
            )
        ]

        let visibleHints = EditorFoldVisibility.visibleCodeVisionHints(
            hints,
            in: source,
            regions: [region],
            collapsedIDs: [region.id]
        )

        #expect(visibleHints.map(\.symbol) == ["next"])
        #expect(!EditorFoldVisibility.isLineHidden(
            2,
            in: source,
            regions: [region],
            collapsedIDs: [region.id]
        ))
    }

    @MainActor
    @Test
    func codeVisionStartsAfterTheCollapsedFoldSummary() throws {
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 160))
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.string = "class Example {\n    void run() {}\n}"
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        layoutManager.delegate = textView
        layoutManager.ensureLayout(for: textContainer)

        let source = textView.string as NSString
        let hiddenRange = source.range(of: "\n    void run() {}\n}")
        let region = JavaFoldRegion(
            kind: .type,
            startLine: 0,
            endLine: 2,
            hiddenRange: hiddenRange
        )
        textView.updateFolds(
            regions: [region],
            collapsedIDs: [region.id],
            onToggle: { _ in }
        )
        let foldSummaryMaxX = try #require(
            textView.collapsedFoldSummaryMaxX(forLine: 0)
        )

        let controller = CodeVisionOverlayController(textView: textView)
        controller.update(
            hints: [JavaCodeVisionHint(
                line: 0,
                utf16Column: 6,
                symbol: "Example",
                usageCount: 2,
                implementationCount: 0,
                authorName: nil
            )],
            onUsages: { _ in },
            onImplementations: { _ in },
            onAuthor: {}
        )
        let usageButton = try #require(
            textView.subviews.compactMap { $0 as? NSButton }.first
        )

        #expect(usageButton.frame.minX >= foldSummaryMaxX + 4)
    }

    @Test
    func codeVisionUsesTheSymbolAsItsVisualLineAnchor() {
        #expect(EditorOverlayLayout.codeVisionAnchorCharacterOffset(
            lineStart: 100,
            contentEnd: 180,
            utf16Column: 24
        ) == 124)
    }

    @Test
    func codeVisionAnchorStaysInsideTheLogicalLine() {
        #expect(EditorOverlayLayout.codeVisionAnchorCharacterOffset(
            lineStart: 100,
            contentEnd: 110,
            utf16Column: 80
        ) == 109)
        #expect(EditorOverlayLayout.codeVisionAnchorCharacterOffset(
            lineStart: 100,
            contentEnd: 100,
            utf16Column: 0
        ) == nil)
    }

    @Test
    func columnsHaveDistinctHitTargets() {
        let layout = EditorGutterLayout(lineNumberTextWidth: 24)
        #expect(layout.hitTarget(at: 6, hasGitChange: false) == .breakpoint)
        #expect(layout.hitTarget(at: 22, hasGitChange: false) == .lineNumber)
        #expect(layout.hitTarget(at: 48, hasGitChange: false) == .implementation)
        #expect(layout.hitTarget(at: 68, hasGitChange: false) == .fold)
        #expect(layout.hitTarget(at: 78, hasGitChange: true) == .gitChange)
    }

    @Test
    func gitColumnDoesNotConsumeClicksWithoutAChange() {
        let layout = EditorGutterLayout(lineNumberTextWidth: 24)
        #expect(layout.hitTarget(at: 78, hasGitChange: false) == nil)
    }

    @Test
    func implementationMarkersRefreshWhenLanguageServerBecomesReady() {
        let transition = EditorLanguageFeatureTransition(
            previous: [],
            current: [.definition, .implementation]
        )
        #expect(transition.refreshImplementationMarkers)
        #expect(!transition.clearImplementationMarkers)
    }

    @Test
    func implementationMarkersClearWhenLanguageServerStopsSupportingThem() {
        let transition = EditorLanguageFeatureTransition(
            previous: [.definition, .implementation],
            current: [.definition]
        )
        #expect(!transition.refreshImplementationMarkers)
        #expect(transition.clearImplementationMarkers)
    }

    @Test
    func unchangedImplementationSupportDoesNotRefreshMarkers() {
        let transition = EditorLanguageFeatureTransition(
            previous: [.definition, .implementation],
            current: [.definition, .implementation]
        )
        #expect(!transition.refreshImplementationMarkers)
        #expect(!transition.clearImplementationMarkers)
    }

    @Test
    func lineNumberColumnExpandsWithoutOverlappingFollowingColumns() {
        let layout = EditorGutterLayout(lineNumberTextWidth: 34)
        #expect(layout.lineNumberRange.upperBound - layout.lineNumberRange.lowerBound == 37)
        #expect(layout.lineNumberRange.upperBound == layout.implementationRange.lowerBound)
        #expect(layout.implementationRange.upperBound == layout.foldRange.lowerBound)
        #expect(layout.foldRange.upperBound == layout.gitChangeRange.lowerBound)
        #expect(layout.gitChangeRange.upperBound == layout.width)
    }

    @Test
    func overlayRelayoutOnlyDependsOnEditorWidth() {
        #expect(!EditorOverlayLayout.requiresRelayout(previousWidth: 640, newWidth: 640))
        #expect(EditorOverlayLayout.requiresRelayout(previousWidth: 640, newWidth: 520))
    }

    @Test
    func overlayFontCenterAlignsWithTheLineCenter() {
        #expect(EditorOverlayLayout.centeredFontOriginY(
            textContainerOriginY: 2,
            lineOriginY: 20,
            lineHeight: 18,
            overlayBaselineOffset: 11,
            overlayAscender: 8,
            overlayDescender: -2
        ) == 23)
    }

    @Test
    func overlayOriginTracksLineHeightInsteadOfEditorBaseline() {
        #expect(EditorOverlayLayout.centeredFontOriginY(
            textContainerOriginY: 2,
            lineOriginY: 20,
            lineHeight: 16,
            overlayBaselineOffset: 9,
            overlayAscender: 7,
            overlayDescender: -1
        ) == 24)
        #expect(EditorOverlayLayout.centeredFontOriginY(
            textContainerOriginY: 2,
            lineOriginY: 20,
            lineHeight: 24,
            overlayBaselineOffset: 9,
            overlayAscender: 7,
            overlayDescender: -1
        ) == 28)
    }

    @Test
    func overlayOriginTracksTheActualFontMetrics() {
        #expect(EditorOverlayLayout.centeredFontOriginY(
            textContainerOriginY: 2,
            lineOriginY: 20,
            lineHeight: 20,
            overlayBaselineOffset: 10,
            overlayAscender: 8,
            overlayDescender: -2
        ) == 25)
        #expect(EditorOverlayLayout.centeredFontOriginY(
            textContainerOriginY: 2,
            lineOriginY: 20,
            lineHeight: 20,
            overlayBaselineOffset: 14,
            overlayAscender: 12,
            overlayDescender: -4
        ) == 22)
    }
}
