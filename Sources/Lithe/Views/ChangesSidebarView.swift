import SwiftUI

struct ChangesSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab = CommitTab.commit
    @State private var trackedExpanded = true
    @State private var untrackedExpanded = true
    @State private var commitAreaHeight: CGFloat = 124
    @State private var commitAreaDragStart: CGFloat = 124
    @State private var stashMessage = "WIP"
    @State private var includeUntracked = true
    @State private var selectedStash: GitStash?
    @State private var pendingDropStash: GitStash?
    @State private var shouldConfirmCommitAndPush = false

    var body: some View {
        VStack(spacing: 0) {
            tabHeader
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if model.gitRepositoryRoot == nil {
                noRepository
            } else if selectedTab == .shelf {
                shelfContent
            } else {
                commitContent
            }
        }
        .background(LitheTheme.sidebar)
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
                Task { await model.dropStash(pendingDropStash) }
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
            "Commit and push changes?",
            isPresented: $shouldConfirmCommitAndPush,
            titleVisibility: .visible
        ) {
            Button("Commit and Push") {
                Task { await model.commitAndPushStagedChanges() }
            }
            .lithePointer()
            Button("Cancel", role: .cancel) {}
                .lithePointer()
        } message: {
            Text("The staged changes will be committed and the current branch will be pushed to its configured remote.")
        }
        .confirmationDialog(
            "Replace current commit message?",
            isPresented: Binding(
                get: { model.pendingGeneratedCommitMessage != nil },
                set: { if !$0 { model.discardPendingGeneratedCommitMessage() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Replace") {
                model.applyPendingGeneratedCommitMessage()
            }
            .lithePointer()
            Button("Keep Current", role: .cancel) {
                model.discardPendingGeneratedCommitMessage()
            }
            .lithePointer()
        } message: {
            Text("The generated message will replace the text currently in the editor.")
        }
    }

    private var tabHeader: some View {
        HStack(spacing: 7) {
            ForEach(CommitTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(LocalizedStringKey(tab.title))
                        .font(.system(size: 12.5, weight: tab == selectedTab ? .semibold : .regular))
                        .foregroundStyle(tab == selectedTab ? LitheTheme.primaryText : LitheTheme.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(tab == selectedTab ? LitheTheme.subtleSelection : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .lithePointer()
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(LitheTheme.toolHeader)
    }

    private var commitContent: some View {
        GeometryReader { geometry in
            let toolbarHeight: CGFloat = 37
            let minimumListHeight: CGFloat = 120
            let minimumCommitHeight: CGFloat = 124
            let availableCommitHeight = geometry.size.height
                - toolbarHeight
                - SplitHandleView.thickness
                - minimumListHeight
            let maximumCommitHeight = max(
                minimumCommitHeight,
                availableCommitHeight
            )
            let resolvedCommitHeight = constrained(
                commitAreaHeight,
                minimum: minimumCommitHeight,
                maximum: maximumCommitHeight
            )

            VStack(spacing: 0) {
                commitToolbar
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                changeList
                    .frame(minHeight: minimumListHeight)
                SplitHandleView(
                    axis: .vertical,
                    onDragStarted: {
                        commitAreaDragStart = resolvedCommitHeight
                    },
                    onDragChanged: { translation in
                        commitAreaHeight = constrained(
                            commitAreaDragStart - translation,
                            minimum: minimumCommitHeight,
                            maximum: maximumCommitHeight
                        )
                    },
                    onDragEnded: {
                        commitAreaHeight = resolvedCommitHeight
                    }
                )
                commitArea
                    .frame(height: resolvedCommitHeight)
            }
        }
    }

    private var shelfContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Stash message", text: $stashMessage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 7)
                    .frame(height: 27)
                    .background(LitheTheme.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Toggle("Untracked", isOn: $includeUntracked)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10.5))
                    .fixedSize()

                Button {
                    Task {
                        await model.stashWorkingTree(
                            message: stashMessage,
                            includeUntracked: includeUntracked
                        )
                        selectedStash = nil
                    }
                } label: {
                    HStack(spacing: 5) {
                        if model.isPerformingStashOperation {
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
            }
            .padding(8)
            .background(LitheTheme.toolHeader)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if model.gitStashes.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 28, weight: .light))
                    Text("No shelves")
                    Text("Stash changes here to switch branches safely.")
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
                        ForEach(model.gitStashes) { stash in
                            stashRow(stash)
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
        .contextMenu {
            Button("Apply") { Task { await model.applyStash(stash) } }
            Button("Pop") { Task { await model.applyStash(stash, pop: true) } }
            Divider()
            Button("Drop", role: .destructive) { pendingDropStash = stash }
        }
    }

    private var commitToolbar: some View {
        HStack(spacing: 2) {
            Button {
                Task { await model.refreshGit() }
            } label: {
                LitheSystemIcon(systemImage: "arrow.clockwise")
            }
            .litheIconButton()
            .help("Refresh changes")

            Button {
                model.requestDiscardSelectedChange()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .litheIconButton()
            .disabled(model.selectedChange == nil)
            .help("Discard selected change")

            Button {
                Task { await model.stageAllChanges() }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .litheIconButton()
            .disabled(model.gitChanges.isEmpty)
            .help("Stage all changes")

            Button {
                if let first = model.gitChanges.first {
                    model.selectChange(first)
                }
            } label: {
                Image(systemName: "eye")
            }
            .litheIconButton()
            .disabled(model.gitChanges.isEmpty)
            .help("Preview first change")

            Spacer()

            Text(model.currentBranch)
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: 36)
    }

    private var changeList: some View {
        Group {
            if model.gitChanges.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(LitheTheme.success)
                    Text("Working tree is clean")
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            changeSection(
                                "Changes",
                                changes: trackedChanges,
                                expanded: $trackedExpanded,
                                showsParentPaths: geometry.size.width >= 300
                            )
                            changeSection(
                                "Unversioned Files",
                                changes: untrackedChanges,
                                expanded: $untrackedExpanded,
                                showsParentPaths: geometry.size.width >= 300
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
        showsParentPaths: Bool
    ) -> some View {
        if !changes.isEmpty {
            Button {
                expanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 10)
                    Image(systemName: "square")
                        .font(.system(size: 16))
                        .foregroundStyle(LitheTheme.secondaryText)
                    Text(LocalizedStringKey(title))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                    Text(changes.count == 1 ? "1 file" : "\(changes.count) files")
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(LitheTheme.subtleSelection.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()

            if expanded.wrappedValue {
                ForEach(changes) { change in
                    changeRow(change, showsParentPath: showsParentPaths)
                }
            }
        }
    }

    private func changeRow(_ change: GitChange, showsParentPath: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.toggleStaging(change) }
            } label: {
                Image(systemName: change.isStaged ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(change.isStaged ? LitheTheme.accent : LitheTheme.secondaryText)
            }
            .litheIconButton()
            .help(change.isStaged ? "Unstage file" : "Stage file")

            Button {
                model.selectChange(change)
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
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()
        }
        .padding(.leading, 30)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(model.selectedChange?.id == change.id ? LitheTheme.subtleSelection : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contextMenu {
            changeContextMenu(for: change)
        }
    }

    @ViewBuilder
    private func changeContextMenu(for change: GitChange) -> some View {
        if change.kind != .deleted {
            Button("Open") {
                model.openFile(change.url, displayPath: change.path)
            }
        }

        Button("Show Diff") {
            model.selectChange(change)
        }

        Divider()

        if change.isStaged {
            Button("Unstage") {
                Task { await model.toggleStaging(change) }
            }
        } else {
            Button("Stage File") {
                Task { await model.toggleStaging(change) }
            }
        }

        if change.hasWorkingTreeChange {
            Button("Discard Changes", role: .destructive) {
                model.requestDiscardChange(change)
            }
        }

        Divider()

        Button("Local History…") {
            model.showLocalHistory(for: change.url)
        }
        .disabled(change.kind == .deleted)

        Button("Show in Finder") {
            let url = change.kind == .deleted
                ? change.url.deletingLastPathComponent()
                : change.url
            model.revealProjectItemInFinder(url)
        }

        Menu("Copy Path / Reference") {
            Button("Copy Path") {
                model.copyProjectItemPath(change.url, relative: false)
            }
            Button("Copy Relative Path") {
                model.copyProjectItemPath(change.url, relative: true)
            }
        }
    }

    private var commitArea: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Toggle("Amend", isOn: $model.amendCommit)
                    .toggleStyle(.checkbox)
                    .lithePointer()
                    .font(.system(size: 12))
                Image(systemName: "clock")
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer()
                Button {
                    Task { await model.generateCommitMessage() }
                } label: {
                    HStack(spacing: 4) {
                        if model.isGeneratingCommitMessage {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text("AI")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(LitheTheme.raised.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .lithePointer()
                .disabled(
                    stagedChanges.isEmpty ||
                        model.isLoadingDiff ||
                        model.isGeneratingCommitMessage
                )
                .help("Generate a commit message from staged diffs")
                Text("\(stagedChanges.count) staged")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.commitMessage)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .padding(4)

                if model.commitMessage.isEmpty {
                    Text("Commit Message")
                        .font(.system(size: 12.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50, maxHeight: .infinity, alignment: .topLeading)
            .background(LitheTheme.editor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(LitheTheme.divider, lineWidth: 1)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await model.commitStagedChanges() }
                } label: {
                    HStack(spacing: 6) {
                        if model.isCommitting {
                            ProgressView().controlSize(.mini)
                        }
                        Text("Commit")
                    }
                }
                .buttonStyle(.bordered)
                .lithePointer()
                .disabled(!canCommit)

                Button {
                    shouldConfirmCommitAndPush = true
                } label: {
                    HStack(spacing: 6) {
                        if model.isCommitting {
                            ProgressView().controlSize(.mini)
                        }
                        Text("Commit and Push…")
                    }
                }
                .buttonStyle(.bordered)
                .lithePointer()
                .disabled(!canCommit)

                Spacer()
                LitheSystemIcon(systemImage: "gearshape")
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(LitheTheme.toolHeader)
    }

    private var noRepository: some View {
        VStack(spacing: 10) {
            LitheIDEAIcon(
                resourcePath: "vcs/branch.svg",
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

    private var trackedChanges: [GitChange] {
        model.gitChanges.filter { !$0.isUntracked }
    }

    private var untrackedChanges: [GitChange] {
        model.gitChanges.filter(\.isUntracked)
    }

    private var stagedChanges: [GitChange] {
        model.gitChanges.filter(\.isStaged)
    }

    private var canCommit: Bool {
        !stagedChanges.isEmpty &&
            !model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.isCommitting
    }

    private var canStash: Bool {
        !model.gitChanges.isEmpty && !model.isPerformingStashOperation
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

    private func changeDisplayName(_ change: GitChange) -> String {
        guard let originalPath = change.originalPath else { return change.url.lastPathComponent }
        let oldName = (originalPath as NSString).lastPathComponent
        return "\(oldName) → \(change.url.lastPathComponent)"
    }

    private func parentPathText(_ change: GitChange) -> String {
        let parent = (change.path as NSString).deletingLastPathComponent
        guard let originalPath = change.originalPath else { return parent }
        let originalParent = (originalPath as NSString).deletingLastPathComponent
        guard originalParent != parent else { return parent }
        return "\(originalParent) → \(parent)"
    }

    private func constrained(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(maximum, max(minimum, value))
    }
}

private enum CommitTab: String, CaseIterable, Identifiable {
    case commit
    case shelf

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}
