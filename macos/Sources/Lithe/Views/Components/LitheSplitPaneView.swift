import SwiftUI

/// A two-pane split whose divider drag is confined to this container.
///
/// One pane has a tracked size and the other takes the remainder. The dragged
/// size lives here rather than in the hosting feature view, so moving a divider
/// invalidates only this container: `sized` and `flexible` were built by the
/// host's last body pass and are the same values on every re-evaluation, which
/// lets SwiftUI skip their bodies. That is the protection `WorkbenchWorkspaceSplitView`
/// already had and this generalizes to the Git, Run, and test tool windows.
struct LitheSplitPaneView<Sized: View, Flexible: View>: View {
    let axis: LitheSplitAxis
    let placement: LitheSplitPaneGeometry.Placement
    /// The size used until the user drags, re-supplied by the host every body
    /// pass. Hosts that derive it from live geometry keep following the window
    /// until the first drag, matching the pre-extraction behavior.
    let defaultSize: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    /// Minimum size reserved for the flexible pane, when the hosted content
    /// has a product-level usability requirement of its own.
    let flexibleMinimum: CGFloat?
    /// Clip a pane with content wider than the dragged size at the split boundary.
    let clipsSizedPane: Bool
    /// Hide the tracked pane and divider without unmounting either pane.
    let isSizedPaneCollapsed: Bool
    let trackBackground: Color
    let dividerColor: Color
    let showsIdleDivider: Bool
    let highlightsOnHover: Bool
    /// Called with the final size when a drag ends. Hosts that persist the size
    /// write it here; the container then defers to `defaultSize` again so the
    /// persisted value is the single source of truth.
    let onCommit: ((CGFloat) -> Void)?

    private let sized: Sized
    private let flexible: Flexible

    @State private var draggedSize: CGFloat?
    @State private var dragStart: CGFloat = 0

    init(
        axis: LitheSplitAxis,
        placement: LitheSplitPaneGeometry.Placement,
        defaultSize: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        flexibleMinimum: CGFloat? = nil,
        clipsSizedPane: Bool = false,
        isSizedPaneCollapsed: Bool = false,
        trackBackground: Color = .clear,
        dividerColor: Color = LitheTheme.divider,
        showsIdleDivider: Bool = true,
        highlightsOnHover: Bool = true,
        onCommit: ((CGFloat) -> Void)? = nil,
        @ViewBuilder sized: () -> Sized,
        @ViewBuilder flexible: () -> Flexible
    ) {
        self.axis = axis
        self.placement = placement
        self.defaultSize = defaultSize
        self.minimum = minimum
        self.maximum = maximum
        self.flexibleMinimum = flexibleMinimum
        self.clipsSizedPane = clipsSizedPane
        self.isSizedPaneCollapsed = isSizedPaneCollapsed
        self.trackBackground = trackBackground
        self.dividerColor = dividerColor
        self.showsIdleDivider = showsIdleDivider
        self.highlightsOnHover = highlightsOnHover
        self.onCommit = onCommit
        self.sized = sized()
        self.flexible = flexible()
    }

    private var resolvedSize: CGFloat {
        if isSizedPaneCollapsed { return 0 }
        return LitheSplitPaneGeometry.clamp(
            draggedSize ?? defaultSize,
            minimum: minimum,
            maximum: maximum
        )
    }

    var body: some View {
        let size = resolvedSize
        LitheSplitPaneLayout(axis: axis, placement: placement, size: size,
            dividerSize: isSizedPaneCollapsed ? 0 : SplitHandleView.thickness,
            flexibleMinimum: flexibleMinimum ?? 0) {
            panes(size)
        }
    }

    @ViewBuilder
    private func panes(_ size: CGFloat) -> some View {
        switch placement {
        case .leading:
            sizedPane
                .opacity(isSizedPaneCollapsed ? 0 : 1)
                .allowsHitTesting(!isSizedPaneCollapsed)
                .accessibilityHidden(isSizedPaneCollapsed)
            handle(size)
            flexiblePane
        case .trailing:
            flexiblePane
            handle(size)
            sizedPane
                .opacity(isSizedPaneCollapsed ? 0 : 1)
                .allowsHitTesting(!isSizedPaneCollapsed)
                .accessibilityHidden(isSizedPaneCollapsed)
        }
    }

    @ViewBuilder
    private var sizedPane: some View {
        let pane = sized.frame(maxWidth: .infinity, maxHeight: .infinity,
            alignment: axis == .horizontal
                ? (placement == .leading ? .leading : .trailing)
                : (placement == .leading ? .top : .bottom))
        if clipsSizedPane {
            pane.clipped().contentShape(Rectangle())
        } else {
            pane
        }
    }

    @ViewBuilder
    private var flexiblePane: some View {
        if axis == .horizontal {
            flexible.frame(minWidth: flexibleMinimum, maxWidth: .infinity)
        } else {
            flexible.frame(minHeight: flexibleMinimum, maxHeight: .infinity)
        }
    }

    private func handle(_ size: CGFloat) -> some View {
        SplitHandleView(
            axis: axis,
            trackBackground: trackBackground,
            dividerColor: dividerColor,
            showsIdleDivider: showsIdleDivider,
            highlightsOnHover: highlightsOnHover,
            onDragStarted: { dragStart = size },
            onDragChanged: { translation in
                let nextSize = resolved(from: translation)
                if nextSize != resolvedSize { draggedSize = nextSize }
            },
            onDragEnded: { translation in
                let finalSize = resolved(from: translation)
                if let onCommit {
                    onCommit(finalSize)
                    // The host now owns the value and feeds it back as
                    // `defaultSize`; keeping a dragged size too would shadow it.
                    draggedSize = nil
                } else {
                    draggedSize = finalSize
                }
            }
        )
        .frame(
            width: axis == .horizontal && isSizedPaneCollapsed ? 0 : nil,
            height: axis == .vertical && isSizedPaneCollapsed ? 0 : nil
        )
        .opacity(isSizedPaneCollapsed ? 0 : 1)
        .allowsHitTesting(!isSizedPaneCollapsed)
        .accessibilityHidden(isSizedPaneCollapsed)
    }

    private func resolved(from translation: CGFloat) -> CGFloat {
        LitheSplitPaneGeometry.resolve(
            start: dragStart,
            translation: translation,
            placement: placement,
            minimum: minimum,
            maximum: maximum
        )
    }
}

/// Like IDEA's ThreeComponentsSplitter, assign existing panes exact bounds.
/// Stack layouts probe children's minimum/ideal sizes on each drag, even when
/// the container and the divider already determine every pane's rectangle.
private struct LitheSplitPaneLayout: Layout {
    let axis: LitheSplitAxis
    let placement: LitheSplitPaneGeometry.Placement
    let size: CGFloat
    let dividerSize: CGFloat
    let flexibleMinimum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if let width = proposal.width, let height = proposal.height,
           width.isFinite, height.isFinite {
            return CGSize(width: max(0, width), height: max(0, height))
        }
        // Intrinsic sizing is only needed if the host has not assigned bounds.
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let sizedExtent = size + dividerSize + flexibleMinimum
        let ideal = axis == .horizontal
            ? CGSize(width: max(sizedExtent, sizes.reduce(0) { $0 + $1.width }),
                     height: sizes.map(\.height).max() ?? 0)
            : CGSize(width: sizes.map(\.width).max() ?? 0,
                     height: max(sizedExtent, sizes.reduce(0) { $0 + $1.height }))
        return CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal.width,
                      height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let extent = axis == .horizontal ? bounds.width : bounds.height
        let divider = min(dividerSize, max(0, extent))
        let tracked = min(max(0, size), max(0, extent - divider - flexibleMinimum))
        let flexible = max(0, extent - tracked - divider)
        let lengths = placement == .leading ? [tracked, divider, flexible] : [flexible, divider, tracked]
        var offset: CGFloat = 0
        for (index, length) in lengths.enumerated() {
            let point = CGPoint(x: bounds.minX + (axis == .horizontal ? offset : 0),
                                y: bounds.minY + (axis == .vertical ? offset : 0))
            let size = axis == .horizontal
                ? CGSize(width: length, height: bounds.height)
                : CGSize(width: bounds.width, height: length)
            let childProposal = ProposedViewSize(size)
            subviews[index].place(at: point, anchor: .topLeading, proposal: childProposal)
            offset += length
        }
    }
}
