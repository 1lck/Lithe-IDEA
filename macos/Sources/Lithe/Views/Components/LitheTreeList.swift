import AppKit
import SwiftUI

/// Features publish visible rows; expansion and asynchronous loading stay with the data owner.
struct LitheTreeListHierarchy {
    var depth = 0
    var isBranch = false
    var isExpanded = false
    var isSelectable = true

    var isKeyboardNavigable: Bool { isSelectable || isBranch }

    func activate(onExpansion: ((Bool) -> Void)?, onActivate: (() -> Void)?) {
        if isBranch, let onExpansion {
            onExpansion(!isExpanded)
        } else {
            onActivate?()
        }
    }
}

/// The disclosure glyph and its slot are shared with the native Project renderer.
struct LitheTreeDisclosureIcon: View {
    let isExpanded: Bool

    var body: some View {
        LitheIDEAIcon(
            resourcePath: isExpanded ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg",
            size: LitheTheme.Tree.iconSize,
            fallbackSystemImage: isExpanded ? "chevron.down" : "chevron.right",
            preservesOriginalColors: true
        )
        .frame(width: LitheTheme.Tree.disclosureSlot, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// Adapter for an existing native pointer/clipboard owner (dragging, filesystem selection).
/// Focus observation and key routing still live inside the shared control.
struct LitheTreeListNativeInteraction<ID: Hashable> {
    var rowHeight = LitheTheme.Tree.rowHeight
    var copy: () -> Void
    var paste: () -> Void
    var selectAll: () -> Void
    var navigate: (ProjectTreeNavigationKey, Bool) -> ID?
    var isSelected: (ID) -> Bool
}

struct LitheTreeListScrollRequest<ID: Hashable>: Equatable {
    let id: ID
    var revision = UUID()
}

/// Complete tree/list owner. Row builders provide content, never focus or highlight chrome.
struct LitheTreeList<Data: RandomAccessCollection, ID: Hashable, RowContent: View>: View {
    typealias Item = Data.Element
    private let items: Data
    private let id: KeyPath<Item, ID>
    private let selection: Binding<Set<ID>>
    private let allowsMultipleSelection: Bool
    private let togglesSelectionOnClick: Bool
    private let hierarchy: (Item) -> LitheTreeListHierarchy
    private let onExpansion: ((Item, Bool) -> Void)?
    private let onActivate: ((Item) -> Void)?
    private let onClick: ((Item) -> Void)?
    private let contextMenu: ((Item) -> [LitheContextMenuItem])?
    private let multiline: Bool
    private let retainsSearchFocus: Bool
    private let native: LitheTreeListNativeInteraction<ID>?
    private let scrollRequest: LitheTreeListScrollRequest<ID>?
    private let row: (Item) -> RowContent
    private var nativeRenderer: AnyView?
    @State private var anchor: ID?
    @State private var cursor: ID?
    @State private var internalSelection: Set<ID>?
    @State private var isActive = false
    @FocusState private var isFocused: Bool

    init(
        _ items: Data, id: KeyPath<Item, ID>, selection: Binding<ID?>,
        hierarchy: @escaping (Item) -> LitheTreeListHierarchy = { _ in .init() },
        onExpansion: ((Item, Bool) -> Void)? = nil, onActivate: ((Item) -> Void)? = nil,
        onClick: ((Item) -> Void)? = nil,
        contextMenu: ((Item) -> [LitheContextMenuItem])? = nil, multiline: Bool = false,
        retainsSearchFocus: Bool = false,
        native: LitheTreeListNativeInteraction<ID>? = nil, scrollRequest: LitheTreeListScrollRequest<ID>? = nil,
        @ViewBuilder row: @escaping (Item) -> RowContent
    ) {
        self.init(
            items, id: id,
            selection: Binding(
                get: { selection.wrappedValue.map { Set([$0]) } ?? [] },
                set: { selection.wrappedValue = $0.first }), allowsMultipleSelection: false,
            hierarchy: hierarchy, onExpansion: onExpansion, onActivate: onActivate, onClick: onClick,
            contextMenu: contextMenu, multiline: multiline, retainsSearchFocus: retainsSearchFocus, native: native,
            scrollRequest: scrollRequest, row: row)
    }

    init(
        _ items: Data, id: KeyPath<Item, ID>, selection: Binding<Set<ID>>,
        allowsMultipleSelection: Bool = true, togglesSelectionOnClick: Bool = false,
        hierarchy: @escaping (Item) -> LitheTreeListHierarchy = { _ in .init() },
        onExpansion: ((Item, Bool) -> Void)? = nil, onActivate: ((Item) -> Void)? = nil,
        onClick: ((Item) -> Void)? = nil,
        contextMenu: ((Item) -> [LitheContextMenuItem])? = nil, multiline: Bool = false,
        retainsSearchFocus: Bool = false,
        native: LitheTreeListNativeInteraction<ID>? = nil, scrollRequest: LitheTreeListScrollRequest<ID>? = nil,
        @ViewBuilder row: @escaping (Item) -> RowContent
    ) {
        self.items = items
        self.id = id
        self.selection = selection
        self.allowsMultipleSelection = allowsMultipleSelection
        self.togglesSelectionOnClick = togglesSelectionOnClick
        self.hierarchy = hierarchy
        self.onExpansion = onExpansion
        self.onActivate = onActivate
        self.onClick = onClick
        self.contextMenu = contextMenu
        self.multiline = multiline
        self.retainsSearchFocus = retainsSearchFocus
        self.row = row
        self.native = native
        self.scrollRequest = scrollRequest
    }

    @ViewBuilder var body: some View {
        if let nativeRenderer { nativeRenderer } else { standardBody }
    }

    private var standardBody: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(native == nil ? .vertical : [.vertical, .horizontal]) {
                    // Flat, lazy rows preserve viewport work for large trees. No per-row geometry preferences.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items, id: id) { item in entry(item).id(item[keyPath: id]) }
                    }
                    .padding(.horizontal, LitheTheme.Tree.horizontalInset)
                    .padding(.vertical, LitheTheme.Tree.verticalInset)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
                .litheScrollViewChrome()
                .focusable(!retainsSearchFocus)
                .focused($isFocused)
                .litheFocusEffectHidden()
                .background {
                    if let native {
                        ProjectTreeKeyboardCommands(
                            copy: native.copy, paste: native.paste, selectAll: native.selectAll,
                            navigate: { key, extending in
                                if let target = native.navigate(key, extending) { proxy.scrollTo(target) }
                            }, focusChanged: { isActive = $0 })
                    } else {
                        LitheToolWindowActivityTracker(
                            isActive: $isActive,
                            onPointerActivity: { inside in
                                // Native pointer owners can consume keys while SwiftUI still has its previous proxy.
                                if !inside { isFocused = false }
                            })
                    }
                }
                .onChange(of: scrollRequest) { request in
                    if let request { proxy.scrollTo(request.id, anchor: .center) }
                }
                .onMoveCommand { direction in
                    navigate(direction, extending: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                    if let cursor { proxy.scrollTo(cursor) }
                }
                .onCommand(#selector(NSResponder.insertNewline(_:)), perform: activate)
                .onCommand(#selector(NSResponder.moveUpAndModifySelection(_:))) { navigate(.up, extending: true) }
                .onCommand(#selector(NSResponder.moveDownAndModifySelection(_:))) { navigate(.down, extending: true) }
                .onCommand(#selector(NSResponder.moveToBeginningOfDocument(_:))) { selectBoundary(last: false) }
                .onCommand(#selector(NSResponder.moveToEndOfDocument(_:))) { selectBoundary(last: true) }
                .onCommand(#selector(NSResponder.selectAll(_:))) {
                    if allowsMultipleSelection {
                        let all = Set(items.filter { hierarchy($0).isSelectable }.map { $0[keyPath: id] })
                        internalSelection = all
                        selection.wrappedValue = all
                    }
                }
                .onChange(of: selection.wrappedValue) { selected in
                    if native == nil, selected != internalSelection {
                        // Only external changes reset the range origin. A Shift
                        // selection must retain its keyboard cursor and anchor.
                        cursor = items.first { selected.contains($0[keyPath: id]) && hierarchy($0).isSelectable }?[keyPath: id]
                        anchor = cursor
                    }
                    internalSelection = nil
                    if let target = LitheTreeListSelection.revealTarget(
                        cursor: cursor, selected: selected,
                        visible: items.map { $0[keyPath: id] })
                    {
                        proxy.scrollTo(target)
                    }
                    if let cursor, !items.contains(where: { $0[keyPath: id] == cursor }) { self.cursor = nil }
                }
            }
        }
    }

    private func entry(_ item: Item) -> some View {
        let state = hierarchy(item)
        let itemID = item[keyPath: id]
        return HStack(spacing: LitheTheme.Tree.iconTextGap) {
            if state.isBranch, let onExpansion {
                Button {
                    onExpansion(item, !state.isExpanded)
                } label: {
                    LitheTreeDisclosureIcon(isExpanded: state.isExpanded)
                }
                .buttonStyle(.litheNoPress)
                .accessibilityLabel(state.isExpanded ? Text("Collapse") : Text("Expand"))
                .accessibilityValue(state.isExpanded ? Text("Expanded") : Text("Collapsed"))
            } else if onExpansion != nil {
                Color.clear.frame(width: LitheTheme.Tree.disclosureSlot)
            }
            row(item).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, native == nil ? CGFloat(max(0, state.depth)) * LitheTheme.Tree.indent : 0)
        .font(LitheTheme.uiFont(size: 13))
        .foregroundStyle(LitheTheme.Tree.text)
        .frame(
            maxWidth: .infinity, minHeight: native?.rowHeight ?? LitheTheme.Tree.rowHeight,
            maxHeight: multiline ? nil : native?.rowHeight ?? LitheTheme.Tree.rowHeight, alignment: .leading
        )
        .contentShape(Rectangle())
        .modifier(
            LitheTreeListRowSurface(
                isSelected: native?.isSelected(itemID)
                    ?? (selection.wrappedValue.contains(itemID)
                        || (!state.isSelectable && state.isBranch && cursor == itemID)),
                isFocused: retainsSearchFocus || isFocused || isActive)
        )
        .onTapGesture {
            guard native == nil else { return }
            if !retainsSearchFocus { isFocused = true }
            if state.isSelectable {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                select(
                    itemID, extending: flags.contains(.shift),
                    toggling: togglesSelectionOnClick || flags.contains(.command))
                if !flags.contains(.shift), !flags.contains(.command) { onClick?(item) }
            } else {
                cursor = itemID
                // A group already expands on its first click; the second click must not undo it.
                if state.isBranch, (NSApp.currentEvent?.clickCount ?? 1) == 1 {
                    onExpansion?(item, !state.isExpanded)
                }
            }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            // Project's native pointer owner already handles its own double click.
            guard native == nil, state.isSelectable else { return }
            activate(item)
        })
        .modifier(
            LitheTreeListMenu(
                items: contextMenu.map { menu in { menu(item) } },
                onRightClick: {
                    if !retainsSearchFocus { isFocused = true }
                    if state.isSelectable, !selection.wrappedValue.contains(itemID) { select(itemID) }
                })
        )
        .environment(
            \.litheTreeListRowState,
            (selection.wrappedValue.contains(itemID), retainsSearchFocus || isFocused || isActive)
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(state.isSelectable || state.isBranch ? .isButton : [])
        .accessibilityAddTraits(selection.wrappedValue.contains(itemID) ? [.isSelected] : [])
        .accessibilityAction {
            if state.isSelectable {
                if !retainsSearchFocus { isFocused = true }
                select(itemID)
                activate(item)
            } else if state.isBranch {
                onExpansion?(item, !state.isExpanded)
            }
        }
    }

    private func select(_ target: ID, extending: Bool = false, toggling: Bool = false) {
        guard let item = items.first(where: { $0[keyPath: id] == target }), hierarchy(item).isSelectable else {
            cursor = target
            return
        }
        let order = items.filter { hierarchy($0).isSelectable }.map { $0[keyPath: id] }
        let previous = cursor ?? order.first { selection.wrappedValue.contains($0) }
        let selected = LitheTreeListSelection.select(
            target, in: order,
            selected: selection.wrappedValue, anchor: anchor ?? previous,
            extending: allowsMultipleSelection && extending, toggling: allowsMultipleSelection && toggling)
        if !extending || anchor == nil { anchor = extending ? previous ?? target : target }
        cursor = target
        internalSelection = selected
        selection.wrappedValue = selected
    }

    private func selectBoundary(last: Bool) {
        let available = items.filter { hierarchy($0).isSelectable }
        if let item = last ? available.last : available.first { select(item[keyPath: id]) }
    }

    private func activate() {
        if let target = cursor
            ?? items.first(where: { selection.wrappedValue.contains($0[keyPath: id]) })?[keyPath: id],
            let item = items.first(where: { $0[keyPath: id] == target })
        {
            activate(item)
        }
    }

    private func activate(_ item: Item) {
        hierarchy(item).activate(
            onExpansion: onExpansion.map { expand in { expand(item, $0) } },
            onActivate: (onActivate ?? onClick).map { activate in { activate(item) } })
    }

    private func navigate(_ direction: MoveCommandDirection, extending: Bool) {
        let key: LitheTreeListNavigationKey
        switch direction {
        case .up: key = .up
        case .down: key = .down
        case .left: key = .left
        case .right: key = .right
        default: return
        }
        if let native {
            cursor = native.navigate(key, extending)
            return
        }
        let visible = Array(items)
        let current = cursor ?? visible.first(where: { selection.wrappedValue.contains($0[keyPath: id]) })?[keyPath: id]
        let index = visible.firstIndex { $0[keyPath: id] == current }
        switch LitheTreeListNavigation.resolve(key, current: index, rows: visible.map(hierarchy)) {
        case .select(let index):
            select(visible[index][keyPath: id], extending: extending && (key == .up || key == .down))
        case .expand(let index, let expanded): onExpansion?(visible[index], expanded)
        case nil: break
        }
    }

}

extension LitheTreeList where Item: Identifiable, ID == Item.ID {
    init(
        _ items: Data, selection: Binding<ID?>,
        hierarchy: @escaping (Item) -> LitheTreeListHierarchy = { _ in .init() },
        onExpansion: ((Item, Bool) -> Void)? = nil, onActivate: ((Item) -> Void)? = nil,
        onClick: ((Item) -> Void)? = nil,
        contextMenu: ((Item) -> [LitheContextMenuItem])? = nil, multiline: Bool = false,
        retainsSearchFocus: Bool = false,
        native: LitheTreeListNativeInteraction<ID>? = nil, scrollRequest: LitheTreeListScrollRequest<ID>? = nil,
        @ViewBuilder row: @escaping (Item) -> RowContent
    ) {
        self.init(
            items, id: \.id, selection: selection, hierarchy: hierarchy, onExpansion: onExpansion,
            onActivate: onActivate, onClick: onClick, contextMenu: contextMenu, multiline: multiline,
            retainsSearchFocus: retainsSearchFocus, native: native, scrollRequest: scrollRequest, row: row)
    }
}

/// Shared selection policy, also usable by native renderers without replacing their drawing.
enum LitheTreeListSelection {
    /// A growing range follows its cursor; external selection changes follow a visible selected item.
    static func revealTarget<ID: Hashable>(cursor: ID?, selected: Set<ID>, visible: [ID]) -> ID? {
        if let cursor, selected.contains(cursor), visible.contains(cursor) { return cursor }
        return visible.first(where: selected.contains)
    }

    static func select<ID: Hashable>(
        _ target: ID, in order: [ID], selected: Set<ID>, anchor: ID?,
        extending: Bool, toggling: Bool
    ) -> Set<ID> {
        guard let end = order.firstIndex(of: target) else { return selected }
        if extending, let anchor, let start = order.firstIndex(of: anchor) {
            let range = Set(order[min(start, end)...max(start, end)])
            return toggling ? selected.union(range) : range
        }
        if toggling {
            var result = selected
            if !result.insert(target).inserted { result.remove(target) }
            return result
        }
        return [target]
    }
}

private struct LitheTreeListMenu: ViewModifier {
    var items: (() -> [LitheContextMenuItem])?
    let onRightClick: () -> Void
    @ViewBuilder func body(content: Content) -> some View {
        // An empty outer menu must not consume the row content's own right-click menu.
        if let items, !items().isEmpty {
            content.litheContextMenu(items: items, onRightClick: onRightClick)
        } else { content }
    }
}

/// Declarative adapter for existing recursive trees. Children are evaluated only
/// while expanded, then flattened into the same lazy control used by flat lists.
struct LitheTreeListNode: Identifiable {
    let id: String
    var depth = 0
    var isExpanded: Bool?
    var isSelectable = true
    var onExpansion: ((Bool) -> Void)?
    var onSelect: (() -> Void)?
    var onActivate: (() -> Void)?
    var onClick: (() -> Void)?
    var menu: () -> [LitheContextMenuItem]
    var content: AnyView
    var children: () -> [LitheTreeListNode]

    init<Content: View>(
        id: String, isExpanded: Bool? = nil, isSelectable: Bool = true,
        onExpansion: ((Bool) -> Void)? = nil, onSelect: (() -> Void)? = nil,
        onActivate: (() -> Void)? = nil, onClick: (() -> Void)? = nil,
        menu: @escaping () -> [LitheContextMenuItem] = { [] },
        @ViewBuilder content: () -> Content, children: @escaping () -> [LitheTreeListNode] = { [] }
    ) {
        self.id = id
        self.isExpanded = isExpanded
        self.isSelectable = isSelectable
        self.onExpansion = onExpansion
        self.onSelect = onSelect
        self.onActivate = onActivate
        self.onClick = onClick
        self.menu = menu
        self.content = AnyView(content())
        self.children = children
    }

    static func visible(_ nodes: [Self], depth: Int = 0) -> [Self] {
        var result: [Self] = []
        func append(_ children: [Self], depth: Int) {
            for node in children {
                var row = node
                row.depth = depth
                result.append(row)
                if node.isExpanded == true { append(node.children(), depth: depth + 1) }
            }
        }
        append(nodes, depth: depth)
        return result
    }
}

extension LitheTreeList where Data == [LitheTreeListNode], ID == String, RowContent == AnyView {
    init(nodes: [LitheTreeListNode], selection: Binding<String?>, multiline: Bool = false) {
        let visible = LitheTreeListNode.visible(nodes)
        self.init(
            visible,
            selection: Binding(
                get: { selection.wrappedValue },
                set: { id in
                    selection.wrappedValue = id
                    visible.first { $0.id == id }?.onSelect?()
                }),
            hierarchy: {
                .init(
                    depth: $0.depth, isBranch: $0.isExpanded != nil,
                    isExpanded: $0.isExpanded == true, isSelectable: $0.isSelectable)
            }, onExpansion: { $0.onExpansion?($1) },
            onActivate: { ($0.onActivate ?? $0.onClick)?() }, onClick: { $0.onClick?() }, contextMenu: { $0.menu() }, multiline: multiline, row: { $0.content })
    }
}

@resultBuilder
enum LitheTreeListNodesBuilder {
    static func buildExpression(_ node: LitheTreeListNode) -> [LitheTreeListNode] { [node] }
    static func buildExpression(_ nodes: [LitheTreeListNode]) -> [LitheTreeListNode] { nodes }
    static func buildBlock(_ parts: [LitheTreeListNode]...) -> [LitheTreeListNode] { parts.flatMap { $0 } }
    static func buildOptional(_ part: [LitheTreeListNode]?) -> [LitheTreeListNode] { part ?? [] }
    static func buildEither(first: [LitheTreeListNode]) -> [LitheTreeListNode] { first }
    static func buildEither(second: [LitheTreeListNode]) -> [LitheTreeListNode] { second }
    static func buildArray(_ parts: [[LitheTreeListNode]]) -> [LitheTreeListNode] { parts.flatMap { $0 } }
}

extension LitheTreeList where Data == [LitheTreeListNode], ID == String, RowContent == AnyView {
    init(
        nodes: [LitheTreeListNode], selection: Binding<Set<String>>, multiline: Bool = false,
        togglesSelectionOnClick: Bool = false
    ) {
        self.init(
            LitheTreeListNode.visible(nodes), id: \.id, selection: selection,
            togglesSelectionOnClick: togglesSelectionOnClick,
            hierarchy: {
                .init(
                    depth: $0.depth, isBranch: $0.isExpanded != nil,
                    isExpanded: $0.isExpanded == true, isSelectable: $0.isSelectable)
            }, onExpansion: { $0.onExpansion?($1) }, onActivate: { ($0.onActivate ?? $0.onClick)?() }, onClick: { $0.onClick?() },
            contextMenu: { $0.menu() }, multiline: multiline, row: { $0.content })
    }
}

/// Visible-order keyboard policy shared with native tree adapters.
enum LitheTreeListNavigationKey: UInt16 {
    case left = 123
    case right = 124
    case down = 125
    case up = 126
}

enum LitheTreeListNavigation {
    enum Result: Equatable {
        case select(Int)
        case expand(Int, Bool)
    }

    static func resolve(_ key: LitheTreeListNavigationKey, current: Int?, rows: [LitheTreeListHierarchy]) -> Result? {
        let stops = rows.indices.filter { rows[$0].isKeyboardNavigable }
        guard let first = stops.first, let last = stops.last else { return nil }
        guard let index = current, rows.indices.contains(index) else {
            return .select(key == .up ? last : first)
        }
        let row = rows[index]
        switch key {
        case .up: return .select(stops.last { $0 < index } ?? (row.isKeyboardNavigable ? index : first))
        case .down: return .select(stops.first { $0 > index } ?? (row.isKeyboardNavigable ? index : last))
        case .right:
            guard row.isBranch else { return nil }
            if !row.isExpanded { return .expand(index, true) }
            if let child = rows.indices.dropFirst(index + 1).prefix(while: { rows[$0].depth > row.depth })
                .first(where: { rows[$0].isKeyboardNavigable }) { return .select(child) }
        case .left:
            if row.isBranch && row.isExpanded { return .expand(index, false) }
            if let parent = rows[..<index].lastIndex(where: { $0.depth < row.depth && $0.isKeyboardNavigable }) {
                return .select(parent)
            }
        }
        return nil
    }
}

/// Native renderers use the same gutter and surface policy as the SwiftUI owner.
/// Keep their viewport drawing; never instantiate a SwiftUI view per native row.
enum LitheTreeListAppearance {
    static func highlightRect(_ row: CGRect) -> CGRect {
        row.insetBy(dx: min(row.width / 2, LitheTheme.Tree.horizontalInset), dy: 0)
    }

    static func paint(_ row: CGRect, selected: Bool, focused: Bool, hovered: Bool) {
        guard selected || hovered else { return }
        let color =
            selected
            ? (focused ? LitheTheme.Tree.focusedSelection : LitheTheme.Tree.inactiveSelection) : LitheTheme.Tree.hover
        NSColor(color).setFill()
        NSBezierPath(
            roundedRect: highlightRect(row), xRadius: LitheTheme.Metrics.projectTreeSelectionCornerRadius,
            yRadius: LitheTheme.Metrics.projectTreeSelectionCornerRadius
        ).fill()
    }
}

/// Native adapters retain viewport rendering and consume this owner's appearance/navigation policy.
protocol LitheTreeListNativeRenderer: View {}

extension LitheTreeList where Data == [Never], ID == Never, RowContent == EmptyView {
    init<Renderer: LitheTreeListNativeRenderer>(native renderer: Renderer) {
        self.init([], id: \.self, selection: .constant(nil)) { _ in EmptyView() }
        nativeRenderer = AnyView(renderer)
    }
}

struct LitheTreeListRowSurface: ViewModifier {
    @Environment(\.controlActiveState) private var controlActiveState
    let isSelected: Bool
    let isFocused: Bool

    func body(content: Content) -> some View {
        content.litheRowHover(
            isActive: isSelected,
            cornerRadius: LitheTheme.Metrics.projectTreeSelectionCornerRadius,
            activeBackground: isFocused && controlActiveState == .key
                ? LitheTheme.Tree.focusedSelection : LitheTheme.Tree.inactiveSelection,
            hoverBackground: LitheTheme.Tree.hover)
    }
}

/// Reuses the branch popup's bounded, clickable hover expansion lifecycle with tree-row styling.
struct LitheTreeListOverflowRow<Label: View>: View {
    @Environment(\.litheTreeListRowState) private var rowState
    @Environment(\.locale) private var locale
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isLithePaneResizing) private var resizing
    @State private var isHovered = false
    let accessibilityTitle: String
    /// Label inputs that the accessibility title does not already describe.
    var contentKey: AnyHashable = 0
    let onPress: () -> Void
    var menu: [LitheContextMenuItem] = []
    @ViewBuilder let label: (Bool, Bool) -> Label

    var body: some View {
        label(false, isHovered)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay(
                BranchPopupRowTracker(
                    isPresented: false, isEnabled: isEnabled && !resizing,
                    accessibilityTitle: accessibilityTitle,
                    contentKey: [contentKey, AnyHashable(rowState.selected), AnyHashable(rowState.focused)],
                    onPress: onPress,
                    onSecondaryPress: { [menu, locale] view, point in
                        LitheContextMenuPresenter.shared.show(
                            items: menu, at: point, appearance: view.effectiveAppearance,
                            locale: locale, parentWindow: view.window)
                    }, onHoverChange: { isHovered = $0 }
                ) {
                    label(true, true)
                        .modifier(LitheTreeListRowSurface(isSelected: rowState.selected, isFocused: rowState.focused))
                        .litheWorkbenchSurface(LitheTheme.sidebar)
                })
    }
}

private struct LitheTreeListRowStateKey: EnvironmentKey {
    static let defaultValue = (selected: false, focused: false)
}

extension EnvironmentValues {
    fileprivate var litheTreeListRowState: (selected: Bool, focused: Bool) {
        get { self[LitheTreeListRowStateKey.self] }
        set { self[LitheTreeListRowStateKey.self] = newValue }
    }
}
