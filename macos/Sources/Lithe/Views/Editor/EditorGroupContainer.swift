import SwiftUI

let editorWorkspaceCoordinateSpaceName = "lithe.editor-workspace"

@MainActor
final class EditorGroupDragState: ObservableObject {
    struct Target: Equatable {
        let group: UUID
        let side: EditorGroupDropSide
        let frame: CGRect
    }
    var frames: [UUID: CGRect] = [:]
    var tabFrames: [UUID: CGRect] = [:]
    private var dragTabFrames: [UUID: CGRect] = [:]
    private var dragFrames: [UUID: CGRect] = [:]
    @Published var target: Target?
    func begin() { dragFrames = frames; dragTabFrames = tabFrames; target = nil }
    func finish() { target = nil; dragFrames = [:]; dragTabFrames = [:] }

    func destination(at point: CGPoint, sourceGroup: UUID) -> Target? {
        guard let (group, fullFrame) = dragFrames.first(where: { $0.value.contains(point) }) else { return nil }
        // The tab strip remains a reorder/move target, never a split edge.
        guard let tabFrame = dragTabFrames[group] else { return nil }
        guard point.y > tabFrame.maxY else {
            return group == sourceGroup ? nil : .init(group: group, side: .center, frame: fullFrame)
        }
        let frame = CGRect(x: fullFrame.minX, y: tabFrame.maxY, width: fullFrame.width, height: max(0, fullFrame.maxY - tabFrame.maxY))
        guard frame.width > 0, frame.height > 0 else { return nil }
        let x = (point.x - frame.minX) / frame.width
        let y = (point.y - frame.minY) / frame.height
        let edges: [(EditorGroupDropSide, CGFloat)] = [(.right, 1 - x), (.left, x), (.bottom, 1 - y), (.top, y)]
        guard let nearest = edges.min(by: { $0.1 < $1.1 }) else { return nil }
        // TabsUtil trapezoids: normalized nearest edge, Registry dragToSplitRatio = 0.2.
        let side = nearest.1 < 0.2 ? nearest.0 : .center
        if side == .center && group == sourceGroup { return nil }
        var preview = frame
        switch side {
        case .left: preview.size.width /= 2
        case .right: preview.origin.x += preview.width / 2; preview.size.width /= 2
        case .top: preview.size.height /= 2
        case .bottom: preview.origin.y += preview.height / 2; preview.size.height /= 2
        case .center: break
        }
        return .init(group: group, side: side, frame: preview)
    }
}

struct EditorGroupContainer: View {
    @ObservedObject var feature: EditorTabOrderFeatureModel
    @ObservedObject var drag: EditorGroupDragState
    var body: some View {
        pane(feature.groupLayout)
            .coordinateSpace(name: editorWorkspaceCoordinateSpaceName)
            .onPreferenceChange(EditorGroupFramePreference.self) { drag.frames = $0 }
            .onPreferenceChange(EditorGroupTabFramePreference.self) { drag.tabFrames = $0 }
            .overlay(alignment: .topLeading) {
                if let target = drag.target {
                    Rectangle().fill(LitheTheme.editorTabDropBackground)
                        .frame(width: target.frame.width, height: target.frame.height)
                        .offset(x: target.frame.minX, y: target.frame.minY)
                        .allowsHitTesting(false)
                }
            }
    }

    private func pane(_ layout: EditorGroupLayout) -> AnyView {
        switch layout {
        case .group(let id):
            return AnyView(EditorAreaView(groupID: id, groupDrag: drag)
                .id(id)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: EditorGroupFramePreference.self,
                        value: [id: geometry.frame(in: .named(editorWorkspaceCoordinateSpaceName))])
                }))
        case .split(let id, let vertical, let first, let second):
            return AnyView(EditorGroupSplit(vertical: vertical, first: pane(first), second: pane(second)).id(id))
        }
    }
}

private struct EditorGroupSplit: View {
    let vertical: Bool
    let first: AnyView
    let second: AnyView
    @State private var fraction = 0.5
    var body: some View {
        GeometryReader { geometry in
            let length = vertical ? geometry.size.height : geometry.size.width
            let minimum = min(CGFloat(WorkbenchLayout.minimumPaneSize), max(0, length / 2))
            LitheSplitPaneView(axis: vertical ? .vertical : .horizontal, placement: .leading,
                defaultSize: length * fraction, minimum: minimum,
                maximum: max(minimum, length - minimum - SplitHandleView.thickness), flexibleMinimum: minimum,
                clipsSizedPane: true, onCommit: { if length > 0 { fraction = $0 / length } },
                sized: { first }, flexible: { second })
        }
    }
}

private struct EditorGroupFramePreference: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct EditorGroupTabFramePreference: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
