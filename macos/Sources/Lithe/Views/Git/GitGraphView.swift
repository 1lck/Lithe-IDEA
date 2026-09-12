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
    var onSelectWithModifiers: ((GitCommit, NSEvent.ModifierFlags) -> Void)? = nil
    var onContextSelect: ((GitCommit) -> Void)? = nil
    var additionalContextMenuItems: ((GitCommit) -> [LitheContextMenuItem])? = nil
    var onNavigateHash: ((String) -> Void)? = nil

    func select(_ commit: GitCommit, modifiers: NSEvent.ModifierFlags) {
        if let onSelectWithModifiers { onSelectWithModifiers(commit, modifiers) }
        else { onSelect(commit) }
    }

    func contextMenuItems(for commit: GitCommit) -> [LitheContextMenuItem] {
        onContextSelect?(commit)
        return [
            .action("Copy Commit Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.hash, forType: .string)
            },
            .action("Copy Short Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.shortHash, forType: .string)
            },
            .separator,
            .action("New Tag…") { onCreateTag(commit) },
            .action("Cherry-pick Commit…") { onCherryPick(commit) },
            .action("Revert Commit…") { onRevert(commit) },
            .action("Reset Current Branch to Here…") { onReset(commit) }
        ] + (additionalContextMenuItems?(commit) ?? [])
    }

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
    @Environment(\.locale) private var locale
    let presentation: GitGraphPresentation
    let selectedHash: String?
    let showCommitDecorations: Bool
    let actions: GitGraphRowActions
    var selectedHashes: Set<String>? = nil

    private let rowHeight = GitGraphGeometry.rowHeight

    var body: some View {
        ZStack(alignment: .topLeading) {
            LazyVStack(spacing: 0) {
                ForEach(presentation.rows) { row in
                    GitGraphRowView(
                        row: row,
                        graphWidth: GitGraphGeometry.rowWidth(row, recommendedLaneCount: presentation.routingSnapshot.recommendedLaneCount),
                        rowHeight: rowHeight,
                        isSelected: selectedHashes?.contains(row.commit.hash) ?? (selectedHash == row.commit.hash),
                        showCommitDecorations: showCommitDecorations,
                        actions: actions
                    )
                    .equatable()
                    .overlay(alignment: .topLeading) {
                        ForEach(row.printElements.filter { $0.hasArrow && $0.targetHash != nil }) { element in
                            let rect = GitGraphGeometry.arrowHitRect(for: element, rowHeight: rowHeight)
                            let target = element.targetHash ?? ""
                            let title = gitLocalizedFormat(
                                element.direction == .down ? "Go to parent commit %@" : "Go to child commit %@",
                                String(target.prefix(8)), locale: locale
                            )
                            Button {
                                actions.onNavigateHash?(target)
                            } label: {
                                Color.clear.frame(width: rect.width, height: rect.height).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(title)
                            .accessibilityLabel(title)
                            .accessibilityIdentifier("git-graph-arrow-\(row.commit.hash)-\(element.id)")
                            .lithePointer()
                            .offset(x: rect.minX, y: rect.minY)
                        }
                    }
                    .id(row.commit.hash)
                }

                if presentation.hasMissingParents {
                    HStack(spacing: 7) {
                        Image(systemName: "ellipsis")
                        Text("Older commits are outside the loaded history")
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, maximumGraphWidth + 6)
                    .frame(height: rowHeight)
                }
            }

            GitGraphNSViewRepresentable(
                snapshot: presentation.routingSnapshot,
                width: maximumGraphWidth,
                rowHeight: rowHeight,
                onNavigateHash: actions.onNavigateHash
            )
            .frame(width: maximumGraphWidth, height: CGFloat(presentation.rows.count) * rowHeight)
        }
    }

    private var maximumGraphWidth: CGFloat {
        GitGraphGeometry.maximumWidth(laneCount: presentation.routingSnapshot.laneCount,
                                      recommendedLaneCount: presentation.routingSnapshot.recommendedLaneCount)
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

    private let rowHeight = GitGraphGeometry.rowHeight

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
            locale: context.environment.locale,
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
    private var locale = Locale.current
    private var selectedHash: String?
    private var rows: [GitGraphRow] = []
    private var routingSnapshot = GitGraphRoutingSnapshot(rows: [], laneCount: 0)
    private var showCommitDecorations = false
    private var didConfigureLoadMoreButton = false
    private var onLoadMore: (() -> Void)?
    private var rowCount = 0
    private var graphWidth: CGFloat = 30
    private let rowHeight = GitGraphGeometry.rowHeight

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(commitRowsView)
        addSubview(graphView)
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
        locale: Locale = .current,
        presentation: GitGraphPresentation,
        selectedHash: String?,
        showCommitDecorations: Bool,
        canLoadMore: Bool,
        isLoadingMore: Bool,
        actions: GitGraphRowActions,
        onLoadMore: @escaping () -> Void
    ) -> Bool {
        let localeChanged = self.locale != locale
        self.locale = locale
        let selectionChanged = self.selectedHash != selectedHash
        let nextGraphWidth = GitGraphGeometry.maximumWidth(laneCount: presentation.routingSnapshot.laneCount,
                                                          recommendedLaneCount: presentation.routingSnapshot.recommendedLaneCount)
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
        if !didConfigureLoadMoreButton || loadMoreStateChanged || loadingStateChanged || localeChanged {
            loadMoreButton.title = isLoadingMore
                ? gitLocalizedFormat("Loading commits…", locale: locale)
                : gitLocalizedFormat("Load more commits", locale: locale)
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
        if graphChanged || rowsChanged || selectionChanged || showDecorationsChanged {
            commitRowsView.update(
                rows: presentation.rows,
                selectedHash: selectedHash,
                showDecorations: showCommitDecorations,
                graphWidth: graphWidth,
                rowHeight: rowHeight,
                recommendedLaneCount: presentation.routingSnapshot.recommendedLaneCount,
                actions: actions
            )
        }
        commitRowsView.updateActions(actions, locale: locale)
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
            x: 0,
            y: 0,
            width: max(0, width),
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
        if event.modifierFlags.contains(.control) {
            _ = menu(for: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if point.x < graphWidth {
            if let hash = graphView.navigationTarget(at: point),
               let index = rows.firstIndex(where: { $0.commit.hash == hash }) {
                commitRowsView.select(rowIndex: index)
                scrollToVisible(NSRect(x: 0, y: CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight))
                return
            }
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
    private var locale = Locale.current
    private var rows: [GitGraphRow] = []
    private var selectedHash: String?
    private var showDecorations = false
    private var graphWidth: CGFloat = 30
    private var recommendedLaneCount = 0
    private var rowHeight = GitGraphGeometry.rowHeight
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
        recommendedLaneCount: Int = 0,
        actions: GitGraphRowActions
    ) {
        guard self.rows != rows
                || self.selectedHash != selectedHash
                || self.showDecorations != showDecorations
                || self.graphWidth != graphWidth
                || self.recommendedLaneCount != recommendedLaneCount
                || self.rowHeight != rowHeight else { return }
        self.rows = rows
        labelWidthCache.removeAll(keepingCapacity: true)
        self.selectedHash = selectedHash
        self.showDecorations = showDecorations
        self.graphWidth = graphWidth
        self.recommendedLaneCount = recommendedLaneCount
        self.rowHeight = rowHeight
        self.actions = actions
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let row = Int(floor(local.y / rowHeight))
        if rows.indices.contains(row), local.x < GitGraphGeometry.rowWidth(rows[row], recommendedLaneCount: recommendedLaneCount) {
            return nil
        }
        return super.hitTest(point)
    }

    func updateActions(_ actions: GitGraphRowActions, locale: Locale = .current) {
        self.locale = locale
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
            let textStart = GitGraphGeometry.rowWidth(row, recommendedLaneCount: recommendedLaneCount)
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
                in: CGRect(x: textStart, y: rect.minY, width: max(0, rect.width - textStart - 230), height: rowHeight),
                font: style.body,
                color: row.commit.parentHashes.count > 1 && selectedHash != row.commit.hash ? style.merge : style.primary
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
        if event.modifierFlags.contains(.control) {
            _ = menu(for: event)
            return
        }
        let index = Int(floor(convert(event.locationInWindow, from: nil).y / rowHeight))
        select(rowIndex: index, modifiers: event.modifierFlags)
    }

    func select(rowIndex index: Int, modifiers: NSEvent.ModifierFlags = []) {
        guard rows.indices.contains(index), let actions else { return }
        actions.select(rows[index].commit, modifiers: modifiers)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let index = Int(floor(convert(event.locationInWindow, from: nil).y / rowHeight))
        guard rows.indices.contains(index), let actions, let window else { return nil }
        LitheContextMenuPresenter.shared.show(
            items: actions.contextMenuItems(for: rows[index].commit),
            at: window.convertPoint(toScreen: event.locationInWindow),
            appearance: effectiveAppearance,
            locale: locale
        )
        return nil
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
        let merge: NSColor
        let secondary: NSColor
        let divider: NSColor
        let selection: NSColor
        let hover: NSColor
        let labelBackground: NSColor

        init(isDark: Bool) {
            primary = LitheTheme.nsColor(.primaryText, isDark: isDark)
            merge = GitGraphColor.mergeForeground(isDark: isDark)
            secondary = LitheTheme.nsColor(.secondaryText, isDark: isDark)
            divider = LitheTheme.nsColor(.divider, isDark: isDark)
            selection = LitheTheme.nsColor(.accent, isDark: isDark).withAlphaComponent(0.16)
            hover = LitheTheme.nsColor(.toolHeader, isDark: isDark).withAlphaComponent(0.55)
            labelBackground = LitheTheme.nsColor(.toolHeader, isDark: isDark)
        }
    }
}

private struct GitGraphRowView: View, Equatable {
    @Environment(\.colorScheme) private var colorScheme
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
        Button { actions.select(row.commit, modifiers: NSApp.currentEvent?.modifierFlags ?? []) } label: {
            HStack(spacing: 0) {
                Color.clear.frame(width: graphWidth, height: rowHeight)

                HStack(spacing: 0) {
                    Text(row.commit.subject)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(row.commit.parentHashes.count > 1 && !isSelected
                            ? Color(nsColor: GitGraphColor.mergeForeground(isDark: colorScheme == .dark))
                            : LitheTheme.primaryText)
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovered = $0 }
        .litheContextMenu { actions.contextMenuItems(for: row.commit) }
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
    let onNavigateHash: ((String) -> Void)?

    func makeNSView(context: Context) -> GitGraphNSView {
        GitGraphNSView()
    }

    func updateNSView(_ nsView: GitGraphNSView, context: Context) {
        nsView.onNavigateHash = onNavigateHash
        nsView.update(snapshot: snapshot, width: width, rowHeight: rowHeight)
    }
}

final class GitGraphNSView: NSView {
    var onNavigateHash: ((String) -> Void)?
    private var colorCache: [Int: NSColor] = [:]
    private var snapshot = GitGraphRoutingSnapshot(rows: [], laneCount: 0)
    private var graphWidth: CGFloat = 0
    private var rowHeight = GitGraphGeometry.rowHeight
    private let laneLineWidth = GitGraphGeometry.lineWidth

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    func navigationTarget(at point: CGPoint) -> String? {
        let row = Int(floor(point.y / rowHeight))
        // Expanded arrows end on a shared row boundary. At that exact pixel,
        // also check the preceding row's down arrow instead of losing its tip
        // to floor() and CGRect's exclusive upper bound.
        let candidates = point.y == CGFloat(row) * rowHeight ? [row, row - 1] : [row]
        for candidate in candidates where snapshot.rows.indices.contains(candidate) {
            let local = CGPoint(x: point.x, y: min(rowHeight.nextDown, point.y - CGFloat(candidate) * rowHeight))
            if let target = snapshot.rows[candidate].printElements.first(where: {
                $0.hasArrow && $0.targetHash != nil && GitGraphGeometry.arrowHitRect(for: $0, rowHeight: rowHeight).contains(local)
            })?.targetHash { return target }
        }
        return nil
    }

    func update(snapshot: GitGraphRoutingSnapshot, width: CGFloat, rowHeight: CGFloat) {
        guard self.snapshot != snapshot || graphWidth != width || self.rowHeight != rowHeight else { return }
        self.snapshot = snapshot
        colorCache.removeAll(keepingCapacity: true)
        graphWidth = width
        self.rowHeight = rowHeight
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colorCache.removeAll(keepingCapacity: true)
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

            for element in row.printElements {
                let segment = GitGraphGeometry.line(for: element, rowHeight: rowHeight)
                let start = CGPoint(x: segment.start.x, y: top + segment.start.y)
                let end = CGPoint(x: segment.end.x, y: top + segment.end.y)
                context.saveGState()
                if element.isDotted && !element.hasArrow {
                    // IDEA fits one dash and one gap into a vertical row.
                    let space = rowHeight / 2 - 2
                    let length = hypot(end.x - start.x, end.y - start.y) * 2
                    let dash = length / max(1, floor(length / rowHeight)) - space
                    context.setLineDash(phase: dash / 2, lengths: [dash, space])
                }
                let edgeColor = color(for: element.colorIndex)
                stroke(line(from: start, to: end), color: edgeColor, width: laneLineWidth, context: context)
                if element.hasArrow {
                    let length = max(1, hypot(end.x - start.x, end.y - start.y))
                    let vx = (start.x - end.x) / length * rowHeight * 0.3
                    let vy = (start.y - end.y) / length * rowHeight * 0.3
                    for sign: CGFloat in [-1, 1] {
                        let tip = CGPoint(x: end.x + vx * sqrt(0.7) - sign * vy * sqrt(0.3),
                                          y: end.y + sign * vx * sqrt(0.3) + vy * sqrt(0.7))
                        stroke(line(from: end, to: tip), color: edgeColor, width: laneLineWidth, context: context)
                    }
                }
                context.restoreGState()
            }

            let nodeSize = GitGraphGeometry.nodeDiameter
            let nodeRect = CGRect(x: currentX - nodeSize / 2, y: centerY - nodeSize / 2, width: nodeSize, height: nodeSize)
            context.setFillColor(color(for: row.nodeColorIndex).cgColor)
            context.fillEllipse(in: nodeRect)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The single drawing surface spans row boundaries, unlike SwiftUI's
        // per-row buttons. Intercept only primary arrow clicks; ordinary row
        // selection, hover and context menus keep their existing SwiftUI path.
        if let event = NSApp.currentEvent,
           (event.type != .leftMouseDown && event.type != .leftMouseUp
                || event.modifierFlags.contains(.control)) { return nil }
        let local = convert(point, from: superview)
        guard onNavigateHash != nil, bounds.contains(local), navigationTarget(at: local) != nil else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control),
              let hash = navigationTarget(at: convert(event.locationInWindow, from: nil)),
              let onNavigateHash else {
            super.mouseDown(with: event)
            return
        }
        onNavigateHash(hash)
    }

    private func x(for lane: Int) -> CGFloat { GitGraphGeometry.leftPadding + CGFloat(lane) * GitGraphGeometry.laneSpacing }

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
        if let color = colorCache[index] { return color }
        let color = GitGraphColor.color(for: index,
            isDark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        colorCache[index] = color
        return color
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
