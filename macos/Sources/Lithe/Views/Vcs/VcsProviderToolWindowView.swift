import LitheModuleAPI
import AppKit
import LitheCoreContracts
import SwiftUI

// Note: 统一 VCS 模型见 .agents/notes/proposed/architecture/2026-10-22-unified-vcs-provider-model.md

struct VcsProviderToolWindowActions {
    let openFile: (URL) -> Void
    let revealInFinder: (URL) -> Void
    let copyPath: (URL) -> Void
    let hide: () -> Void
    var showDiffInNewTab: ((VcsChange, String) -> Void)? = nil
    var deleteFiles: (([VcsChange], String) -> Void)? = nil
}

/// The tool window of one plugin VCS, laid out like IDEA's Commit window:
/// a Changes tab with the root's changes, a commit message, and the
/// actions the provider negotiated; a History tab with its revisions.
/// Every provider uses this view, so no VCS is named here; an action shows
/// only when the provider declares its capability.
struct VcsProviderToolWindowView: View {
    @ObservedObject var feature: VcsProvidersFeatureModel
    let title: String
    let pluginID: String
    let vcs: String
    let actions: VcsProviderToolWindowActions
    @State private var tab = Tab.changes
    @State private var listActive = false
    @State private var selectedRootID: String?
    /// Selected and explicitly included or excluded paths, root-relative,
    /// of the shown root; a root change clears them.
    @State private var selection: Set<String> = []
    @State private var inclusion: [String: Bool] = [:]
    @State private var collapsedGroups: Set<Group> = []
    @State private var message = ""
    @State private var messageFocused = false
    @State private var pendingRollback: [VcsChange] = []
    @State private var notice: String?
    /// The file whose history the History tab shows; nil is the whole root.
    @State private var historyPath: String?

    enum Tab: Hashable { case changes, history }

    enum Group: Hashable, CaseIterable {
        case conflicts, changes, unversioned

        var title: String {
            switch self {
            case .conflicts: L10n.string("Conflicts")
            case .changes: L10n.string("Changes")
            case .unversioned: L10n.string("Unversioned Files")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let root {
                toolbar(root)
                rootBar(root)
            }
            banners
            if let root {
                switch tab {
                case .changes: changesPane(root)
                case .history: historyPane(root)
                }
            } else {
                emptyState
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .workbenchHoverTooltipScope()
        .onAppear(perform: loadDraft)
        .onChange(of: root?.id) { _ in
            selection = []; inclusion = [:]; notice = nil; historyPath = nil; pendingRollback = []
            loadDraft()
        }
        .onChange(of: message) { text in
            guard let root else { return }
            feature.commitMessageDrafts[root.id] = text.isEmpty ? nil : text
        }
        .onChange(of: root?.snapshot?.changes) { changes in
            let paths = Set((changes ?? []).map(\.path))
            selection.formIntersection(paths)
            inclusion = inclusion.filter { paths.contains($0.key) }
        }
        .confirmationDialog(
            L10n.string("Roll back the selected changes?"),
            isPresented: Binding(get: { !pendingRollback.isEmpty }, set: { if !$0 { pendingRollback = [] } }),
            titleVisibility: .visible
        ) {
            Button(L10n.string("Roll Back"), role: .destructive) {
                let changes = pendingRollback
                pendingRollback = []
                rollback(changes)
            }
            Button("Cancel", role: .cancel) { pendingRollback = [] }
        } message: {
            Text(verbatim: pendingRollback.map(\.path).joined(separator: "\n") + "\n\n"
                 + L10n.string("Local edits to these files are lost."))
        }
    }

    // MARK: Roots

    private var roots: [VcsRootState] {
        feature.roots.filter { $0.pluginID == pluginID && $0.root.vcs == vcs }
    }

    private var root: VcsRootState? {
        let roots = roots
        return roots.first { $0.id == selectedRootID } ?? roots.first
    }

    private var ambiguous: [VcsAmbiguousDirectory] {
        feature.ambiguous.filter { $0.vcs.contains(vcs) }
    }

    private func loadDraft() {
        message = root.flatMap { feature.commitMessageDrafts[$0.id] } ?? ""
    }

    // MARK: Header and toolbar

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: title)
                .font(LitheTheme.uiFont(size: LitheTheme.Commit.toolbarFontSize, weight: .semibold))
                .foregroundStyle(LitheTheme.toolWindowText)
                .lineLimit(1)
                .padding(.trailing, 4)
            if root != nil {
                tabButton(.changes, title: L10n.string("Changes"))
                if root?.supports(.history) == true {
                    tabButton(.history, title: L10n.string("History"))
                }
            }
            Spacer()
            LitheSidebarHideButton(title: title, action: actions.hide)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 41)
        .background(LitheTheme.toolHeader)
        .overlay(alignment: .bottom) { LitheToolWindowHeaderDivider() }
    }

    private func tabButton(_ value: Tab, title: String) -> some View {
        Button {
            tab = value
            if value == .changes { historyPath = nil }
        } label: {
            Text(verbatim: title)
                .font(LitheTheme.uiFont(size: LitheTheme.Commit.toolbarFontSize, weight: .regular))
                .foregroundStyle(tab == value ? LitheTheme.primaryText : LitheTheme.secondaryText)
                .padding(.horizontal, LitheTheme.Commit.tabItemHorizontalPadding)
                .frame(height: 28)
        }
        .buttonStyle(.litheNoPress)
        .modifier(LitheToolWindowTabStyle(isSelected: tab == value, isActive: listActive))
    }

    private func toolbar(_ root: VcsRootState) -> some View {
        let busy = feature.runningOperation != nil
        let selected = selectedChanges(root)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                toolbarButton(L10n.string("Refresh"), icon: "expui/general/refresh.svg",
                              isEnabled: !feature.isDetecting && !root.isRefreshing) {
                    feature.detect()
                }
                if root.supports(.update) {
                    toolbarButton(L10n.string("Update Project"), icon: "expui/vcs/update.svg", isEnabled: !busy) {
                        update(root)
                    }
                }
                if tab == .changes {
                    if root.supports(.rollback) {
                        toolbarButton(L10n.string("Roll Back…"), icon: "expui/vcs/revert.svg",
                                      isEnabled: !busy && !rollbackTargets(selected).isEmpty) {
                            pendingRollback = rollbackTargets(selected)
                        }
                    }
                    if root.supports(.baseContent) {
                        toolbarButton(L10n.string("Show Diff"), icon: "expui/vcs/diff.svg",
                                      isEnabled: selected.count == 1) {
                            if let change = selected.first { showDiff(change, in: root) }
                        }
                    }
                    if root.supports(.conflicts) {
                        toolbarButton(L10n.string("Mark as Resolved"), icon: "expui/actions/checked.svg",
                                      isEnabled: !busy && !conflicted(selected).isEmpty) {
                            resolve(conflicted(selected), in: root)
                        }
                    }
                }
                if root.supports(.cleanup) {
                    LitheMenu {
                        LitheContextMenuItem.action(L10n.string("Clean Up Working Copy"), localizesTitle: false,
                                                    isEnabled: !busy) { cleanup(root) }
                    } label: {
                        icon("expui/general/moreVertical.svg")
                    }
                    .litheToolbarIconButton()
                    .padding(.horizontal, 2)
                    .accessibilityLabel(Text("More Actions"))
                    .workbenchHoverHelp(Text("More Actions"))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
        }
        .frame(height: LitheTheme.Metrics.toolbarIconButtonSize + 12)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private func toolbarButton(_ help: String, icon path: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { icon(path) }
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityLabel(Text(verbatim: help))
            .buttonStyle(LitheIconButtonStyle(
                size: LitheTheme.Metrics.toolbarIconButtonSize, cornerRadius: 4,
                hoverBackground: LitheTheme.toolbarHoverBackground,
                pressedBackground: LitheTheme.toolbarPressedBackground
            ))
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .workbenchHoverHelp(Text(verbatim: help))
    }

    private func icon(_ path: String) -> some View {
        LitheIDEAIcon(resourcePath: path, size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
    }

    /// The shown root, with a picker when the workspace has several, and
    /// where its working copy points.
    private func rootBar(_ root: VcsRootState) -> some View {
        HStack(spacing: 6) {
            icon("expui/nodes/folder.svg")
            if roots.count > 1 {
                LitheMenu {
                    for candidate in roots {
                        LitheContextMenuItem.action(
                            candidate.title, localizesTitle: false,
                            checked: candidate.id == root.id, leadingCheckmark: true,
                            initiallySelected: candidate.id == root.id
                        ) { selectedRootID = candidate.id }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: root.title).lineLimit(1)
                        icon("expui/general/chevronDown.svg")
                    }
                }
                .litheToolbarIconButton(isIconOnly: false)
                .accessibilityLabel(Text("Working copy"))
            } else {
                Text(verbatim: root.title).lineLimit(1)
            }
            Spacer(minLength: 8)
            if root.isRefreshing { ProgressView().controlSize(.mini) }
            if let head = root.snapshot?.head {
                Text(verbatim: Self.headSummary(head))
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(head.location ?? "")
            }
        }
        .font(LitheTheme.uiFont(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .help(root.url.path)
    }

    static func headSummary(_ head: VcsHead) -> String {
        [head.revision?.display, head.branch].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Banners and empty state

    @ViewBuilder
    private var banners: some View {
        ForEach(feature.issues, id: \.self) { issue in
            LitheBanner(status: .warning, layout: .editor) {
                Text(verbatim: issue).lineLimit(3).textSelection(.enabled)
            }
        }
        ForEach(ambiguous, id: \.id) { directory in
            LitheBanner(status: .info, layout: .editor) {
                Text(String(format: L10n.string("%@ holds the metadata of several version control systems. Choose the one that manages it."),
                            directory.id.isEmpty ? L10n.string("The workspace") : directory.id))
                HStack(spacing: 6) {
                    ForEach(directory.vcs, id: \.self) { candidate in
                        Button(feature.vcsNames[candidate] ?? candidate) { feature.map(directory.id, to: candidate) }
                    }
                }
            }
        }
        if feature.isTruncated {
            LitheBanner(status: .warning, layout: .editor) {
                Text("The workspace is too large to search completely; some working copies may be missing.")
            }
        }
        if let running = feature.runningOperation, roots.contains(where: { $0.id == running.rootID }) {
            LitheBanner(status: .info, layout: .editor, isProgress: true) {
                Text(verbatim: running.title)
            }
        }
        if let failure = feature.failure, failure.rootID.map({ id in roots.contains { $0.id == id } }) ?? true {
            LitheBanner(status: .error, layout: .editor, dismiss: feature.dismissFailure) {
                Text(verbatim: failure.message).lineLimit(6).textSelection(.enabled)
            }
            .id(failure.id)
        }
        if let root, let message = root.failure {
            LitheBanner(status: .error, layout: .editor) {
                Text(verbatim: message).lineLimit(6).textSelection(.enabled)
                Button(L10n.string("Retry")) { feature.refresh(root.id) }
            }
        }
        if let root, root.snapshot?.truncated == true {
            LitheBanner(status: .warning, layout: .editor) {
                Text("There are too many changes to list; some are not shown.")
            }
        }
        if let notice {
            LitheBanner(status: .success, layout: .editor, dismiss: { self.notice = nil }) {
                Text(verbatim: notice)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if feature.isDetecting {
                ProgressView().controlSize(.small)
                Text("Detecting working copies…")
            } else {
                Text(String(format: L10n.string("No %@ working copy was detected in this workspace."), title))
                    .multilineTextAlignment(.center)
                Button(L10n.string("Detect Again")) { feature.detect() }
            }
        }
        .font(LitheTheme.uiFont(size: 12))
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Changes

    private func changesPane(_ root: VcsRootState) -> some View {
        VStack(spacing: 0) {
            SwiftUI.Group {
                let groups = Self.groups(root.snapshot?.changes ?? [])
                if root.snapshot == nil, root.isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading changes…")
                    }
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .padding(.vertical, 20)
                } else if groups.isEmpty, root.snapshot != nil {
                    Text("No local changes")
                        .font(LitheTheme.uiFont(size: 12))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .padding(.vertical, 20)
                } else {
                    let rows: [ChangeEntry] = groups.flatMap { entry in
                        [.group(entry)] + (collapsedGroups.contains(entry.group) ? [] : entry.changes.map(ChangeEntry.file))
                    }
                    LitheTreeList(
                        rows, id: \.id,
                        selection: Binding<Set<ChangeEntry.ID>>(
                            get: { Set(selection.map(ChangeEntry.ID.file)) },
                            set: { selection = Set($0.compactMap { if case .file(let path) = $0 { return path }; return nil }) }),
                        hierarchy: { entry in
                            switch entry {
                            case .group(let group): .init(isBranch: true, isExpanded: !collapsedGroups.contains(group.group), isSelectable: false)
                            case .file: .init(depth: 1)
                            }
                        },
                        onExpansion: { entry, expanded in
                            guard case .group(let group) = entry else { return }
                            if expanded { collapsedGroups.remove(group.group) } else { collapsedGroups.insert(group.group) }
                        },
                        onActivate: { entry in if case .file(let change) = entry { open(change, in: root) } },
                        contextMenu: { entry in
                            if case .file(let change) = entry { return contextMenu(for: change, root: root) }
                            return []
                        }
                    ) { entry in
                        switch entry {
                        case .group(let group): groupHeader(group.group, changes: group.changes, root: root)
                        case .file(let change): changeRow(change, group: Self.group(of: change), root: root)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .litheWorkbenchSurface(LitheTheme.sidebar)
            .background(LitheToolWindowActivityTracker(isActive: $listActive))
            if root.supports(.checkin) {
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                commitArea(root)
            }
        }
    }

    private enum ChangeEntry: Identifiable {
        enum ID: Hashable { case group(Group), file(String) }
        case group(GroupedChanges)
        case file(VcsChange)

        var id: ID {
            switch self {
            case .group(let entry): .group(entry.group)
            case .file(let change): .file(change.path)
            }
        }
    }

    struct GroupedChanges {
        let group: Group
        let changes: [VcsChange]
    }

    /// Conflicts first, as IDEA lists them; ignored files never reach the
    /// list because status asks for none.
    static func groups(_ changes: [VcsChange]) -> [GroupedChanges] {
        var buckets: [Group: [VcsChange]] = [:]
        for change in changes where change.status != .ignored {
            buckets[group(of: change), default: []].append(change)
        }
        return Group.allCases.compactMap { group in
            buckets[group].map { GroupedChanges(group: group, changes: $0.sorted { $0.path < $1.path }) }
        }
    }

    static func group(of change: VcsChange) -> Group {
        if change.status == .conflicted || change.hasTreeConflict { return .conflicts }
        return change.status == .unversioned ? .unversioned : .changes
    }

    /// IDEA includes every versioned change and leaves new files out; a
    /// conflict cannot be committed until it is resolved. An ignored file is
    /// never listed, so it is never committed either.
    static func isIncludedByDefault(_ change: VcsChange) -> Bool {
        change.status != .ignored && group(of: change) == .changes
    }

    private func isIncluded(_ change: VcsChange) -> Bool {
        guard change.status != .ignored, Self.group(of: change) != .conflicts else { return false }
        return inclusion[change.path] ?? Self.isIncludedByDefault(change)
    }

    private func groupHeader(_ group: Group, changes: [VcsChange], root: VcsRootState) -> some View {
        let included = changes.filter(isIncluded).count
        return HStack(spacing: LitheTheme.Tree.iconTextGap) {
            if group != .conflicts && root.supports(.checkin) {
                LitheTreeCheckbox(
                    state: included == 0 ? .off : included == changes.count ? .on : .mixed,
                    accessibilityTitle: L10n.string("Include in commit")
                ) {
                    let include = included < changes.count
                    for change in changes { inclusion[change.path] = include }
                }
            }
            Text(verbatim: group.title)
            Text(verbatim: "\(changes.count)")
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer(minLength: 0)
        }
    }

    private func changeRow(_ change: VcsChange, group: Group, root: VcsRootState) -> some View {
        let url = root.url.appendingPathComponent(change.path)
        let name = (change.path as NSString).lastPathComponent
        let directory = (change.path as NSString).deletingLastPathComponent
        let detail = change.oldPath.map { "← " + $0 } ?? directory
        return HStack(spacing: LitheTheme.Tree.iconTextGap) {
            if root.supports(.checkin) {
                LitheTreeCheckbox(
                    state: isIncluded(change) ? .on : .off,
                    accessibilityTitle: L10n.string("Include in commit")
                ) {
                    inclusion[change.path] = !isIncluded(change)
                }
                .disabled(group == .conflicts)
            }
            LitheIcon(kind: LitheIcons.kind(for: url, isDirectory: false), size: LitheTheme.Tree.iconSize)
            Text(verbatim: name)
                .foregroundStyle(change.status.listColor)
                .lineLimit(1)
                .layoutPriority(1)
            if !detail.isEmpty {
                Text(verbatim: detail)
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if change.flags.contains("locked") || change.flags.contains("lockedByOther") {
                icon("expui/general/locked.svg")
            }
            Text(verbatim: change.hasTreeConflict ? "C" : change.status.letter)
                .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                .foregroundStyle(change.status.listColor)
                .padding(.trailing, 4)
        }
        .help(Self.rowHelp(change))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(change.path), \(change.status.title)"))
        .accessibilityAction(named: Text("Include in commit")) {
            guard root.supports(.checkin), group != .conflicts else { return }
            inclusion[change.path] = !isIncluded(change)
        }
    }

    static func rowHelp(_ change: VcsChange) -> String {
        var parts = [change.path, change.status.title]
        if let oldPath = change.oldPath { parts.append(String(format: L10n.string("Moved from %@"), oldPath)) }
        if change.hasTreeConflict { parts.append(L10n.string("Tree conflict")) }
        if change.flags.contains("propertiesModified") { parts.append(L10n.string("Properties modified")) }
        if change.flags.contains("locked") { parts.append(L10n.string("Locked in this working copy")) }
        if change.flags.contains("lockedByOther") { parts.append(L10n.string("Locked by another user")) }
        return parts.joined(separator: "\n")
    }

    /// Double-click compares with the base when there is one; a new file
    /// has nothing to compare, so it opens.
    private func open(_ change: VcsChange, in root: VcsRootState) {
        selection = [change.path]
        if root.comparesWithBase(change) {
            showDiff(change, in: root)
        } else if ![.deleted, .missing].contains(change.status) {
            actions.openFile(root.url.appendingPathComponent(change.path))
        }
    }

    func contextMenu(for change: VcsChange, root: VcsRootState) -> [LitheContextMenuItem] {
        let selected = Self.actionTargets(root.snapshot?.changes ?? [], selection: selection, clicked: change)
        let url = root.url.appendingPathComponent(change.path)
        let exists = ![.deleted, .missing].contains(change.status)
        let busy = feature.runningOperation != nil
        var items: [LitheContextMenuItem] = []
        items.append(.action("Commit Files…", isEnabled: root.supports(.checkin) && !busy && !selected.isEmpty
            && !selected.contains(where: { Self.group(of: $0) == .conflicts })) {
                let paths = Set(selected.map(\.path))
                inclusion = Dictionary(uniqueKeysWithValues: (root.snapshot?.changes ?? []).map { ($0.path, paths.contains($0.path)) })
                tab = .changes
                messageFocused = true
            })
        if root.supports(.baseContent) {
            items.append(.action(L10n.string("Show Diff"), localizesTitle: false, isEnabled: selected.count == 1) {
                showDiff(change, in: root)
            })
            items.append(.action("Show Diff in New Tab", isEnabled: selected.count == 1 && actions.showDiffInNewTab != nil) {
                actions.showDiffInNewTab?(change, root.id)
            })
        }
        items.append(.action(L10n.string("Open"), localizesTitle: false, isEnabled: exists) { actions.openFile(url) })
        if root.supports(.fileHistory) && change.status != .unversioned {
            items.append(.action(L10n.string("Show History"), localizesTitle: false) {
                historyPath = change.path
                tab = .history
            })
        }
        items.append(.separator)
        items.append(.action("Delete…", role: .destructive,
            isEnabled: !busy && actions.deleteFiles != nil && !selected.isEmpty
                && (feature.canTrash(selected, in: root.id) || feature.canDelete(selected, in: root.id))) {
                    actions.deleteFiles?(selected, root.id)
                })
        items.append(.action("Add to VCS", isEnabled: feature.canAdd(selected, in: root.id)) {
            Task { _ = await feature.add(selected, in: root.id) }
        })
        items.append(.separator)
        if root.supports(.conflicts) && !conflicted(selected).isEmpty {
            items.append(.action(L10n.string("Mark as Resolved"), localizesTitle: false, isEnabled: !busy) {
                resolve(conflicted(selected), in: root)
            })
        }
        if root.supports(.rollback) && !rollbackTargets(selected).isEmpty {
            items.append(.action(L10n.string("Roll Back…"), localizesTitle: false, role: .destructive, isEnabled: !busy) {
                pendingRollback = rollbackTargets(selected)
            })
        }
        items.append(.separator)
        items.append(.action(L10n.string("Copy Path"), localizesTitle: false) { actions.copyPath(url) })
        items.append(.action(L10n.string("Reveal in Finder"), localizesTitle: false, isEnabled: exists) {
            actions.revealInFinder(url)
        })
        return items
    }

    static func actionTargets(_ changes: [VcsChange], selection: Set<String>, clicked: VcsChange) -> [VcsChange] {
        changes.filter { selection.contains(clicked.path) ? selection.contains($0.path) : $0.path == clicked.path }
    }

    private func selectedChanges(_ root: VcsRootState) -> [VcsChange] {
        (root.snapshot?.changes ?? []).filter { selection.contains($0.path) }
    }

    /// Rolling back cannot bring back a file the VCS never had.
    private func rollbackTargets(_ changes: [VcsChange]) -> [VcsChange] {
        changes.filter { ![.unversioned, .ignored].contains($0.status) }
    }

    private func conflicted(_ changes: [VcsChange]) -> [VcsChange] {
        changes.filter { Self.group(of: $0) == .conflicts }
    }

    // MARK: Commit

    private func commitArea(_ root: VcsRootState) -> some View {
        let included = (root.snapshot?.changes ?? []).filter(isIncluded)
        let canCommit = !included.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && feature.runningOperation == nil
        return VStack(spacing: 0) {
            CommitMessageEditor(text: $message, focused: $messageFocused)
                .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 140, alignment: .topLeading)
                .background {
                    RoundedRectangle(cornerRadius: LitheTheme.Commit.controlCornerRadius)
                        .fill(LitheTheme.editor)
                        .padding(1.5)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: LitheTheme.Commit.controlCornerRadius)
                        .strokeBorder(
                            messageFocused ? LitheTheme.searchFieldFocusBorder : LitheTheme.searchFieldBorder,
                            lineWidth: messageFocused ? 2 : 1
                        )
                        .padding(messageFocused ? 0 : 1)
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, LitheTheme.Commit.messageHorizontalGap)
                .padding(.vertical, LitheTheme.Commit.messageVerticalGap)
            HStack(spacing: 8) {
                Button {
                    commit(included, in: root)
                } label: {
                    HStack(spacing: 6) {
                        if feature.runningOperation?.rootID == root.id { ProgressView().controlSize(.mini) }
                        Text("Commit")
                    }
                }
                .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                .disabled(!canCommit)
                Text(String(format: L10n.string("%lld files selected"), included.count))
                    .font(LitheTheme.uiFont(size: LitheTheme.Commit.metadataFontSize))
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(.leading, LitheTheme.Commit.contentInset)
            .padding(.trailing, LitheTheme.Commit.contentInset)
            .padding(.bottom, LitheTheme.ActionButton.spacing + 4)
        }
        .background(LitheTheme.toolHeader)
    }

    /// A move commits both of its paths, so the source is never left behind.
    static func commitPaths(_ changes: [VcsChange]) -> [String] {
        var seen: Set<String> = []
        return changes.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) }.filter { seen.insert($0).inserted }
    }

    private func commit(_ changes: [VcsChange], in root: VcsRootState) {
        let text = message
        let rootID = root.id
        Task {
            guard let result = await feature.checkin(Self.commitPaths(changes), message: text, in: rootID) else { return }
            feature.commitMessageDrafts[rootID] = nil
            if self.root?.id == rootID {
                message = ""
                inclusion = [:]
                selection = []
            }
            notice = result.revision.map { String(format: L10n.string("Committed revision %@."), $0.display) }
                ?? L10n.string("Committed.")
        }
    }

    // MARK: Actions

    private func update(_ root: VcsRootState) {
        notice = nil
        Task {
            guard let result = await feature.update(root.id) else { return }
            var text = result.revision.map { String(format: L10n.string("Updated to revision %@."), $0.display) }
                ?? L10n.string("Updated.")
            if !result.conflicts.isEmpty {
                text += " " + String(format: L10n.string("%lld files have conflicts."), result.conflicts.count)
            }
            notice = text
        }
    }

    private func rollback(_ changes: [VcsChange]) {
        guard let root else { return }
        let paths = Self.commitPaths(changes)
        Task {
            if await feature.rollback(paths, in: root.id) { selection.subtract(paths) }
        }
    }

    private func resolve(_ changes: [VcsChange], in root: VcsRootState) {
        Task { _ = await feature.resolve(changes.map(\.path), in: root.id) }
    }

    private func cleanup(_ root: VcsRootState) {
        Task {
            if await feature.cleanup(root.id) { notice = L10n.string("The working copy was cleaned up.") }
        }
    }

    private func showDiff(_ change: VcsChange, in root: VcsRootState) {
        feature.showDiff(change, in: root.id)
    }

    // MARK: History

    @ViewBuilder
    private func historyPane(_ root: VcsRootState) -> some View {
        VStack(spacing: 0) {
            if let historyPath {
                HStack(spacing: 6) {
                    Text(String(format: L10n.string("History of %@"), historyPath))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button(L10n.string("Show All")) { self.historyPath = nil }
                        .buttonStyle(.link)
                }
                .font(LitheTheme.uiFont(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 26)
            }
            VcsHistoryListView(feature: feature, rootID: root.id, path: historyPath)
                .id([root.id, historyPath ?? ""])
        }
    }
}
