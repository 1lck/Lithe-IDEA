import AppKit
import SwiftUI
import LitheGitModule

/// Native worktree list surface. A single document view lets AppKit move the
/// clip bounds without rebuilding one SwiftUI hierarchy per worktree row.
struct GitWorktreeListScrollView: NSViewRepresentable {
    static let rowHeight: CGFloat = 84
    static let rowSpacing: CGFloat = 7
    static let verticalInset: CGFloat = 10

    let items: [GitWorktreeListItem]
    let selectedWorktreeID: String?
    let onSelect: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(
            items: items,
            selectedWorktreeID: selectedWorktreeID,
            onSelect: onSelect
        )
    }

    static func makeScrollView(
        items: [GitWorktreeListItem],
        selectedWorktreeID: String?,
        onSelect: @escaping (String) -> Void
    ) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .allowed
        scrollView.usesPredominantAxisScrolling = true
        scrollView.scrollsDynamically = true

        let documentView = GitWorktreeListNSView()
        documentView.autoresizingMask = [.width]
        documentView.update(items: items, selectedWorktreeID: selectedWorktreeID, onSelect: onSelect)
        scrollView.documentView = documentView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let documentView = nsView.documentView as? GitWorktreeListNSView else { return }
        let previousOrigin = nsView.contentView.bounds.origin
        let contentChanged = documentView.update(
            items: items,
            selectedWorktreeID: selectedWorktreeID,
            onSelect: onSelect
        )
        let layoutChanged = documentView.updateLayout(width: nsView.contentView.bounds.width)

        // SwiftUI may call updateNSView for every window-resize frame. Avoid a
        // synchronous subtree layout and bounds write unless the document or
        // its content actually changed; AppKit already lays out the clip view
        // after a width change.
        if contentChanged || layoutChanged {
            nsView.contentView.setBoundsOrigin(Self.preservedScrollOrigin(
                previous: previousOrigin,
                documentHeight: documentView.bounds.height,
                viewportHeight: nsView.contentView.bounds.height
            ))
        }
    }

    static func preservedScrollOrigin(
        previous: CGPoint,
        documentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGPoint {
        let maxY = max(0, documentHeight - viewportHeight)
        return CGPoint(x: max(previous.x, 0), y: min(max(previous.y, 0), maxY))
    }
}

final class GitWorktreeListNSView: NSView {
    private var items: [GitWorktreeListItem] = []
    private var selectedWorktreeID: String?
    private var onSelect: ((String) -> Void)?
    private var drawingStyle: DrawingStyle?
    private var hoveredIndex: Int?
    private var lastLayoutWidth: CGFloat = -.greatestFiniteMagnitude

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.list)
        setAccessibilityLabel(String(localized: "Worktrees"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @discardableResult
    func update(
        items: [GitWorktreeListItem],
        selectedWorktreeID: String?,
        onSelect: @escaping (String) -> Void
    ) -> Bool {
        let dataChanged = self.items != items
        let selectionChanged = self.selectedWorktreeID != selectedWorktreeID
        self.items = items
        self.selectedWorktreeID = selectedWorktreeID
        self.onSelect = onSelect
        setAccessibilityValue(String(format: String(localized: "%lld worktrees"), items.count))
        if dataChanged || selectionChanged { needsDisplay = true }
        return dataChanged || selectionChanged
    }

    @discardableResult
    func updateLayout(width: CGFloat) -> Bool {
        guard width.isFinite, width > 0, width != lastLayoutWidth else { return false }
        lastLayoutWidth = width
        let rowStride = GitWorktreeListScrollView.rowHeight + GitWorktreeListScrollView.rowSpacing
        let rowsHeight = max(0, CGFloat(items.count) * rowStride - GitWorktreeListScrollView.rowSpacing)
        let size = CGSize(width: width, height: rowsHeight + GitWorktreeListScrollView.verticalInset * 2)
        guard frame.size != size else { return false }
        setFrameSize(size)
        return true
    }

    override func layout() {
        super.layout()
        _ = updateLayout(width: bounds.width)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        drawingStyle = nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let index = rowIndex(at: convert(event.locationInWindow, from: nil))
        guard hoveredIndex != index else { return }
        if let hoveredIndex { setNeedsDisplay(rowRect(for: hoveredIndex)) }
        hoveredIndex = index
        if let index { setNeedsDisplay(rowRect(for: index)) }
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredIndex != nil else { return }
        if let hoveredIndex { setNeedsDisplay(rowRect(for: hoveredIndex)) }
        hoveredIndex = nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point), items.indices.contains(index) else {
            super.mouseDown(with: event)
            return
        }
        onSelect?(items[index].id)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let range = Self.visibleRowRange(
                rowCount: items.count,
                rowHeight: GitWorktreeListScrollView.rowHeight,
                rowSpacing: GitWorktreeListScrollView.rowSpacing,
                inset: GitWorktreeListScrollView.verticalInset,
                dirtyRect: dirtyRect
              ) else { return }

        let style = resolvedDrawingStyle()
        context.setShouldAntialias(true)
        for index in range {
            let item = items[index]
            let rect = rowRect(for: index)
            let isSelected = item.id == selectedWorktreeID
            let isHovered = index == hoveredIndex
            let background = isSelected ? style.selection : (isHovered ? style.hover : style.raised)
            background.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            (isSelected ? style.focusBorder : style.panelBorder).setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            border.lineWidth = 1
            border.stroke()

            drawRow(item, in: rect.insetBy(dx: 12, dy: 9), style: style, context: context)
        }
    }

    static func visibleRowRange(
        rowCount: Int,
        rowHeight: CGFloat,
        rowSpacing: CGFloat,
        inset: CGFloat,
        dirtyRect: NSRect
    ) -> Range<Int>? {
        guard rowCount > 0, rowHeight > 0, rowSpacing >= 0 else { return nil }
        let stride = rowHeight + rowSpacing
        let first = max(0, Int(floor((dirtyRect.minY - inset) / stride)))
        let last = min(rowCount - 1, Int(ceil((dirtyRect.maxY - inset) / stride)))
        guard first <= last else { return nil }
        return first..<(last + 1)
    }

    private func rowIndex(at point: CGPoint) -> Int? {
        let stride = GitWorktreeListScrollView.rowHeight + GitWorktreeListScrollView.rowSpacing
        let relativeY = point.y - GitWorktreeListScrollView.verticalInset
        guard relativeY >= 0 else { return nil }
        let index = Int(floor(relativeY / stride))
        guard items.indices.contains(index), rowRect(for: index).contains(point) else { return nil }
        return index
    }

    private func rowRect(for index: Int) -> CGRect {
        let stride = GitWorktreeListScrollView.rowHeight + GitWorktreeListScrollView.rowSpacing
        return CGRect(
            x: 0,
            y: GitWorktreeListScrollView.verticalInset + CGFloat(index) * stride,
            width: bounds.width,
            height: GitWorktreeListScrollView.rowHeight
        )
    }

    private func drawRow(
        _ item: GitWorktreeListItem,
        in rect: CGRect,
        style: DrawingStyle,
        context: CGContext
    ) {
        let worktree = item.worktree
        let title = worktree.isPrimary ? String(localized: "Main Worktree") : worktree.displayName
        drawText(title, in: CGRect(x: rect.minX, y: rect.minY, width: max(0, rect.width - 175), height: 18), style: style.title)
        if worktree.isPrimary {
            drawText("♛", in: CGRect(x: rect.minX + 128, y: rect.minY, width: 16, height: 18), style: style.warning)
        }
        if worktree.isCurrent {
            drawText(String(localized: "Current"), in: CGRect(x: max(rect.minX + 145, rect.maxX - 145), y: rect.minY, width: 64, height: 18), style: style.accent)
        }
        let statusTitle = statusTitle(for: item.status)
        let statusRect = CGRect(x: max(rect.minX + 150, rect.maxX - 92), y: rect.minY, width: 78, height: 18)
        context.setFillColor(statusColor(for: item.status, style: style).cgColor)
        context.fillEllipse(in: CGRect(x: statusRect.minX, y: statusRect.midY - 4, width: 8, height: 8))
        drawText(statusTitle, in: CGRect(x: statusRect.minX + 12, y: statusRect.minY, width: 66, height: statusRect.height), style: style.metadata)
        drawText("⋯", in: CGRect(x: rect.maxX - 17, y: rect.minY - 1, width: 17, height: 18), style: style.tertiary, alignment: .right)

        drawText(worktree.path, in: CGRect(x: rect.minX, y: rect.minY + 23, width: rect.width, height: 17), style: style.path, lineBreakMode: .byTruncatingMiddle)
        let branch = worktree.branchName ?? String(localized: "Detached HEAD")
        drawText(String(format: String(localized: "Branch: %@"), branch), in: CGRect(x: rect.minX, y: rect.minY + 45, width: rect.width, height: 17), style: style.path)
    }

    private func drawText(_ text: String, in rect: CGRect, style: TextStyle, lineBreakMode: NSLineBreakMode? = nil, alignment: NSTextAlignment? = nil) {
        guard rect.width > 0 else { return }
        let paragraph = lineBreakMode == nil && alignment == nil
            ? style.paragraph
            : style.paragraph.with(lineBreakMode: lineBreakMode ?? style.paragraph.lineBreakMode, alignment: alignment ?? style.paragraph.alignment)
        let textRect = CGRect(x: rect.minX, y: rect.midY - style.height / 2, width: rect.width, height: style.height)
        (text as NSString).draw(in: textRect, withAttributes: [
            .font: style.font,
            .foregroundColor: style.color,
            .paragraphStyle: paragraph
        ])
    }

    private func resolvedDrawingStyle() -> DrawingStyle {
        if let drawingStyle { return drawingStyle }
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let style = DrawingStyle(isDark: isDark)
        drawingStyle = style
        return style
    }

    private func statusTitle(for status: GitWorktreeStatusKind) -> String {
        switch status {
        case .pathMissing: String(localized: "Path Missing")
        case .locked: String(localized: "Locked")
        case .modified: String(localized: "Modified")
        case .current: String(localized: "Current")
        case .available: String(localized: "Available")
        }
    }

    private func statusColor(for status: GitWorktreeStatusKind, style: DrawingStyle) -> NSColor {
        switch status {
        case .pathMissing: style.error
        case .locked, .modified: style.warningColor
        case .current, .available: style.success
        }
    }

    private struct DrawingStyle {
        let title: TextStyle
        let metadata: TextStyle
        let path: TextStyle
        let accent: TextStyle
        let warning: TextStyle
        let tertiary: TextStyle
        let primary: NSColor
        let secondary: NSColor
        let raised: NSColor
        let selection: NSColor
        let hover: NSColor
        let panelBorder: NSColor
        let focusBorder: NSColor
        let success: NSColor
        let warningColor: NSColor
        let error: NSColor

        init(isDark: Bool) {
            primary = LitheTheme.nsColor(.primaryText, isDark: isDark)
            secondary = LitheTheme.nsColor(.secondaryText, isDark: isDark)
            raised = LitheTheme.nsColor(.sidebar, isDark: isDark)
            selection = LitheTheme.nsColor(.accent, isDark: isDark).withAlphaComponent(0.16)
            hover = LitheTheme.nsColor(.toolHeader, isDark: isDark).withAlphaComponent(0.55)
            panelBorder = LitheTheme.nsColor(.divider, isDark: isDark)
            focusBorder = LitheTheme.nsColor(.accent, isDark: isDark)
            success = LitheTheme.nsColor(.success, isDark: isDark)
            warningColor = LitheTheme.nsColor(.warning, isDark: isDark)
            error = LitheTheme.nsColor(.error, isDark: isDark)
            title = TextStyle(font: .systemFont(ofSize: 13, weight: .medium), color: primary)
            metadata = TextStyle(font: .systemFont(ofSize: 12.5), color: primary)
            path = TextStyle(font: .systemFont(ofSize: 12.5), color: secondary)
            accent = TextStyle(font: .systemFont(ofSize: 12.5), color: LitheTheme.nsColor(.accent, isDark: isDark))
            warning = TextStyle(font: .systemFont(ofSize: 11), color: warningColor)
            tertiary = TextStyle(font: .systemFont(ofSize: 17), color: secondary.withAlphaComponent(0.8))
        }
    }

    private struct TextStyle {
        let font: NSFont
        let color: NSColor
        let paragraph: NSParagraphStyle
        let height: CGFloat

        init(font: NSFont, color: NSColor, paragraph: NSParagraphStyle? = nil) {
            self.font = font
            self.color = color
            if let paragraph {
                self.paragraph = paragraph
            } else {
                let truncatingParagraph = NSMutableParagraphStyle()
                truncatingParagraph.lineBreakMode = .byTruncatingTail
                self.paragraph = truncatingParagraph
            }
            height = ceil(font.ascender - font.descender)
        }
    }
}

private extension NSParagraphStyle {
    func with(lineBreakMode: NSLineBreakMode, alignment: NSTextAlignment) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.setParagraphStyle(self)
        paragraph.lineBreakMode = lineBreakMode
        paragraph.alignment = alignment
        return paragraph
    }
}
