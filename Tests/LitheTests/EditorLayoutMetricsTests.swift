import Testing
@testable import Lithe

struct EditorLayoutMetricsTests {
    @Test
    func blameGutterKeepsTheStandardEditorGutterBesideCompactMetadata() {
        #expect(EditorLayoutMetrics.blameGutterWidth == 185)
        #expect(
            abs(
                EditorLayoutMetrics.blameGutterWidth
                    - EditorLayoutMetrics.blameMetadataWidth
                    - EditorLayoutMetrics.standardGutterWidth
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
}
