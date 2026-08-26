import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The small amount of state needed to make a tab drag observable and
/// cancellable from the surrounding SwiftUI view.
struct EditorTabDragState: Equatable {
    /// Identifies one tab-reorder gesture. A stale DropDelegate callback from
    /// a previous session must never mutate the next session's state.
    var sessionID: UUID?
    var draggedItem: EditorTabItem?
    var dropTarget: EditorTabDropTarget?
    /// Incremented whenever the current target changes. This lets us ignore
    /// dropExited callbacks emitted by a tab view that was rebuilt during
    /// flow-layout reordering.
    var dropTargetRevision: UInt

    static let idle = EditorTabDragState(
        sessionID: nil,
        draggedItem: nil,
        dropTarget: nil,
        dropTargetRevision: 0
    )

    var draggedDocumentID: UUID? {
        guard let draggedItem,
              case .document(let documentID) = draggedItem else { return nil }
        return documentID
    }

    mutating func begin(documentID: UUID) {
        begin(item: .document(documentID))
    }

    mutating func begin(item: EditorTabItem) {
        sessionID = UUID()
        draggedItem = item
        dropTarget = nil
        dropTargetRevision = 0
    }

    mutating func updateTarget(_ target: EditorTabDropTarget) {
        guard dropTarget != target else { return }
        dropTarget = target
        dropTargetRevision &+= 1
    }

    mutating func clearTarget(
        documentID: UUID,
        sessionID: UUID?,
        revision: UInt
    ) -> Bool {
        guard self.sessionID == sessionID,
              dropTargetRevision == revision,
              dropTarget?.documentID == documentID else { return false }
        dropTarget = nil
        dropTargetRevision &+= 1
        return true
    }

    mutating func finish() {
        self = .idle
    }
}

struct EditorTabDropTarget: Equatable {
    let documentID: UUID
    let side: EditorTabDropSide
}

struct EditorTabReorderTarget: Equatable {
    let item: EditorTabItem
    let side: EditorTabDropSide
}

enum EditorTabDropSide: Equatable {
    case before
    case after
}

/// Keeps live tab reordering away from the midpoint where layout changes can
/// otherwise make the pointer oscillate between before and after.
enum EditorTabDropGeometry {
    static let hoverDeadZoneRatio: CGFloat = 0.10

    static func hoverSide(locationX: CGFloat, width: CGFloat) -> EditorTabDropSide? {
        guard width > 0 else { return nil }
        let midpoint = width / 2
        let deadZone = width * hoverDeadZoneRatio
        if locationX < midpoint - deadZone { return .before }
        if locationX > midpoint + deadZone { return .after }
        return nil
    }

    static func finalSide(locationX: CGFloat, width: CGFloat) -> EditorTabDropSide {
        width > 0 && locationX > width / 2 ? .after : .before
    }
}

enum EditorTabDragPayload {
    static let type = UTType(exportedAs: "com.lithe.editor-tab")

    static func provider(for documentID: UUID) -> NSItemProvider {
        // Supplying a standard text representation as well as the private
        // payload gives AppKit a concrete dragging item to snapshot, while the
        // private type keeps tab reordering limited to this app process.
        let provider = NSItemProvider(object: documentID.uuidString as NSString)
        let data = Data(documentID.uuidString.utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: type.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

struct EditorTabFlowItem: Equatable {
    let index: Int
    let width: CGFloat
}

struct EditorTabFlowRow: Equatable {
    let items: [EditorTabFlowItem]
    let width: CGFloat
    let height: CGFloat
}

/// Pure row planning keeps the wrapping behavior deterministic and testable
/// without constructing a full SwiftUI hierarchy.
enum EditorTabFlowPlanner {
    static func height(
        for rows: [EditorTabFlowRow],
        verticalSpacing: CGFloat
    ) -> CGFloat {
        rows.reduce(into: CGFloat.zero) { result, row in
            result += row.height
        } + max(0, CGFloat(rows.count - 1)) * verticalSpacing
    }

    static func rows(
        for sizes: [CGSize],
        availableWidth: CGFloat,
        horizontalSpacing: CGFloat,
        minimumItemWidth: CGFloat = 1
    ) -> [EditorTabFlowRow] {
        guard !sizes.isEmpty else { return [] }

        // A very narrow window cannot honor the preferred minimum width. In
        // that case, keep the tab inside the available bounds and let the
        // title truncate instead of allowing the layout to overflow.
        let widthLimit = max(availableWidth, 1)
        var rows: [EditorTabFlowRow] = []
        var currentItems: [EditorTabFlowItem] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        func appendCurrentRow() {
            guard !currentItems.isEmpty else { return }
            rows.append(
                EditorTabFlowRow(
                    items: currentItems,
                    width: currentWidth,
                    height: currentHeight
                )
            )
            currentItems = []
            currentWidth = 0
            currentHeight = 0
        }

        for (index, size) in sizes.enumerated() {
            let itemWidth = min(max(size.width, minimumItemWidth), widthLimit)
            let itemHeight = max(size.height, 1)
            let spacing = currentItems.isEmpty ? 0 : horizontalSpacing
            let nextWidth = currentWidth + spacing + itemWidth

            if !currentItems.isEmpty, nextWidth > widthLimit {
                appendCurrentRow()
            }

            let rowSpacing = currentItems.isEmpty ? 0 : horizontalSpacing
            currentItems.append(
                EditorTabFlowItem(
                    index: index,
                    width: itemWidth
                )
            )
            currentWidth += rowSpacing + itemWidth
            currentHeight = max(currentHeight, itemHeight)
        }

        appendCurrentRow()
        return rows
    }
}

/// A compact, intrinsic-width wrapping layout for editor tabs. Unlike an
/// adaptive LazyVGrid, every tab keeps its own measured width and wraps only
/// when the next tab no longer fits on the current row.
struct EditorTabFlowLayout: Layout {
    static let minimumItemWidth: CGFloat = 154

    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    init(horizontalSpacing: CGFloat = 4, verticalSpacing: CGFloat = 2) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    struct Cache {
        var sizes: [CGSize]
        var rows: [EditorTabFlowRow] = []
        var availableWidth: CGFloat = -1
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.rows = []
        cache.availableWidth = -1
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let width = proposal.width ?? naturalWidth(for: cache.sizes)
        let rows = rows(for: width, cache: &cache)

        return CGSize(
            width: proposal.width ?? rows.map(\.width).max() ?? 0,
            height: EditorTabFlowPlanner.height(
                for: rows,
                verticalSpacing: verticalSpacing
            )
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let rows = rows(for: max(bounds.width, 1), cache: &cache)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(
                        width: item.width,
                        height: row.height
                    )
                )
                x += item.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private func rows(for width: CGFloat, cache: inout Cache) -> [EditorTabFlowRow] {
        guard cache.availableWidth != width || cache.rows.isEmpty else {
            return cache.rows
        }
        cache.rows = EditorTabFlowPlanner.rows(
            for: cache.sizes,
            availableWidth: width,
            horizontalSpacing: horizontalSpacing,
            minimumItemWidth: Self.minimumItemWidth
        )
        cache.availableWidth = width
        return cache.rows
    }

    private func naturalWidth(for sizes: [CGSize]) -> CGFloat {
        guard !sizes.isEmpty else { return 0 }
        let itemWidths = sizes.map { max($0.width, Self.minimumItemWidth) }
        return itemWidths.reduce(0, +)
            + CGFloat(max(0, itemWidths.count - 1)) * horizontalSpacing
    }
}
