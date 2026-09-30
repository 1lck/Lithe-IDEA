import AppKit
import CoreText
import SwiftUI
import LitheGitModule

/// Display-only formatting uses the app language, retaining the parsed commit instant.
enum GitLogDatePresentation {
    private static let twentyFourHour = formatter("yyyy/MM/dd HH:mm")
    private static let twelveHour = formatter("yyyy/MM/dd hh:mm a")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = format
        formatter.amSymbol = "AM"
        formatter.pmSymbol = "PM"
        return formatter
    }

    static func components(_ value: String, locale: Locale) -> (text: String, period: String?) {
        guard let date = GitLogQuery.parseCommitDate(value) else { return (value, nil) }
        if locale.language.languageCode?.identifier == "en" {
            let text = twelveHour.string(from: date)
            return (String(text.dropLast(3)), String(text.suffix(2)))
        }
        return (twentyFourHour.string(from: date), nil)
    }

    static func string(_ value: String, locale: Locale) -> String {
        let parts = components(value, locale: locale)
        return parts.text + (parts.period.map { " " + $0 } ?? "")
    }
}

/// Commit-row callbacks are grouped so that a row receives one stable value
/// instead of four freshly allocated closures per redraw. Rows are compared by
/// their rendered data alone, which keeps SwiftUI from re-evaluating hundreds of
/// canvases and context menus whenever an unrelated observable changes.
struct GitGraphRowActions {
    let onSelect: (GitCommit) -> Void
    let onCherryPick: (GitCommit) -> Void
    let onRevert: (GitCommit) -> Void
    let onReset: (GitCommit, GitResetMode) -> Void
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
            .submenu("Reset Current Branch to Here…", items: [
                .action("Soft Reset (Keep Changes Staged)") { onReset(commit, .soft) },
                .action("Mixed Reset (Keep Changes Unstaged)") { onReset(commit, .mixed) },
                .action("Hard Reset (Discard Changes)", role: .destructive) { onReset(commit, .hard) }
            ])
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
    @Environment(\.displayScale) private var displayScale
    @Environment(\.locale) private var locale
    let presentation: GitGraphPresentation
    let selectedHash: String?
    let showCommitDecorations: Bool
    let actions: GitGraphRowActions
    var selectedHashes: Set<String>? = nil
    var isFocused = true

    private let rowHeight = GitGraphGeometry.rowHeight

    var body: some View {
        ZStack(alignment: .topLeading) {
            LazyVStack(spacing: 0) {
                ForEach(presentation.rows) { row in
                    GitGraphRowView(
                        row: row,
                        graphWidth: GitGraphGeometry.titleOffset(row, recommendedLaneCount: presentation.routingSnapshot.recommendedLaneCount),
                        rowHeight: rowHeight,
                        isSelected: selectedHashes?.contains(row.commit.hash) ?? (selectedHash == row.commit.hash),
                        showCommitDecorations: showCommitDecorations,
                        actions: actions,
                        isFocused: isFocused
                    )
                    .equatable()
                    .overlay(alignment: .topLeading) {
                        ForEach(row.printElements.filter { $0.hasArrow && $0.targetHash != nil }) { element in
                            let rect = GitGraphGeometry.arrowHitRect(for: element, rowHeight: rowHeight, backingScale: displayScale)
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
                            .buttonStyle(.litheNoPress)
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
                    .font(LitheTheme.uiFont(size: 10.5))
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
        loadMoreButton.font = LitheTheme.uiNSFont(size: 11.5, weight: .medium)
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
    private var dateTextCache: [String: (text: String, period: String?)] = [:]

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
        if self.rows != rows { dateTextCache.removeAll(keepingCapacity: true) }
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
        if self.locale != locale {
            dateTextCache.removeAll(keepingCapacity: true)
            needsDisplay = true
        }
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
        let visible = dirtyRect.intersection(bounds)
        guard !visible.isEmpty else { return }
        let first = max(0, Int(floor(visible.minY / rowHeight)))
        let last = min(rows.count - 1, Int(ceil(visible.maxY / rowHeight)))
        guard first <= last else { return }
        let context = NSGraphicsContext.current?.cgContext

        let dateWidth = LitheTheme.GitLog.dateColumnWidth(locale: locale)
        for index in first...last {
            let row = rows[index]
            let textStart = GitGraphGeometry.titleOffset(row, recommendedLaneCount: recommendedLaneCount)
            let foreground = GitGraphColor.commitForeground(
                parentCount: row.commit.parentHashes.count, isSelected: selectedHash == row.commit.hash,
                normal: style.primary, isDark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            )
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
                in: CGRect(x: textStart, y: rect.minY, width: max(0, rect.width - textStart - dateWidth - 120), height: rowHeight),
                font: style.body,
                color: foreground
            )
            drawText(
                row.commit.authorName,
                in: CGRect(x: max(0, rect.maxX - dateWidth - 112), y: rect.minY, width: 104, height: rowHeight),
                font: style.meta,
                color: foreground
            )
            let date = dateTextCache[row.commit.date] ?? GitLogDatePresentation.components(row.commit.date, locale: locale)
            dateTextCache[row.commit.date] = date
            let periodWidth = date.period == nil ? 0 : LitheTheme.GitLog.meridiemWidth + 4
            drawText(date.text,
                in: CGRect(x: max(0, rect.maxX - dateWidth - 8), y: rect.minY, width: dateWidth - periodWidth, height: rowHeight),
                font: style.date, color: foreground, alignment: .right)
            if let period = date.period {
                drawText(period,
                    in: CGRect(x: rect.maxX - LitheTheme.GitLog.meridiemWidth - 8, y: rect.minY,
                               width: LitheTheme.GitLog.meridiemWidth, height: rowHeight),
                    font: style.date, color: foreground, alignment: .right)
            }
            if showDecorations, !row.labels.isEmpty {
                drawLabels(row.labels, in: rect, style: style, context: context)
            }
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
        var x = max(0, rect.width - LitheTheme.GitLog.dateColumnWidth(locale: locale) - 120)
        for label in labels.reversed() {
            let measuredWidth = labelWidthCache[label.title] ?? {
                let value = (label.title as NSString).size(withAttributes: [.font: style.reference]).width + 8
                labelWidthCache[label.title] = value
                return value
            }()
            let width = min(130, max(28, measuredWidth))
            x -= width + 5
            drawText(label.title, in: CGRect(x: x + 7, y: rect.minY, width: width - 10, height: rect.height), font: style.reference, color: style.referenceText)
        }
    }

    private func drawText(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        guard rect.width > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let fullLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let line = CTLineGetTypographicBounds(fullLine, nil, nil, nil) > rect.width
            ? CTLineCreateTruncatedLine(fullLine, Double(rect.width), .end, token) ?? token
            : fullLine
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x = alignment == .right ? rect.maxX - width : rect.minX
        let baseline = rect.minY + GitGraphGeometry.textBaseline(for: font, height: rect.height)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        // SimpleColoredComponent defaults fractional metrics off; use pixel-aligned glyph origins.
        context.setShouldSubpixelPositionFonts(false)
        // Draw at the shared integer baseline rather than centering an AppKit text rectangle.
        context.translateBy(x: x, y: baseline)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
    }

    private func resolvedDrawingStyle() -> DrawingStyle? {
        if let drawingStyle { return drawingStyle }
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let style = DrawingStyle(isDark: isDark)
        drawingStyle = style
        return style
    }

    private struct DrawingStyle {
        let body = LitheTheme.uiNSFont(size: LitheTheme.GitLog.fontSize)
        let meta = LitheTheme.uiNSFont(size: LitheTheme.GitLog.fontSize)
        let date = LitheTheme.GitLog.dateFont
        let reference = LitheTheme.uiNSFont(size: LitheTheme.GitLog.fontSize - 1)
        let referenceText = NSColor(LitheTheme.GitLog.referenceText)
        let primary: NSColor
        let selection: NSColor
        let hover: NSColor

        init(isDark: Bool) {
            primary = NSColor(LitheTheme.searchFieldText)
            selection = NSColor(LitheTheme.GitLog.rowBackground(selected: true, hovered: false))
            hover = NSColor(LitheTheme.GitLog.rowBackground(selected: false, hovered: true))
        }
    }
}

private struct GitGraphRowView: View, Equatable {
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    let row: GitGraphRow
    let graphWidth: CGFloat
    let rowHeight: CGFloat
    let isSelected: Bool
    let showCommitDecorations: Bool
    let actions: GitGraphRowActions
    var isFocused = true

    @State private var isHovered = false

    static func == (lhs: GitGraphRowView, rhs: GitGraphRowView) -> Bool {
        lhs.row == rhs.row
            && lhs.graphWidth == rhs.graphWidth
            && lhs.rowHeight == rhs.rowHeight
            && lhs.isSelected == rhs.isSelected
            && lhs.showCommitDecorations == rhs.showCommitDecorations
            && lhs.isFocused == rhs.isFocused
    }

    var body: some View {
        Button { actions.select(row.commit, modifiers: NSApp.currentEvent?.modifierFlags ?? []) } label: {
            HStack(spacing: 0) {
                Color.clear.frame(width: graphWidth, height: rowHeight)

                HStack(spacing: 0) {
                    Text(row.commit.subject)
                        .font(LitheTheme.uiFont(size: LitheTheme.GitLog.fontSize))
                        .foregroundStyle(foregroundColor)
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
                    .font(LitheTheme.uiFont(size: LitheTheme.GitLog.fontSize))
                    .foregroundStyle(foregroundColor)
                    .lineLimit(1)
                    .frame(width: 104, alignment: .leading)

                let date = GitLogDatePresentation.components(row.commit.date, locale: locale)
                HStack(spacing: 4) {
                    Text(verbatim: date.text)
                    if let period = date.period {
                        Text(verbatim: period)
                            .frame(width: LitheTheme.GitLog.meridiemWidth, alignment: .trailing)
                    }
                }
                .font(Font(LitheTheme.GitLog.dateFont))
                .foregroundStyle(foregroundColor)
                .lineLimit(1)
                .frame(width: LitheTheme.GitLog.dateColumnWidth(locale: locale), alignment: .trailing)
            }
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: rowHeight)
            .background(backgroundColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovered = $0 }
        .litheContextMenu { actions.contextMenuItems(for: row.commit) }
    }

    private var foregroundColor: Color {
        Color(nsColor: GitGraphColor.commitForeground(
            parentCount: row.commit.parentHashes.count, isSelected: isSelected,
            normal: NSColor(LitheTheme.searchFieldText), isDark: colorScheme == .dark
        ))
    }

    private var backgroundColor: Color {
        LitheTheme.GitLog.rowBackground(selected: isSelected, hovered: isHovered, focused: isFocused)
    }
}

struct GitGraphLabelView: View {
    let label: GitGraphLabel
    var fontSize: CGFloat = LitheTheme.GitLog.fontSize - 1
    var height: CGFloat = GitGraphGeometry.rowHeight

    var body: some View {
        HStack(spacing: 2) {
            GitReferenceTagIcon(color: accentColor)
                .frame(width: 12, height: 12)
            Text(label.title)
                .font(LitheTheme.uiFont(size: fontSize))
                .foregroundStyle(LitheTheme.GitLog.referenceText)
                .lineLimit(1)
        }
        .padding(.leading, 3)
        .padding(.trailing, 4)
        .frame(height: height)
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
    private var backingScale: CGFloat { window?.backingScaleFactor ?? 1 }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    func navigationTarget(at point: CGPoint) -> String? {
        let row = Int(floor(point.y / rowHeight))
        // Pixel alignment can move diagonal tips across a logical row boundary.
        let candidates = [row, row - 1, row + 1]
        for candidate in candidates where snapshot.rows.indices.contains(candidate) {
            let local = CGPoint(x: point.x, y: point.y - CGFloat(candidate) * rowHeight)
            if let target = snapshot.rows[candidate].printElements.first(where: {
                $0.hasArrow && $0.targetHash != nil && GitGraphGeometry.arrowHitRect(for: $0, rowHeight: rowHeight, backingScale: backingScale).contains(local)
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

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldAntialias(true)
        let paint = GitGraphGeometry.PaintMetrics(rowHeight: rowHeight,
            backingScale: abs(context.convertToDeviceSpace(CGSize(width: 1, height: 1)).width))

        let visible = dirtyRect.intersection(bounds)
        guard !visible.isEmpty else { return }
        let firstRow = max(0, Int(floor(visible.minY / rowHeight)))
        let lastRow = min(snapshot.rows.count - 1, Int(ceil(visible.maxY / rowHeight)))
        guard firstRow <= lastRow else { return }

        for index in firstRow...lastRow {
            let row = snapshot.rows[index]
            let top = CGFloat(index) * rowHeight

            for element in row.printElements {
                let segment = paint.line(for: element)
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
                stroke(line(from: start, to: end), color: edgeColor, width: paint.lineWidth, context: context)
                if element.hasArrow {
                    for arm in paint.arrowArms(for: element) {
                        let tip = CGPoint(x: arm.x, y: top + arm.y)
                        stroke(line(from: end, to: tip), color: edgeColor, width: paint.lineWidth, context: context)
                    }
                }
                context.restoreGState()
            }

            let nodeRect = paint.nodeRect(lane: row.nodeLane).offsetBy(dx: 0, dy: top)
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
