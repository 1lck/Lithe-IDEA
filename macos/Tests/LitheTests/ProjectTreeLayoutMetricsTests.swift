import Testing
@testable import Lithe

struct ProjectTreeLayoutMetricsTests {
    @Test
    func treeRowsMatchIntelliJNewUILayoutMetrics() {
        #expect(LitheTheme.Metrics.projectTreeRowSpacing == 0)
        #expect(LitheTheme.Metrics.projectTreeContentVerticalInset == 4)
        #expect(LitheTheme.Metrics.projectTreeContentHorizontalInset == 12)
        #expect(LitheTheme.Metrics.projectTreeSelectionCornerRadius == 4)
        #expect(LitheTheme.Metrics.treeIconSize == 16)
    }
}
