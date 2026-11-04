import AppKit
import SwiftUI
import LitheModuleAPI

/// Native selection retains the mouse event's modifiers, including Command-click.
/// Shared list chrome still owns selection geometry, colors and scrolling.
struct LogChannelList: NSViewRepresentable, LitheTreeListNativeRenderer {
    let rows: [LogWindowView.ChannelRow]
    let unread: Set<String>
    @Binding var selection: Set<String>

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let table = LogChannelTableView()
        table.headerView = nil
        table.rowHeight = LitheTheme.Tree.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.focusRingType = .none
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: .init("channel"))
        column.width = 212
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.setAccessibilityLabel(L10n.string("All channels"))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.parent = self
        context.coordinator.updating = true
        table.reloadData()
        table.selectRowIndexes(IndexSet(rows.indices.filter { rows[$0].root == nil && selection.contains(rows[$0].id) }), byExtendingSelection: false)
        context.coordinator.updating = false
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll.documentView as? NSTableView)?.delegate = nil
        (scroll.documentView as? NSTableView)?.dataSource = nil
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: LogChannelList
        var updating = false
        init(_ parent: LogChannelList) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { parent.rows[row].root == nil }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            parent.selection = Set(table.selectedRowIndexes.map { parent.rows[$0].id })
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ChannelRowView() }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = parent.rows[row]
            let cell = tableView.makeView(withIdentifier: .init("channel"), owner: self) as? ChannelCell ?? ChannelCell()
            cell.identifier = .init("channel")
            if let root = item.root {
                cell.name.stringValue = root
                cell.name.textColor = LogWindowPalette.tx3
                cell.count.stringValue = ""
            } else {
                let parts = item.id.split(separator: "/")
                let title = item.id.isEmpty ? L10n.string("All channels") : parts.count == 1 ? item.id : parts.dropFirst().filter { $0 != "host" }.joined(separator: "/")
                cell.name.stringValue = (item.id.isEmpty ? "□ " : "■ ") + title + (parent.unread.contains(item.id) ? " ●" : "")
                cell.name.textColor = item.id.isEmpty ? LogWindowPalette.tx : LogWindowPalette.channel(item.id)
                cell.count.stringValue = item.count.formatted(.number.locale(Locale(identifier: "en_US")))
            }
            cell.setAccessibilityIdentifier("logs.channel." + item.id)
            cell.setAccessibilityLabel(cell.name.stringValue)
            return cell
        }
    }
}

final class LogChannelTableView: NSTableView {
    private var anchor: String?
    override func mouseDown(with event: NSEvent) {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0, delegate?.tableView?(self, shouldSelectRow: index) != false else { return }
        window?.makeFirstResponder(self)
        let visible = (0..<numberOfRows).filter { delegate?.tableView?(self, shouldSelectRow: $0) != false }
        let order = visible.map(String.init)
        let selected = LitheTreeListSelection.select(String(index), in: order,
            selected: Set(selectedRowIndexes.map(String.init)), anchor: anchor,
            extending: event.modifierFlags.contains(.shift), toggling: event.modifierFlags.contains(.command))
        if !event.modifierFlags.contains(.shift) || anchor == nil { anchor = String(index) }
        selectRowIndexes(IndexSet(selected.compactMap(Int.init)), byExtendingSelection: false)
    }
}

private final class ChannelCell: NSTableCellView {
    let name = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = LitheTheme.uiNSFont(size: 12)
        name.lineBreakMode = .byTruncatingTail
        count.font = LitheTheme.editorFont(size: 11)
        count.textColor = LogWindowPalette.tx3
        count.alignment = .right
        addSubview(name); addSubview(count)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        name.frame = NSRect(x: 12, y: 3, width: max(0, bounds.width - 64), height: 18)
        count.frame = NSRect(x: max(0, bounds.width - 48), y: 3, width: 36, height: 18)
    }
}

private final class ChannelRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        LitheTreeListAppearance.paint(bounds, selected: isSelected,
            focused: window?.isKeyWindow == true && window?.firstResponder === superview, hovered: false)
    }
    override func drawSelection(in dirtyRect: NSRect) { drawBackground(in: dirtyRect) }
}
