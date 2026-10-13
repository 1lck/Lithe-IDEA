import AppKit
import SwiftUI
import LitheGitModule

struct ChangesSidebarView: View {
    private let changeRowHeight = LitheTheme.Tree.rowHeight

    @ObservedObject var feature: GitFeatureModel
    let draft: CommitDraftFeatureModel
    let commitWorkflow: CommitWorkflowCoordinator
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    let workbench: WorkbenchFeatureModel
    let hasBackgroundImage: Bool
    let openSavedDiff: (GitSavedChangesSnapshot, String, GitCommitFile) -> Void
    let selectChange: (GitChange) -> Void
    let setStaging: ([GitChange], Bool) -> Void
    let openFile: (URL, String) -> Void
    let showLocalHistory: (URL) -> Void
    let revealInFinder: (URL) -> Void
    let copyPath: (URL, Bool) -> Void
    let showSettings: (SettingsCategory) -> Void
    @State private var selectedTab = CommitTab.commit
    @State private var commitToolActive = false
    @State private var changelistExpanded: [String: Bool] = [:]
    @State private var repositoryExpanded: [String: Bool] = [:]
    @State private var pendingDropStash: GitStash?
    @State private var pendingDropShelf: GitShelfEntry?
    @State private var pendingDiscardSelection: [GitChange] = []
    @State private var selection = GitChangeSelection()
    @State private var sectionsCache = GitChangeSectionsCache()

    var body: some View {
        let _ = LitheSignpost.bodyEvaluated("ChangesSidebarView")
        VStack(spacing: 0) {
            tabHeader

            GitChangesOperationStatus(feature: feature, editor: feature.interactiveRebase)

            if let conflict = feature.pendingStashRestoreConflict {
                if feature.isStashRestoreConflictNoticeVisible {
                    GitStashRestoreConflictBanner(
                        feature: feature, workbench: workbench, conflict: conflict
                    )
                } else {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(LitheTheme.warning)
                        Text("Stash restore needs attention")
                            .font(LitheTheme.uiFont(size: 11.5, weight: .semibold))
                            .foregroundStyle(LitheTheme.primaryText)
                        Spacer(minLength: 0)
                        Button("Review") { feature.showStashRestoreConflictNotice() }
                            .controlSize(.small)
                            .lithePointer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(LitheTheme.raised)
                }
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }

            if feature.gitRepositoryRoot == nil {
                noRepository
            } else if selectedTab == .shelf {
                shelfContent
            } else {
                commitContent
            }
        }
        .background(hasBackgroundImage ? Color.clear : LitheTheme.sidebar)
        .background(LitheToolWindowActivityTracker(isActive: $commitToolActive))
        .onAppear {
            selectRequestedStashIfNeeded()
            if let id = feature.selectedChange?.id {
                selection.select(id, orderedIDs: visibleChangeIDs, command: false, shift: false)
            }
        }
        .onChange(of: visibleChangeIDs) { selection.retain($0) }
        .onChange(of: draft.commitEditorRequestVersion) { _ in selectedTab = .commit }
        .modifier(GitPatchPresentation(editor: feature.patchExchange, surface: .changes))
        .onChange(of: feature.requestedStashReference) { _ in
            selectRequestedStashIfNeeded()
        }
        .confirmationDialog(
            "Discard changes to selected files?",
            isPresented: Binding(get: { !pendingDiscardSelection.isEmpty },
                                 set: { if !$0 { pendingDiscardSelection = [] } }),
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                let changes = pendingDiscardSelection
                pendingDiscardSelection = []
                Task { await feature.discardChanges(changes) }
            }
            Button("Cancel", role: .cancel) { pendingDiscardSelection = [] }
        } message: {
            Text(pendingDiscardSelection.map(\.path).joined(separator: "\n")
                 + "\nThis action cannot be undone by Lithe. Untracked files will be deleted.")
        }
        .confirmationDialog(
            "Drop \(pendingDropStash?.reference ?? "stash")?",
            isPresented: Binding(
                get: { pendingDropStash != nil },
                set: { if !$0 { pendingDropStash = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Drop Stash", role: .destructive) {
                guard let pendingDropStash else { return }
                self.pendingDropStash = nil
                Task { await feature.dropStash(pendingDropStash) }
            }
            .lithePointer()
            Button("Cancel", role: .cancel) {
                pendingDropStash = nil
            }
            .lithePointer()
        } message: {
            Text("This removes the stash from Git and cannot be undone.")
        }
        .confirmationDialog(
            "Drop this shelf?",
            isPresented: Binding(
                get: { pendingDropShelf != nil },
                set: { if !$0 { pendingDropShelf = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Drop Shelf", role: .destructive) {
                guard let pendingDropShelf else { return }
                self.pendingDropShelf = nil
                Task { await feature.dropShelf(pendingDropShelf) }
            }
            .lithePointer()
            Button("Cancel", role: .cancel) { pendingDropShelf = nil }
                .lithePointer()
        } message: {
            Text("This removes the saved patch from Lithe and cannot be undone.")
        }

    }

    private var tabHeader: some View {
        HStack(spacing: 8) {
            ForEach(CommitTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(LocalizedStringKey(tab.title))
                        .font(LitheTheme.uiFont(size: LitheTheme.Commit.toolbarFontSize, weight: .regular))
                        .foregroundStyle(tab == selectedTab ? LitheTheme.primaryText : LitheTheme.secondaryText)
                        .padding(.horizontal, LitheTheme.Commit.tabItemHorizontalPadding)
                        .frame(height: 28)
                }
                .buttonStyle(.litheNoPress)
                .modifier(LitheToolWindowTabStyle(isSelected: tab == selectedTab, isActive: commitToolActive))
            }
            Spacer()
            GitPatchToolbar(feature: feature)
            LitheSidebarHideButton(title: "Commit") { workbench.hideSidebar() }
        }
        // Islands: 4pt layout start + 4pt inset of the painted tab.
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 41)
        .background(hasBackgroundImage ? Color.clear : LitheTheme.toolHeader)
        .overlay(alignment: .bottom) {
            LitheToolWindowHeaderDivider()
        }
    }

    private var commitContent: some View {
        GeometryReader { geometry in
            let toolbarHeight = LitheTheme.Commit.toolbarHeight
            let minimumListHeight = LitheTheme.Commit.listMinimumHeight
            let minimumCommitHeight = LitheTheme.Commit.areaMinimumHeight
            let availableCommitHeight = geometry.size.height
                - toolbarHeight
                - SplitHandleView.thickness
                - minimumListHeight
            let maximumCommitHeight = max(
                minimumCommitHeight,
                availableCommitHeight
            )

            VStack(spacing: 0) {
                commitToolbar

                LitheSplitPaneView(
                    axis: .vertical,
                    placement: .trailing,
                    defaultSize: Self.defaultCommitAreaHeight,
                    minimum: minimumCommitHeight,
                    maximum: maximumCommitHeight,
                    dividerColor: LitheTheme.toolWindowBorder(for: colorScheme),
                    highlightsOnHover: false,
                    sized: {
                        CommitAreaView(feature: feature, draft: draft, commitWorkflow: commitWorkflow,
                                       hasBackgroundImage: hasBackgroundImage, showSettings: showSettings)
                    },
                    flexible: {
                        VStack(spacing: 0) {
                            GitChangelistBar(feature: feature)
                            changeList
                        }.frame(minHeight: minimumListHeight)
                    }
                )
            }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private static let defaultCommitAreaHeight = LitheTheme.Commit.areaMinimumHeight

    private var shelfContent: some View {
        GitSavedChangesView(feature: feature, isActive: commitToolActive, openDiff: openSavedDiff,
            dropStash: { pendingDropStash = $0 }, dropShelf: { pendingDropShelf = $0 })
    }

    private var commitToolbar: some View {
        HStack(spacing: 2) {
            Button {
                Task { await feature.refreshGit() }
            } label: {
                LitheIDEAIcon(
                    resourcePath: "expui/general/refresh.svg",
                    size: LitheTheme.Metrics.toolbarIconSize,
                    fallbackSystemImage: "arrow.clockwise",
                    preservesOriginalColors: true
                )
            }
            .litheToolbarIconButton()
            .help("Refresh changes")

            Button {
                pendingDiscardSelection = selectedChanges
            } label: {
                LitheIDEAIcon(
                    resourcePath: "expui/vcs/revert.svg",
                    size: LitheTheme.Metrics.toolbarIconSize,
                    fallbackSystemImage: "arrow.uturn.backward",
                    preservesOriginalColors: true
                )
            }
            .litheToolbarIconButton(isEnabled: !selectedChanges.isEmpty)
            .help("Discard selected change")

            Button {
                Task { await feature.stageAllChanges() }
            } label: {
                LitheIDEAIcon(
                    resourcePath: "expui/general/download.svg",
                    size: LitheTheme.Metrics.toolbarIconSize,
                    fallbackSystemImage: "square.and.arrow.down",
                    preservesOriginalColors: true
                )
            }
            .litheToolbarIconButton(isEnabled: !feature.activeChangelistChanges.isEmpty && !feature.isCommitting && !feature.changelistStorageFailed)
            .help("Stage all files in current ChangeList")

            Button {
                if let first = feature.gitChanges.first {
                    selectChange(first)
                }
            } label: {
                LitheIDEAIcon(
                    resourcePath: "expui/general/show.svg",
                    size: LitheTheme.Metrics.toolbarIconSize,
                    fallbackSystemImage: "eye",
                    preservesOriginalColors: true
                )
            }
            .litheToolbarIconButton(isEnabled: !feature.gitChanges.isEmpty)
            .help("Preview first change")

            Spacer()

            if !feature.gitConflictFilterPaths.isEmpty {
                Button {
                    feature.clearGitConflictFilter()
                } label: {
                    Label("Clear conflict filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.litheNoPress)
                .font(LitheTheme.uiFont(size: 10.5))
                .foregroundStyle(LitheTheme.warning)
                .lithePointer()
            }

            if feature.availableRepositoryRoots.count > 1 {
                LitheMenu {
                    for root in feature.availableRepositoryRoots {
                        LitheContextMenuItem.action(root.path) {
                            Task { await feature.selectRepository(root) }
                        }
                    }
                } label: {
                    Label(
                        feature.gitRepositoryRoot?.lastPathComponent ?? "Repository", systemImage: "externaldrive"
                    )
                    .lineLimit(1)
                }
                .buttonStyle(.litheNoPress)
                .help("Select repository for commits and branch operations")
            }

            Text(feature.currentBranch)
                .font(LitheTheme.uiFont(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: LitheTheme.Commit.toolbarHeight)
    }

    private var changeList: some View {
        Group {
            if feature.gitChanges.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "checkmark.circle")
                        .font(LitheTheme.uiFont(size: 27, weight: .light))
                        .foregroundStyle(LitheTheme.success)
                    Text("Working tree is clean")
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayedChanges.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(LitheTheme.uiFont(size: 27, weight: .light))
                        .foregroundStyle(LitheTheme.warning)
                    Text("No files match the conflict filter")
                    Button("Show all changes") { feature.clearGitConflictFilter() }
                        .buttonStyle(.litheNoPress)
                        .lithePointer()
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if feature.availableRepositoryRoots.count > 1 {
                multiRepositoryChangeList
            } else {
                singleRepositoryChangeList
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var singleRepositoryChangeList: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(changeSections.changelists) { section in
                        changelistSection(section, repositoryID: "", showsParentPaths: geometry.size.width >= 300)
                    }
                }
                .padding(.horizontal, LitheTheme.Tree.horizontalInset)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var multiRepositoryChangeList: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(changeSections.repositories) { repository in
                        repositoryChangeSection(
                            repository,
                            showsParentPaths: geometry.size.width >= 300
                        )
                    }
                }
                .padding(.horizontal, LitheTheme.Tree.horizontalInset)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func repositoryChangeSection(
        _ repository: GitChangeSectionsCache.RepositorySection,
        showsParentPaths: Bool
    ) -> some View {
        let repositoryID = repository.id
        let activeChanges = repository.changes.filter { feature.changelists.listID(for: $0) == feature.changelists.activeID }
        let isExpanded = repositoryExpanded[repositoryID] ?? true

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    repositoryExpanded[repositoryID] = !isExpanded
                } label: {
                    LitheIDEAIcon(resourcePath: isExpanded ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg",
                                  size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
                        .frame(width: LitheTheme.Tree.disclosureSlot, height: changeRowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .help(LocalizedStringKey(isExpanded ? "Collapse repository" : "Expand repository"))

                GitChangeInclusionCheckbox(state: stagingState(for: activeChanges)) {
                    setStaging(activeChanges, !allChangesStaged(activeChanges))
                }
                .disabled(feature.isCommitting || feature.changelistStorageFailed || !activeChanges.contains(where: \.canToggleStaging))
                .help(LocalizedStringKey(
                    allChangesStaged(activeChanges)
                        ? "Unstage all files in repository"
                        : "Stage all files in repository"
                ))

                Button {
                    repositoryExpanded[repositoryID] = !isExpanded
                } label: {
                    HStack(spacing: LitheTheme.Tree.iconTextGap) {
                        Image(systemName: "folder.fill")
                            .font(LitheTheme.uiFont(size: 12, weight: .medium))
                            .foregroundStyle(GitRepositoryColor.color(
                                for: repository.root,
                                in: feature.availableRepositoryRoots
                            ))
                        Text(repositoryDisplayName(repository.root))
                            .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                            .foregroundStyle(LitheTheme.primaryText)
                            .lineLimit(1)
                        Text("\(repository.changes.count)")
                            .font(LitheTheme.uiFont(size: 13))
                            .foregroundStyle(LitheTheme.Tree.secondaryText)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: changeRowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .help(repository.root.path)
            }
            .frame(maxWidth: .infinity)


            if isExpanded {
                ForEach(repository.changelists) { section in
                    changelistSection(section, repositoryID: repositoryID, showsParentPaths: showsParentPaths)
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(LitheTheme.divider.opacity(0.72))
                .frame(height: 1)
        }
    }

    private func changelistSection(
        _ section: GitChangeSectionsCache.ChangelistSection, repositoryID: String, showsParentPaths: Bool
    ) -> some View {
        let key = repositoryID + ":" + section.id
        return changeSection(
            section.list,
            changes: section.changes,
            expanded: Binding(get: { changelistExpanded[key] ?? true }, set: { changelistExpanded[key] = $0 }),
            showsParentPaths: showsParentPaths
        )
    }

    @ViewBuilder
    private func changeSection(
        _ list: GitLocalChangelist,
        changes: [GitChange],
        expanded: Binding<Bool>,
        showsParentPaths: Bool,
        leadingInset: CGFloat = 0
    ) -> some View {
        if !changes.isEmpty {
            HStack(spacing: 0) {
                Button {
                    expanded.wrappedValue.toggle()
                } label: {
                    LitheIDEAIcon(resourcePath: expanded.wrappedValue ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg",
                                  size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
                        .frame(width: LitheTheme.Tree.disclosureSlot, height: changeRowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .help(LocalizedStringKey(expanded.wrappedValue ? "Collapse section" : "Expand section"))

                GitChangeInclusionCheckbox(state: stagingState(for: changes)) {
                    setStaging(changes, !allChangesStaged(changes))
                }
                .disabled(feature.isCommitting || feature.changelistStorageFailed || !changes.contains(where: \.canToggleStaging))
                .help(LocalizedStringKey(allChangesStaged(changes) ? "Unstage all files" : "Stage all files"))

                Button {
                    expanded.wrappedValue.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Group {
                            if list.id == GitLocalChangelists.defaultID {
                                Text("Default ChangeList")
                            } else {
                                Text(verbatim: list.name)
                            }
                        }
                            .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                            .foregroundStyle(LitheTheme.primaryText)
                        Text("\(changes.count) files")
                            .font(LitheTheme.uiFont(size: 13))
                            .foregroundStyle(LitheTheme.Tree.secondaryText)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
            }
            .padding(.leading, leadingInset)
            .frame(maxWidth: .infinity)
            .frame(height: changeRowHeight)

            if expanded.wrappedValue {
                ForEach(changes) { change in
                    changeRow(
                        change,
                        showsParentPath: showsParentPaths,
                        leadingInset: leadingInset
                    )
                }
            }
        }
    }

    private func changeRow(
        _ change: GitChange,
        showsParentPath: Bool,
        includesRepositoryRootInParentPath: Bool = true,
        leadingInset: CGFloat = 0
    ) -> some View {
        HStack(spacing: LitheTheme.Tree.iconTextGap) {
            GitChangeInclusionCheckbox(state: isEffectivelyStaged(change) ? .on : .off) {
                let targets = selection.actionTargets(in: displayedChanges, clicked: change)
                setStaging(targets, !isEffectivelyStaged(change))
            }
            .disabled(feature.isCommitting || feature.changelistStorageFailed || !change.canToggleStaging)
            .help(LocalizedStringKey(change.canToggleStaging
                ? (isEffectivelyStaged(change) ? "Unstage file" : "Stage file")
                : "Commit changed files in the submodule first"))

            Button {
                selectRow(change)
            } label: {
                HStack(spacing: LitheTheme.Tree.iconTextGap) {
                    LitheIcon(kind: LitheIcons.kind(for: change.url, isDirectory: false), size: LitheTheme.Tree.iconSize)
                        .help(LocalizedStringKey(change.kind.title))
                    Text(changeDisplayName(change))
                        .font(LitheTheme.uiFont(size: 13, weight: .regular))
                        .foregroundStyle(fileNameColor(change))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !change.canToggleStaging {
                        Text("Uncommitted submodule changes")
                            .font(LitheTheme.uiFont(.caption)).foregroundStyle(LitheTheme.Tree.secondaryText)
                    }
                    let parent = parentPathText(
                        change,
                        includesRepositoryRoot: includesRepositoryRootInParentPath
                    )
                    if showsParentPath, !parent.isEmpty {
                        Text(parent)
                            .font(LitheTheme.uiFont(size: 13))
                            .foregroundStyle(LitheTheme.Tree.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: changeRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
        }
        .padding(.leading, LitheTheme.Tree.indent + LitheTheme.Tree.disclosureSlot + leadingInset)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity)
        .frame(height: changeRowHeight)
        .litheTreeRow(isSelected: selection.ids.contains(change.id), isFocused: commitToolActive)
        .contentShape(Rectangle())
        .onTapGesture { selectRow(change) }
        .accessibilityAddTraits(selection.ids.contains(change.id) ? .isSelected : [])
        .transaction { $0.animation = nil }
        .litheContextMenu {
            changeContextMenuItems(for: change)
        }
    }

    private func repositoryDisplayName(_ root: URL) -> String {
        let name = root.lastPathComponent
        return name.isEmpty ? root.path : name
    }

    private var selectedChanges: [GitChange] {
        selection.actionTargets(in: displayedChanges)
    }

    private var visibleChangeIDs: [String] {
        if feature.availableRepositoryRoots.count == 1 {
            return changeSections.changelists.flatMap { section in
                (changelistExpanded[":" + section.id] ?? true) ? section.changes.map(\.id) : []
            }
        }
        return changeSections.repositories.flatMap { repository in
            guard repositoryExpanded[repository.id] ?? true else { return [String]() }
            return repository.changelists.flatMap { section in
                (changelistExpanded[repository.id + ":" + section.id] ?? true) ? section.changes.map(\.id) : []
            }
        }
    }

    private func selectRow(_ change: GitChange) {
        let modifiers = NSEvent.modifierFlags
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        selection.select(change.id, orderedIDs: visibleChangeIDs, command: command, shift: shift)
        // Extending a selection must not rebuild the diff or launch Git reads.
        if !command && !shift && feature.selectedChange != change {
            selectChange(change)
        }
    }

    private func changeContextMenuItems(for change: GitChange) -> [LitheContextMenuItem] {
        let targets = selection.actionTargets(in: displayedChanges, clicked: change)
        let shouldStage = !targets.allSatisfy(isEffectivelyStaged)
        var items: [LitheContextMenuItem] = []
        if change.kind != .deleted {
            items.append(.action("Open", systemImage: "doc.text", action: {
                openFile(change.url, change.path)
            }))
        }
        items.append(.action("Show Diff", systemImage: "doc.text.magnifyingglass", action: {
            selectChange(change)
        }))
        items.append(.submenu("Move to ChangeList", items: feature.changelists.lists.map { list in
            .action(list.displayName, isEnabled: !feature.changelistEditingDisabled,
                    action: { feature.moveChanges(targets, toChangelist: list.id) })
        }))
        items.append(.separator)
        items.append(.action(
            shouldStage ? "Stage Files" : "Unstage Files",
            systemImage: shouldStage ? "plus.square" : "arrow.uturn.backward",
            isEnabled: !feature.isCommitting && !feature.changelistStorageFailed,
            action: { setStaging(targets, shouldStage) }
        ))
        if targets.contains(where: \.hasWorkingTreeChange) {
            items.append(.action(
                "Discard Changes",
                systemImage: "trash",
                role: .destructive,
                action: { pendingDiscardSelection = targets }
            ))
        }
        items += [
            .separator,
            .action(
                "Local History…",
                systemImage: "clock.arrow.circlepath",
                isEnabled: change.kind != .deleted,
                action: { showLocalHistory(change.url) }
            ),
            .action("Show in Finder", systemImage: "folder", action: {
                let url = change.kind == .deleted
                    ? change.url.deletingLastPathComponent()
                    : change.url
                revealInFinder(url)
            }),
            .submenu("Copy Path / Reference", items: [
                .action("Copy Path", action: { copyPath(change.url, false) }),
                .action("Copy Relative Path", action: { copyPath(change.url, true) })
            ])
        ]
        return items
    }

    private var noRepository: some View {
        VStack(spacing: 10) {
            LitheIDEAIcon(
                resourcePath: "toolwindows/toolWindowVcs.svg",
                size: 30,
                fallbackSystemImage: "point.3.connected.trianglepath.dotted"
            )
            Text("This project is not a Git repository")
                .multilineTextAlignment(.center)
        }
        .font(LitheTheme.uiFont)
        .foregroundStyle(LitheTheme.Tree.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    /// All four sections come from one pass over `gitChanges`; see
    /// `GitChangeSectionsCache`.
    private var changeSections: GitChangeSectionsCache.Sections {
        sectionsCache.sections(
            changes: feature.gitChanges,
            conflictFilterPaths: feature.gitConflictFilterPaths,
            changelists: feature.changelists
        )
    }

    private var displayedChanges: [GitChange] {
        changeSections.displayed
    }

    private func isEffectivelyStaged(_ change: GitChange) -> Bool {
        feature.effectiveStagingState(for: change)
    }

    private func allChangesStaged(_ changes: [GitChange]) -> Bool {
        let selectable = changes.filter(\.canToggleStaging)
        return !selectable.isEmpty && selectable.allSatisfy(isEffectivelyStaged)
    }

    private func stagingState(for changes: [GitChange]) -> NSControl.StateValue {
        if allChangesStaged(changes) { return .on }
        return changes.contains(where: isEffectivelyStaged) ? .mixed : .off
    }

    private func fileNameColor(_ change: GitChange) -> Color {
        if change.isUntracked { return LitheTheme.Commit.fileUntracked }
        switch change.kind {
        case .modified: return LitheTheme.Commit.fileModified
        case .added, .copied: return LitheTheme.Commit.fileAdded
        case .deleted: return LitheTheme.Commit.fileDeleted
        case .moved: return LitheTheme.Commit.fileRenamed
        case .conflicted: return LitheTheme.Commit.fileConflicted
        }
    }

    private func selectRequestedStashIfNeeded() {
        guard feature.requestedStashReference != nil else { return }
        selectedTab = .shelf
    }

    private func changeDisplayName(_ change: GitChange) -> String {
        guard let originalPath = change.originalPath else { return change.url.lastPathComponent }
        let oldName = (originalPath as NSString).lastPathComponent
        return "\(oldName) → \(change.url.lastPathComponent)"
    }

    private func parentPathText(
        _ change: GitChange,
        includesRepositoryRoot: Bool = true
    ) -> String {
        let parent = (change.path as NSString).deletingLastPathComponent
        let prefix = includesRepositoryRoot && feature.availableRepositoryRoots.count > 1
            ? change.repositoryRoot.path + "/" : ""
        guard let originalPath = change.originalPath else { return prefix + parent }
        let originalParent = (originalPath as NSString).deletingLastPathComponent
        guard originalParent != parent else { return prefix + parent }
        return "\(prefix)\(originalParent) → \(parent)"
    }

    private func constrained(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(maximum, max(minimum, value))
    }
}

/// Persistent banner for a merge, rebase, cherry-pick, or revert that Git stopped
/// partway through. Deliberately not a dialog: resolving conflicts means editing
/// files, so the controls have to stay reachable rather than block the window.
private struct GitChangesOperationStatus: View {
    @ObservedObject var feature: GitFeatureModel
    @ObservedObject var editor: GitInteractiveRebaseFeatureModel

    var body: some View {
        if editor.session?.isActive == true || (editor.session != nil && feature.gitOperationState == nil) {
            GitInteractiveRebaseStatusView(editor: editor) { name, session in
                await feature.createHistoryRecoveryBranch(named: name, from: session)
            }
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
        } else if let operation = feature.gitOperationState {
            GitOperationBanner(feature: feature, operation: operation)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
        }
    }
}

private struct GitOperationBanner: View {
    @ObservedObject var feature: GitFeatureModel
    let operation: GitOperationState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LitheTheme.warning)
                Text(LocalizedStringKey(operation.kind.inProgressTitle))
                    .font(LitheTheme.uiFont(size: 12, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                if let reference = operation.reference {
                    Text(verbatim: "— \(reference)")
                        .font(LitheTheme.uiFont(size: 12))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 3) {
                if let step = operation.step, let total = operation.total {
                    Text("Step \(step) of \(total)")
                }
                if operation.hasConflicts {
                    Text("Resolve \(operation.conflictedPaths.count) conflicted file(s), stage them, then continue.")
                } else {
                    Text("All conflicts resolved. Continue to finish, or abort to undo.")
                }
            }
            .font(LitheTheme.uiFont(size: 11))
            .foregroundStyle(LitheTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(LocalizedStringKey(operation.kind.continueTitle)) {
                    Task { await feature.continueGitOperation() }
                }
                .buttonStyle(.borderedProminent)
                .tint(LitheTheme.accent)
                .disabled(feature.isResolvingGitOperation || operation.hasConflicts)
                .lithePointer()

                if operation.kind.canSkip {
                    Button("Skip Commit") {
                        Task { await feature.skipGitOperationStep() }
                    }
                    .disabled(feature.isResolvingGitOperation)
                    .lithePointer()
                }

                Button("Abort") {
                    Task { await feature.abortGitOperation() }
                }
                .disabled(feature.isResolvingGitOperation)
                .lithePointer()

                Spacer(minLength: 0)
            }
            .font(LitheTheme.uiFont(size: 11))
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.raised)
    }

}

private struct GitStashRestoreConflictBanner: View {
    let feature: GitFeatureModel
    let workbench: WorkbenchFeatureModel
    let conflict: GitStashRestoreConflictRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LitheTheme.warning)
                Text("Local changes were restored with conflicts")
                    .font(LitheTheme.uiFont(size: 11.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer(minLength: 0)
            }

            Text("Your local changes are safe in \(conflict.stashReference). The \(Text(LocalizedStringKey(conflict.operationTitle))) is incomplete. Resolve the conflicts, then drop this stash manually.")
                .font(LitheTheme.uiFont(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 7) {
                Button("Show Conflict Files") {
                    workbench.selectedSidebar = .changes
                    feature.showStashRestoreConflictFiles()
                }
                .buttonStyle(.borderedProminent)
                .tint(LitheTheme.accent)
                .lithePointer()

                Button("View Saved Changes") {
                    workbench.selectedSidebar = .changes
                    feature.showStashRestoreConflictStash()
                }
                .lithePointer()

                Spacer(minLength: 0)

                Button("Later") {
                    feature.dismissStashRestoreConflictNotice()
                }
                .lithePointer()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.raised)
    }
}

private enum CommitTab: String, CaseIterable, Identifiable {
    case commit
    case shelf

    var id: String { rawValue }
    var title: String { self == .shelf ? "Stash" : "Commit" }
}

/// ChangesTreeCellRenderer uses a 24pt ThreeStateCheckBox with a 16pt painted square.
struct GitChangeInclusionCheckbox: View {
    let state: NSControl.StateValue
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    static func assetPath(state: NSControl.StateValue, enabled: Bool, focused: Bool) -> String {
        let name = state == .mixed ? "checkBoxIndeterminateSelected" : state == .on ? "checkBoxSelected" : "checkBox"
        let suffix = !enabled ? "Disabled" : focused ? "Focused" : ""
        return "commit/" + name + suffix + ".svg"
    }

    var body: some View {
        Button(action: action) {
            LitheIDEAIcon(resourcePath: Self.assetPath(state: state, enabled: isEnabled, focused: isFocused),
                          size: 24, preservesOriginalColors: true)
                .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .focused($isFocused)
        .accessibilityRepresentation {
            Toggle("Include in commit", isOn: Binding(get: { state == .on }, set: { _ in action() }))
                .accessibilityValue(Text(state == .mixed ? "Partially selected" : state == .on ? "Selected" : "Not selected"))
        }
    }
}
