import Combine
import Foundation

enum DocumentPreviewMode: String, CaseIterable, Identifiable, Equatable {
    case editor
    case split
    case preview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: "Editor"
        case .split: "Editor and Preview"
        case .preview: "Preview"
        }
    }

    var symbolName: String {
        switch self {
        case .editor: "pencil.line"
        case .split: "rectangle.split.2x1"
        case .preview: "doc.richtext"
        }
    }
}


struct AgentEditorConversation: Equatable {
    let agentID: String
    let sessionID: String?
}

/// Owns only the mixed presentation order of document and terminal tabs, and
/// which Agent session each Agent tab presents. Resource lifecycle and active
/// selection remain with their existing features.
@MainActor
final class EditorTabOrderFeatureModel: ObservableObject {
    @Published var documentPreviewModes: [UUID: DocumentPreviewMode] = [:]
    @Published private(set) var items: [EditorTabItem] = [] {
        didSet {
            reconcileGroups()
            let open = Set(agentTabIDs)
            if agentSessionByTab.keys.contains(where: { !open.contains($0) }) {
                agentSessionByTab = agentSessionByTab.filter { open.contains($0.key) }
            }
            let diffs = Set(repositoryDiffIDs)
            providerDiffs = providerDiffs.filter { diffs.contains($0.key) }
            loadingProviderDiffs.formIntersection(diffs)
            for (id, task) in providerDiffTasks where !diffs.contains(id) { task.cancel() }
            providerDiffTasks = providerDiffTasks.filter { diffs.contains($0.key) }
        }
    }
    @Published private(set) var groupLayout: EditorGroupLayout = .group(UUID())
    @Published private(set) var groupSelections: [UUID: EditorTabItem] = [:]
    /// Agent identity also belongs to an empty tab; session IDs are only unique
    /// within their Agent. Entries disappear with their tab.
    @Published private(set) var agentSessionByTab: [UUID: AgentEditorConversation] = [:]
    private var placements: [EditorTabItem: UUID] = [:]
    private var focusedGroup: UUID?
    /// Membership and selection rules live in Core; this model keeps the platform state they act on.
    private let workbench = RustEditorWorkbenchState()
    var groupDropRequestID = UUID()

    func items(in group: UUID) -> [EditorTabItem] {
        items.filter { placements[$0] == group }
    }

    /// Group presenting `item`, or nil while it is outside the editor (for example in the tool window).
    func group(containing item: EditorTabItem) -> UUID? { placements[item] }

    /// Close menus operate on visible group order and leave mixed non-document tabs open.
    func documentCloseTargets(for id: UUID, in group: UUID?) -> (other: [UUID], left: [UUID], right: [UUID]) {
        let tabs = group.map { items(in: $0) } ?? items
        let documents = tabs.compactMap { item -> UUID? in
            guard case .document(let id) = item else { return nil }
            return id
        }
        guard let index = documents.firstIndex(of: id) else { return ([], [], []) }
        return (documents.filter { $0 != id }, Array(documents.prefix(index)), Array(documents.dropFirst(index + 1)))
    }

    var focusedItem: EditorTabItem? { focusedGroup.flatMap { groupSelections[$0] } }

    var agentTabIDs: [UUID] {
        items.compactMap {
            guard case .agentConversation(let id) = $0 else { return nil }
            return id
        }
    }

    /// The Agent tab that currently has the focus, if the focused tab is one.
    var focusedAgentTab: UUID? {
        guard case .agentConversation(let id) = focusedItem else { return nil }
        return id
    }

    func agentConversation(of tab: UUID) -> AgentEditorConversation? { agentSessionByTab[tab] }
    func agentSession(of tab: UUID) -> String? { agentConversation(of: tab)?.sessionID }

    func agentTab(showing session: String, agentID: String) -> UUID? {
        agentTabIDs.first { agentSessionByTab[$0] == AgentEditorConversation(agentID: agentID, sessionID: session) }
    }

    /// Points a tab at an Agent's session. An earlier binding of the same pair
    /// is released first; another Agent can use the same session ID.
    func bindAgentTab(_ tab: UUID, to session: String?, agentID: String) {
        guard agentTabIDs.contains(tab) else { return }
        let binding = AgentEditorConversation(agentID: agentID, sessionID: session)
        var next = agentSessionByTab.filter { session == nil || $0.value != binding || $0.key == tab }
        next[tab] = binding
        if next != agentSessionByTab { agentSessionByTab = next }
    }

    func discardAgentSessions(_ sessions: Set<String>, agentID: String) {
        for tab in agentTabIDs {
            guard let binding = agentConversation(of: tab), binding.agentID == agentID,
                  let session = binding.sessionID, sessions.contains(session) else { continue }
            if focusedAgentTab == tab { bindAgentTab(tab, to: nil, agentID: agentID) }
            else { remove(.agentConversation(tab)) }
        }
    }

    func selectedItem(in group: UUID) -> EditorTabItem? { groupSelections[group] }

    func focus(_ item: EditorTabItem) {
        guard let group = placements[item] else { return }
        focusedGroup = group
        if groupSelections[group] != item { groupSelections[group] = item }
    }

    func canDrop(_ item: EditorTabItem, into group: UUID, side: EditorGroupDropSide) -> Bool {
        guard items.contains(item), groupLayout.groups.contains(group) else { return false }
        return placements[item] != group || (side != .center && items(in: group).count > 1)
    }

    /// A drop moves membership only; it never closes or reopens the underlying resource.
    @discardableResult
    func drop(_ item: EditorTabItem, into group: UUID, side: EditorGroupDropSide) -> Bool {
        guard canDrop(item, into: group, side: side) else { return false }
        if side == .center {
            guard let members = relocate(item, to: group) else { return false }
            var ordered = items.filter { $0 != item }
            ordered.insert(item, at: globalIndex(afterPredecessorOf: item, in: members, within: ordered))
            if ordered != items { items = ordered }
        } else {
            let created = UUID()
            groupLayout = groupLayout.splitting(group, by: side, newGroup: created)
            guard relocate(item, to: created) != nil else { return false }
        }
        focus(item)
        return true
    }

    /// Adds a tab from outside the editor; an edge always splits because the target group does not own it yet.
    @discardableResult
    func insert(_ item: EditorTabItem, into group: UUID?, side: EditorGroupDropSide) -> Bool {
        guard !items.contains(item) else { return false }
        guard let group else {
            // A tab without a home joins the focused group when the items change.
            var next = items
            next.append(item)
            items = next
            focus(item)
            return true
        }
        guard groupLayout.groups.contains(group) else { return false }
        if side == .center {
            guard let members = relocate(item, to: group) else { return false }
            var next = items
            next.insert(item, at: globalIndex(afterPredecessorOf: item, in: members, within: next))
            items = next
        } else {
            let created = UUID()
            groupLayout = groupLayout.splitting(group, by: side, newGroup: created)
            guard relocate(item, to: created) != nil else { return false }
            var next = items
            next.append(item)
            items = next
        }
        focus(item)
        return true
    }

    /// Canonical Core state for the current groups. Tabs without a valid group are reported as
    /// `unplaced`; `extra` makes a tab that is not in `items` yet resolvable in Core's answer.
    private func workbenchSnapshot(extra: [EditorTabItem] = []) -> (
        state: RustEditorWorkbenchState.State, unplaced: [String], lookup: [String: EditorTabItem]
    ) {
        let groupIDs = groupLayout.groups
        let known = Set(groupIDs)
        var lookup: [String: EditorTabItem] = [:]
        var members: [UUID: [String]] = [:]
        var unplaced: [String] = []
        for item in items + extra { lookup[item.workbenchKey] = item }
        for item in items {
            if let group = placements[item], known.contains(group) {
                members[group, default: []].append(item.workbenchKey)
            } else {
                unplaced.append(item.workbenchKey)
            }
        }
        let groups = groupIDs.map { id in
            RustEditorWorkbenchState.Group(
                id: id.uuidString,
                members: members[id] ?? [],
                selected: groupSelections[id]?.workbenchKey
            )
        }
        let state = RustEditorWorkbenchState.State(groups: groups, focusedGroup: focusedGroup?.uuidString)
        return (state, unplaced, lookup)
    }

    /// Writes Core's answer back: placements, per-group selection, focus and the pruned layout tree.
    private func applyWorkbench(_ reduction: RustEditorWorkbenchState.Reduction, lookup: [String: EditorTabItem]) {
        var nextPlacements: [EditorTabItem: UUID] = [:]
        var selections: [UUID: EditorTabItem] = [:]
        var remaining: [UUID] = []
        for group in reduction.state.groups {
            guard let id = UUID(uuidString: group.id) else { continue }
            remaining.append(id)
            for key in group.members { if let item = lookup[key] { nextPlacements[item] = id } }
            if let key = group.selected, let item = lookup[key] { selections[id] = item }
        }
        placements = nextPlacements
        focusedGroup = reduction.state.focusedGroup.flatMap(UUID.init(uuidString:))
        if !reduction.removedGroupIds.isEmpty {
            // Core decided which groups vanished; only the layout tree is pruned here.
            groupLayout = groupLayout.keeping(Set(remaining)) ?? .group(remaining.first ?? groupLayout.groups[0])
        }
        if selections != groupSelections { groupSelections = selections }
    }

    private func reconcileGroups() {
        let snapshot = workbenchSnapshot()
        guard let reduction = workbench.reduce(snapshot.state, .normalize(unplaced: snapshot.unplaced)) else { return }
        applyWorkbench(reduction, lookup: snapshot.lookup)
    }

    /// Moves `item` into `destination` (at the end, or next to `anchor`) and returns the
    /// destination's tabs afterwards. The item may not be in `items` yet.
    private func relocate(
        _ item: EditorTabItem,
        to destination: UUID,
        anchor: (item: EditorTabItem, after: Bool)? = nil
    ) -> [EditorTabItem]? {
        let snapshot = workbenchSnapshot(extra: [item])
        let action = RustEditorWorkbenchState.Action.move(
            member: item.workbenchKey,
            from: placements[item]?.uuidString ?? "",
            to: destination.uuidString,
            before: anchor.flatMap { $0.after ? nil : $0.item.workbenchKey },
            after: anchor.flatMap { $0.after ? $0.item.workbenchKey : nil }
        )
        guard let reduction = workbench.reduce(snapshot.state, action) else { return nil }
        applyWorkbench(reduction, lookup: snapshot.lookup)
        return reduction.state.groups.first { $0.id == destination.uuidString }?
            .members.compactMap { snapshot.lookup[$0] } ?? []
    }

    /// Position in the mixed tab order that keeps `item` right after the tab Core placed before it.
    private func globalIndex(
        afterPredecessorOf item: EditorTabItem,
        in members: [EditorTabItem],
        within ordered: [EditorTabItem]
    ) -> Int {
        guard let index = members.firstIndex(of: item), index > 0,
              let predecessor = ordered.firstIndex(of: members[index - 1]) else { return ordered.count }
        return predecessor + 1
    }

    @Published var repositoryDiffSelected = false
    var repositoryDiffReturnTabs: [UUID: EditorTabItem] = [:]
    var repositoryDiffKeys: [UUID: RepositoryDiffTabKey] = [:]
    /// Loaded plugin comparisons share the existing diff tab/group lifecycle,
    /// without activating Git or storing them in Git's comparison sessions.
    @Published var providerDiffs: [UUID: VcsFileDiff] = [:]
    var loadingProviderDiffs: Set<UUID> = []
    var providerDiffTasks: [UUID: Task<Void, Never>] = [:]

    var repositoryDiffIDs: [UUID] {
        items.compactMap {
            guard case .repositoryDiff(let id) = $0 else { return nil }
            return id
        }
    }

    var documentIDs: [UUID] {
        items.compactMap {
            guard case .document(let id) = $0 else { return nil }
            return id
        }
    }

    var mediaIDs: [UUID] {
        items.compactMap {
            guard case .media(let id) = $0 else { return nil }
            return id
        }
    }

    var terminalIDs: [UUID] {
        items.compactMap {
            guard case .terminal(let id) = $0 else { return nil }
            return id
        }
    }

    func contains(_ item: EditorTabItem) -> Bool {
        items.contains(item)
    }

    func moveToEnd(_ item: EditorTabItem) {
        var next = items
        next.removeAll { $0 == item }
        next.append(item)
        guard next != items else { return }
        items = next
    }

    func remove(_ item: EditorTabItem) {
        items.removeAll { $0 == item }
    }

    func removeAllTerminals() {
        items.removeAll {
            guard case .terminal = $0 else { return false }
            return true
        }
    }

    @discardableResult
    func move(_ item: EditorTabItem, before target: EditorTabItem) -> Bool {
        move(item, relativeTo: target, insertAfter: false)
    }

    @discardableResult
    func move(_ item: EditorTabItem, after target: EditorTabItem) -> Bool {
        move(item, relativeTo: target, insertAfter: true)
    }

    /// Reconciles document membership and relative order while leaving terminal
    /// slots untouched. This lets the document feature remain the resource owner.
    func reconcileDocuments(orderedIDs: [UUID]) {
        let openDocumentIDs = Set(orderedIDs)
        let representedDocumentIDs = Set(documentIDs)
        let reorderedExistingIDs = orderedIDs.filter { representedDocumentIDs.contains($0) }
        var existingIndex = 0
        var next: [EditorTabItem] = []

        for item in items {
            switch item {
            case .document(let id):
                guard openDocumentIDs.contains(id),
                      reorderedExistingIDs.indices.contains(existingIndex) else { continue }
                next.append(.document(reorderedExistingIDs[existingIndex]))
                existingIndex += 1
            case .terminal, .media, .repositoryDiff, .agentConversation, .languageLogs:
                next.append(item)
            }
        }

        let alreadyRepresented = Set(reorderedExistingIDs)
        next.append(contentsOf: orderedIDs.compactMap { id in
            alreadyRepresented.contains(id) ? nil : .document(id)
        })

        guard next != items else { return }
        items = next
    }

    /// Reconciles media membership while preserving the mixed tab slots.
    func reconcileMedia(orderedIDs: [UUID]) {
        let openMediaIDs = Set(orderedIDs)
        let representedMediaIDs = Set(mediaIDs)
        let reorderedExistingIDs = orderedIDs.filter { representedMediaIDs.contains($0) }
        var existingIndex = 0
        var next: [EditorTabItem] = []

        for item in items {
            switch item {
            case .media(let id):
                guard openMediaIDs.contains(id),
                      reorderedExistingIDs.indices.contains(existingIndex) else { continue }
                next.append(.media(reorderedExistingIDs[existingIndex]))
                existingIndex += 1
            default:
                next.append(item)
            }
        }

        let alreadyRepresented = Set(reorderedExistingIDs)
        next.append(contentsOf: orderedIDs.compactMap { id in
            alreadyRepresented.contains(id) ? nil : .media(id)
        })

        guard next != items else { return }
        items = next
    }

    private func move(
        _ item: EditorTabItem,
        relativeTo target: EditorTabItem,
        insertAfter: Bool
    ) -> Bool {
        guard item != target, items.contains(target) else { return false }
        var next = items
        next.removeAll { $0 == item }
        guard let targetIndex = next.firstIndex(of: target) else { return false }
        next.insert(item, at: targetIndex + (insertAfter ? 1 : 0))
        guard next != items || placements[item] != placements[target] else { return false }
        if let destination = placements[target] {
            guard relocate(item, to: destination, anchor: (target, insertAfter)) != nil else { return false }
        }
        items = next
        return true
    }
}
