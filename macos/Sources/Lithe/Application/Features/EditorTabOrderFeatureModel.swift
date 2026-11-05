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
            if !isApplyingWorkbenchState {
                reduceWorkbench(.sync(tabs: items.map(Self.workbenchID)), previousItems: oldValue)
            }
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
    private var isApplyingWorkbenchState = false
    /// Drop eligibility per state; drags query it on every pointer move, so
    /// Core answers each tab/group/side once until the state changes.
    private var dropEligibility: [String: Bool] = [:]
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
        guard let group = placements[item], focusedGroup != group || groupSelections[group] != item else { return }
        reduceWorkbench(.focus(tab: Self.workbenchID(item)))
    }

    func canDrop(_ item: EditorTabItem, into group: UUID, side: EditorGroupDropSide) -> Bool {
        let key = "\(Self.workbenchID(item))|\(group.uuidString)|\(side.rawValue)"
        if let cached = dropEligibility[key] { return cached }
        let allowed = reduceWorkbench(.canDrop(tab: Self.workbenchID(item), group: group, side: side))
        dropEligibility[key] = allowed
        return allowed
    }

    /// A drop moves membership only; it never closes or reopens the underlying resource.
    @discardableResult
    func drop(_ item: EditorTabItem, into group: UUID, side: EditorGroupDropSide) -> Bool {
        let split = side == .center ? nil : (group: UUID(), split: UUID())
        return reduceWorkbench(.drop(
            tab: Self.workbenchID(item), group: group, side: side,
            newGroup: split?.group, newSplit: split?.split))
    }

    /// Adds a tab from outside the editor; an edge always splits because the target group does not own it yet.
    @discardableResult
    func insert(_ item: EditorTabItem, into group: UUID?, side: EditorGroupDropSide) -> Bool {
        let split = group == nil || side == .center ? nil : (group: UUID(), split: UUID())
        return reduceWorkbench(
            .insert(tab: Self.workbenchID(item), group: group, side: side,
                    newGroup: split?.group, newSplit: split?.split),
            adding: [item])
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
        reduceWorkbench(
            .move(tab: Self.workbenchID(item), target: Self.workbenchID(target),
                  position: insertAfter ? "after" : "before"),
            adding: [item])
    }

    // MARK: Core-owned group membership

    /// Rust Core (`editor.workbenchState.reduce`) owns placement, split and
    /// collapse, selection and focus; this model only stores the result.
    private enum WorkbenchAction: Encodable {
        case sync(tabs: [String])
        case drop(tab: String, group: UUID, side: EditorGroupDropSide, newGroup: UUID?, newSplit: UUID?)
        case canDrop(tab: String, group: UUID, side: EditorGroupDropSide)
        case insert(tab: String, group: UUID?, side: EditorGroupDropSide, newGroup: UUID?, newSplit: UUID?)
        case move(tab: String, target: String, position: String)
        case focus(tab: String)

        private enum CodingKeys: String, CodingKey {
            case type, tabs, tab, group, side, newGroup, newSplit, target, position
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .sync(let tabs):
                try container.encode("sync", forKey: .type)
                try container.encode(tabs, forKey: .tabs)
            case .drop(let tab, let group, let side, let newGroup, let newSplit):
                try container.encode("drop", forKey: .type)
                try container.encode(tab, forKey: .tab)
                try container.encode(group, forKey: .group)
                try container.encode(side, forKey: .side)
                try container.encodeIfPresent(newGroup, forKey: .newGroup)
                try container.encodeIfPresent(newSplit, forKey: .newSplit)
            case .canDrop(let tab, let group, let side):
                try container.encode("canDrop", forKey: .type)
                try container.encode(tab, forKey: .tab)
                try container.encode(group, forKey: .group)
                try container.encode(side, forKey: .side)
            case .insert(let tab, let group, let side, let newGroup, let newSplit):
                try container.encode("insert", forKey: .type)
                try container.encode(tab, forKey: .tab)
                try container.encode(group, forKey: .group)
                try container.encode(side, forKey: .side)
                try container.encodeIfPresent(newGroup, forKey: .newGroup)
                try container.encodeIfPresent(newSplit, forKey: .newSplit)
            case .move(let tab, let target, let position):
                try container.encode("move", forKey: .type)
                try container.encode(tab, forKey: .tab)
                try container.encode(target, forKey: .target)
                try container.encode(position, forKey: .position)
            case .focus(let tab):
                try container.encode("focus", forKey: .type)
                try container.encode(tab, forKey: .tab)
            }
        }
    }

    private struct WorkbenchState: Codable {
        struct Tab: Codable { let id: String; let group: UUID? }
        struct Selection: Codable { let group: UUID; let tab: String? }
        let layout: EditorGroupLayout
        let tabs: [Tab]
        let selections: [Selection]
        let focusedGroup: UUID?
    }

    private struct WorkbenchRequest: Encodable {
        let state: WorkbenchState
        let action: WorkbenchAction
    }

    private struct WorkbenchReduction: Decodable {
        let applied: Bool
        let state: WorkbenchState
    }

    private static func workbenchID(_ item: EditorTabItem) -> String {
        switch item {
        case .document(let id): "document:\(id.uuidString)"
        case .terminal(let id): "terminal:\(id.uuidString)"
        case .media(let id): "media:\(id.uuidString)"
        case .repositoryDiff(let id): "repositoryDiff:\(id.uuidString)"
        case .agentConversation(let id): "agentConversation:\(id.uuidString)"
        case .languageLogs: "languageLogs"
        }
    }

    /// Sends the current state and one action to Core and stores an applied
    /// result. `previousItems` describes the state a `sync` started from;
    /// `adding` names tabs the action may introduce.
    @discardableResult
    private func reduceWorkbench(
        _ action: WorkbenchAction,
        previousItems: [EditorTabItem]? = nil,
        adding: [EditorTabItem] = []
    ) -> Bool {
        let source = previousItems ?? items
        let state = WorkbenchState(
            layout: groupLayout,
            tabs: source.map { WorkbenchState.Tab(id: Self.workbenchID($0), group: placements[$0]) },
            selections: groupLayout.groups.map {
                WorkbenchState.Selection(group: $0, tab: groupSelections[$0].map(Self.workbenchID))
            },
            focusedGroup: focusedGroup)
        let result: Result<WorkbenchReduction, RustCoreBridge.CoreCallError> = RustCoreBridge().executeResult(
            command: "editor.workbenchState.reduce", payload: WorkbenchRequest(state: state, action: action))
        guard case .success(let reduction) = result else {
            // log-exempt: 同一次失败已经记录过：Core 请求轨迹已记录这次失败，标签分组保持原状态
            return false
        }
        if case .canDrop = action { return reduction.applied }
        guard reduction.applied else { return false }
        var lookup: [EditorTabItem] = items
        lookup.append(contentsOf: source)
        lookup.append(contentsOf: adding)
        applyWorkbench(reduction.state, lookup: Dictionary(
            lookup.map { (Self.workbenchID($0), $0) }, uniquingKeysWith: { first, _ in first }))
        return true
    }

    private func applyWorkbench(_ state: WorkbenchState, lookup: [String: EditorTabItem]) {
        var nextPlacements: [EditorTabItem: UUID] = [:]
        var nextItems: [EditorTabItem] = []
        for tab in state.tabs {
            guard let item = lookup[tab.id] else { continue }
            nextItems.append(item)
            if let group = tab.group { nextPlacements[item] = group }
        }
        var selections: [UUID: EditorTabItem] = [:]
        for selection in state.selections {
            if let tab = selection.tab, let item = lookup[tab] { selections[selection.group] = item }
        }
        dropEligibility.removeAll()
        placements = nextPlacements
        focusedGroup = state.focusedGroup
        if groupLayout != state.layout { groupLayout = state.layout }
        if groupSelections != selections { groupSelections = selections }
        if nextItems != items {
            isApplyingWorkbenchState = true
            defer { isApplyingWorkbenchState = false }
            items = nextItems
        }
    }
}
