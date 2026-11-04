import AppKit
import QuartzCore
import SwiftUI
import LitheModuleAPI

/// Fixed-height, view-based native table. Prepared text is retained once per record,
/// independent of viewport creation/reuse; scrolling never parses evidence.
struct LogWindowTable: NSViewRepresentable {
    @ObservedObject var model: LogWindowModel
    static let columns = ["seq", "time", "level", "channel", "event", "message", "fields"]
    static let titles = ["#", "Time", "Level", "Channel", "Event", "Message", "Fields"]
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = LogScrollView()
        let table = LogTableView()
        table.headerView = NSTableHeaderView()
        table.rowHeight = 22; table.usesAutomaticRowHeights = false
        table.intercellSpacing = NSSize(width: 10, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true; table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.backgroundColor = LogWindowPalette.bg
        for (index, column) in Self.columns.enumerated() {
            let value = NSTableColumn(identifier: .init(column))
            value.title = L10n.string(key: Self.titles[index])
            value.headerCell = LogHeaderCell(textCell: value.title)
            value.headerCell.alignment = index == 0 ? .right : .left
            value.width = model.preferences.widths[column] ?? [52, 96, 62, 170, 230, 160, 300][index]
            value.minWidth = 40
            value.isHidden = model.preferences.hidden.contains(column)
            table.addTableColumn(value)
        }
        table.preferredWidths = Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier, $0.width) })
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.owner = context.coordinator
        let header = LogTableHeaderView()
        header.owner = context.coordinator
        header.frame.size.height = 26
        table.headerView = header
        scroll.documentView = table
        let chrome = LitheScrollViewChrome.ScrollViewProbe(hideHorizontal: false, alwaysShowVertical: false, usesCompactScrollers: true)
        table.addSubview(chrome)
        chrome.frame = .zero
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.onUp = { [weak model] in model?.userScrolledUp() }
        context.coordinator.table = table
        context.coordinator.scroll = scroll
        table.setAccessibilityLabel(L10n.string("Logs"))
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update() }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        (view as? LogScrollView)?.onUp = nil
        coordinator.table?.delegate = nil; coordinator.table?.dataSource = nil
    }
    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        struct Prepared {
            let record: RustCoreBridge.LogQueryRecord
            let time: String
            let fields: NSAttributedString
            let message: NSAttributedString
            let channelColor: NSColor
            let channelWidth: CGFloat
        }
        typealias Row = LogWindowModel.DisplayRow
        let model: LogWindowModel
        weak var table: LogTableView?
        weak var scroll: NSScrollView?
        private var prepared: [String: Prepared] = [:]
        private(set) var rows: [Row] = []
        private var signature = ""
        private var appearanceName: NSAppearance.Name?
        private var scrollRevision = -1
        private var updating = false
        private var selectedRecord: RustCoreBridge.LogQueryRecord?
        private var renderedTimeMode = -1
        private var renderedReference: Int64?
        private var renderedSignature = ""
        private let timeFormatter: DateFormatter = {
            let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"; return formatter
        }()
        init(model: LogWindowModel) { self.model = model }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func update() {
            guard let table, let scroll else { return }
            selectedRecord = model.selected
            let appearanceChanged = appearanceName != table.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            if appearanceChanged {
                appearanceName = table.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]); prepared.removeAll(keepingCapacity: true)
            }
            table.backgroundColor = LogWindowPalette.bg
            let oldTop = max(0, table.row(at: scroll.contentView.bounds.origin))
            let anchor = rows.indices.contains(oldTop) ? rows[oldTop].id : nil
            let offset = scroll.contentView.bounds.minY - CGFloat(oldTop) * 22
            let ids = Set(model.state.records.map(LogWindowModel.recordID))
            prepared = prepared.filter { ids.contains($0.key) }
            let newSignature = model.terms.filter { $0.kind == "text" && !$0.negate }.map(\.value).joined(separator: "\u{0}")
            if signature != newSignature { prepared.removeAll(keepingCapacity: true); signature = newSignature }
            for record in model.state.records {
                let id = LogWindowModel.recordID(record)
                if prepared[id] == nil { prepared[id] = prepare(record) }
            }
            let nextRows = model.displayRows
            let oldCount = rows.count
            let reference = model.preferences.timeMode == 2 ? selectedRecord?.epochMs : nil
            let presentationChanged = appearanceChanged || renderedTimeMode != model.preferences.timeMode || renderedReference != reference || renderedSignature != signature
            let common = zip(rows, nextRows).prefix { $0 == $1 }.count
            updating = true
            for column in table.tableColumns { column.isHidden = model.preferences.hidden.contains(column.identifier.rawValue) }
            table.fitColumnsToViewport()
            rows = nextRows
            // Live append and fold changes replace only the affected suffix. Native
            // cells above it survive; selection and status updates do not repaint all rows.
            if !presentationChanged, table.dataSource === self, table.numberOfRows == oldCount,
               common >= max(0, oldCount - 1) {
                table.beginUpdates()
                if common < oldCount { table.removeRows(at: IndexSet(integersIn: common..<oldCount), withAnimation: []) }
                if common < rows.count { table.insertRows(at: IndexSet(integersIn: common..<rows.count), withAnimation: []) }
                table.endUpdates()
            } else { table.reloadData() }
            renderedTimeMode = model.preferences.timeMode; renderedReference = reference; renderedSignature = signature
            table.enumerateAvailableRowViews { view, index in
                guard let view = view as? LogRowView, self.rows.indices.contains(index),
                      let record = self.prepared[self.rows[index].id]?.record else { return }
                view.isOperation = record.op != nil && record.op == self.selectedRecord?.op
                view.needsDisplay = true
            }
            table.selectRowIndexes(IndexSet(rows.indices.filter { model.state.selection.contains(rows[$0].id) }), byExtendingSelection: false)
            if model.state.follows, !rows.isEmpty {
                if oldCount > 0, rows.count > oldCount, !presentationChanged {
                    let point = NSPoint(x: scroll.contentView.bounds.minX,
                        y: max(0, table.rect(ofRow: rows.count - 1).maxY - scroll.contentView.bounds.height))
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.1
                        context.timingFunction = CAMediaTimingFunction(name: .linear)
                        scroll.contentView.animator().setBoundsOrigin(point)
                    }
                } else { table.scrollRowToVisible(rows.count - 1) }
            }
            else if scrollRevision != model.state.scrollRevision, let target = model.state.scrollTarget,
                    let row = rows.firstIndex(where: { $0.id == target }) { table.scrollRowToVisible(row) }
            else if let anchor, let row = rows.firstIndex(where: { $0.id == anchor }) {
                let point = NSPoint(x: scroll.contentView.bounds.minX, y: CGFloat(row) * 22 + offset)
                scroll.contentView.scroll(to: point); scroll.reflectScrolledClipView(scroll.contentView)
            }
            scrollRevision = model.state.scrollRevision
            updating = false
        }
        private func prepare(_ record: RustCoreBridge.LogQueryRecord) -> Prepared {
            let time = timeFormatter.string(from: Date(timeIntervalSince1970: Double(record.epochMs) / 1000))
            let fields = NSMutableAttributedString()
            for key in record.fields.keys.sorted() {
                let value = record.fields[key]!
                fields.append(NSAttributedString(string: key + "=", attributes: [.foregroundColor: LogWindowPalette.cyn]))
                let color: NSColor = (value == "‹redacted›" || value == "<redacted>") ? LogWindowPalette.tx3 : (value == "true" || value == "false") ? LogWindowPalette.pnk : Double(value) != nil ? LogWindowPalette.blu : LogWindowPalette.grn
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
                if value != "‹redacted›" && value != "<redacted>" { attributes[.link] = key }
                let redacted = value == "‹redacted›" || value == "<redacted>"
                if redacted { attributes[.obliqueness] = 0.15 }
                let shown = redacted || Double(value) != nil || value == "true" || value == "false" ? value : "\"" + value + "\""
                fields.append(NSAttributedString(string: shown, attributes: attributes))
                fields.append(NSAttributedString(string: " "))
            }
            let message = NSMutableAttributedString(string: record.msg)
            for term in model.terms where term.kind == "text" && !term.negate && !term.value.isEmpty {
                let text = record.msg as NSString
                var search = NSRange(location: 0, length: text.length)
                while search.length > 0 {
                    let match = text.range(of: term.value, options: .caseInsensitive, range: search)
                    guard match.location != NSNotFound else { break }
                    message.addAttribute(.backgroundColor, value: LogWindowPalette.yel.withAlphaComponent(0.3), range: match)
                    search = NSRange(location: NSMaxRange(match), length: text.length - NSMaxRange(match))
                }
            }
            return Prepared(record: record, time: time, fields: fields, message: message, channelColor: Self.channelColor(record.channel),
                channelWidth: (record.channel as NSString).size(withAttributes: [.font: LitheTheme.editorFont(size: 11.5)]).width + 10)
        }
        static func channelColor(_ channel: String) -> NSColor {
            LogWindowPalette.channel(channel)
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let column = tableColumn?.identifier,
                  let value = prepared[rows[row].id] else { return nil }
            let cell = tableView.makeView(withIdentifier: column, owner: self) as? LogCell ?? LogCell()
            cell.identifier = column
            cell.field.font = LitheTheme.editorFont(size: 12.5)
            cell.field.textColor = LogWindowPalette.tx;
            cell.field.alignment = column.rawValue == "seq" ? .right : .left
            cell.tagColor = nil; cell.tagWidth = 0; cell.repeatText = nil; cell.field.toolTip = nil
            cell.wantsLayer = true; cell.layer?.backgroundColor = NSColor.clear.cgColor
            cell.layer?.cornerRadius = 3
            cell.onField = nil; cell.onFold = nil
            let record = value.record
            switch column.rawValue {
            case "seq": cell.field.stringValue = String(record.seq); cell.field.textColor = LogWindowPalette.tx3
            case "time":
                cell.field.textColor = LogWindowPalette.tx3
                let reference: Int64 = model.preferences.timeMode == 1 ? (row > 0 ? prepared[rows[row - 1].id]?.record.epochMs ?? record.epochMs : record.epochMs) : selectedRecord?.epochMs ?? record.epochMs
                cell.field.stringValue = model.preferences.timeMode == 0 ? value.time : String(format: "%+.0f ms", Double(record.epochMs - reference))
            case "level":
                cell.field.stringValue = LogWindowPalette.symbol(record.level) + " " + record.level
                cell.field.font = LitheTheme.editorFont(size: 11.5, weight: .semibold)
                cell.field.textColor = LogWindowPalette.level(record.level)
            case "channel":
                cell.field.stringValue = record.channel; cell.field.textColor = value.channelColor
                cell.tagColor = value.channelColor; cell.tagWidth = value.channelWidth
                cell.field.font = LitheTheme.editorFont(size: 11.5)
            case "event": cell.field.stringValue = record.event; cell.field.textColor = LogWindowPalette.pur
            case "message":
                let text = NSMutableAttributedString()
                if rows[row].isRun {
                    cell.repeatText = "×\(rows[row].count)"
                    cell.field.toolTip = String(format: L10n.string("Repeated %lld times · last %@"), Int64(rows[row].count), rows[row].last)
                    let id = rows[row].id
                    cell.onFold = { [weak self] in
                        guard let self else { return }
                        if self.model.expandedRuns.contains(id) { self.model.expandedRuns.remove(id) } else { self.model.expandedRuns.insert(id) }
                    }
                }
                text.append(value.message); cell.field.attributedStringValue = text
            case "fields":
                cell.field.attributedStringValue = value.fields
                cell.onField = { [weak self] key in
                    guard let self, let text = record.fields[key], text != "‹redacted›" && text != "<redacted>" else { return }
                    Task { await self.model.compose(kind: "field", key: key, value: text) }
                }
            default: break
            }
            cell.setAccessibilityLabel(cell.field.stringValue)
            return cell
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = LogRowView()
            if let record = prepared[rows[row].id]?.record {
                view.isError = record.level == "ERROR"
                view.isOperation = record.op != nil && record.op == selectedRecord?.op
            }
            return view
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            model.select(Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }))
        }
        func commitColumnWidths(previous: [NSUserInterfaceItemIdentifier: CGFloat]) {
            guard let table else { return }
            for column in table.tableColumns where previous[column.identifier] != column.width {
                table.preferredWidths[column.identifier] = column.width
                model.setWidth(column.identifier.rawValue, width: column.width)
            }
            table.fitColumnsToViewport()
        }
        func copy(format: String, only: RustCoreBridge.LogQueryRecord? = nil) {
            let records = only.map { [$0] } ?? model.selectedRecords
            Task {
                if let text = await model.formatted(records: records, format: format) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
        func headerContext(event: NSEvent) {
            guard let table, let window = table.window else { return }
            let items = LogWindowTable.columns.enumerated().map { index, column in
                LitheContextMenuItem.action(LogWindowTable.titles[index], checked: !model.preferences.hidden.contains(column)) { [weak self] in
                    guard let self else { return }
                    self.model.setColumn(column, hidden: !self.model.preferences.hidden.contains(column))
                }
            }
            LitheContextMenuPresenter.shared.show(items: items, at: window.convertPoint(toScreen: event.locationInWindow),
                appearance: table.effectiveAppearance, locale: InterfaceLanguage.locale, parentWindow: window)
        }
        func context(row: Int, event: NSEvent) {
            guard rows.indices.contains(row), let table, let record = prepared[rows[row].id]?.record,
                  let window = table.window else { return }
            if !model.state.selection.contains(rows[row].id) { model.select([rows[row].id]) }
            let items: [LitheContextMenuItem] = [
                .action("Copy line") { self.copy(format: "json", only: record) },
                .action("Copy selection as Markdown") { self.copy(format: "markdown") }, .separator,
                .action("Show only this event") { Task { await self.model.compose(kind: "event", value: record.event) } },
                .action("Hide this event") { Task { await self.model.compose(kind: "event", value: record.event, negate: true) } },
                .action("Show only this channel") { Task { await self.model.compose(kind: "channel", value: record.channel) } },
                .action("Trace this operation", isEnabled: record.op != nil) { if let op = record.op { Task { await self.model.compose(kind: "op", value: op) } } },
                .submenu("Copy field value", items: record.fields.keys.sorted().filter { record.fields[$0] != "‹redacted›" && record.fields[$0] != "<redacted>" }.map { key in
                    .action(key, localizesTitle: false) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.fields[key]!, forType: .string)
                    }
                })
            ]
            LitheContextMenuPresenter.shared.show(items: items, at: window.convertPoint(toScreen: event.locationInWindow),
                appearance: table.effectiveAppearance, locale: InterfaceLanguage.locale, parentWindow: window)
        }
    }
}

private final class LogCell: NSTableCellView {
    let field = NSTextField(labelWithString: "")
    var tagColor: NSColor?
    var tagWidth: CGFloat = 0
    var repeatText: String?
    var onField: ((String) -> Void)?
    var onFold: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1
        addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let inset: CGFloat = tagColor == nil ? 0 : 5
        let prefix: CGFloat = repeatText == nil ? 0 : 48
        field.frame = NSRect(x: inset + prefix, y: 2, width: max(0, bounds.width - inset * 2 - prefix), height: 18)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let tagColor {
            tagColor.withAlphaComponent(0.15).setFill()
            let width = min(bounds.width, tagWidth)
            NSBezierPath(roundedRect: NSRect(x: 0, y: 3, width: width, height: 16), xRadius: 3, yRadius: 3).fill()
        }
        if let repeatText {
            let rect = NSRect(x: 0, y: 3, width: 43, height: 16)
            LogWindowPalette.bg3.setFill(); NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            LogWindowPalette.bd.setStroke(); NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
            (repeatText as NSString).draw(at: NSPoint(x: 5, y: 3), withAttributes: [.font: LitheTheme.editorFont(size: 11), .foregroundColor: LogWindowPalette.tx2])
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        if let onFold, convert(event.locationInWindow, from: nil).x < 65 { onFold(); return }
        if let onField {
            let point = convert(event.locationInWindow, from: nil)
            let storage = NSTextStorage(attributedString: field.attributedStringValue)
            let layout = NSLayoutManager(); let container = NSTextContainer(containerSize: field.bounds.size)
            container.lineFragmentPadding = 0; layout.addTextContainer(container); storage.addLayoutManager(layout)
            let index = layout.characterIndex(for: NSPoint(x: point.x - field.frame.minX, y: point.y - field.frame.minY), in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            if index < storage.length, let key = storage.attribute(.link, at: index, effectiveRange: nil) as? String { onField(key); return }
        }
        super.mouseDown(with: event)
    }
}
private final class LogRowView: NSTableRowView {
    var isError = false
    var isOperation = false
    override func drawBackground(in dirtyRect: NSRect) {
        (isError ? LogWindowPalette.errrow : isOperation ? LogWindowPalette.oprow : LogWindowPalette.bg).setFill(); bounds.fill()
        LogWindowPalette.line.setFill(); NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        if isOperation { LogWindowPalette.pur.setFill(); NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill() }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        (isError ? LogWindowPalette.errsel : LogWindowPalette.hl).setFill(); bounds.fill()
        LogWindowPalette.blu.setFill(); NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
        LogWindowPalette.line.setFill(); NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
private final class LogHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        LogWindowPalette.bg2.setFill(); cellFrame.fill()
        font = LitheTheme.editorFont(size: 11); textColor = LogWindowPalette.tx3
        drawInterior(withFrame: cellFrame.insetBy(dx: 0, dy: 4), in: controlView)
        LogWindowPalette.line.setFill(); NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        LogWindowPalette.bd.setFill(); NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 4, width: 1, height: cellFrame.height - 8).fill()
    }
}

private final class LogScrollView: NSScrollView {
    var onUp: (() -> Void)?
    private var lastY: CGFloat = 0
    private var boundsObserver: NSObjectProtocol?
    override func tile() {
        super.tile()
        (documentView as? LogTableView)?.fitColumnsToViewport()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver); self.boundsObserver = nil }
        guard window != nil else { return }
        contentView.postsBoundsChangedNotifications = true
        lastY = contentView.bounds.minY
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in
            guard let self else { return }
            let y = self.contentView.bounds.minY
            if y < self.lastY, NSApp.currentEvent?.type == .leftMouseDragged { self.onUp?() }
            self.lastY = y
        }
    }
    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }
    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY > 0 { onUp?() }
        super.scrollWheel(with: event)
    }
}
final class LogTableView: NSTableView {
    weak var owner: LogWindowTable.Coordinator?
    var preferredWidths: [NSUserInterfaceItemIdentifier: CGFloat] = [:]
    var isResizingColumns = false
    private(set) var isFittingColumns = false

    /// Widths are presentation state: resizing never reloads records or persists
    /// the space added by the viewport. Narrow windows keep horizontal scrolling.
    func fitColumnsToViewport() {
        guard !isFittingColumns, !isResizingColumns, !preferredWidths.isEmpty, let scroll = enclosingScrollView else { return }
        let visible = tableColumns.filter { !$0.isHidden }
        guard !visible.isEmpty else { return }
        let flexible = visible.filter { ["event", "message", "fields"].contains($0.identifier.rawValue) }
        let expanding = flexible.isEmpty ? Array(visible.suffix(1)) : flexible
        let baseline = visible.reduce(CGFloat.zero) { $0 + (preferredWidths[$1.identifier] ?? $1.width) + intercellSpacing.width }
        let spare = max(0, scroll.contentSize.width - baseline)
        let weight = expanding.reduce(CGFloat.zero) { $0 + (preferredWidths[$1.identifier] ?? $1.width) }
        isFittingColumns = true
        defer { isFittingColumns = false }
        for column in visible {
            let preferred = preferredWidths[column.identifier] ?? column.width
            let extra = expanding.contains(column) ? spare * preferred / max(1, weight) : 0
            let width = preferred + extra
            if abs(column.width - width) > 0.1 { column.width = width }
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { owner?.copy(format: "json"); return }
        if event.keyCode == 53 { owner?.model.select([]); return }
        super.keyDown(with: event)
    }
    override func rightMouseDown(with event: NSEvent) {
        owner?.context(row: row(at: convert(event.locationInWindow, from: nil)), event: event)
    }
}

private final class LogTableHeaderView: NSTableHeaderView {
    weak var owner: LogWindowTable.Coordinator?
    override func mouseDown(with event: NSEvent) {
        let widths = Dictionary(uniqueKeysWithValues: (tableView?.tableColumns ?? []).map { ($0.identifier, $0.width) })
        (tableView as? LogTableView)?.isResizingColumns = true
        super.mouseDown(with: event)
        (tableView as? LogTableView)?.isResizingColumns = false
        owner?.commitColumnWidths(previous: widths)
    }
    override func rightMouseDown(with event: NSEvent) { owner?.headerContext(event: event) }
}
