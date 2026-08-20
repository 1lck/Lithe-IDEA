import Testing
@testable import Lithe

struct EditorLayoutMetricsTests {
    @Test
    func blameGutterKeepsTheStandardEditorGutterBesideCompactMetadata() {
        #expect(EditorLayoutMetrics.blameGutterWidth == 205)
        #expect(
            abs(
                EditorLayoutMetrics.blameGutterWidth
                    - EditorLayoutMetrics.blameMetadataWidth
                    - EditorLayoutMetrics.standardGutterWidth
            ) < 0.001
        )
    }

    @Test
    func standardGutterUsesDistinctMarkerLineNumberAndFoldColumns() {
        #expect(EditorLayoutMetrics.markerColumnWidth == 16)
        #expect(EditorLayoutMetrics.lineNumberWidth == 36)
        #expect(EditorLayoutMetrics.foldIndicatorWidth == 13)
        #expect(
            abs(
                EditorLayoutMetrics.standardGutterWidth
                    - (
                        EditorLayoutMetrics.markerColumnWidth
                            + EditorLayoutMetrics.lineNumberWidth
                            + EditorLayoutMetrics.foldIndicatorWidth
                    )
            ) < 0.001
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
