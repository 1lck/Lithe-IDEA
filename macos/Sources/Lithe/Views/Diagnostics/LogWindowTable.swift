import AppKit
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
        table.intercellSpacing = NSSize(width: 8, height: 1)
        table.allowsMultipleSelection = true; table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.backgroundColor = NSColor(LitheTheme.editor)
        for (index, column) in Self.columns.enumerated() {
            let value = NSTableColumn(identifier: .init(column))
            value.title = L10n.string(key: Self.titles[index])
            value.width = model.preferences.widths[column] ?? [55, 130, 90, 160, 210, 370, 330][index]
            value.minWidth = 40
            value.isHidden = model.preferences.hidden.contains(column)
            table.addTableColumn(value)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.owner = context.coordinator
        let header = LogTableHeaderView()
        header.owner = context.coordinator
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
        }
        struct Row { let id: String; let count: Int; let last: String; let isRun: Bool }
        let model: LogWindowModel
        weak var table: LogTableView?
        weak var scroll: NSScrollView?
        private var prepared: [String: Prepared] = [:]
        private(set) var rows: [Row] = []
        private var signature = ""
        private var scrollRevision = -1
        private var updating = false
        private var selectedRecord: RustCoreBridge.LogQueryRecord?
        private let timeFormatter: DateFormatter = {
            let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"; return formatter
        }()
        init(model: LogWindowModel) { self.model = model }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func update() {
            guard let table, let scroll else { return }
            selectedRecord = model.selected
            table.backgroundColor = NSColor(LitheTheme.editor)
            let oldTop = max(0, table.row(at: scroll.contentView.bounds.origin))
            let anchor = rows.indices.contains(oldTop) ? rows[oldTop].id : nil
            let offset = scroll.contentView.bounds.minY - CGFloat(oldTop) * 23
            let ids = Set(model.state.records.map(LogWindowModel.recordID))
            prepared = prepared.filter { ids.contains($0.key) }
            let newSignature = model.terms.filter { $0.kind == "text" && !$0.negate }.map(\.value).joined(separator: "\u{0}")
            if signature != newSignature { prepared.removeAll(keepingCapacity: true); signature = newSignature }
            for record in model.state.records {
                let id = LogWindowModel.recordID(record)
                if prepared[id] == nil { prepared[id] = prepare(record) }
            }
            var projected: [Row] = []
            var index = 0
            let records = model.state.records
            while index < records.count {
                var end = index + 1
                while end < records.count && records[end].foldKey == records[index].foldKey { end += 1 }
                let count = end - index, id = LogWindowModel.recordID(records[index])
                let collapse = model.preferences.collapse && count >= model.state.foldMinimumRun
                projected.append(.init(id: id, count: count, last: records[end - 1].ts, isRun: collapse))
                if !collapse || model.expandedRuns.contains(id) {
                    for child in (index + 1)..<end { projected.append(.init(id: LogWindowModel.recordID(records[child]), count: 1, last: "", isRun: false)) }
                }
                index = end
            }
            rows = projected
            updating = true
            for column in table.tableColumns { column.isHidden = model.preferences.hidden.contains(column.identifier.rawValue) }
            table.reloadData()
            table.selectRowIndexes(IndexSet(rows.indices.filter { model.state.selection.contains(rows[$0].id) }), byExtendingSelection: false)
            if model.state.follows, !rows.isEmpty { table.scrollRowToVisible(rows.count - 1) }
            else if scrollRevision != model.state.scrollRevision, let target = model.state.scrollTarget,
                    let row = rows.firstIndex(where: { $0.id == target }) { table.scrollRowToVisible(row) }
            else if let anchor, let row = rows.firstIndex(where: { $0.id == anchor }) {
                let point = NSPoint(x: scroll.contentView.bounds.minX, y: CGFloat(row) * 23 + offset)
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
                fields.append(NSAttributedString(string: key + "=", attributes: [.foregroundColor: NSColor.systemCyan]))
                let color: NSColor = (value == "‹redacted›" || value == "<redacted>") ? .secondaryLabelColor : (value == "true" || value == "false") ? .systemPink : Double(value) != nil ? .systemBlue : .systemGreen
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
                if value != "‹redacted›" && value != "<redacted>" { attributes[.link] = key }
                fields.append(NSAttributedString(string: value, attributes: attributes))
                fields.append(NSAttributedString(string: " "))
            }
            let message = NSMutableAttributedString(string: record.msg)
            for term in model.terms where term.kind == "text" && !term.negate && !term.value.isEmpty {
                let text = record.msg as NSString
                var search = NSRange(location: 0, length: text.length)
                while search.length > 0 {
                    let match = text.range(of: term.value, options: .caseInsensitive, range: search)
                    guard match.location != NSNotFound else { break }
                    message.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: match)
                    search = NSRange(location: NSMaxRange(match), length: text.length - NSMaxRange(match))
                }
            }
            return Prepared(record: record, time: time, fields: fields, message: message, channelColor: Self.channelColor(record.channel))
        }
        static func channelColor(_ channel: String) -> NSColor {
            let colors: [NSColor] = [.systemBlue, .systemPurple, .systemTeal, .systemOrange, .systemPink, .systemGreen]
            let hash = channel.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            return colors[Int(hash % UInt64(colors.count))]
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let column = tableColumn?.identifier,
                  let value = prepared[rows[row].id] else { return nil }
            let cell = tableView.makeView(withIdentifier: column, owner: self) as? LogCell ?? LogCell()
            cell.identifier = column
            cell.field.font = LitheTheme.editorFont(size: 11)
            cell.field.textColor = .labelColor; cell.field.toolTip = nil
            cell.wantsLayer = true; cell.layer?.backgroundColor = NSColor.clear.cgColor
            cell.layer?.cornerRadius = 3
            cell.onField = nil; cell.onFold = nil
            let record = value.record
            switch column.rawValue {
            case "seq": cell.field.stringValue = String(record.seq)
            case "time":
                let reference: Int64 = model.preferences.timeMode == 1 ? (row > 0 ? prepared[rows[row - 1].id]?.record.epochMs ?? record.epochMs : record.epochMs) : selectedRecord?.epochMs ?? record.epochMs
                cell.field.stringValue = model.preferences.timeMode == 0 ? value.time : String(format: "%+.0f ms", Double(record.epochMs - reference))
            case "level":
                cell.field.stringValue = (record.level == "ERROR" ? "● " : record.level == "WARN" ? "▲ " : "· ") + record.level
                cell.field.textColor = record.level == "ERROR" ? .systemRed : record.level == "WARN" ? .systemOrange : record.level == "INFO" ? .systemBlue : .secondaryLabelColor
            case "channel":
                cell.field.stringValue = record.channel; cell.field.textColor = value.channelColor
                cell.layer?.backgroundColor = value.channelColor.withAlphaComponent(0.10).cgColor
            case "event": cell.field.stringValue = record.event; cell.field.textColor = .systemPurple
            case "message":
                let text = NSMutableAttributedString()
                if rows[row].isRun {
                    text.append(NSAttributedString(string: "×\(rows[row].count) "))
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
                view.tint = record.level == "ERROR" ? NSColor.systemRed.withAlphaComponent(0.08) : (record.op != nil && record.op == selectedRecord?.op) ? NSColor.systemPurple.withAlphaComponent(0.08) : .clear
            }
            return view
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            model.select(Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }))
        }
        func tableViewColumnDidResize(_ notification: Notification) {
            guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
            model.setWidth(column.identifier.rawValue, width: column.width)
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
    var onField: ((String) -> Void)?
    var onFold: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1
        addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); field.frame = bounds.insetBy(dx: 2, dy: 2) }
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
            let index = layout.characterIndex(for: NSPoint(x: point.x - 2, y: point.y - 2), in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            if index < storage.length, let key = storage.attribute(.link, at: index, effectiveRange: nil) as? String { onField(key); return }
        }
        super.mouseDown(with: event)
    }
}
private final class LogRowView: NSTableRowView {
    var tint = NSColor.clear
    override func drawBackground(in dirtyRect: NSRect) { tint.setFill(); dirtyRect.fill() }
}
private final class LogScrollView: NSScrollView {
    var onUp: (() -> Void)?
    private var lastY: CGFloat = 0
    private var boundsObserver: NSObjectProtocol?
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
    override func rightMouseDown(with event: NSEvent) { owner?.headerContext(event: event) }
}
