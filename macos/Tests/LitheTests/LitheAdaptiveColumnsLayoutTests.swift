import AppKit
import SwiftUI
import Testing
@testable import Lithe

private final class FirstColumn: NSView {}
private final class SecondColumn: NSView {}

/// A 30pt-tall block that takes whatever width it is offered.
private struct Column<Probe: NSView>: NSViewRepresentable {
    let make: () -> Probe
    func makeNSView(context: Context) -> Probe { make() }
    func updateNSView(_ view: Probe, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Probe, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 100, height: 30)
    }
}

@Suite("Adaptive columns layout", .serialized)
@MainActor
struct LitheAdaptiveColumnsLayoutTests {
    private func frames(rowWidth: CGFloat) throws -> (first: CGRect, second: CGRect) {
        let hosting = NSHostingView(rootView: LitheAdaptiveColumnsLayout(minimumColumnWidth: 300, spacing: 20) {
            Column { FirstColumn() }
            Column { SecondColumn() }
        }.frame(width: rowWidth, height: 200, alignment: .topLeading))
        hosting.frame = NSRect(x: 0, y: 0, width: rowWidth, height: 200)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()
        func find<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
            if let match = view as? V { return match }
            for child in view.subviews { if let match = find(type, in: child) { return match } }
            return nil
        }
        let first = try #require(find(FirstColumn.self, in: hosting))
        let second = try #require(find(SecondColumn.self, in: hosting))
        return (first.convert(first.bounds, to: hosting), second.convert(second.bounds, to: hosting))
    }

    @Test
    func wideRowsShareTheWidthAndNarrowRowsStack() throws {
        let wide = try frames(rowWidth: 700)
        #expect(wide.first.width == 340 && wide.second.width == 340)
        #expect(wide.first.minY == wide.second.minY, "side by side, aligned at the top")
        #expect(wide.second.minX == wide.first.maxX + 20)

        // 600 leaves 290 per column, under the 300 minimum.
        let narrow = try frames(rowWidth: 600)
        #expect(narrow.first.width == 600 && narrow.second.width == 600)
        #expect(narrow.first.minX == narrow.second.minX)
        #expect(abs(narrow.second.minY - narrow.first.minY) == 50, "30pt block plus the 20pt gap")
    }
}
