import CoreGraphics
import SwiftUI
import Testing
@testable import Lithe

@Suite("Workbench hover tooltips", .serialized)
@MainActor
struct WorkbenchHoverTooltipTests {
    @Test
    func previousIconExitDoesNotDismissTheNewTooltip() async {
        let state = WorkbenchHoverTooltipState()
        let previous = UUID()
        let current = UUID()
        state.enter(previous)
        state.enter(current)
        state.leave(previous)

        #expect(state.hoveredID == current)
        state.leave(current)
        #expect(state.hoveredID == nil)
    }

    @Test
    func dismissingTheScopeClearsItsCurrentTooltip() async {
        let state = WorkbenchHoverTooltipState()
        state.enter(UUID())
        state.dismiss()
        #expect(state.hoveredID == nil)
    }

    @Test
    func tooltipOwnersRemainIndependentAcrossWindows() async {
        let first = WorkbenchHoverTooltipState()
        let second = WorkbenchHoverTooltipState()
        let id = UUID()
        first.enter(id)
        second.dismiss()
        #expect(first.hoveredID == id)
        #expect(second.hoveredID == nil)
    }

    @Test
    func shortTextUsesItsIntrinsicWidth() async throws {
        let bounds = try renderedBounds(text: "跳过测试")
        // A fixed 236pt tooltip fails this even though its text remains readable.
        #expect(bounds.width > 30)
        #expect(bounds.width < 120)
    }

    @Test
    func longTextWrapsWithinANarrowViewport() async throws {
        let text = "运行选中的 Maven 生命周期阶段"
        let wide = try renderedBounds(text: text)
        let narrow = try renderedBounds(text: text, viewport: CGSize(width: 130, height: 120))
        #expect(narrow.height > wide.height)
        #expect(narrow.width < wide.width)
        #expect(narrow.minX >= 7)
        #expect(narrow.maxX <= 123)
    }

    @Test
    func tooltipsStayInsideBothHorizontalEdges() async throws {
        let left = try renderedBounds(text: "跳过测试", source: CGRect(x: 0, y: 20, width: 30, height: 30))
        let right = try renderedBounds(text: "跳过测试", source: CGRect(x: 330, y: 20, width: 30, height: 30))
        // Allow one raster pixel for the rounded rectangle's antialiased border.
        #expect(left.minX >= 7 && left.minX <= 9)
        #expect(right.maxX >= 351 && right.maxX <= 353)
    }

    @Test
    func activityRailTipsOpenTowardTheWorkspace() async throws {
        let leftSource = CGRect(x: 4, y: 20, width: 30, height: 30)
        let rightSource = CGRect(x: 326, y: 20, width: 30, height: 30)
        let left = try renderedBounds(text: "项目", source: leftSource, placement: .trailing)
        let right = try renderedBounds(text: "Maven", source: rightSource, placement: .leading)
        #expect(left.minX >= leftSource.maxX + 4)
        #expect(right.maxX <= rightSource.minX - 4)
    }

    @Test
    func bottomActivityTooltipKeepsAVerticalMargin() async throws {
        let bounds = try renderedBounds(
            text: "设置",
            source: CGRect(x: 4, y: 105, width: 30, height: 30),
            placement: .trailing
        )
        #expect(bounds.minY >= 7)
        #expect(bounds.maxY <= 113)
    }

    private func renderedBounds(
        text: String,
        viewport: CGSize = CGSize(width: 360, height: 120),
        source: CGRect = CGRect(x: 150, y: 20, width: 30, height: 30),
        placement: WorkbenchHoverTooltipPlacement = .below
    ) throws -> CGRect {
        // Render the production Layout and label synchronously, without a window or waits.
        let renderer = ImageRenderer(content:
            WorkbenchHoverTooltipLayout(sourceFrame: source, placement: placement) {
                WorkbenchHoverTooltipLabel(title: Text(verbatim: text))
            }
            .frame(width: viewport.width, height: viewport.height)
        )
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 16 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        try #require(maxX >= minX && maxY >= minY, "Tooltip did not render any visible pixels")
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
