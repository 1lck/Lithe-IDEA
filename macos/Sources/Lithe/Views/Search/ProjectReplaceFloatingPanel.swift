import AppKit
import SwiftUI

/// Keeps moving and resizing state local; the workbench supplies already-built content.
struct ProjectReplaceFloatingPanel<Content: View>: View {
    private let content: Content
    @State private var storedFrame: CGRect?
    @State private var dragStart: CGRect?

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let frame = ProjectReplacePanelGeometry.constrained(storedFrame ?? CGRect(
                x: (geometry.size.width - 650) / 2,
                y: (geometry.size.height - 614) / 2,
                width: 650, height: 614
            ), in: geometry.size)
            content
                .frame(width: frame.width, height: frame.height)
                .overlay(alignment: .topLeading) {
                    Color.clear
                        .frame(width: max(0, frame.width - 260), height: 38)
                        .contentShape(Rectangle())
                        .gesture(drag(frame: frame, viewport: geometry.size, corner: nil))
                        .help("Drag to move")
                        .accessibilityLabel("Move Replace in Files dialog")
                }
                .overlay {
                    ForEach(ProjectReplacePanelGeometry.Corner.allCases, id: \.self) { corner in
                        ProjectReplaceCornerHandle(
                            corner: corner,
                            onStart: { dragStart = frame },
                            onChange: { translation in
                                storedFrame = ProjectReplacePanelGeometry.updated(
                                    dragStart ?? frame, translation: translation, corner: corner, in: geometry.size
                                )
                            },
                            onEnd: { translation in
                                storedFrame = ProjectReplacePanelGeometry.updated(
                                    dragStart ?? frame, translation: translation, corner: corner, in: geometry.size
                                )
                                dragStart = nil
                            }
                        )
                            .frame(width: 18, height: 18)
                            .help("Drag corner to resize")
                            .accessibilityLabel("Resize dialog, \(corner.rawValue)")
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                    }
                }
                .position(x: frame.midX, y: frame.midY)
                .onChange(of: geometry.size) { size in
                    storedFrame = ProjectReplacePanelGeometry.constrained(frame, in: size)
                    dragStart = nil
                }
        }
    }

    private func drag(frame: CGRect, viewport: CGSize, corner: ProjectReplacePanelGeometry.Corner?) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if dragStart == nil { dragStart = frame }
                let next = ProjectReplacePanelGeometry.updated(
                    dragStart ?? frame, translation: value.translation, corner: corner, in: viewport
                )
                // Filter sub-point motion so pointer jitter does not trigger layout updates.
                if abs(next.minX - frame.minX) >= 1 || abs(next.minY - frame.minY) >= 1 ||
                    abs(next.width - frame.width) >= 1 || abs(next.height - frame.height) >= 1 {
                    storedFrame = next
                }
            }
            .onEnded { value in
                storedFrame = ProjectReplacePanelGeometry.updated(
                    dragStart ?? frame, translation: value.translation, corner: corner, in: viewport
                )
                dragStart = nil
            }
    }
}

enum ProjectReplacePanelGeometry {
    enum Corner: String, CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var alignment: Alignment {
            switch self {
            case .topLeading: .topLeading
            case .topTrailing: .topTrailing
            case .bottomLeading: .bottomLeading
            case .bottomTrailing: .bottomTrailing
            }
        }
        var isLeading: Bool { self == .topLeading || self == .bottomLeading }
        var isTop: Bool { self == .topLeading || self == .topTrailing }
    }

    static let minimum = CGSize(width: 520, height: 400)

    static func constrained(_ frame: CGRect, in viewport: CGSize) -> CGRect {
        let width = min(max(frame.width, minimum.width), max(0, viewport.width))
        let height = min(max(frame.height, minimum.height), max(0, viewport.height))
        return CGRect(
            x: min(max(0, frame.minX), max(0, viewport.width - width)),
            y: min(max(0, frame.minY), max(0, viewport.height - height)),
            width: width, height: height
        )
    }

    static func updated(_ start: CGRect, translation: CGSize, corner: Corner?, in viewport: CGSize) -> CGRect {
        guard let corner else {
            return constrained(start.offsetBy(dx: translation.width, dy: translation.height), in: viewport)
        }
        let start = constrained(start, in: viewport)
        let minWidth = min(minimum.width, viewport.width)
        let minHeight = min(minimum.height, viewport.height)
        let left = corner.isLeading ? min(max(0, start.minX + translation.width), start.maxX - minWidth) : start.minX
        let right = corner.isLeading ? start.maxX : max(min(viewport.width, start.maxX + translation.width), start.minX + minWidth)
        let top = corner.isTop ? min(max(0, start.minY + translation.height), start.maxY - minHeight) : start.minY
        let bottom = corner.isTop ? start.maxY : max(min(viewport.height, start.maxY + translation.height), start.minY + minHeight)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
