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
        let scrollView = GitCommitFileTreeScrollNSView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .allowed
        scrollView.usesPredominantAxisScrolling = true
        scrollView.scrollsDynamically = true

        let documentView = GitCommitFileTreeNSView()
        documentView.autoresizingMask = []
        documentView.update(
            items: items,
            selectedFileID: selectedFileID,
            rootSubtitle: rootSubtitle,
            collapsedFolderIDs: collapsedFolderIDs,
            onToggleFolder: onToggleFolder,
            onSelectFile: onSelectFile
        )
        scrollView.documentView = documentView
        scrollView.updateDocumentLayout()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let documentView = nsView.documentView as? GitCommitFileTreeNSView else { return }
        documentView.update(
            items: items,
            selectedFileID: selectedFileID,
            rootSubtitle: rootSubtitle,
            collapsedFolderIDs: collapsedFolderIDs,
            onToggleFolder: onToggleFolder,
            onSelectFile: onSelectFile
        )
        (nsView as? GitCommitFileTreeScrollNSView)?.updateDocumentLayout()
    }

    static func preservedScrollOrigin(
        previous: CGPoint,
        documentHeight: CGFloat,
        viewportHeight: CGFloat,
        documentWidth: CGFloat,
        viewportWidth: CGFloat
    ) -> CGPoint {
        let maxY = max(0, documentHeight - viewportHeight)
        let maxX = max(0, documentWidth - viewportWidth)
        return CGPoint(x: min(max(previous.x, 0), maxX), y: min(max(previous.y, 0), maxY))
    }
}

final class GitCommitFileTreeScrollNSView: NSScrollView {
    override func layout() {
        super.layout()
        updateDocumentLayout()
    }

    func updateDocumentLayout() {
        guard let documentView = documentView as? GitCommitFileTreeNSView else { return }
        let previousOrigin = contentView.bounds.origin
        guard documentView.updateLayout(width: contentView.bounds.width) else { return }
        contentView.setBoundsOrigin(GitCommitFileTreeScrollView.preservedScrollOrigin(
            previous: previousOrigin,
            documentHeight: documentView.bounds.height,
            viewportHeight: contentView.bounds.height,
            documentWidth: documentView.bounds.width,
            viewportWidth: contentView.bounds.width
        ))
        reflectScrolledClipView(contentView)
    }
}

final class GitCommitFileTreeNSView: NSControl {
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
    private var rowPresentations: [RowPresentation] = []
    private var contentWidth: CGFloat = 0
    private var hoverTrackingArea: NSTrackingArea?

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowsExpansionToolTips = true
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
        let contentChanged = self.items != items || self.rootSubtitle != rootSubtitle
        let changed = contentChanged
            || self.selectedFileID != selectedFileID
            || self.collapsedFolderIDs != collapsedFolderIDs
        self.items = items
        self.selectedFileID = selectedFileID
        self.rootSubtitle = rootSubtitle
        self.collapsedFolderIDs = collapsedFolderIDs
        self.onToggleFolder = onToggleFolder
        self.onSelectFile = onSelectFile
        setAccessibilityValue(String(format: String(localized: "%lld changed files"), items.count))
        if contentChanged {
            rebuildRowPresentations()
            hoveredIndex = nil
        }
        if changed { needsDisplay = true }
        return changed
    }

    @discardableResult
    func updateLayout(width: CGFloat) -> Bool {
        guard width.isFinite, width >= 0 else { return false }
        let size = CGSize(
            width: max(width, contentWidth),
            height: CGFloat(items.count) * Self.rowHeight + verticalInset * 2
        )
        guard frame.size != size else { return false }
        setFrameSize(size)
        needsDisplay = true
        return true
    }

    override func layout() {
        super.layout()
        _ = updateLayout(width: enclosingScrollView?.contentView.bounds.width ?? bounds.width)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        drawingStyle = nil
        rebuildRowPresentations()
        enclosingScrollView?.needsLayout = true
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        hoverTrackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    private func updateHover(at point: CGPoint) {
        let index = rowIndex(at: point)
        guard hoveredIndex != index else { return }
        if let hoveredIndex { setNeedsDisplay(rowRect(for: hoveredIndex)) }
        hoveredIndex = index
        if let index { setNeedsDisplay(rowRect(for: index)) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
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

    override func expansionFrame(withFrame contentFrame: NSRect) -> NSRect {
        guard let hoveredIndex, rowPresentations.indices.contains(hoveredIndex) else { return .zero }
        let presentation = rowPresentations[hoveredIndex]
        let row = rowRect(for: hoveredIndex)
        let titleRect = CGRect(x: presentation.textX, y: row.minY, width: presentation.textWidth, height: row.height)
        guard titleRect.intersects(visibleRect), !visibleRect.contains(titleRect) else { return .zero }
        return titleRect
    }

    override func draw(withExpansionFrame contentFrame: NSRect, in view: NSView) {
        guard let hoveredIndex, rowPresentations.indices.contains(hoveredIndex) else { return }
        let presentation = rowPresentations[hoveredIndex]
        let style = resolvedDrawingStyle()
        style.background.setFill()
        contentFrame.fill()
        drawText(presentation.title, in: contentFrame, font: presentation.font)
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
                drawFolder(node, depth: depth, presentation: rowPresentations[index], in: rowRect, style: style, context: context)
            case let .file(file, depth):
                drawFile(file, depth: depth, presentation: rowPresentations[index], in: rowRect, style: style, context: context)
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
        presentation: RowPresentation,
        in rect: CGRect,
        style: DrawingStyle,
        context: CGContext
    ) {
        let x = 8 + CGFloat(depth * 16)
        let isCollapsed = collapsedFolderIDs.contains(node.id)
        drawText(isCollapsed ? ">" : "v", in: CGRect(x: x, y: rect.minY, width: 10, height: rect.height), font: style.disclosureFont, color: style.secondaryText)
        drawText(
            presentation.title,
            in: CGRect(x: presentation.textX, y: rect.minY, width: presentation.textWidth, height: rect.height),
            font: presentation.font
        )
        context.setFillColor(style.divider.cgColor)
        context.fill(CGRect(x: 0, y: rect.maxY - 1, width: rect.width, height: 1))
    }

    private func drawFile(
        _ file: GitCommitFile,
        depth: Int,
        presentation: RowPresentation,
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
        drawText(
            presentation.title,
            in: CGRect(x: presentation.textX, y: rect.minY, width: presentation.textWidth, height: rect.height),
            font: presentation.font
        )
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
        drawText(
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]),
            in: rect,
            font: font,
            alignment: alignment
        )
    }

    private func drawText(
        _ text: NSAttributedString,
        in rect: CGRect,
        font: NSFont,
        alignment: NSTextAlignment = .left
    ) {
        guard rect.width > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.alignment = alignment
        let height = ceil(font.ascender - font.descender)
        let textRect = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        let attributedText = NSMutableAttributedString(attributedString: text)
        attributedText.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributedText.length))
        NSGraphicsContext.saveGraphicsState()
        textRect.clip()
        attributedText.draw(in: textRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    private struct RowPresentation {
        let title: NSAttributedString
        let font: NSFont
        let textX: CGFloat
        let textWidth: CGFloat
    }

    private func rebuildRowPresentations() {
        let style = resolvedDrawingStyle()
        // Intrinsic widths depend on content and fonts, never on the viewport.
        // Scrolling and splitter drags only move or resize the native clip view.
        rowPresentations = items.map { item in
            let title: NSMutableAttributedString
            let font: NSFont
            let textX: CGFloat
            switch item {
            case let .folder(node, depth):
                font = style.mediumFont
                textX = 29 + CGFloat(depth * 16)
                title = NSMutableAttributedString(string: node.name, attributes: [
                    .font: font, .foregroundColor: style.primaryText
                ])
                let count = node.fileCount == 1 ? String(localized: "1 file") : String(format: String(localized: "%lld files"), node.fileCount)
                title.append(NSAttributedString(string: "  \(count)", attributes: [
                    .font: style.metadataFont, .foregroundColor: style.secondaryText
                ]))
                if depth == 0, let rootSubtitle, !rootSubtitle.isEmpty {
                    title.append(NSAttributedString(string: "  \(rootSubtitle)", attributes: [
                        .font: style.metadataFont, .foregroundColor: style.tertiaryText
                    ]))
                }
            case let .file(file, depth):
                font = style.bodyFont
                textX = 56 + CGFloat(max(depth - 1, 0) * 16)
                title = NSMutableAttributedString(string: (file.path as NSString).lastPathComponent, attributes: [
                    .font: font, .foregroundColor: style.primaryText
                ])
            }
            return RowPresentation(title: title, font: font, textX: textX, textWidth: ceil(title.size().width))
        }
        contentWidth = rowPresentations.reduce(0) { max($0, $1.textX + $1.textWidth + 8) }
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
        let background: NSColor
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
            background = LitheTheme.nsColor(.sidebar, isDark: isDark)
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
