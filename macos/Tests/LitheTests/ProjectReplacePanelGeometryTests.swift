import CoreGraphics
import Testing
@testable import Lithe

@Suite("Replacement dialog geometry")
struct ProjectReplacePanelGeometryTests {
    @Test
    func draggingStaysInsideTheWorkbench() {
        let start = CGRect(x: 100, y: 100, width: 650, height: 614)
        let viewport = CGSize(width: 1000, height: 800)
        #expect(ProjectReplacePanelGeometry.updated(start, translation: CGSize(width: -500, height: 900), corner: nil, in: viewport) == CGRect(x: 0, y: 186, width: 650, height: 614))
    }

    @Test
    func allCornersKeepTheOppositeCornerFixedAndEnforceLimits() {
        let start = CGRect(x: 100, y: 100, width: 650, height: 614)
        let viewport = CGSize(width: 1000, height: 800)
        for corner in ProjectReplacePanelGeometry.Corner.allCases {
            for distance in [-2000.0, 2000.0] {
                let result = ProjectReplacePanelGeometry.updated(start, translation: CGSize(width: distance, height: distance), corner: corner, in: viewport)
                #expect(result.width >= 520 && result.height >= 400)
                #expect(result.minX >= 0 && result.minY >= 0)
                #expect(result.maxX <= viewport.width && result.maxY <= viewport.height)
                #expect(corner.isLeading ? result.maxX == start.maxX : result.minX == start.minX)
                #expect(corner.isTop ? result.maxY == start.maxY : result.minY == start.minY)
            }
        }
    }

    @Test
    func shrinkingTheWorkbenchKeepsTheDialogVisible() {
        let result = ProjectReplacePanelGeometry.constrained(CGRect(x: 700, y: 600, width: 650, height: 614), in: CGSize(width: 450, height: 300))
        #expect(result == CGRect(x: 0, y: 0, width: 450, height: 300))
    }
}
