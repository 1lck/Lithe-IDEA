import SwiftUI
import LitheGitModule

/// Whole-file change overview drawn beside the scrollbar, like IDEA's diff map.
///
/// A tall diff shows only its current viewport, so there is no way to see where
/// the remaining changes sit or how many are left. This compresses every row
/// into one narrow strip: each change becomes a tick at its relative position,
/// and clicking a tick scrolls to that row.
struct DiffMapView: View {
    /// One contiguous run of same-kind changes, positioned in [0, 1].
    struct Marker: Identifiable {
        let id: DiffRowID
        let kind: DiffRowKind
        /// Fraction of the way down the file where the run starts.
        let start: Double
        /// Fraction of the file the run spans. Never zero, so single-line
        /// changes stay visible instead of collapsing to nothing.
        let extent: Double
    }

    let rows: [DiffRow]
    /// Where the viewport currently sits, in [0, 1], or nil while unknown.
    var visibleRange: ClosedRange<Double>?
    let onSelect: (DiffRowID) -> Void

    static let width: CGFloat = 14

    /// Smallest fraction of the strip a marker may occupy. Below roughly this,
    /// a tick stops being clickable at typical pane heights.
    static let minimumExtent: Double = 0.004

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack(alignment: .top) {
                LitheTheme.window

                if let visibleRange {
                    // The viewport shade reads as "you are here" against the ticks.
                    Rectangle()
                        .fill(LitheTheme.subtleSelection)
                        .frame(height: max(6, CGFloat(visibleRange.upperBound - visibleRange.lowerBound) * height))
                        .offset(y: CGFloat(visibleRange.lowerBound) * height)
                }

                ForEach(markers) { marker in
                    Rectangle()
                        .fill(color(for: marker.kind))
                        .frame(height: max(2, CGFloat(marker.extent) * height))
                        .padding(.horizontal, 3)
                        .offset(y: CGFloat(marker.start) * height)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(marker.id) }
                        .lithePointer()
                }
            }
            .frame(width: Self.width)
        }
        .frame(width: Self.width)
        .accessibilityLabel("Diff overview")
        .accessibilityValue(accessibilitySummary)
    }

    /// Groups adjacent same-kind change rows so a 40-line block draws as one
    /// band rather than 40 abutting ticks.
    var markers: [Marker] {
        guard !rows.isEmpty else { return [] }
        let total = Double(rows.count)

        var markers: [Marker] = []
        var index = 0
        while index < rows.count {
            let kind = rows[index].kind
            guard kind != .context, kind != .information else {
                index += 1
                continue
            }

            let start = index
            while index < rows.count, rows[index].kind == kind {
                index += 1
            }

            markers.append(
                Marker(
                    id: rows[start].id,
                    kind: kind,
                    start: Double(start) / total,
                    extent: max(Self.minimumExtent, Double(index - start) / total)
                )
            )
        }
        return markers
    }

    private var accessibilitySummary: String {
        let count = markers.count
        return count == 1 ? "1 change" : "\(count) changes"
    }

    private func color(for kind: DiffRowKind) -> Color {
        switch kind {
        case .addition: return LitheTheme.success.opacity(0.9)
        case .removal: return .red.opacity(0.8)
        case .changed: return LitheTheme.accent.opacity(0.9)
        case .context, .information: return .clear
        }
    }
}
