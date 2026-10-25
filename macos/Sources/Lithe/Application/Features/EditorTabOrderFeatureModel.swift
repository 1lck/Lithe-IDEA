import Combine
import Foundation

struct AgentEditorConversation: Equatable {
    let agentID: String
    let sessionID: String?
}

/// Owns only the mixed presentation order of document and terminal tabs, and
/// which Agent session each Agent tab presents. Resource lifecycle and active
/// selection remain with their existing features.
@MainActor
final class EditorTabOrderFeatureModel: ObservableObject {
    @Published private(set) var items: [EditorTabItem] = [] {
        didSet {
            reconcileGroups()
            let open = Set(agentTabIDs)
            if agentSessionByTab.keys.contains(where: { !open.contains($0) }) {
                agentSessionByTab = agentSessionByTab.filter { open.contains($0.key) }
            }
        }
    }
    @Published private(set) var groupLayout: EditorGroupLayout = .group(UUID())
    @Published private(set) var groupSelections: [UUID: EditorTabItem] = [:]
    /// Agent identity also belongs to an empty tab; session IDs are only unique
    /// within their Agent. Entries disappear with their tab.
    @Published private(set) var agentSessionByTab: [UUID: AgentEditorConversation] = [:]
    private var placements: [EditorTabItem: UUID] = [:]
    private var focusedGroup: UUID?
    var groupDropRequestID = UUID()

    func items(in group: UUID) -> [EditorTabItem] {
        items.filter { placements[$0] == group }
    }

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
            placements[item] = group
            var ordered = items.filter { $0 != item }
            let last = ordered.lastIndex { placements[$0] == group }
            ordered.insert(item, at: last.map { $0 + 1 } ?? ordered.count)
            if ordered != items { items = ordered }
        } else {
            let created = UUID()
            let new = EditorGroupLayout.group(created), old = EditorGroupLayout.group(group)
            let leading = side == .left || side == .top
            groupLayout = groupLayout.replacing(group, with: .split(id: UUID(),
                vertical: side == .top || side == .bottom, first: leading ? new : old, second: leading ? old : new))
            placements[item] = created
        }
        reconcileGroups()
        focus(item)
        return true
    }

    private func reconcileGroups() {
        let groups = groupLayout.groups
        let destination = focusedGroup.flatMap { groups.contains($0) ? $0 : nil } ?? groups[0]
        placements = placements.filter { items.contains($0.key) }
        for item in items where placements[item] == nil { placements[item] = destination }
        let occupied = Set(placements.values)
        groupLayout = groupLayout.keeping(occupied) ?? .group(groups[0])
        let remaining = groupLayout.groups
        if !remaining.contains(destination) { focusedGroup = remaining[0] }
        var selections: [UUID: EditorTabItem] = [:]
        for group in remaining {
            let tabs = items(in: group)
            if let selected = groupSelections[group], tabs.contains(selected) { selections[group] = selected }
            else { selections[group] = tabs.first }
        }
        if selections != groupSelections { groupSelections = selections }
    }

    @Published var repositoryDiffSelected = false
    var repositoryDiffReturnTab: EditorTabItem?
    var repositoryDiffRequestID: UUID?

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
            case .terminal, .media, .repositoryDiff, .agentConversation:
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
        if let destination = placements[target] { placements[item] = destination }
        items = next
        return true
    }
}
