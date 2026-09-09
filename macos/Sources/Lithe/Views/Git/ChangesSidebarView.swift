import AppKit
import SwiftUI
import LitheGitModule

struct ChangesSidebarView: View {
    private let changeRowHeight: CGFloat = 24

    @ObservedObject var feature: GitFeatureModel
    let draft: CommitDraftFeatureModel
    let commitWorkflow: CommitWorkflowCoordinator
    @EnvironmentObject private var settings: AppSettings
    let workbench: WorkbenchFeatureModel
    let hasBackgroundImage: Bool
    let selectChange: (GitChange) -> Void
    let setStaging: ([GitChange], Bool) -> Void
    let openFile: (URL, String) -> Void
    let showLocalHistory: (URL) -> Void
    let revealInFinder: (URL) -> Void
    let copyPath: (URL, Bool) -> Void
    let showSettings: (SettingsCategory) -> Void
    @State private var selectedTab = CommitTab.commit
    @State private var trackedExpanded = true
    @State private var untrackedExpanded = true
    @State private var stashMessage = "WIP"
    @State private var includeUntracked = true
    @State private var selectedStash: GitStash?
    @State private var selectedShelf: GitShelfEntry?
    @State private var pendingDropStash: GitStash?
    @State private var pendingDropShelf: GitShelfEntry?
    @State private var pendingDiscardSelection: [GitChange] = []
    @State private var selection = GitChangeSelection()
    @State private var sectionsCache = GitChangeSectionsCache()

    var body: some View {
        let _ = LitheSignpost.bodyEvaluated("ChangesSidebarView")
        VStack(spacing: 0) {
            tabHeader
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if let operation = feature.gitOperationState {
                GitOperationBanner(feature: feature, operation: operation)
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }

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
                            .font(.system(size: 11.5, weight: .semibold))
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
        .onAppear {
            selectRequestedStashIfNeeded()
            if let id = feature.selectedChange?.id {
                selection.select(id, orderedIDs: visibleChangeIDs, command: false, shift: false)
            }
        }
        .onChange(of: visibleChangeIDs) { selection.retain($0) }
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
        HStack(spacing: 7) {
            ForEach(CommitTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(LocalizedStringKey(tab.title))
                        .font(.system(size: LitheTheme.Commit.toolbarFontSize, weight: tab == selectedTab ? .semibold : .regular))
                        .foregroundStyle(tab == selectedTab ? LitheTheme.primaryText : LitheTheme.secondaryText)
                        .padding(.horizontal, LitheTheme.Commit.tabItemHorizontalPadding)
                        .padding(.vertical, LitheTheme.Commit.tabItemVerticalPadding)
                        .litheRowHover(
                            isActive: tab == selectedTab,
                            cornerRadius: LitheTheme.Metrics.cornerRadius,
                            activeBackground: LitheTheme.subtleSelection,
                            hoverBackground: LitheTheme.hoverBackground
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(hasBackgroundImage ? Color.clear : LitheTheme.toolHeader)
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
                Rectangle().fill(LitheTheme.divider).frame(height: 1)

                LitheSplitPaneView(
                    axis: .vertical,
                    placement: .trailing,
                    defaultSize: Self.defaultCommitAreaHeight,
                    minimum: minimumCommitHeight,
                    maximum: maximumCommitHeight,
                    sized: {
                        CommitAreaView(feature: feature, draft: draft, commitWorkflow: commitWorkflow,
                                       hasBackgroundImage: hasBackgroundImage, showSettings: showSettings)
                    },
                    flexible: { changeList.frame(minHeight: minimumListHeight) }
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
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Save message", text: $stashMessage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 7)
                    .frame(height: 27)
                    .litheRoundedControlBackground(LitheTheme.inputBackground, cornerRadius: 4)

                Toggle("Untracked", isOn: $includeUntracked)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10.5))
                    .fixedSize()

                Button {
                    Task {
                        await feature.stashWorkingTree(
                            message: stashMessage,
                            includeUntracked: includeUntracked
                        )
                        selectedStash = nil
                    }
                } label: {
                    HStack(spacing: 5) {
                        if feature.isPerformingStashOperation {
                            ProgressView().controlSize(.mini)
                        }
                        Text("Stash")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(LitheTheme.accent)
                .lithePointer()
                .disabled(!canStash)

                Button {
                    Task {
                        await feature.shelveWorkingTree(message: stashMessage)
                        selectedShelf = nil
                    }
                } label: {
                    HStack(spacing: 5) {
                        if feature.isPerformingShelfOperation {
                            ProgressView().controlSize(.mini)
                        }
                        Text("Shelf")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .lithePointer()
                .disabled(!canShelf)
            }
            .padding(8)
            .background(hasBackgroundImage ? Color.clear : LitheTheme.toolHeader)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if feature.gitStashes.isEmpty && feature.gitShelves.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 28, weight: .light))
                    Text("No saved changes")
                    Text("Stash or shelf changes here to switch branches safely.")
                        .font(.system(size: 11.5))
                        .multilineTextAlignment(.center)
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if !feature.gitShelves.isEmpty {
                            savedChangesSectionHeader("Lithe Shelves")
                            ForEach(feature.gitShelves) { shelf in
                                shelfRow(shelf)
                            }
                        }
                        if !feature.gitStashes.isEmpty {
                            savedChangesSectionHeader("Git Stashes")
                            ForEach(feature.gitStashes) { stash in
                                stashRow(stash)
                            }
                        }
                    }
                    .padding(7)
                }
            }
        }
    }

    private func stashRow(_ stash: GitStash) -> some View {
        Button {
            selectedStash = stash
        } label: {
            HStack(spacing: 8) {
                LitheSystemIcon(systemImage: "archivebox")
                    .foregroundStyle(LitheTheme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stash.message.isEmpty ? stash.reference : stash.message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(stash.reference)
                        if let branch = stash.branch, !branch.isEmpty {
                            Text("·")
                            Text(branch)
                        }
                        Text("·")
                        Text(stash.date)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                selectedStash?.id == stash.id
                    ? LitheTheme.subtleSelection
                    : LitheTheme.sidebar
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
        .litheContextMenu {
            [
                .action("Apply", systemImage: "arrow.down.circle", action: {
                    Task { await feature.applyStash(stash) }
                }),
                .action("Pop", systemImage: "arrow.up.circle", action: {
                    Task { await feature.applyStash(stash, pop: true) }
                }),
                .separator,
                .action("Drop", role: .destructive, action: { pendingDropStash = stash })
            ]
        }
    }

    private func savedChangesSectionHeader(_ title: String) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 3)
    }

    private func shelfRow(_ shelf: GitShelfEntry) -> some View {
        Button {
            selectedShelf = shelf
        } label: {
            HStack(spacing: 8) {
                LitheSystemIcon(systemImage: "shippingbox")
                    .foregroundStyle(LitheTheme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shelf.message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                    Text("\(shelf.paths.count) file(s) · \(shelf.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                selectedShelf?.id == shelf.id
                    ? LitheTheme.subtleSelection
                    : LitheTheme.sidebar
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
        .litheContextMenu {
            [
                .action("Restore", systemImage: "arrow.uturn.backward", action: {
                    Task { await feature.applyShelf(shelf) }
                }),
                .action("Drop", role: .destructive, action: { pendingDropShelf = shelf })
            ]
        }
    }

    private var commitToolbar: some View {
        HStack(spacing: 2) {
            Button {
                Task { await feature.refreshGit() }
            } label: {
                LitheSystemIcon(systemImage: "arrow.clockwise")
            }
            .litheIconButton()
            .help("Refresh changes")

            Button {
                pendingDiscardSelection = selectedChanges
            } label: {
                LitheSystemIcon(systemImage: "arrow.uturn.backward", size: LitheTheme.Commit.actionIconSize)
            }
            .litheIconButton()
            .disabled(selectedChanges.isEmpty)
            .help("Discard selected change")

            Button {
                Task { await feature.stageAllChanges() }
            } label: {
                LitheSystemIcon(systemImage: "square.and.arrow.down", size: LitheTheme.Commit.actionIconSize)
            }
            .litheIconButton()
            .disabled(feature.gitChanges.isEmpty)
            .help("Stage all changes")

            Button {
                if let first = feature.gitChanges.first {
                    selectChange(first)
                }
            } label: {
                LitheSystemIcon(systemImage: "eye", size: LitheTheme.Commit.actionIconSize)
            }
            .litheIconButton()
            .disabled(feature.gitChanges.isEmpty)
            .help("Preview first change")

            Spacer()

            if !feature.gitConflictFilterPaths.isEmpty {
                Button {
                    feature.clearGitConflictFilter()
                } label: {
                    Label("Clear conflict filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.warning)
                .lithePointer()
            }

            if feature.availableRepositoryRoots.count > 1 {
                Menu {
                    ForEach(feature.availableRepositoryRoots, id: \.self) { root in
                        Button(root.path) {
                            Task { await feature.selectRepository(root) }
                        }
                    }
                } label: {
                    Label(feature.gitRepositoryRoot?.lastPathComponent ?? "Repository", systemImage: "externaldrive")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .help("Select repository for commits and branch operations")
            }

            Text(feature.currentBranch)
                .font(.system(size: 10.5))
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
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(LitheTheme.success)
                    Text("Working tree is clean")
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayedChanges.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(LitheTheme.warning)
                    Text("No files match the conflict filter")
                    Button("Show all changes") { feature.clearGitConflictFilter() }
                        .buttonStyle(.borderless)
                        .lithePointer()
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            changeSection(
                                "Changes",
                                changes: trackedChanges,
                                expanded: $trackedExpanded,
                                showsParentPaths: geometry.size.width >= 300,
                                joinsNextHeader: !trackedExpanded && !addedChanges.isEmpty
                            )
                            changeSection(
                                "Unversioned Files",
                                changes: addedChanges,
                                expanded: $untrackedExpanded,
                                showsParentPaths: geometry.size.width >= 300,
                                joinsPreviousHeader: !trackedExpanded && !trackedChanges.isEmpty
                            )
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func changeSection(
        _ title: String,
        changes: [GitChange],
        expanded: Binding<Bool>,
        showsParentPaths: Bool,
        joinsPreviousHeader: Bool = false,
        joinsNextHeader: Bool = false
    ) -> some View {
        if !changes.isEmpty {
            HStack(spacing: 7) {
                Button {
                    expanded.wrappedValue.toggle()
                } label: {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 10, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(LocalizedStringKey(expanded.wrappedValue ? "Collapse section" : "Expand section"))

                Button {
                    setStaging(changes, !allChangesStaged(changes))
                } label: {
                    Image(systemName: stagingSymbol(for: changes))
                        .font(.system(size: 16))
                        .foregroundStyle(changes.contains(where: isEffectivelyStaged) ? LitheTheme.accent : LitheTheme.secondaryText)
                        .frame(width: 18, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(LocalizedStringKey(allChangesStaged(changes) ? "Unstage all files" : "Stage all files"))

                Button {
                    expanded.wrappedValue.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Text(LocalizedStringKey(title))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(LitheTheme.primaryText)
                        Text(changes.count == 1 ? "1 file" : "\(changes.count) files")
                            .font(.system(size: 11))
                            .foregroundStyle(LitheTheme.secondaryText)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity)
            .frame(height: changeRowHeight)
            .background {
                LitheTheme.subtleSelection.opacity(0.72)
                    .mask {
                        RoundedRectangle(cornerRadius: 4)
                            .overlay(alignment: .top) {
                                if joinsPreviousHeader { Rectangle().frame(height: 4) }
                            }
                            .overlay(alignment: .bottom) {
                                if joinsNextHeader { Rectangle().frame(height: 4) }
                            }
                    }
            }

            if expanded.wrappedValue {
                ForEach(Array(changes.enumerated()), id: \.element.id) { index, change in
                    changeRow(
                        change,
                        showsParentPath: showsParentPaths,
                        joinsPrevious: index > 0 && selection.ids.contains(changes[index - 1].id),
                        joinsNext: index + 1 < changes.count && selection.ids.contains(changes[index + 1].id)
                    )
                }
            }
        }
    }

    private func changeRow(
        _ change: GitChange,
        showsParentPath: Bool,
        joinsPrevious: Bool,
        joinsNext: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                let targets = selection.actionTargets(in: displayedChanges, clicked: change)
                setStaging(targets, !isEffectivelyStaged(change))
            } label: {
                Image(systemName: isEffectivelyStaged(change) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(isEffectivelyStaged(change) ? LitheTheme.accent : LitheTheme.secondaryText)
                    .frame(width: 28, height: changeRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(LitheTreeRowButtonStyle())
            .help(LocalizedStringKey(isEffectivelyStaged(change) ? "Unstage file" : "Stage file"))

            Button {
                selectRow(change)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: change.kind.symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(statusColor(change))
                        .frame(width: 17, height: 17)
                        .background(statusColor(change).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .help(LocalizedStringKey(change.kind.title))
                    Text(changeDisplayName(change))
                        .font(.system(size: 12.5))
                        .foregroundStyle(fileNameColor(change))
                        .strikethrough(change.kind == .deleted, color: statusColor(change))
                        .lineLimit(1)
                        .layoutPriority(1)
                    let parent = parentPathText(change)
                    if showsParentPath, !parent.isEmpty {
                        Text(parent)
                            .font(.system(size: 10.5))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: changeRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(LitheTreeRowButtonStyle())
        }
        .padding(.leading, 30)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity)
        .frame(height: changeRowHeight)
        .background {
            if selection.ids.contains(change.id) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LitheTheme.subtleSelection)
                    .overlay(alignment: .top) {
                        if joinsPrevious { LitheTheme.subtleSelection.frame(height: 4) }
                    }
                    .overlay(alignment: .bottom) {
                        if joinsNext { LitheTheme.subtleSelection.frame(height: 4) }
                    }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectRow(change) }
        .accessibilityAddTraits(selection.ids.contains(change.id) ? .isSelected : [])
        .transaction { $0.animation = nil }
        .litheContextMenu {
            changeContextMenuItems(for: change)
        }
    }

    private var selectedChanges: [GitChange] {
        selection.actionTargets(in: displayedChanges)
    }

    private var visibleChangeIDs: [String] {
        ((trackedExpanded ? trackedChanges : []) + (untrackedExpanded ? addedChanges : [])).map(\.id)
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
        items.append(.separator)
        items.append(.action(
            shouldStage ? "Stage Files" : "Unstage Files",
            systemImage: shouldStage ? "plus.square" : "arrow.uturn.backward",
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
        .foregroundStyle(LitheTheme.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    /// All four sections come from one pass over `gitChanges`; see
    /// `GitChangeSectionsCache`.
    private var changeSections: GitChangeSectionsCache.Sections {
        sectionsCache.sections(
            changes: feature.gitChanges,
            conflictFilterPaths: feature.gitConflictFilterPaths
        )
    }

    private var trackedChanges: [GitChange] {
        changeSections.tracked
    }

    private var addedChanges: [GitChange] {
        changeSections.added
    }

    private var displayedChanges: [GitChange] {
        changeSections.displayed
    }

    private func isEffectivelyStaged(_ change: GitChange) -> Bool {
        feature.effectiveStagingState(for: change)
    }

    private func allChangesStaged(_ changes: [GitChange]) -> Bool {
        changes.allSatisfy(isEffectivelyStaged)
    }

    private func stagingSymbol(for changes: [GitChange]) -> String {
        if allChangesStaged(changes) { return "checkmark.square.fill" }
        return changes.contains(where: isEffectivelyStaged) ? "minus.square.fill" : "square"
    }

    private var canStash: Bool {
        !feature.activeRepositoryChanges.isEmpty && !feature.isPerformingStashOperation
    }

    private var canShelf: Bool {
        !feature.activeRepositoryChanges.isEmpty && !feature.isPerformingShelfOperation
    }

    private func statusColor(_ change: GitChange) -> Color {
        switch change.kind {
        case .added: LitheTheme.success
        case .modified: LitheTheme.warning
        case .deleted: .red.opacity(0.86)
        case .moved: LitheTheme.accent
        case .copied: Color(red: 0.46, green: 0.72, blue: 0.92)
        case .conflicted: .red
        }
    }

    private func fileNameColor(_ change: GitChange) -> Color {
        change.kind == .modified ? LitheTheme.primaryText : statusColor(change)
    }

    private func selectRequestedStashIfNeeded() {
        guard let reference = feature.requestedStashReference else { return }
        selectedTab = .shelf
        selectedStash = feature.gitStashes.first(where: { $0.reference == reference })
    }

    private func changeDisplayName(_ change: GitChange) -> String {
        guard let originalPath = change.originalPath else { return change.url.lastPathComponent }
        let oldName = (originalPath as NSString).lastPathComponent
        return "\(oldName) → \(change.url.lastPathComponent)"
    }

    private func parentPathText(_ change: GitChange) -> String {
        let parent = (change.path as NSString).deletingLastPathComponent
        let prefix = feature.availableRepositoryRoots.count > 1
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
private struct GitOperationBanner: View {
    @ObservedObject var feature: GitFeatureModel
    let operation: GitOperationState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LitheTheme.warning)
                Text(LocalizedStringKey(operation.kind.inProgressTitle))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                if let reference = operation.reference {
                    Text(verbatim: "— \(reference)")
                        .font(.system(size: 12))
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
            .font(.system(size: 11))
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
            .font(.system(size: 11))
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
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer(minLength: 0)
            }

            Text("Your local changes are safe in \(conflict.stashReference). The \(conflict.operationTitle) is incomplete. Resolve the conflicts, then drop this stash manually.")
                .font(.system(size: 10.5))
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
    var title: String { rawValue.capitalized }
}
