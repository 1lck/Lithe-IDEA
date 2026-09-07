import AppKit
import SwiftUI
import LitheGitModule

enum GitCommitFileTreeItem: Equatable, Identifiable {
    case folder(GitCommitFileTreeNode, depth: Int)
    case file(GitCommitFile, depth: Int)

    var id: String {
        switch self {
        case let .folder(node, _): "folder:\(node.id)"
        case let .file(file, _): "file:\(file.id)"
        }
    }
}

struct GitCommitFileTreeScrollView: NSViewRepresentable {
    let items: [GitCommitFileTreeItem]
    let selectedFileID: String?
    let rootSubtitle: String?
    let collapsedFolderIDs: Set<String>
    let onToggleFolder: (String) -> Void
    let onSelectFile: (GitCommitFile) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(
            items: items,
            selectedFileID: selectedFileID,
            rootSubtitle: rootSubtitle,
            collapsedFolderIDs: collapsedFolderIDs,
            onToggleFolder: onToggleFolder,
            onSelectFile: onSelectFile
        )
    }

    static func makeScrollView(
        items: [GitCommitFileTreeItem],
        selectedFileID: String?,
        rootSubtitle: String?,
        collapsedFolderIDs: Set<String>,
        onToggleFolder: @escaping (String) -> Void,
        onSelectFile: @escaping (GitCommitFile) -> Void
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

        let documentView = GitCommitFileTreeNSView()
        documentView.autoresizingMask = [.width]
        documentView.update(
            items: items,
            selectedFileID: selectedFileID,
            rootSubtitle: rootSubtitle,
            collapsedFolderIDs: collapsedFolderIDs,
            onToggleFolder: onToggleFolder,
            onSelectFile: onSelectFile
        )
        scrollView.documentView = documentView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let documentView = nsView.documentView as? GitCommitFileTreeNSView else { return }
        let previousOrigin = nsView.contentView.bounds.origin
        let contentChanged = documentView.update(
            items: items,
            selectedFileID: selectedFileID,
            rootSubtitle: rootSubtitle,
            collapsedFolderIDs: collapsedFolderIDs,
            onToggleFolder: onToggleFolder,
            onSelectFile: onSelectFile
        )
        let layoutChanged = documentView.updateLayout(width: nsView.contentView.bounds.width)
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

final class GitCommitFileTreeNSView: NSView {
    static let rowHeight: CGFloat = 28
    private let verticalInset: CGFloat = 5

    private var items: [GitCommitFileTreeItem] = []
    private var selectedFileID: String?
    private var rootSubtitle: String?
    private var collapsedFolderIDs: Set<String> = []
    private var onToggleFolder: ((String) -> Void)?
    private var onSelectFile: ((GitCommitFile) -> Void)?
    private var drawingStyle: DrawingStyle?
    private var hoveredIndex: Int?
    private var lastLayoutWidth: CGFloat = -.greatestFiniteMagnitude

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.outline)
        setAccessibilityLabel(String(localized: "Commit changed files"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @discardableResult
    func update(
        items: [GitCommitFileTreeItem],
        selectedFileID: String?,
        rootSubtitle: String?,
        collapsedFolderIDs: Set<String>,
        onToggleFolder: @escaping (String) -> Void,
        onSelectFile: @escaping (GitCommitFile) -> Void
    ) -> Bool {
        let changed = self.items != items
            || self.selectedFileID != selectedFileID
            || self.rootSubtitle != rootSubtitle
            || self.collapsedFolderIDs != collapsedFolderIDs
        self.items = items
        self.selectedFileID = selectedFileID
        self.rootSubtitle = rootSubtitle
        self.collapsedFolderIDs = collapsedFolderIDs
        self.onToggleFolder = onToggleFolder
        self.onSelectFile = onSelectFile
        setAccessibilityValue(String(format: String(localized: "%lld changed files"), items.count))
        if changed { needsDisplay = true }
        return changed
    }

    @discardableResult
    func updateLayout(width: CGFloat) -> Bool {
        guard width.isFinite, width > 0, width != lastLayoutWidth else { return false }
        lastLayoutWidth = width
        let size = CGSize(
            width: width,
            height: CGFloat(items.count) * Self.rowHeight + verticalInset * 2
        )
        guard frame.size != size else { return false }
        setFrameSize(size)
        needsDisplay = true
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
        guard let index = rowIndex(at: convert(event.locationInWindow, from: nil)),
              items.indices.contains(index) else {
            super.mouseDown(with: event)
            return
        }
        switch items[index] {
        case let .folder(node, _):
            onToggleFolder?(node.id)
        case let .file(file, _):
            onSelectFile?(file)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let range = Self.visibleRowRange(
                itemCount: items.count,
                rowHeight: Self.rowHeight,
                dirtyRect: dirtyRect
              ) else { return }

        let style = resolvedDrawingStyle()
        context.setShouldAntialias(true)
        for index in range {
            let rowRect = rowRect(for: index)
            if index == hoveredIndex {
                context.setFillColor(style.hover.cgColor)
                context.fill(rowRect.insetBy(dx: 4, dy: 1))
            }
            switch items[index] {
            case let .folder(node, depth):
                drawFolder(node, depth: depth, in: rowRect, style: style, context: context)
            case let .file(file, depth):
                drawFile(file, depth: depth, in: rowRect, style: style, context: context)
            }
        }
    }

    static func visibleRowRange(
        itemCount: Int,
        rowHeight: CGFloat,
        dirtyRect: CGRect
    ) -> Range<Int>? {
        guard itemCount > 0, rowHeight > 0, !dirtyRect.isEmpty else { return nil }
        let first = max(0, Int(floor(dirtyRect.minY / rowHeight)))
        let last = min(itemCount - 1, Int(ceil(dirtyRect.maxY / rowHeight)))
        guard first <= last else { return nil }
        return first..<(last + 1)
    }

    private func rowIndex(at point: CGPoint) -> Int? {
        let relativeY = point.y - verticalInset
        guard relativeY >= 0 else { return nil }
        let index = Int(floor(relativeY / Self.rowHeight))
        guard items.indices.contains(index), rowRect(for: index).contains(point) else { return nil }
        return index
    }

    private func rowRect(for index: Int) -> CGRect {
        CGRect(
            x: 0,
            y: verticalInset + CGFloat(index) * Self.rowHeight,
            width: bounds.width,
            height: Self.rowHeight
        )
    }

    private func drawFolder(
        _ node: GitCommitFileTreeNode,
        depth: Int,
        in rect: CGRect,
        style: DrawingStyle,
        context: CGContext
    ) {
        let x = 8 + CGFloat(depth * 16)
        let isCollapsed = collapsedFolderIDs.contains(node.id)
        drawText(isCollapsed ? ">" : "v", in: CGRect(x: x, y: rect.minY, width: 10, height: rect.height), font: style.disclosureFont, color: style.secondaryText)
        drawText(node.name, in: CGRect(x: x + 21, y: rect.minY, width: max(0, rect.width - x - 125), height: rect.height), font: style.mediumFont, color: style.primaryText)
        let countText = node.fileCount == 1 ? String(localized: "1 file") : String(format: String(localized: "%lld files"), node.fileCount)
        drawText(countText, in: CGRect(x: max(x + 95, rect.maxX - 118), y: rect.minY, width: 70, height: rect.height), font: style.metadataFont, color: style.secondaryText, alignment: .right)
        if depth == 0, let rootSubtitle {
            drawText(rootSubtitle, in: CGRect(x: max(x + 170, rect.maxX - 300), y: rect.minY, width: 170, height: rect.height), font: style.metadataFont, color: style.tertiaryText, alignment: .right)
        }
        context.setFillColor(style.divider.cgColor)
        context.fill(CGRect(x: 0, y: rect.maxY - 1, width: rect.width, height: 1))
    }

    private func drawFile(
        _ file: GitCommitFile,
        depth: Int,
        in rect: CGRect,
        style: DrawingStyle,
        context: CGContext
    ) {
        if file.id == selectedFileID {
            context.setFillColor(style.selection.cgColor)
            context.fill(rect.insetBy(dx: 4, dy: 1))
        }
        let x = 30 + CGFloat(max(depth - 1, 0) * 16)
        drawText(file.status, in: CGRect(x: x, y: rect.minY, width: 18, height: rect.height), font: style.statusFont, color: statusColor(file.status, style: style), alignment: .center)
        let title = (file.path as NSString).lastPathComponent
        drawText(title, in: CGRect(x: x + 26, y: rect.minY, width: max(0, rect.width - x - 34), height: rect.height), font: style.bodyFont, color: style.primaryText)
        context.setFillColor(style.divider.cgColor)
        context.fill(CGRect(x: 0, y: rect.maxY - 1, width: rect.width, height: 1))
    }

    private func drawText(
        _ text: String,
        in rect: CGRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        guard rect.width > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        let height = ceil(font.ascender - font.descender)
        let textRect = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        (text as NSString).draw(in: textRect, withAttributes: [
            .font: font,
            .foregroundColor: color,
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

    private func statusColor(_ status: String, style: DrawingStyle) -> NSColor {
        if status.hasPrefix("A") { return style.success }
        if status.hasPrefix("D") { return style.error }
        if status.hasPrefix("R") { return style.accent }
        return style.warning
    }

    private struct DrawingStyle {
        let bodyFont = NSFont.systemFont(ofSize: 13)
        let mediumFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let metadataFont = NSFont.systemFont(ofSize: 12)
        let disclosureFont = NSFont.systemFont(ofSize: 9, weight: .bold)
        let statusFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let primaryText: NSColor
        let secondaryText: NSColor
        let tertiaryText: NSColor
        let accent: NSColor
        let success: NSColor
        let warning: NSColor
        let error: NSColor
        let divider: NSColor
        let hover: NSColor
        let selection: NSColor

        init(isDark: Bool) {
            primaryText = LitheTheme.nsColor(.primaryText, isDark: isDark)
            secondaryText = LitheTheme.nsColor(.secondaryText, isDark: isDark)
            tertiaryText = LitheTheme.nsColor(.secondaryText, isDark: isDark).withAlphaComponent(0.76)
            accent = LitheTheme.nsColor(.accent, isDark: isDark)
            success = LitheTheme.nsColor(.success, isDark: isDark)
            warning = LitheTheme.nsColor(.warning, isDark: isDark)
            error = LitheTheme.nsColor(.error, isDark: isDark)
            divider = LitheTheme.nsColor(.divider, isDark: isDark)
            hover = LitheTheme.nsColor(.toolHeader, isDark: isDark).withAlphaComponent(0.55)
            selection = LitheTheme.nsColor(.accent, isDark: isDark).withAlphaComponent(0.16)
        }
    }
}
