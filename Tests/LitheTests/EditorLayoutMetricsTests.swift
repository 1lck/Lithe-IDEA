import Testing
@testable import Lithe

struct EditorLayoutMetricsTests {
    @Test
    func blameGutterKeepsTheStandardEditorGutterBesideCompactMetadata() {
        #expect(EditorLayoutMetrics.blameGutterWidth == 220)
        #expect(
            abs(
                EditorLayoutMetrics.blameGutterWidth
                    - EditorLayoutMetrics.blameMetadataWidth
                    - EditorLayoutMetrics.standardGutterWidth
            ) < 0.001
        )
    }

    @Test
    func standardGutterUsesDistinctBreakpointImplementationLineNumberAndFoldColumns() {
        let layout = EditorGutterLayout(lineNumberTextWidth: 0)
        #expect(layout.breakpointRange.upperBound == layout.implementationRange.lowerBound)
        #expect(layout.implementationRange.upperBound == layout.lineNumberRange.lowerBound)
        #expect(layout.lineNumberRange.upperBound == layout.foldRange.lowerBound)
        #expect(layout.foldRange.upperBound == layout.gitChangeRange.lowerBound)
        #expect(layout.gitChangeRange.upperBound == EditorLayoutMetrics.standardGutterWidth)
    }

    @Test
    func lineNumberFontTracksTheEditorFontSize() {
        let smallEditorFont = LitheTheme.editorFont(size: 11)
        let largeEditorFont = LitheTheme.editorFont(size: 20)
        #expect(
            EditorGutterLayout.lineNumberFont(for: largeEditorFont).pointSize
                > EditorGutterLayout.lineNumberFont(for: smallEditorFont).pointSize
        )
    }

    @Test
    func blameMetadataAppearsAtVisibleAndCommitBoundaries() {
        #expect(EditorLayoutMetrics.showsBlameMetadata(
            line: 12,
            firstVisibleLine: 12,
            commitHash: "same",
            previousCommitHash: "same"
        ))
        #expect(EditorLayoutMetrics.showsBlameMetadata(
            line: 13,
            firstVisibleLine: 12,
            commitHash: "new",
            previousCommitHash: "same"
        ))
        #expect(!EditorLayoutMetrics.showsBlameMetadata(
            line: 13,
            firstVisibleLine: 12,
            commitHash: "same",
            previousCommitHash: "same"
        ))
    }

    @Test
    func blameMetadataMovesToTheNewFirstVisibleLineWithinTheSameCommit() {
        #expect(EditorLayoutMetrics.showsBlameMetadata(
            line: 2,
            firstVisibleLine: 2,
            commitHash: "same",
            previousCommitHash: "same"
        ))
        #expect(!EditorLayoutMetrics.showsBlameMetadata(
            line: 1,
            firstVisibleLine: 2,
            commitHash: "same",
            previousCommitHash: "same"
        ))
        #expect(EditorLayoutMetrics.showsBlameMetadata(
            line: 3,
            firstVisibleLine: 2,
            commitHash: "new",
            previousCommitHash: "same"
        ))
    }
}
