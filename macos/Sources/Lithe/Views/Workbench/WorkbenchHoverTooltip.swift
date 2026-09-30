import SwiftUI

enum WorkbenchHoverTooltipPlacement {
    case above
    case below
    case leading
    case trailing
}

/// A window-local owner; only the tooltip overlay observes its hover changes.
@MainActor
final class WorkbenchHoverTooltipState: ObservableObject {
    @Published private(set) var hoveredID: UUID?

    func enter(_ id: UUID) {
        guard hoveredID != id else { return }
        hoveredID = id
    }

    func leave(_ id: UUID) {
        // An old icon can deliver its exit after the next icon has entered.
        guard hoveredID == id else { return }
        hoveredID = nil
    }

    func dismiss() {
        guard hoveredID != nil else { return }
        hoveredID = nil
    }
}

private struct WorkbenchHoverTooltipEnvironmentKey: EnvironmentKey {
    static let defaultValue: WorkbenchHoverTooltipState? = nil
}

private extension EnvironmentValues {
    var workbenchHoverTooltipState: WorkbenchHoverTooltipState? {
        get { self[WorkbenchHoverTooltipEnvironmentKey.self] }
        set { self[WorkbenchHoverTooltipEnvironmentKey.self] = newValue }
    }
}

private struct WorkbenchHoverTooltipAnchor {
    let bounds: Anchor<CGRect>
    let title: Text
    let placement: WorkbenchHoverTooltipPlacement
}

private struct WorkbenchHoverTooltipPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: WorkbenchHoverTooltipAnchor] = [:]

    static func reduce(
        value: inout [UUID: WorkbenchHoverTooltipAnchor],
        nextValue: () -> [UUID: WorkbenchHoverTooltipAnchor]
    ) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

private struct WorkbenchHoverTooltipScope: ViewModifier {
    @Environment(\.workbenchHoverTooltipState) private var inheritedState
    // @State retains the owner without subscribing the workbench to its changes.
    @State private var state = WorkbenchHoverTooltipState()

    func body(content: Content) -> some View {
        let owner = inheritedState ?? state
        content
            .environment(\.workbenchHoverTooltipState, owner)
            .overlayPreferenceValue(WorkbenchHoverTooltipPreferenceKey.self) { anchors in
                WorkbenchHoverTooltipOverlay(state: owner, anchors: anchors)
            }
            // Nested panels share the owner but render within their own bounds.
            .transformPreference(WorkbenchHoverTooltipPreferenceKey.self) { $0.removeAll() }
            .onDisappear {
                if inheritedState == nil { state.dismiss() }
            }
    }
}

private struct WorkbenchHoverTooltipSource: ViewModifier {
    @Environment(\.workbenchHoverTooltipState) private var state
    @State private var id = UUID()
    let title: Text
    let placement: WorkbenchHoverTooltipPlacement

    func body(content: Content) -> some View {
        // Keep hover tracking outside the Button's disabled environment.
        ZStack { content }
            .contentShape(Rectangle())
            .anchorPreference(key: WorkbenchHoverTooltipPreferenceKey.self, value: .bounds) {
                [id: WorkbenchHoverTooltipAnchor(bounds: $0, title: title, placement: placement)]
            }
            .onHover { isHovered in
                if isHovered {
                    state?.enter(id)
                } else {
                    state?.leave(id)
                }
            }
            .simultaneousGesture(TapGesture().onEnded { state?.leave(id) })
            .onDisappear { state?.leave(id) }
    }
}

private struct WorkbenchHoverTooltipOverlay: View {
    @ObservedObject var state: WorkbenchHoverTooltipState
    let anchors: [UUID: WorkbenchHoverTooltipAnchor]

    var body: some View {
        GeometryReader { geometry in
            if let id = state.hoveredID, let anchor = anchors[id] {
                let sourceFrame = geometry[anchor.bounds]
                if sourceFrame.intersects(CGRect(origin: .zero, size: geometry.size)) {
                    WorkbenchHoverTooltipLayout(sourceFrame: sourceFrame, placement: anchor.placement) {
                        WorkbenchHoverTooltipLabel(title: anchor.title)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct WorkbenchHoverTooltipLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: Text

    var body: some View {
        let isDark = colorScheme == .dark
        title
            .font(LitheTheme.uiFont(size: 12))
            .foregroundStyle(isDark ? Color(red: 240.0 / 255, green: 241.0 / 255, blue: 242.0 / 255) : .white)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 9)
            .background(isDark ? Color(red: 57.0 / 255, green: 59.0 / 255, blue: 64.0 / 255)
                               : Color(red: 39.0 / 255, green: 40.0 / 255, blue: 46.0 / 255),
                        in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isDark ? Color(red: 67.0 / 255, green: 69.0 / 255, blue: 74.0 / 255)
                                         : Color(red: 39.0 / 255, green: 40.0 / 255, blue: 46.0 / 255),
                                  lineWidth: 1)
            }
    }
}

struct WorkbenchHoverTooltipLayout: Layout {
    let sourceFrame: CGRect
    let placement: WorkbenchHoverTooltipPlacement

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let tooltip = subviews.first else { return }
        let edgeInset: CGFloat = 8
        let maximumWidth = min(236, max(bounds.width - edgeInset * 2, 0))
        let size = tooltip.sizeThatFits(ProposedViewSize(width: maximumWidth, height: nil))
        let gap: CGFloat = 6
        let preferredOrigin: CGPoint
        switch placement {
        case .above:
            preferredOrigin = CGPoint(x: sourceFrame.midX - size.width / 2, y: sourceFrame.minY - size.height - gap)
        case .below:
            preferredOrigin = CGPoint(x: sourceFrame.midX - size.width / 2, y: sourceFrame.maxY + gap)
        case .leading:
            preferredOrigin = CGPoint(x: sourceFrame.minX - size.width - gap, y: sourceFrame.midY - size.height / 2)
        case .trailing:
            preferredOrigin = CGPoint(x: sourceFrame.maxX + gap, y: sourceFrame.midY - size.height / 2)
        }
        let maximumX = max(edgeInset, bounds.width - size.width - edgeInset)
        let maximumY = max(edgeInset, bounds.height - size.height - edgeInset)
        let origin = CGPoint(
            x: bounds.minX + min(max(preferredOrigin.x, edgeInset), maximumX),
            y: bounds.minY + min(max(preferredOrigin.y, edgeInset), maximumY)
        )
        tooltip.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

extension View {
    func workbenchHoverTooltipScope() -> some View {
        modifier(WorkbenchHoverTooltipScope())
    }

    func workbenchHoverHelp(_ title: Text, placement: WorkbenchHoverTooltipPlacement = .below) -> some View {
        modifier(WorkbenchHoverTooltipSource(title: title, placement: placement))
    }
}
