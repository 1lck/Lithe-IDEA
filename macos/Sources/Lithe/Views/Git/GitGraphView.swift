import AppKit
import SwiftUI
import LitheGitModule

/// Commit-row callbacks are grouped so that a row receives one stable value
/// instead of four freshly allocated closures per redraw. Rows are compared by
/// their rendered data alone, which keeps SwiftUI from re-evaluating hundreds of
/// canvases and context menus whenever an unrelated observable changes.
struct GitGraphRowActions {
    let onSelect: (GitCommit) -> Void
    let onCherryPick: (GitCommit) -> Void
    let onRevert: (GitCommit) -> Void
    let onReset: (GitCommit) -> Void
    let onCreateTag: (GitCommit) -> Void
}

/// Immutable graph data prepared by the log's data-refresh task. Keeping the
/// rows and routing together prevents selection and hover updates from
/// reconstructing graph topology during the view's render pass.
struct GitGraphPresentation: Sendable {
    let rows: [GitGraphRow]
    let routingSnapshot: GitGraphRoutingSnapshot
    let hasMissingParents: Bool

    static let empty = GitGraphPresentation(
        rows: [],
        routingSnapshot: GitGraphRoutingSnapshot(rows: [], laneCount: 0),
        hasMissingParents: false
    )
}

struct GitGraphView: View {
    let presentation: GitGraphPresentation
    let selectedHash: String?
    let showCommitDecorations: Bool
    let actions: GitGraphRowActions

    private let rowHeight: CGFloat = 30

    var body: some View {
        ZStack(alignment: .topLeading) {
            LazyVStack(spacing: 0) {
                ForEach(presentation.rows) { row in
                    GitGraphRowView(
                        row: row,
                        graphWidth: maximumGraphWidth,
                        rowHeight: rowHeight,
                        isSelected: selectedHash == row.commit.hash,
                        showCommitDecorations: showCommitDecorations,
                        actions: actions
                    )
                    .equatable()
                    .id(row.commit.hash)
                }

                if presentation.hasMissingParents {
                    HStack(spacing: 7) {
                        Image(systemName: "ellipsis")
                        Text(String(localized: "Older commits are outside the loaded history"))
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, maximumGraphWidth + 6)
                    .frame(height: 30)
                }
            }

            GitGraphNSViewRepresentable(
                snapshot: presentation.routingSnapshot,
                width: maximumGraphWidth,
                rowHeight: rowHeight
            )
            .frame(width: maximumGraphWidth, height: CGFloat(presentation.rows.count) * rowHeight)
            .allowsHitTesting(false)
        }
    }

    private var maximumGraphWidth: CGFloat {
        max(30, CGFloat(max(presentation.routingSnapshot.laneCount, 1)) * 13 + 16)
    }
}

/// Native viewport for the middle commit list. The commit rows remain hosted
/// by one SwiftUI document view so their existing actions and accessibility
/// stay intact, while wheel movement is handled entirely by AppKit.
struct GitGraphScrollView: NSViewRepresentable {
    let presentation: GitGraphPresentation
    let selectedHash: String?
    let showCommitDecorations: Bool
    let canLoadMore: Bool
    let isLoadingMore: Bool
    let actions: GitGraphRowActions
    let onLoadMore: () -> Void

    private let rowHeight: CGFloat = 30

    /// Keep the user's viewport stable while the document grows or is
    /// refreshed for reasons unrelated to selection.
    static func preservedScrollOrigin(
        previous: CGPoint,
        documentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGPoint {
        let maxY = max(0, documentHeight - viewportHeight)
        return CGPoint(
            x: previous.x,
            y: min(max(previous.y, 0), maxY)
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = Self.makeScrollView(
            presentation: presentation,
            selectedHash: selectedHash,
            showCommitDecorations: showCommitDecorations,
            canLoadMore: canLoadMore,
            isLoadingMore: isLoadingMore,
            actions: actions,
            onLoadMore: onLoadMore
        )
        return scrollView
    }

    static func makeScrollView(
        presentation: GitGraphPresentation,
        selectedHash: String?,
        showCommitDecorations: Bool,
        canLoadMore: Bool,
        isLoadingMore: Bool,
        actions: GitGraphRowActions,
        onLoadMore: @escaping () -> Void
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

        let documentView = GitGraphScrollDocumentView()
        documentView.update(
            presentation: presentation,
            selectedHash: selectedHash,
            showCommitDecorations: showCommitDecorations,
            canLoadMore: canLoadMore,
            isLoadingMore: isLoadingMore,
            actions: actions,
            onLoadMore: onLoadMore
        )
        documentView.autoresizingMask = [.width]
        scrollView.documentView = documentView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let documentView = nsView.documentView as? GitGraphScrollDocumentView else { return }
        let previousOrigin = nsView.contentView.bounds.origin
        let selectionChanged = documentView.update(
            presentation: presentation,
            selectedHash: selectedHash,
            showCommitDecorations: showCommitDecorations,
            canLoadMore: canLoadMore,
            isLoadingMore: isLoadingMore,
            actions: actions,
            onLoadMore: onLoadMore
        )
        let width = max(nsView.contentView.bounds.width, 1)
        documentView.updateLayout(width: width, viewportHeight: nsView.contentView.bounds.height)

        if selectionChanged,
           let selectedIndex = presentation.rows.firstIndex(where: { $0.commit.hash == selectedHash }) {
            // Selection changes are the only updates that should move the
            // viewport. Appending a history page must leave the user's
            // current scroll position untouched.
            nsView.contentView.scrollToVisible(
                NSRect(
                    x: 0,
                    y: CGFloat(selectedIndex) * rowHeight,
                    width: width,
                    height: rowHeight
                )
            )
        } else {
            // Growing the document view can make AppKit adjust the clip view
            // origin. Restore the previous origin for data-only updates such
            // as Load more, clamped by the new document bounds.
            nsView.layoutSubtreeIfNeeded()
            nsView.contentView.setBoundsOrigin(Self.preservedScrollOrigin(
                previous: previousOrigin,
                documentHeight: documentView.bounds.height,
                viewportHeight: nsView.contentView.bounds.height
            ))
        }
    }
}

final class GitGraphScrollDocumentView: NSView {
    private let graphView = GitGraphNSView()
    private let commitRowsView = GitGraphCommitRowsNSView()
    private let loadMoreButton = NSButton()
    private var loadMoreTarget: GitGraphLoadMoreButtonTarget?
    private var canLoadMore = false
    private var isLoadingMore = false
    private var hasMissingParents = false
    private var selectedHash: String?
    private var rows: [GitGraphRow] = []
    private var routingSnapshot = GitGraphRoutingSnapshot(rows: [], laneCount: 0)
    private var showCommitDecorations = false
    private var didConfigureLoadMoreButton = false
    private var onLoadMore: (() -> Void)?
    private var rowCount = 0
    private var graphWidth: CGFloat = 30
    private let rowHeight: CGFloat = 30

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(graphView)
        addSubview(commitRowsView)
        loadMoreButton.setButtonType(.momentaryPushIn)
        loadMoreButton.isBordered = false
        loadMoreButton.bezelStyle = .inline
        loadMoreButton.alignment = .center
        loadMoreButton.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        loadMoreButton.contentTintColor = LitheTheme.nsColor(.accent, isDark: false)
        addSubview(loadMoreButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @discardableResult
    func update(
        presentation: GitGraphPresentation,
        selectedHash: String?,
        showCommitDecorations: Bool,
        canLoadMore: Bool,
        isLoadingMore: Bool,
        actions: GitGraphRowActions,
        onLoadMore: @escaping () -> Void
    ) -> Bool {
        let selectionChanged = self.selectedHash != selectedHash
        let nextGraphWidth = max(30, CGFloat(max(presentation.routingSnapshot.laneCount, 1)) * 13 + 16)
        let graphChanged = routingSnapshot != presentation.routingSnapshot || graphWidth != nextGraphWidth
        let rowsChanged = rows != presentation.rows
        let missingParentsChanged = hasMissingParents != presentation.hasMissingParents
        let showDecorationsChanged = self.showCommitDecorations != showCommitDecorations
        let loadMoreStateChanged = self.canLoadMore != canLoadMore
        let loadingStateChanged = self.isLoadingMore != isLoadingMore

        self.selectedHash = selectedHash
        graphWidth = nextGraphWidth
        rowCount = presentation.rows.count + (presentation.hasMissingParents ? 1 : 0)
        hasMissingParents = presentation.hasMissingParents
        rows = presentation.rows
        routingSnapshot = presentation.routingSnapshot
        self.showCommitDecorations = showCommitDecorations
        self.canLoadMore = canLoadMore
        self.isLoadingMore = isLoadingMore
        self.onLoadMore = onLoadMore
        if !didConfigureLoadMoreButton || loadMoreStateChanged || loadingStateChanged {
            loadMoreButton.title = isLoadingMore
                ? String(localized: "Loading commits…")
                : String(localized: "Load more commits")
            loadMoreButton.isHidden = !canLoadMore
            loadMoreButton.isEnabled = !isLoadingMore
            didConfigureLoadMoreButton = true
        }
        // The callback may capture refreshed feature state, so keep the
        // target current even when the rendered button state is unchanged.
        loadMoreTarget = GitGraphLoadMoreButtonTarget(action: onLoadMore)
        loadMoreButton.target = loadMoreTarget
        loadMoreButton.action = #selector(GitGraphLoadMoreButtonTarget.invoke)
        if graphChanged {
            graphView.update(
                snapshot: presentation.routingSnapshot,
                width: graphWidth,
                rowHeight: rowHeight
            )
        }
        if rowsChanged || selectionChanged || showDecorationsChanged {
            commitRowsView.update(
                rows: presentation.rows,
                selectedHash: selectedHash,
                showDecorations: showCommitDecorations,
                graphWidth: graphWidth,
                rowHeight: rowHeight,
                actions: actions
            )
        } else {
            commitRowsView.updateActions(actions)
        }
        if graphChanged || rowsChanged || missingParentsChanged || loadMoreStateChanged {
            needsLayout = true
            needsDisplay = true
        }
        return selectionChanged
    }

    func updateLayout(width: CGFloat, viewportHeight: CGFloat) {
        let footerHeight = canLoadMore ? rowHeight + 2 : 0
        let height = max(viewportHeight, CGFloat(rowCount) * rowHeight + footerHeight)
        let size = CGSize(width: max(width, 1), height: height)
        if frame.size != size { setFrameSize(size) }
        let graphFrame = CGRect(x: 0, y: 0, width: graphWidth, height: height)
        if graphView.frame != graphFrame { graphView.frame = graphFrame }
        let rowsFrame = CGRect(
            x: graphWidth,
            y: 0,
            width: max(0, width - graphWidth),
            height: CGFloat(rowCount) * rowHeight
        )
        if commitRowsView.frame != rowsFrame { commitRowsView.frame = rowsFrame }
        let missingParentsHeight = hasMissingParents ? rowHeight : 0
        let buttonFrame = CGRect(
            x: 0,
            y: CGFloat(presentationRowCount) * rowHeight + missingParentsHeight + 1,
            width: max(0, width),
            height: rowHeight
        )
        if loadMoreButton.frame != buttonFrame { loadMoreButton.frame = buttonFrame }
    }

    override func draw(_ dirtyRect: NSRect) {
        let firstFooterRow = CGFloat(presentationRowCount) * rowHeight
        let missingParentsHeight = hasMissingParents ? rowHeight : 0
        let footerY = firstFooterRow + missingParentsHeight
        guard dirtyRect.maxY >= footerY else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let divider = LitheTheme.nsColor(.divider, isDark: isDark)
        divider.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: footerY, width: bounds.width, height: 1)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x < graphWidth {
            commitRowsView.select(rowIndex: Int(floor(point.y / rowHeight)))
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if point.x < graphWidth {
            return commitRowsView.menu(for: event)
        }
        return super.menu(for: event)
    }

    private var presentationRowCount: Int {
        max(0, rowCount - (hasMissingParents ? 1 : 0))
    }

    override func layout() {
        super.layout()
        updateLayout(width: bounds.width, viewportHeight: bounds.height)
    }
}

private final class GitGraphLoadMoreButtonTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke() {
        action()
    }
}

final class GitGraphCommitRowsNSView: NSView {
    private var rows: [GitGraphRow] = []
    private var selectedHash: String?
    private var showDecorations = false
    private var graphWidth: CGFloat = 30
    private var rowHeight: CGFloat = 30
    private var actions: GitGraphRowActions?
    private var drawingStyle: DrawingStyle?
    private var hoveredIndex: Int?
    private var labelWidthCache: [String: CGFloat] = [:]

    override var isFlipped: Bool { true }

    func update(
        rows: [GitGraphRow],
        selectedHash: String?,
        showDecorations: Bool,
        graphWidth: CGFloat,
        rowHeight: CGFloat,
        actions: GitGraphRowActions
    ) {
        guard self.rows != rows
                || self.selectedHash != selectedHash
                || self.showDecorations != showDecorations
                || self.graphWidth != graphWidth
                || self.rowHeight != rowHeight else { return }
        self.rows = rows
        labelWidthCache.removeAll(keepingCapacity: true)
        self.selectedHash = selectedHash
        self.showDecorations = showDecorations
        self.graphWidth = graphWidth
        self.rowHeight = rowHeight
        self.actions = actions
        needsDisplay = true
    }

    func updateActions(_ actions: GitGraphRowActions) {
        self.actions = actions
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        drawingStyle = nil
        labelWidthCache.removeAll(keepingCapacity: true)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let index = Int(floor(convert(event.locationInWindow, from: nil).y / rowHeight))
        let next = rows.indices.contains(index) ? index : nil
        guard hoveredIndex != next else { return }
        let previous = hoveredIndex
        hoveredIndex = next
        if let previous {
            setNeedsDisplay(NSRect(x: 0, y: CGFloat(previous) * rowHeight, width: bounds.width, height: rowHeight))
        }
        if let next {
            setNeedsDisplay(NSRect(x: 0, y: CGFloat(next) * rowHeight, width: bounds.width, height: rowHeight))
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard let previous = hoveredIndex else { return }
        hoveredIndex = nil
        setNeedsDisplay(NSRect(x: 0, y: CGFloat(previous) * rowHeight, width: bounds.width, height: rowHeight))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty, let style = resolvedDrawingStyle() else { return }
        let first = max(0, Int(floor(dirtyRect.minY / rowHeight)))
        let last = min(rows.count - 1, Int(ceil(dirtyRect.maxY / rowHeight)))
        guard first <= last else { return }
        let context = NSGraphicsContext.current?.cgContext

        for index in first...last {
            let row = rows[index]
            let rect = CGRect(x: 0, y: CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
            if selectedHash == row.commit.hash {
                style.selection.setFill()
                NSBezierPath(rect: rect).fill()
            } else if hoveredIndex == index {
                style.hover.setFill()
                NSBezierPath(rect: rect).fill()
            }
            drawText(
                row.commit.subject,
                in: CGRect(x: 0, y: rect.minY, width: max(0, rect.width - 230), height: rowHeight),
                font: style.body,
                color: style.primary
            )
            drawText(
                row.commit.authorName,
                in: CGRect(x: max(0, rect.maxX - 222), y: rect.minY, width: 104, height: rowHeight),
                font: style.meta,
                color: style.secondary
            )
            drawText(
                row.commit.date,
                in: CGRect(x: max(0, rect.maxX - 118), y: rect.minY, width: 110, height: rowHeight),
                font: style.monoMeta,
                color: style.secondary,
                alignment: .right
            )
            if showDecorations, !row.labels.isEmpty {
                drawLabels(row.labels, in: rect, style: style, context: context)
            }
            style.divider.setFill()
            NSBezierPath(rect: CGRect(x: 0, y: rect.maxY - 1, width: rect.width, height: 1)).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let index = Int(floor(convert(event.locationInWindow, from: nil).y / rowHeight))
        select(rowIndex: index)
    }

    func select(rowIndex index: Int) {
        guard rows.indices.contains(index), let actions else { return }
        actions.onSelect(rows[index].commit)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let index = Int(floor(convert(event.locationInWindow, from: nil).y / rowHeight))
        guard rows.indices.contains(index), let actions else { return nil }
        let commit = rows[index].commit
        let target = GitGraphCommitMenuTarget(commit: commit, actions: actions)
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Copy Commit Hash"), action: #selector(GitGraphCommitMenuTarget.copyHash), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Copy Short Hash"), action: #selector(GitGraphCommitMenuTarget.copyShortHash), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "New Tag…"), action: #selector(GitGraphCommitMenuTarget.createTag), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Cherry-pick Commit…"), action: #selector(GitGraphCommitMenuTarget.cherryPick), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Revert Commit…"), action: #selector(GitGraphCommitMenuTarget.revert), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Reset Current Branch to Here…"), action: #selector(GitGraphCommitMenuTarget.reset), keyEquivalent: "")
        for item in menu.items { item.target = target }
        return menu
    }

    private func drawLabels(_ labels: [GitGraphLabel], in rect: CGRect, style: DrawingStyle, context: CGContext?) {
        var x = max(0, rect.width - 230)
        for label in labels.reversed() {
            let measuredWidth = labelWidthCache[label.title] ?? {
                let value = (label.title as NSString).size(withAttributes: [.font: style.meta]).width + 14
                labelWidthCache[label.title] = value
                return value
            }()
            let width = min(130, max(28, measuredWidth))
            x -= width + 5
            style.labelBackground.setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: rect.midY - 8, width: width, height: 16), xRadius: 4, yRadius: 4).fill()
            drawText(label.title, in: CGRect(x: x + 7, y: rect.minY, width: width - 10, height: rect.height), font: style.meta, color: style.primary)
        }
    }

    private static let leftParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineBreakMode = .byTruncatingTail
        return style.copy() as! NSParagraphStyle
    }()

    private static let rightParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byTruncatingTail
        return style.copy() as! NSParagraphStyle
    }()

    private func drawText(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        guard rect.width > 0 else { return }
        let paragraph = alignment == .right ? Self.rightParagraphStyle : Self.leftParagraphStyle
        let height = ceil(font.ascender - font.descender)
        (text as NSString).draw(in: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height), withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private func resolvedDrawingStyle() -> DrawingStyle? {
        if let drawingStyle { return drawingStyle }
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let style = DrawingStyle(isDark: isDark)
        drawingStyle = style
        return style
    }

    private struct DrawingStyle {
        let body = NSFont.systemFont(ofSize: 12.5)
        let meta = NSFont.systemFont(ofSize: 11.5)
        let monoMeta = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let primary: NSColor
        let secondary: NSColor
        let divider: NSColor
        let selection: NSColor
        let hover: NSColor
        let labelBackground: NSColor

        init(isDark: Bool) {
            primary = LitheTheme.nsColor(.primaryText, isDark: isDark)
            secondary = LitheTheme.nsColor(.secondaryText, isDark: isDark)
            divider = LitheTheme.nsColor(.divider, isDark: isDark)
            selection = LitheTheme.nsColor(.accent, isDark: isDark).withAlphaComponent(0.16)
            hover = LitheTheme.nsColor(.toolHeader, isDark: isDark).withAlphaComponent(0.55)
            labelBackground = LitheTheme.nsColor(.toolHeader, isDark: isDark)
        }
    }
}

private final class GitGraphCommitMenuTarget: NSObject {
    let commit: GitCommit
    let actions: GitGraphRowActions

    init(commit: GitCommit, actions: GitGraphRowActions) {
        self.commit = commit
        self.actions = actions
    }

    @objc func copyHash() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.hash, forType: .string)
    }

    @objc func copyShortHash() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.shortHash, forType: .string)
    }

    @objc func createTag() { actions.onCreateTag(commit) }
    @objc func cherryPick() { actions.onCherryPick(commit) }
    @objc func revert() { actions.onRevert(commit) }
    @objc func reset() { actions.onReset(commit) }
}

private struct GitGraphRowView: View, Equatable {
    let row: GitGraphRow
    let graphWidth: CGFloat
    let rowHeight: CGFloat
    let isSelected: Bool
    let showCommitDecorations: Bool
    let actions: GitGraphRowActions

    @State private var isHovered = false

    static func == (lhs: GitGraphRowView, rhs: GitGraphRowView) -> Bool {
        lhs.row == rhs.row
            && lhs.graphWidth == rhs.graphWidth
            && lhs.rowHeight == rhs.rowHeight
            && lhs.isSelected == rhs.isSelected
            && lhs.showCommitDecorations == rhs.showCommitDecorations
    }

    var body: some View {
        Button { actions.onSelect(row.commit) } label: {
            HStack(spacing: 0) {
                Color.clear.frame(width: graphWidth, height: rowHeight)

                HStack(spacing: 0) {
                    Text(row.commit.subject)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)

                    if showCommitDecorations, !row.labels.isEmpty {
                        Spacer(minLength: 8)

                        HStack(spacing: 6) {
                            ForEach(row.labels) { label in
                                GitGraphLabelView(label: label)
                            }
                        }
                        .padding(.trailing, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(row.commit.authorName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .frame(width: 104, alignment: .leading)

                Text(row.commit.date)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 118, alignment: .trailing)
            }
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: rowHeight)
            .background(backgroundColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Copy Commit Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.commit.hash, forType: .string)
            }
            Button("Copy Short Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.commit.shortHash, forType: .string)
            }
            Divider()
            Button("New Tag…") { actions.onCreateTag(row.commit) }
            Button("Cherry-pick Commit…") { actions.onCherryPick(row.commit) }
            Button("Revert Commit…") { actions.onRevert(row.commit) }
            Button("Reset Current Branch to Here…") { actions.onReset(row.commit) }
        }
    }

    private var backgroundColor: Color {
        if isSelected { return LitheTheme.selection }
        if isHovered { return LitheTheme.hoverBackground }
        return .clear
    }
}

private struct GitGraphLabelView: View {
    let label: GitGraphLabel

    var body: some View {
        HStack(spacing: 2) {
            GitReferenceTagIcon(color: accentColor)
                .frame(width: 12, height: 12)
            Text(label.title)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(LitheTheme.primaryText.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.leading, 3)
        .padding(.trailing, 4)
        .frame(height: 17)
        .background(LitheTheme.primaryText.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var accentColor: Color {
        switch label.kind {
        case .head: return LitheTheme.accent
        case .branch: return LitheTheme.success
        case .remote: return Color(red: 0.55, green: 0.70, blue: 0.96)
        case .tag: return LitheTheme.warning
        }
    }
}

private struct GitReferenceTagIcon: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 6.25
            let origin = CGPoint(
                x: (size.width - 5.25 * scale) / 2,
                y: (size.height - 5 * scale) / 2
            )
            var path = Path()
            path.move(to: CGPoint(x: origin.x, y: origin.y))
            path.addLine(to: CGPoint(x: origin.x + 2 * scale, y: origin.y))
            path.addLine(to: CGPoint(x: origin.x + 5 * scale, y: origin.y + 3 * scale))
            path.addLine(to: CGPoint(x: origin.x + 3 * scale, y: origin.y + 5 * scale))
            path.addLine(to: CGPoint(x: origin.x, y: origin.y + 2 * scale))
            path.closeSubpath()
            path.addEllipse(in: CGRect(
                x: origin.x + scale,
                y: origin.y + scale,
                width: scale,
                height: scale
            ))
            context.fill(path, with: .color(color), style: FillStyle(eoFill: true))
        }
        .accessibilityHidden(true)
    }
}

private struct GitGraphNSViewRepresentable: NSViewRepresentable {
    let snapshot: GitGraphRoutingSnapshot
    let width: CGFloat
    let rowHeight: CGFloat

    func makeNSView(context: Context) -> GitGraphNSView {
        GitGraphNSView()
    }

    func updateNSView(_ nsView: GitGraphNSView, context: Context) {
        nsView.update(snapshot: snapshot, width: width, rowHeight: rowHeight)
    }
}

private final class GitGraphNSView: NSView {
    private static let palette: [NSColor] = [
        NSColor(calibratedRed: 0.29, green: 0.72, blue: 0.45, alpha: 1),
        NSColor(calibratedRed: 0.35, green: 0.62, blue: 0.96, alpha: 1),
        NSColor(calibratedRed: 0.82, green: 0.47, blue: 0.82, alpha: 1),
        NSColor(calibratedRed: 0.96, green: 0.61, blue: 0.28, alpha: 1),
        NSColor(calibratedRed: 0.36, green: 0.78, blue: 0.78, alpha: 1),
        NSColor(calibratedRed: 0.93, green: 0.42, blue: 0.48, alpha: 1),
        NSColor(calibratedRed: 0.70, green: 0.63, blue: 0.94, alpha: 1)
    ]

    private var snapshot = GitGraphRoutingSnapshot(rows: [], laneCount: 0)
    private var graphWidth: CGFloat = 0
    private var rowHeight: CGFloat = 30
    private let laneSpacing: CGFloat = 13
    private let laneLineWidth: CGFloat = 1.6
    private let leftPadding: CGFloat = 8

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    func update(snapshot: GitGraphRoutingSnapshot, width: CGFloat, rowHeight: CGFloat) {
        guard self.snapshot != snapshot || graphWidth != width || self.rowHeight != rowHeight else { return }
        self.snapshot = snapshot
        graphWidth = width
        self.rowHeight = rowHeight
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldAntialias(true)

        let firstRow = max(0, Int(floor(dirtyRect.minY / rowHeight)))
        let lastRow = min(snapshot.rows.count - 1, Int(ceil(dirtyRect.maxY / rowHeight)))
        guard firstRow <= lastRow else { return }

        for index in firstRow...lastRow {
            let row = snapshot.rows[index]
            let top = CGFloat(index) * rowHeight
            let centerY = top + rowHeight / 2
            let currentX = x(for: row.nodeLane)

            for segment in row.incoming {
                stroke(
                    line(from: CGPoint(x: x(for: segment.lane), y: top), to: CGPoint(x: x(for: segment.lane), y: segment.lane == row.nodeLane ? centerY : top + rowHeight)),
                    color: color(for: segment.colorIndex),
                    width: laneLineWidth,
                    context: context
                )
            }

            for route in row.routes {
                let color = color(for: route.colorIndex)
                if let targetLane = route.targetLane {
                    let target = CGPoint(x: x(for: targetLane), y: top + rowHeight)
                    let start = CGPoint(x: currentX, y: centerY)
                    let path: CGPath
                    if targetLane == row.nodeLane {
                        path = line(from: start, to: target)
                    } else {
                        let controlY = centerY + (rowHeight - rowHeight / 2) * 0.62
                        let bezier = CGMutablePath()
                        bezier.move(to: start)
                        bezier.addCurve(to: target, control1: CGPoint(x: start.x, y: controlY), control2: CGPoint(x: target.x, y: controlY))
                        path = bezier
                    }
                    stroke(path, color: color, width: laneLineWidth, context: context)
                } else {
                    context.saveGState()
                    context.setLineDash(phase: 0, lengths: [3, 2])
                    stroke(line(from: CGPoint(x: currentX, y: centerY), to: CGPoint(x: currentX, y: top + rowHeight - 2)), color: color.withAlphaComponent(0.65), width: 1.5, context: context)
                    context.restoreGState()
                }
            }

            let nodeSize: CGFloat = row.routes.count > 1 ? 9.5 : 8.5
            let nodeRect = CGRect(x: currentX - nodeSize / 2, y: centerY - nodeSize / 2, width: nodeSize, height: nodeSize)
            context.setFillColor(color(for: nodeColorIndex(row)).cgColor)
            context.fillEllipse(in: nodeRect)
            if row.routes.count > 1 {
                context.setStrokeColor(NSColor.white.withAlphaComponent(0.72).cgColor)
                context.setLineWidth(1)
                context.strokeEllipse(in: nodeRect.insetBy(dx: 1, dy: 1))
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Graph strokes are visual only; the document view routes clicks to
        // the matching commit row so the whole row remains selectable.
        nil
    }

    private func nodeColorIndex(_ row: GitGraphRoutingRow) -> Int {
        row.incoming.first(where: { $0.lane == row.nodeLane })?.colorIndex ?? row.routes.first?.colorIndex ?? 0
    }

    private func x(for lane: Int) -> CGFloat { leftPadding + CGFloat(lane) * laneSpacing }

    private func line(from start: CGPoint, to end: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)
        return path
    }

    private func stroke(_ path: CGPath, color: NSColor, width: CGFloat, context: CGContext) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.addPath(path)
        context.strokePath()
    }

    private func color(for index: Int) -> NSColor {
        Self.palette[index % Self.palette.count]
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
