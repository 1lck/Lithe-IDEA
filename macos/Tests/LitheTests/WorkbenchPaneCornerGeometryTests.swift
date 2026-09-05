import CoreGraphics
import SwiftUI
import Testing
@testable import Lithe

/// The pane corner notch is what makes a workbench pane read as rounded without
/// clipping its AppKit-backed content. It is built from tangent points rather
/// than sweep angles, so these tests pin the arc to the correct side: an arc
/// bulging the wrong way would paint over the pane instead of its square corner.
@Suite("Workbench pane corner geometry")
struct WorkbenchPaneCornerGeometryTests {
    private let radius: CGFloat = 10

    @Test(arguments: WorkbenchPaneCornerGeometry.Corner.allCases)
    func theNotchFillsTheSquareCornerAndNotThePaneInterior(
        corner: WorkbenchPaneCornerGeometry.Corner
    ) {
        let path = WorkbenchPaneCornerGeometry.makePath(for: corner, radius: radius)

        // Just inside the square corner: this is the sliver the rounded
        // silhouette leaves behind and the notch must cover it.
        #expect(path.contains(nearPaneCorner(corner)))
        // The diagonally opposite point is deep inside the rounded pane and must
        // stay uncovered, which is exactly what a reversed arc would break.
        #expect(!path.contains(nearArcCenter(corner)))
    }

    @Test(arguments: WorkbenchPaneCornerGeometry.Corner.allCases)
    func theNotchStaysInsideItsOwnBox(corner: WorkbenchPaneCornerGeometry.Corner) {
        let path = WorkbenchPaneCornerGeometry.makePath(for: corner, radius: radius)
        let bounds = path.boundingRect

        // The notch is overlaid unclipped, so escaping the radius-square box
        // would paint the surrounding color across pane content.
        #expect(bounds.minX >= -0.01)
        #expect(bounds.minY >= -0.01)
        #expect(bounds.maxX <= radius + 0.01)
        #expect(bounds.maxY <= radius + 0.01)
    }

    @Test
    func theNotchCoversTheCornerButNotTheTangentMidpoint() {
        let path = WorkbenchPaneCornerGeometry.makePath(for: .topLeading, radius: radius)

        #expect(path.contains(CGPoint(x: 0.5, y: 0.5)))
        // The arc passes through radius * (1 - 1/sqrt(2)) ≈ 2.93 on the diagonal;
        // a point beyond it is inside the rounded pane.
        #expect(!path.contains(CGPoint(x: 4, y: 4)))
    }

    /// A point just inside the pane's square corner, which the notch covers.
    private func nearPaneCorner(_ corner: WorkbenchPaneCornerGeometry.Corner) -> CGPoint {
        let near: CGFloat = 0.5
        let far = radius - 0.5
        return switch corner {
        case .topLeading: CGPoint(x: near, y: near)
        case .topTrailing: CGPoint(x: far, y: near)
        case .bottomLeading: CGPoint(x: near, y: far)
        case .bottomTrailing: CGPoint(x: far, y: far)
        }
    }

    /// A point next to the arc center, which lies inside the rounded pane.
    private func nearArcCenter(_ corner: WorkbenchPaneCornerGeometry.Corner) -> CGPoint {
        let near: CGFloat = 0.5
        let far = radius - 0.5
        return switch corner {
        case .topLeading: CGPoint(x: far, y: far)
        case .topTrailing: CGPoint(x: near, y: far)
        case .bottomLeading: CGPoint(x: far, y: near)
        case .bottomTrailing: CGPoint(x: near, y: near)
        }
    }
}
