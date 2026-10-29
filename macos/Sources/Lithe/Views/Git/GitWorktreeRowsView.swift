import AppKit
import SwiftUI
import LitheGitModule

struct GitWorktreeRowsSnapshot: Equatable, Sendable {
    enum Identity: Equatable, Sendable {
        case changes(inspectionVersion: Int)
        case history(inspectionVersion: Int, query: String)
    }

    enum StatusColor: Equatable, Sendable {
        case success
        case warning
        case error
    }

    enum Row: Equatable, Sendable {
        case change(GitChange)
        case changelist(id: String, name: String, changes: [GitChange], expanded: Bool)
        case commit(subject: String, author: String, date: String)
    }

    let identity: Identity
    let rows: [Row]
    /// Staged state to show for a change instead of the row's own: the state the user just
    /// asked for, which Git has not confirmed yet.
    var stagedOverrides: [String: Bool] = [:]

    func isStaged(_ change: GitChange) -> Bool {
        stagedOverrides[change.id] ?? change.isStaged
    }
}

struct GitWorktreeRowsView: NSViewRepresentable {
    static let rowHeight = GitGraphGeometry.rowHeight

    let snapshot: GitWorktreeRowsSnapshot

    func makeNSView(context: Context) -> GitWorktreeRowsNSView {
        GitWorktreeRowsNSView()
    }

    func updateNSView(_ nsView: GitWorktreeRowsNSView, context: Context) {
        nsView.update(snapshot: snapshot, rowHeight: Self.rowHeight, locale: context.environment.locale)
    }
}

/// Owns the scrolling viewport for Worktree rows. Keeping NSScrollView as the
/// only scroll container means wheel events update the clip view bounds without
/// rebuilding the surrounding SwiftUI detail hierarchy.
struct GitWorktreeRowsScrollView: NSViewRepresentable, LitheTreeListNativeRenderer {
    @Environment(\.controlActiveState) private var controlActiveState
    let snapshot: GitWorktreeRowsSnapshot
    var contextID = ""
    var canLoadMore = false
    var isLoadingMore = false
    var loadMoreFailed = false
    var onLoadMore: (() -> Void)?
    var interaction: GitWorktreeChangeInteraction?

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(snapshot: snapshot)
    }

    static func makeScrollView(snapshot: GitWorktreeRowsSnapshot) -> NSScrollView {
        let scrollView = GitWorktreeRowsScrollNSView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller = LitheScrollViewChrome.CompactScroller()
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .allowed
        scrollView.usesPredominantAxisScrolling = true
        scrollView.scrollsDynamically = true

        let documentView = GitWorktreeRowsNSView()
        documentView.autoresizingMask = [.width]
        scrollView.documentView = documentView
        documentView.update(snapshot: snapshot, rowHeight: GitWorktreeRowsView.rowHeight)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let _ = controlActiveState
        Self.updateScrollView(nsView, snapshot: snapshot, contextID: contextID,
            canLoadMore: canLoadMore, isLoadingMore: isLoadingMore, loadMoreFailed: loadMoreFailed,
            locale: context.environment.locale, onLoadMore: onLoadMore)
        (nsView.documentView as? GitWorktreeRowsNSView)?.configureInteraction(interaction)
    }

    static func updateScrollView(
        _ nsView: NSScrollView, snapshot: GitWorktreeRowsSnapshot, contextID: String = "",
        canLoadMore: Bool = false, isLoadingMore: Bool = false, loadMoreFailed: Bool = false,
        locale: Locale = .current, onLoadMore: (() -> Void)? = nil
    ) {
        guard let documentView = nsView.documentView as? GitWorktreeRowsNSView else { return }
        let contextChanged = documentView.configurePaging(contextID: contextID, canLoadMore: canLoadMore,
            isLoadingMore: isLoadingMore, failed: loadMoreFailed, onLoadMore: onLoadMore)
        let previousOrigin = contextChanged ? CGPoint.zero : nsView.contentView.bounds.origin
        let contentChanged = documentView.update(snapshot: snapshot, rowHeight: GitWorktreeRowsView.rowHeight, locale: locale)
        let layoutChanged = documentView.updateLayout(width: nsView.contentView.bounds.width)
        if contentChanged || layoutChanged || contextChanged {
            nsView.contentView.setBoundsOrigin(Self.preservedScrollOrigin(
                previous: previousOrigin,
                documentHeight: documentView.bounds.height,
                viewportHeight: nsView.contentView.bounds.height
            ))
        }
        documentView.scheduleAutomaticLoading()
    }

    static func preservedScrollOrigin(
        previous: CGPoint,
        documentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGPoint {
        let maxY = max(0, documentHeight - viewportHeight)
        return CGPoint(
            x: max(previous.x, 0),
            y: min(max(previous.y, 0), maxY)
        )
    }
}

final class GitWorktreeRowsScrollNSView: NSScrollView {
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        (documentView as? GitWorktreeRowsNSView)?.scheduleAutomaticLoading()
    }

    override func layout() {
        super.layout()
        guard let document = documentView as? GitWorktreeRowsNSView else { return }
        document.updateLayout(width: contentView.bounds.width)
        document.scheduleAutomaticLoading()
    }
}

/// A single native drawing surface replaces one SwiftUI subtree per row. Its
/// dirty-rect range is the scrolling contract: moving the viewport visits only
/// the visible rows rather than rebuilding the entire Worktree section.
struct GitWorktreeChangeInteraction {
    var selectedIDs: Set<String>
    var isEnabled: Bool
    /// Whether checkboxes look usable. A click that arrives while a toggle is still being
    /// applied is ignored, but the boxes must not grey out and flash on every click.
    var paintsAsEnabled: Bool?
    var onSelection: (Set<String>) -> Void
    var onToggle: (GitChange) -> Void
    var onOpen: (GitChange) -> Void
    var menuItems: (GitChange) -> [LitheContextMenuItem]
    var onToggleList: (([GitChange]) -> Void)? = nil
    var onExpandList: ((String) -> Void)? = nil
}

final class GitWorktreeRowsNSView: NSControl {
    private var snapshot = GitWorktreeRowsSnapshot(
        identity: .changes(inspectionVersion: 0),
        rows: []
    )
    private var locale = Locale.current
    private var rowHeight = GitWorktreeRowsView.rowHeight
    private var drawingStyle: DrawingStyle?
    private var pagingContextID = ""
    private var canLoadMore = false
    private var isLoadingMore = false
    private var pageFailed = false
    private var requestedRowCount: Int?
    private var automaticLoadingScheduled = false
    private var onLoadMore: (() -> Void)?
    private var interaction: GitWorktreeChangeInteraction?
    private var selection = GitChangeSelection()
    private var cursorID: String?
    private var hoveredIndex: Int?
    private var hasChangelistHeaders = false

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { interaction != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        setAccessibilityRole(.list)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configureInteraction(_ interaction: GitWorktreeChangeInteraction?) {
        let hadInteraction = self.interaction != nil
        self.interaction = interaction
        if let interaction { selection.replace(with: interaction.selectedIDs) }
        if hadInteraction != (interaction != nil) { updateTrackingAreas() }
        needsDisplay = true
    }

    override func accessibilityChildren() -> [Any]? {
        guard interaction != nil else { return super.accessibilityChildren() }
        return snapshot.rows.enumerated().compactMap { index, content -> NSAccessibilityElement? in
            if case let .changelist(id, name, changes, expanded) = content {
                let header = GitWorktreeChangeAccessibilityElement()
                header.setAccessibilityParent(self)
                header.setAccessibilityRole(.row)
                header.setAccessibilityLabel(name)
                header.setAccessibilityFrameInParentSpace(rowRect(index))
                header.setAccessibilityExpanded(expanded)
                header.onPress = { [weak self] in self?.interaction?.onExpandList?(id) }
                let checkbox = GitWorktreeChangeAccessibilityElement()
                checkbox.setAccessibilityParent(header)
                checkbox.setAccessibilityRole(.checkBox)
                checkbox.setAccessibilityLabel(gitLocalizedFormat("Include in commit", locale: locale))
                checkbox.setAccessibilityValue(listStagingState(changes).rawValue)
                checkbox.setAccessibilityEnabled(interaction?.isEnabled == true && changes.contains(where: \.canToggleStaging))
                checkbox.setAccessibilityFrameInParentSpace(listCheckboxRect(in: rowRect(index)).offsetBy(dx: 0, dy: -CGFloat(index) * rowHeight))
                checkbox.onPress = { [weak self] in
                    guard let self, self.interaction?.isEnabled == true else { return }
                    self.interaction?.onToggleList?(changes)
                }
                header.setAccessibilityChildren([checkbox])
                return header
            }
            guard case let .change(change) = content else { return nil }
            let row = GitWorktreeChangeAccessibilityElement()
            row.setAccessibilityParent(self)
            row.setAccessibilityRole(.row)
            row.setAccessibilityLabel(change.path)
            row.setAccessibilitySelected(selection.ids.contains(change.id))
            row.setAccessibilityFrameInParentSpace(rowRect(index))
            row.onPress = { [weak self] in
                self?.select(change.id)
                if !change.isUntrackedDirectory { self?.interaction?.onOpen(change) }
            }
            let checkbox = GitWorktreeChangeAccessibilityElement()
            checkbox.setAccessibilityParent(row)
            checkbox.setAccessibilityRole(.checkBox)
            checkbox.setAccessibilityLabel(gitLocalizedFormat("Include in commit", locale: locale))
            checkbox.setAccessibilityValue(snapshot.isStaged(change) ? 1 : 0)
            checkbox.setAccessibilityEnabled(interaction?.isEnabled == true && change.canToggleStaging)
            checkbox.setAccessibilityFrameInParentSpace(changeCheckboxRect(in: rowRect(index)).offsetBy(dx: 0, dy: -CGFloat(index) * rowHeight))
            checkbox.onPress = { [weak self] in
                guard let self, self.interaction?.isEnabled == true, change.canToggleStaging else { return }
                self.interaction?.onToggle(change)
            }
            row.setAccessibilityChildren([checkbox])
            return row
        }
    }

    private var changes: [GitChange] {
        snapshot.rows.compactMap { if case .change(let change) = $0 { change } else { nil } }
    }

    private func change(at point: CGPoint) -> (Int, GitChange)? {
        guard point.y >= 0, bounds.contains(point) else { return nil }
        let index = Int(point.y / rowHeight)
        guard snapshot.rows.indices.contains(index), case .change(let change) = snapshot.rows[index] else { return nil }
        return (index, change)
    }

    static func checkboxRect(in row: CGRect) -> CGRect {
        let content = LitheTreeListAppearance.highlightRect(row)
        return CGRect(x: content.minX + LitheTheme.Tree.horizontalInset, y: row.minY,
                      width: LitheTheme.Tree.rowHeight, height: row.height)
    }

    private func rowRect(_ index: Int) -> CGRect {
        CGRect(x: 0, y: CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let rowIndex = point.y >= 0 ? Int(point.y / rowHeight) : -1
        if interaction != nil, bounds.contains(point), snapshot.rows.indices.contains(rowIndex),
           case let .changelist(id, _, changes, _) = snapshot.rows[rowIndex] {
            window?.makeFirstResponder(self)
            if listCheckboxRect(in: rowRect(rowIndex)).contains(point) {
                if interaction?.isEnabled == true { interaction?.onToggleList?(changes) }
            } else { interaction?.onExpandList?(id) }
            return
        }
        guard interaction != nil, let (index, change) = change(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        if event.modifierFlags.contains(.control) { _ = menu(for: event); return }
        window?.makeFirstResponder(self)
        if changeCheckboxRect(in: rowRect(index)).contains(convert(event.locationInWindow, from: nil)) {
            if interaction?.isEnabled == true && change.canToggleStaging { interaction?.onToggle(change) }
            return
        }
        select(change.id, command: event.modifierFlags.contains(.command), shift: event.modifierFlags.contains(.shift))
        if !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift), !change.isUntrackedDirectory {
            interaction?.onOpen(change)
        }
    }

    private func select(_ id: String, command: Bool = false, shift: Bool = false) {
        selection.select(id, orderedIDs: changes.map(\.id), command: command, shift: shift)
        cursorID = id
        interaction?.onSelection(selection.ids)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard interaction != nil else { super.keyDown(with: event); return }
        let changes = changes
        let current = changes.firstIndex { $0.id == cursorID }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
            selectAll(nil)
        } else if let key = LitheTreeListNavigationKey(rawValue: event.keyCode),
                  case .select(let index) = LitheTreeListNavigation.resolve(key, current: current, rows: changes.map { _ in .init() }) {
            select(changes[index].id, shift: event.modifierFlags.contains(.shift))
            scrollToVisible(rowRect(rowIndex(for: changes[index])))
        } else if event.keyCode == 115 || event.keyCode == 119 {
            let index = event.keyCode == 115 ? 0 : changes.count - 1
            guard changes.indices.contains(index) else { return }
            select(changes[index].id, shift: event.modifierFlags.contains(.shift))
            scrollToVisible(rowRect(rowIndex(for: changes[index])))
        } else if let current, event.keyCode == 49 {
            if interaction?.isEnabled == true, changes[current].canToggleStaging { interaction?.onToggle(changes[current]) }
        } else if let current, event.keyCode == 36 || event.keyCode == 76 {
            if !changes[current].isUntrackedDirectory { interaction?.onOpen(changes[current]) }
        } else { super.keyDown(with: event) }
    }

    override func selectAll(_ sender: Any?) {
        guard interaction != nil else { return }
        selection.replace(with: Set(changes.map(\.id)))
        interaction?.onSelection(selection.ids)
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let window, let (_, change) = change(at: convert(event.locationInWindow, from: nil)), let interaction else { return nil }
        // Resolve menu targets synchronously, before the selection callback rebuilds SwiftUI.
        let items = interaction.menuItems(change)
        window.makeFirstResponder(self)
        if !selection.ids.contains(change.id) { select(change.id) }
        LitheContextMenuPresenter.shared.show(items: items, at: window.convertPoint(toScreen: event.locationInWindow),
            appearance: effectiveAppearance, locale: locale)
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        if interaction != nil {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let index = change(at: convert(event.locationInWindow, from: nil))?.0
        guard index != hoveredIndex else { return }
        if let hoveredIndex { setNeedsDisplay(rowRect(hoveredIndex)) }
        hoveredIndex = index
        if let index { setNeedsDisplay(rowRect(index)) }
    }

    override func mouseExited(with event: NSEvent) {
        if let hoveredIndex { setNeedsDisplay(rowRect(hoveredIndex)) }
        hoveredIndex = nil
    }

    @discardableResult
    func configurePaging(contextID: String, canLoadMore: Bool, isLoadingMore: Bool,
                         failed: Bool, onLoadMore: (() -> Void)?) -> Bool {
        let contextChanged = pagingContextID != contextID
        if contextChanged || (self.isLoadingMore && !isLoadingMore) {
            requestedRowCount = nil
        }
        pagingContextID = contextID
        self.canLoadMore = canLoadMore
        self.isLoadingMore = isLoadingMore
        pageFailed = failed
        self.onLoadMore = onLoadMore
        return contextChanged
    }

    func scheduleAutomaticLoading() {
        guard !automaticLoadingScheduled else { return }
        automaticLoadingScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.automaticLoadingScheduled = false
            guard self.window != nil, !self.isHiddenOrHasHiddenAncestor,
                  self.canLoadMore, !self.isLoadingMore, !self.pageFailed,
                  let scroll = self.enclosingScrollView, scroll.contentView.bounds.height > 0,
                  scroll.contentView.bounds.maxY >= self.bounds.height - GitGraphGeometry.rowHeight * 10,
                  self.requestedRowCount != self.snapshot.rows.count else { return }
            self.requestedRowCount = self.snapshot.rows.count
            self.onLoadMore?()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { scheduleAutomaticLoading() }
    }

    @discardableResult
    func update(snapshot: GitWorktreeRowsSnapshot, rowHeight: CGFloat, locale: Locale = .current) -> Bool {
        guard self.snapshot != snapshot || self.rowHeight != rowHeight || self.locale != locale else { return false }
        self.locale = locale
        self.snapshot = snapshot
        hasChangelistHeaders = snapshot.rows.contains { if case .changelist = $0 { return true }; return false }
        self.rowHeight = rowHeight
        selection.retain(changes.map(\.id))
        if let cursorID, !changes.contains(where: { $0.id == cursorID }) { self.cursorID = nil }
        setAccessibilityLabel(snapshot.accessibilityLabel(locale: locale))
        setAccessibilityValue(gitLocalizedFormat("%lld rows", snapshot.rows.count, locale: locale))
        needsDisplay = true
        return true
    }

    @discardableResult
    func updateLayout(width: CGFloat) -> Bool {
        guard width.isFinite, width > 0 else { return false }
        let documentSize = CGSize(
            width: width,
            height: CGFloat(snapshot.rows.count) * rowHeight
        )
        guard frame.size != documentSize else { return false }
        setFrameSize(documentSize)
        needsDisplay = true
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        drawingStyle = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let range = Self.visibleRowRange(
                rowCount: snapshot.rows.count,
                rowHeight: rowHeight,
                dirtyRect: dirtyRect
              ) else { return }
        let style = resolvedDrawingStyle()
        context.setShouldAntialias(true)

        for index in range {
            let rowRect = CGRect(
                x: 0,
                y: CGFloat(index) * rowHeight,
                width: bounds.width,
                height: rowHeight
            )
            switch snapshot.rows[index] {
            case let .change(change):
                LitheTreeListAppearance.paint(rowRect, selected: selection.ids.contains(change.id),
                    focused: window?.isKeyWindow == true && window?.firstResponder === self, hovered: index == hoveredIndex)
                drawChange(change, in: rowRect, style: style)
            case let .changelist(_, name, changes, expanded):
                drawChangelist(name, changes: changes, expanded: expanded, in: rowRect, style: style)
            case let .commit(subject, author, date):
                drawCommit(
                    subject: subject,
                    author: author,
                    date: date,
                    in: rowRect,
                    style: style,
                    context: context
                )
            }
        }
    }

    static func visibleRowRange(
        rowCount: Int,
        rowHeight: CGFloat,
        dirtyRect: CGRect
    ) -> ClosedRange<Int>? {
        guard rowCount > 0, rowHeight > 0, !dirtyRect.isEmpty else { return nil }
        let first = max(0, Int(floor(dirtyRect.minY / rowHeight)))
        let last = min(rowCount - 1, Int(ceil(dirtyRect.maxY / rowHeight)))
        return first <= last ? first...last : nil
    }

    private func drawChange(_ change: GitChange, in rect: CGRect, style: DrawingStyle) {
        let isStaged = snapshot.isStaged(change)
        let stageText = isStaged ? gitLocalizedFormat("Staged", locale: locale) : gitLocalizedFormat("Unstaged", locale: locale)
        let content = LitheTreeListAppearance.highlightRect(rect).insetBy(dx: LitheTheme.Tree.horizontalInset, dy: 0)
        let stageWidth = ceil((stageText as NSString).size(withAttributes: [.font: style.bodyFont]).width)
        let stageX = max(content.minX, content.maxX - stageWidth)
        let checkbox = changeCheckboxRect(in: rect)
        let path = LitheTreeCheckbox.assetPath(state: isStaged ? .on : .off,
            enabled: (interaction?.paintsAsEnabled ?? interaction?.isEnabled) == true && change.canToggleStaging, focused: false)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let image = (dark ? LitheIcons.ideaImage(resourcePath: LitheIcons.darkIdeaAssetPath(for: path)) : nil)
            ?? LitheIcons.ideaImage(resourcePath: path)
        image?.draw(in: checkbox, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let iconX = checkbox.maxX + LitheTheme.Tree.iconTextGap
        let iconSize = LitheTheme.Tree.iconSize
        LitheIcons.ideaImage(for: LitheIcons.kind(for: change.url, isDirectory: change.isUntrackedDirectory), isDark: dark)?
            .draw(in: CGRect(x: iconX, y: rect.midY - iconSize / 2, width: iconSize, height: iconSize),
                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let textX = iconX + iconSize + LitheTheme.Tree.iconTextGap
        drawText(
            change.path,
            in: CGRect(
                x: textX,
                y: rect.minY,
                width: max(0, stageX - LitheTheme.Tree.horizontalInset - textX),
                height: rect.height
            ),
            font: style.bodyFont,
            color: NSColor(change.fileNameColor),
            lineBreakMode: .byTruncatingMiddle
        )
        drawText(
            stageText,
            in: CGRect(x: stageX, y: rect.minY, width: max(0, content.maxX - stageX), height: rect.height),
            font: style.bodyFont,
            color: style.primaryText,
            lineBreakMode: .byTruncatingTail,
            alignment: .right
        )
    }

    private func rowIndex(for change: GitChange) -> Int {
        snapshot.rows.firstIndex { if case .change(let row) = $0 { row.id == change.id } else { false } } ?? 0
    }

    private func listStagingState(_ changes: [GitChange]) -> NSControl.StateValue {
        let selectable = changes.filter(\.canToggleStaging)
        if !selectable.isEmpty, selectable.allSatisfy({ snapshot.isStaged($0) }) { return .on }
        return selectable.contains { snapshot.isStaged($0) } ? .mixed : .off
    }

    private func listCheckboxRect(in rect: CGRect) -> CGRect {
        Self.checkboxRect(in: rect).offsetBy(dx: LitheTheme.Tree.disclosureSlot, dy: 0)
    }

    private func changeCheckboxRect(in rect: CGRect) -> CGRect {
        Self.checkboxRect(in: rect).offsetBy(dx: hasChangelistHeaders ? LitheTheme.Tree.disclosureSlot + LitheTheme.Tree.indent : 0, dy: 0)
    }

    private func drawChangelist(_ name: String, changes: [GitChange], expanded: Bool, in rect: CGRect, style: DrawingStyle) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let disclosure = expanded ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg"
        let checkbox = listCheckboxRect(in: rect)
        func drawIcon(_ path: String, in bounds: CGRect) {
            let image = (dark ? LitheIcons.ideaImage(resourcePath: LitheIcons.darkIdeaAssetPath(for: path)) : nil)
                ?? LitheIcons.ideaImage(resourcePath: path)
            image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        drawIcon(disclosure, in: CGRect(x: Self.checkboxRect(in: rect).minX, y: rect.midY - 8, width: 16, height: 16))
        let path = LitheTreeCheckbox.assetPath(state: listStagingState(changes),
            enabled: (interaction?.paintsAsEnabled ?? interaction?.isEnabled) == true && changes.contains(where: \.canToggleStaging),
            focused: false)
        drawIcon(path, in: checkbox)
        let title = name + "  " + gitLocalizedFormat("%lld files", changes.reduce(0) { $0 + $1.fileCount }, locale: locale)
        drawText(title, in: CGRect(x: checkbox.maxX + LitheTheme.Tree.iconTextGap, y: rect.minY,
            width: max(0, rect.maxX - checkbox.maxX - 12), height: rect.height), font: style.bodyFont,
            color: style.secondaryText, lineBreakMode: .byTruncatingTail)
    }

    private func drawCommit(
        subject: String,
        author: String,
        date: String,
        in rect: CGRect,
        style: DrawingStyle,
        context: CGContext
    ) {
        let dotSize: CGFloat = 7
        context.setFillColor(style.accent.cgColor)
        context.fillEllipse(in: CGRect(
            x: 3,
            y: rect.midY - dotSize / 2,
            width: dotSize,
            height: dotSize
        ))
        let authorWidth: CGFloat = 116
        let dateWidth: CGFloat = 128
        let subjectX: CGFloat = 20
        drawText(
            subject,
            in: CGRect(
                x: subjectX,
                y: rect.minY,
                width: max(0, rect.width - subjectX - authorWidth - dateWidth - 16),
                height: rect.height
            ),
            font: style.bodyFont,
            color: style.primaryText,
            lineBreakMode: .byTruncatingTail
        )
        drawText(
            author,
            in: CGRect(
                x: max(subjectX, rect.maxX - authorWidth - dateWidth - 8),
                y: rect.minY,
                width: authorWidth,
                height: rect.height
            ),
            font: style.bodyFont,
            color: style.primaryText,
            lineBreakMode: .byTruncatingTail
        )
        drawText(
            date,
            in: CGRect(x: max(subjectX, rect.maxX - dateWidth), y: rect.minY, width: dateWidth - 8, height: rect.height),
            font: style.bodyFont,
            color: style.primaryText,
            lineBreakMode: .byTruncatingTail,
            alignment: .right
        )
    }

    private func drawText(
        _ text: String,
        in rect: CGRect,
        font: NSFont,
        color: NSColor,
        lineBreakMode: NSLineBreakMode,
        alignment: NSTextAlignment = .left
    ) {
        guard rect.width > 0 else { return }
        let paragraph = resolvedParagraphStyle(lineBreakMode: lineBreakMode, alignment: alignment)
        let height = ceil(font.ascender - font.descender)
        let textRect = CGRect(
            x: rect.minX,
            y: rect.midY - height / 2,
            width: rect.width,
            height: height
        )
        (text as NSString).draw(
            in: textRect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }

    private func resolvedParagraphStyle(
        lineBreakMode: NSLineBreakMode,
        alignment: NSTextAlignment
    ) -> NSParagraphStyle {
        let style = resolvedDrawingStyle()
        if lineBreakMode == .byTruncatingTail, alignment == .left { return style.bodyParagraph }
        if lineBreakMode == .byTruncatingMiddle, alignment == .left { return style.middleParagraph }
        if lineBreakMode == .byTruncatingTail, alignment == .right { return style.rightParagraph }
        return style.customParagraph(lineBreakMode: lineBreakMode, alignment: alignment)
    }

    private func resolvedDrawingStyle() -> DrawingStyle {
        if let drawingStyle { return drawingStyle }
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let style = DrawingStyle(isDark: isDark)
        drawingStyle = style
        return style
    }

    private struct DrawingStyle {
        let bodyFont = LitheTheme.uiNSFont(size: 13)
        let metadataFont = LitheTheme.uiNSFont(size: 12.5)
        let monospacedFont = LitheTheme.uiNSFont(size: 12.5, weight: .regular)
        let primaryText: NSColor
        let secondaryText: NSColor
        let accent: NSColor
        let success: NSColor
        let warning: NSColor
        let error: NSColor
        let bodyParagraph: NSParagraphStyle
        let middleParagraph: NSParagraphStyle
        let rightParagraph: NSParagraphStyle

        init(isDark: Bool) {
            primaryText = LitheTheme.nsColor(.primaryText, isDark: isDark)
            secondaryText = LitheTheme.nsColor(.secondaryText, isDark: isDark)
            accent = LitheTheme.nsColor(.accent, isDark: isDark)
            success = LitheTheme.nsColor(.success, isDark: isDark)
            warning = LitheTheme.nsColor(.warning, isDark: isDark)
            error = LitheTheme.nsColor(.error, isDark: isDark)
            bodyParagraph = Self.paragraph(lineBreakMode: .byTruncatingTail, alignment: .left)
            middleParagraph = Self.paragraph(lineBreakMode: .byTruncatingMiddle, alignment: .left)
            rightParagraph = Self.paragraph(lineBreakMode: .byTruncatingTail, alignment: .right)
        }

        func statusColor(_ color: GitWorktreeRowsSnapshot.StatusColor) -> NSColor {
            switch color {
            case .success: success
            case .warning: warning
            case .error: error
            }
        }

        func customParagraph(lineBreakMode: NSLineBreakMode, alignment: NSTextAlignment) -> NSParagraphStyle {
            Self.paragraph(lineBreakMode: lineBreakMode, alignment: alignment)
        }

        private static func paragraph(lineBreakMode: NSLineBreakMode, alignment: NSTextAlignment) -> NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = lineBreakMode
            paragraph.alignment = alignment
            return paragraph
        }
    }
}

private extension GitWorktreeRowsSnapshot {
    func accessibilityLabel(locale: Locale) -> String {
        switch identity {
        case .changes: gitLocalizedFormat("Worktree changes", locale: locale)
        case .history: gitLocalizedFormat("Worktree commit history", locale: locale)
        }
    }
}

private final class GitWorktreeChangeAccessibilityElement: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
}
