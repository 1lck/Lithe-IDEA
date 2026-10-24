import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
struct LitheFormGridTests {
    @Test func gridSpansShareColumnEdgesAndUseTheTallestCellPerRow() {
        let grid = LitheFormGrid(columns: 12)
        let frames = grid.frames(width: 1200, spans: [4, 4, 4, 6, 6, 12], heights: [44, 60, 44, 16, 16, 28])
        #expect(frames[0] == CGRect(x: 0, y: 0, width: 392, height: 44))
        #expect(frames[1].minX == 404)
        #expect(frames[2].maxX == 1200)
        #expect(frames[3].minY == 72)
        #expect(frames[3].width == 594)
        #expect(frames[4].maxX == 1200)
        #expect(frames[5] == CGRect(x: 0, y: 100, width: 1200, height: 28))
    }

    @Test func partialRowsWrapAndNarrowPanelsBecomeSingleColumn() {
        let grid = LitheFormGrid(columns: 12)
        let partial = grid.frames(width: 1200, spans: [8, 6, 6], heights: [24, 48, 24])
        #expect(partial[1].origin == CGPoint(x: 0, y: 36))
        #expect(partial[2].minY == partial[1].minY)
        let narrow = grid.frames(width: 639, spans: [4, 4, 4], heights: [24, 48, 24])
        #expect(narrow.map(\.minX) == [0, 0, 0])
        #expect(narrow.map(\.width) == [639, 639, 639])
        #expect(narrow.map(\.minY) == [0, 36, 96])
        #expect(grid.effectiveColumns(width: 640) == 12)
        #expect(grid.frames(width: 0, spans: [12], heights: [24]).first?.width == 0)
        #expect(grid.frames(width: 400, spans: [], heights: []).isEmpty)
    }

    @Test func nativeLayoutMeasuresWideAndNarrowContentWithoutFixedRowHeights() {
        func height(width: CGFloat) -> CGFloat {
            let host = NSHostingView(rootView: LitheFormGrid(columns: 12) {
                Color.clear.frame(height: 24).layoutValue(key: LitheFormGrid.Span.self, value: 6)
                Color.clear.frame(height: 48).layoutValue(key: LitheFormGrid.Span.self, value: 6)
                Color.clear.frame(height: 24).layoutValue(key: LitheFormGrid.Span.self, value: 12)
            }.frame(width: width))
            return host.fittingSize.height
        }
        #expect(height(width: 1200) == 84)
        #expect(height(width: 400) == 120)
    }
}
