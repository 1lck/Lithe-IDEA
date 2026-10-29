import AppKit
import SwiftUI
import Testing
@testable import Lithe

private final class ChipView: NSView {}

/// A chip that is 400pt wide when unconstrained and shrinks to a proposed width.
private struct FlexibleChip: NSViewRepresentable {
    func makeNSView(context: Context) -> ChipView { ChipView() }
    func updateNSView(_ view: ChipView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChipView, context: Context) -> CGSize? {
        CGSize(width: min(proposal.width ?? 400, 400), height: 10)
    }
}

@Suite("Chip flow layout", .serialized)
@MainActor
struct LitheChipFlowLayoutTests {
    /// Placed width of a lone 400pt chip in a 200pt row.
    private func placedWidth(clampsToWidth: Bool) throws -> CGFloat {
        let hosting = NSHostingView(rootView: LitheChipFlowLayout(spacing: 4, clampsToWidth: clampsToWidth) {
            FlexibleChip()
        }.frame(width: 200, height: 40, alignment: .topLeading))
        hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> ChipView? {
            if let chip = view as? ChipView { return chip }
            for child in view.subviews { if let chip = find(child) { return chip } }
            return nil
        }
        return try #require(find(hosting)).frame.width
    }

    @Test
    func aChipWiderThanTheRowIsNarrowedOnlyWhenAskedTo() throws {
        #expect(try placedWidth(clampsToWidth: true) == 200, "The chip receives the row width and can truncate")
        #expect(try placedWidth(clampsToWidth: false) == 400, "The default keeps every existing caller's ideal sizes")
    }
}
