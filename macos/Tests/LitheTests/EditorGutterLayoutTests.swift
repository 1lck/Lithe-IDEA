import AppKit
import Testing
@testable import Lithe

@Suite("Editor gutter layout")
struct EditorGutterLayoutTests {
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
    func inlayLayoutChangesForceCodeVisionToReposition() {
        let plan = EditorOverlayUpdatePlan(
            codeVisionChanged: false,
            inlayHintsChanged: true,
            layoutChanged: false
        )
        #expect(plan.updateInlayHints)
        #expect(plan.updateCodeVision)
    }

    @Test
    func unchangedOverlaysDoNotRebuild() {
        let plan = EditorOverlayUpdatePlan(
            codeVisionChanged: false,
            inlayHintsChanged: false,
            layoutChanged: false
        )
        #expect(!plan.updateInlayHints)
        #expect(!plan.updateCodeVision)
    }

    @Test
    func viewportResizeDoesNotReapplyInlaySpacing() {
        let plan = EditorOverlayUpdatePlan(
            codeVisionChanged: false,
            inlayHintsChanged: false,
            layoutChanged: true
        )
        #expect(!plan.updateInlayHints)
        #expect(plan.updateCodeVision)
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
    func inlayHintBoxCenterAlignsWithTheLineCenter() {
        #expect(EditorOverlayLayout.centeredBoxOriginY(
            textContainerOriginY: 2,
            lineOriginY: 20,
            lineHeight: 18,
            boxHeight: 16
        ) == 23)
        #expect(EditorOverlayLayout.centeredBoxOriginY(
            textContainerOriginY: 2,
            lineOriginY: 20,
            lineHeight: 24,
            boxHeight: 18
        ) == 25)
    }

    @Test
    func inlayHintBoxHeightDependsOnItsFontInsteadOfEditorLineHeight() {
        let height = EditorOverlayLayout.inlayHintBoxHeight(
            fontAscender: 10,
            fontDescender: -3,
            fontLeading: 1
        )
        #expect(height == 18)
        #expect(EditorOverlayLayout.centeredBoxOriginY(
            textContainerOriginY: 2,
            lineOriginY: 20,
            lineHeight: 40,
            boxHeight: height
        ) == 33)
    }

    @Test
    func inlayHintBoxAlignsWithTheActualTextCenter() {
        #expect(EditorOverlayLayout.boxOriginYAlignedToTextCenter(
            textContainerOriginY: 2,
            lineOriginY: 0,
            baselineOffsetY: 28.6,
            textAscender: 23.2,
            textDescender: -5.0,
            boxHeight: 18
        ) == 12.5)
    }

    @Test
    func inlayHintOnALaterLineIncludesTheLineOrigin() {
        #expect(EditorOverlayLayout.boxOriginYAlignedToTextCenter(
            textContainerOriginY: 2,
            lineOriginY: 638.4,
            baselineOffsetY: 28.6,
            textAscender: 23.2,
            textDescender: -5.0,
            boxHeight: 18
        ) == 650.9)
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
