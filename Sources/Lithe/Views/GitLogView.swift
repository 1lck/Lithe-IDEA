import SwiftUI

struct GitLogView: View {
    @EnvironmentObject private var model: AppModel
    @State private var localExpanded = true
    @State private var remoteExpanded = true
    @State private var tagsExpanded = true
    @State private var collapsedReferenceGroups: Set<String> = []
    @State private var collapsedFileGroups: Set<String> = []
    @State private var referencePaneWidth: CGFloat = 300
    @State private var referencePaneDragStart: CGFloat = 300
    @State private var detailPaneWidth: CGFloat = 350
    @State private var detailPaneDragStart: CGFloat = 350
    @State private var filesPaneHeight: CGFloat?
    @State private var filesPaneDragStart: CGFloat = 0
    @State private var branchDialogRequest: GitBranchDialogRequest?
    @State private var pendingPushReference: GitReference?
    @State private var pendingCommitOperation: GitCommitOperationRequest?
    @State private var pendingBranchOperation: GitBranchOperationRequest?
    @State private var showCommitDecorations = true
    @FocusState private var gitLogSearchFocused: Bool

    /// IntelliJ's Git tool window uses the macOS system UI font throughout;
    /// only hashes and timestamps use a monospaced face. Keeping these values
    /// together makes the Git surface read as one coherent tool window.
    private enum GitVisual {
        static let title = Font.system(size: 13.5, weight: .semibold)
        static let toolbar = Font.system(size: 12.5, weight: .regular)
        static let section = Font.system(size: 13, weight: .medium)
        static let body = Font.system(size: 13, weight: .regular)
        static let bodyMedium = Font.system(size: 13, weight: .medium)
        static let meta = Font.system(size: 12, weight: .regular)
        static let monoMeta = Font.system(size: 12, weight: .regular, design: .monospaced)
        static let rowHeight: CGFloat = 38
        static let treeRowHeight: CGFloat = 28
        static let toolbarHeight: CGFloat = 38
    }

    var body: some View {
        VStack(spacing: 0) {
            toolWindowHeader

            GeometryReader { geometry in
                let minimumReferencePaneWidth: CGFloat = 220
                let minimumCommitPaneWidth: CGFloat = 340
                let minimumDetailPaneWidth: CGFloat = 280
                let availablePaneWidth = max(
                    0,
                    geometry.size.width - (SplitHandleView.thickness * 2)
                )
                let maximumDetailPaneWidth = max(
                    minimumDetailPaneWidth,
                    min(520, availablePaneWidth - minimumReferencePaneWidth - minimumCommitPaneWidth)
                )
                let resolvedDetailPaneWidth = constrained(
                    detailPaneWidth,
                    minimum: minimumDetailPaneWidth,
                    maximum: maximumDetailPaneWidth
                )
                let maximumReferencePaneWidth = max(
                    minimumReferencePaneWidth,
                    min(480, availablePaneWidth - resolvedDetailPaneWidth - minimumCommitPaneWidth)
                )
                let resolvedReferencePaneWidth = constrained(
                    referencePaneWidth,
                    minimum: minimumReferencePaneWidth,
                    maximum: maximumReferencePaneWidth
                )

                HStack(spacing: 0) {
                    referencePane
                        .frame(width: resolvedReferencePaneWidth)

                    SplitHandleView(
                        axis: .horizontal,
                        onDragStarted: {
                            referencePaneDragStart = resolvedReferencePaneWidth
                        },
                        onDragChanged: { translation in
                            referencePaneWidth = constrained(
                                referencePaneDragStart + translation,
                                minimum: minimumReferencePaneWidth,
                                maximum: maximumReferencePaneWidth
                            )
                        },
                        onDragEnded: {}
                    )

                    commitPane
                        .frame(minWidth: minimumCommitPaneWidth, maxWidth: .infinity)

                    SplitHandleView(
                        axis: .horizontal,
                        onDragStarted: {
                            detailPaneDragStart = resolvedDetailPaneWidth
                        },
                        onDragChanged: { translation in
                            detailPaneWidth = constrained(
                                detailPaneDragStart - translation,
                                minimum: minimumDetailPaneWidth,
                                maximum: maximumDetailPaneWidth
                            )
                        },
                        onDragEnded: {}
                    )

                    detailPane
                        .frame(width: resolvedDetailPaneWidth)
                }
            }
        }
        .background(LitheTheme.sidebar)
        .sheet(item: $branchDialogRequest) { request in
            GitBranchNameDialog(request: request) { name, checkout in
                Task {
                    switch request.kind {
                    case .create:
                        await model.createBranch(
                            named: name,
                            from: request.reference,
                            checkout: checkout
                        )
                    case .rename:
                        await model.renameBranch(request.reference, to: name)
                    }
                }
            }
        }
        .confirmationDialog(
            "Push '\(pendingPushReference?.shortName ?? "")'?",
            isPresented: Binding(
                get: { pendingPushReference != nil },
                set: { if !$0 { pendingPushReference = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Push") {
                guard let reference = pendingPushReference else { return }
                pendingPushReference = nil
                Task { await model.pushBranch(reference) }
            }
            .lithePointer()
            Button("Cancel", role: .cancel) {
                pendingPushReference = nil
            }
            .lithePointer()
        } message: {
            Text("This sends the selected local branch to its configured remote.")
        }
        .confirmationDialog(
            pendingCommitOperation?.kind.title ?? "Git operation",
            isPresented: Binding(
                get: { pendingCommitOperation != nil },
                set: { if !$0 { pendingCommitOperation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let operation = pendingCommitOperation {
                Button(operation.kind.actionTitle) {
                    pendingCommitOperation = nil
                    Task {
                        switch operation.kind {
                        case .cherryPick:
                            await model.cherryPick(operation.commit)
                        case .revert:
                            await model.revert(operation.commit)
                        case .reset:
                            await model.resetCurrentBranch(to: operation.commit)
                        }
                    }
                }
                .disabled(model.isPerformingBranchOperation)
                .lithePointer()
            }
            Button("Cancel", role: .cancel) {
                pendingCommitOperation = nil
            }
            .lithePointer()
        } message: {
            if let operation = pendingCommitOperation {
                Text(operation.kind.message(for: operation.commit))
            }
        }
        .confirmationDialog(
            pendingBranchOperation?.kind.title ?? "Git branch operation",
            isPresented: Binding(
                get: { pendingBranchOperation != nil },
                set: { if !$0 { pendingBranchOperation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let operation = pendingBranchOperation {
                Button(operation.kind.actionTitle, role: operation.kind == .delete ? .destructive : nil) {
                    pendingBranchOperation = nil
                    Task {
                        switch operation.kind {
                        case .delete:
                            await model.deleteBranch(operation.reference)
                        case .merge:
                            await model.mergeBranch(operation.reference)
                        case .rebase:
                            await model.rebaseCurrentBranch(onto: operation.reference)
                        }
                    }
                }
                .disabled(model.isPerformingBranchOperation)
                .lithePointer()
            }
            Button("Cancel", role: .cancel) {
                pendingBranchOperation = nil
            }
            .lithePointer()
        } message: {
            if let operation = pendingBranchOperation {
                Text(operation.kind.message(for: operation.reference))
            }
        }
    }

    private var toolWindowHeader: some View {
        HStack(spacing: 8) {
            LitheIDEAIcon(
                resourcePath: "vcs/branch.svg",
                size: 14,
                fallbackSystemImage: "point.3.connected.trianglepath.dotted"
            )
            .foregroundStyle(LitheTheme.secondaryText)

            Text("Git")
                .font(GitVisual.title)
                .foregroundStyle(LitheTheme.primaryText)

            Button {
                Task { await model.selectGitReference(nil) }
            } label: {
                HStack(spacing: 6) {
                    Text("Log: \(model.selectedGitReference?.shortName ?? model.currentBranch)")
                        .font(GitVisual.title)
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(LitheTheme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(LitheTheme.inputFocusBorder.opacity(0.72), lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()
            .help("Show all references")

            Button {
                Task { await model.selectGitReference(nil) }
            } label: {
                Image(systemName: "plus")
            }
            .litheIconButton()
            .help("Show all references")

            Menu {
                Button("Fetch All Remotes") {
                    Task { await model.fetchGit() }
                }
                Button("Update Current Branch") {
                    guard let currentReference else { return }
                    Task { await model.updateCurrentBranch(currentReference) }
                }
                .disabled(currentReference == nil)
                Button("Refresh Log") {
                    Task { await model.refreshGitHistory() }
                }
                Divider()
                Button("Show Changes") {
                    model.selectedSidebar = .changes
                }
            } label: {
                LitheIDEAIcon(resourcePath: "actions/more.svg", size: 15, fallbackSystemImage: "ellipsis")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .lithePointer()
            .frame(width: 28, height: 28)
            .help("Git tool window actions")

            Spacer(minLength: 12)

            Button {
                model.closeGitLog()
            } label: {
                Image(systemName: "minus")
            }
            .litheIconButton()
            .help("Hide Git tool window")
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: 32)
        .background(LitheTheme.toolHeader)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
        }
    }

    private var referencePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    Task { await model.selectGitReference(nil) }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .litheIconButton()

                Button {
                    model.gitLogSearchQuery = ""
                } label: {
                    LitheSystemIcon(systemImage: "magnifyingglass")
                }
                .litheIconButton()
                .help("Clear log search")

                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(height: GitVisual.toolbarHeight)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            GeometryReader { geometry in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let current = currentReference {
                            referenceButton(current, title: "HEAD (Current Branch)", icon: "arrow.right")
                                .padding(.bottom, 4)
                        }

                        referenceSection(
                            title: "Local",
                            icon: "folder",
                            kind: .local,
                            expanded: $localExpanded
                        )
                        referenceSection(
                            title: "Remote",
                            icon: "network",
                            kind: .remote,
                            expanded: $remoteExpanded
                        )
                        referenceSection(
                            title: "Tags",
                            icon: "tag",
                            kind: .tag,
                            expanded: $tagsExpanded
                        )
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 9)
                    .frame(
                        minWidth: geometry.size.width,
                        minHeight: geometry.size.height,
                        alignment: .topLeading
                    )
                }
                .litheScrollViewChrome(hideHorizontal: true)
            }
        }
        .background(LitheTheme.sidebar)
    }

    private func referenceSection(
        title: String,
        icon: String,
        kind: GitReferenceKind,
        expanded: Binding<Bool>
    ) -> some View {
        let references = model.gitReferences.filter { $0.kind == kind }
        return VStack(alignment: .leading, spacing: 1) {
            Button {
                expanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 10)
                    LitheSystemIcon(systemImage: icon, size: 14)
                    Text(LocalizedStringKey(title))
                        .font(GitVisual.section)
                }
                .foregroundStyle(LitheTheme.primaryText)
                .frame(maxWidth: .infinity, minHeight: GitVisual.treeRowHeight, alignment: .leading)
                .contentShape(Rectangle())
                .litheRowHover(cornerRadius: 4)
            }
            .buttonStyle(.plain)
            .lithePointer()

            if expanded.wrappedValue {
                ForEach(GitReferenceTreeNode.build(from: references)) { node in
                    referenceTreeNode(node, kind: kind, depth: 0)
                }
            }
        }
    }

    private func referenceTreeNode(
        _ node: GitReferenceTreeNode,
        kind: GitReferenceKind,
        depth: Int
    ) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 1) {
                if let reference = node.reference {
                    referenceButton(reference, title: node.name, icon: referenceIcon(reference))
                        .padding(.leading, CGFloat(18 + depth * 18))
                }

                if !node.children.isEmpty {
                    Button {
                        let key = "\(kind.rawValue):\(node.path)"
                        if collapsedReferenceGroups.contains(key) {
                            collapsedReferenceGroups.remove(key)
                        } else {
                            collapsedReferenceGroups.insert(key)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: collapsedReferenceGroups.contains("\(kind.rawValue):\(node.path)") ? "chevron.right" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .frame(width: 10)
                            LitheSystemIcon(systemImage: "folder", size: 14)
                            Text(node.name)
                                .font(GitVisual.body)
                                .foregroundStyle(LitheTheme.primaryText)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                        }
                        .padding(.leading, CGFloat(18 + depth * 18))
                        .padding(.trailing, 8)
                        .frame(maxWidth: .infinity, minHeight: GitVisual.treeRowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                        .litheRowHover(cornerRadius: 4)
                    }
                    .buttonStyle(.plain)
                    .lithePointer()

                    if !collapsedReferenceGroups.contains("\(kind.rawValue):\(node.path)") {
                        ForEach(node.children) { child in
                            referenceTreeNode(child, kind: kind, depth: depth + 1)
                        }
                    }
                }
            }
        )
    }

    private func referenceButton(_ reference: GitReference, title: String, icon: String) -> some View {
        Button {
            Task { await model.selectGitReference(reference) }
        } label: {
            HStack(spacing: 7) {
                LitheSystemIcon(systemImage: icon, size: 14)
                    .foregroundStyle(reference.kind == .tag ? LitheTheme.warning : LitheTheme.secondaryText)
                    .frame(width: 16)
                Text(LocalizedStringKey(title))
                    .font(GitVisual.body)
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: GitVisual.treeRowHeight, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .litheRowHover(
                isActive: model.selectedGitReference?.id == reference.id
                    || (model.selectedGitReference == nil && reference.isCurrent),
                cornerRadius: 4,
                activeBackground: LitheTheme.subtleSelection
            )
        }
        .buttonStyle(.plain)
        .lithePointer()
        .contextMenu {
            Button("New Branch from '\(reference.shortName)'…") {
                branchDialogRequest = GitBranchDialogRequest(kind: .create, reference: reference)
            }

            Button("Show Diff with Working Tree") {
                Task { await model.showComparisonWithWorkingTree(for: reference) }
            }

            if reference.kind == .local {
                Divider()

                if !reference.isCurrent {
                    Button("Checkout") {
                        Task { await model.checkoutReference(reference) }
                    }
                    .disabled(model.isPerformingBranchOperation)
                }

                Button("Update") {
                    Task { await model.updateCurrentBranch(reference) }
                }
                .disabled(!reference.isCurrent || model.isPerformingBranchOperation)

                Button("Push…") {
                    pendingPushReference = reference
                }
                .disabled(model.isPerformingBranchOperation)

                if !reference.isCurrent {
                    Button("Merge into Current Branch") {
                        pendingBranchOperation = GitBranchOperationRequest(
                            kind: .merge,
                            reference: reference
                        )
                    }
                    Button("Rebase Current Branch onto…") {
                        pendingBranchOperation = GitBranchOperationRequest(
                            kind: .rebase,
                            reference: reference
                        )
                    }
                    Button("Delete Branch", role: .destructive) {
                        pendingBranchOperation = GitBranchOperationRequest(
                            kind: .delete,
                            reference: reference
                        )
                    }
                    .disabled(model.isPerformingBranchOperation)
                }

                Divider()

                Button("Rename…") {
                    branchDialogRequest = GitBranchDialogRequest(kind: .rename, reference: reference)
                }
                .disabled(model.isPerformingBranchOperation)
            }
        }
    }

    private var commitPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    LitheIDEAIcon(resourcePath: "actions/search.svg", size: 14, fallbackSystemImage: "magnifyingglass")
                        .foregroundStyle(LitheTheme.secondaryText)
                    TextField("Text or hash", text: $model.gitLogSearchQuery)
                        .textFieldStyle(.plain)
                        .font(GitVisual.toolbar)
                        .focused($gitLogSearchFocused)
                    if !model.gitLogSearchQuery.isEmpty {
                        Button {
                            model.gitLogSearchQuery = ""
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .litheIconButton()
                        .foregroundStyle(LitheTheme.secondaryText)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: 236, height: 29, alignment: .leading)
                .background(LitheTheme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(LitheTheme.inputBorder, lineWidth: 1)
                }

                Text("Branch: \(model.selectedGitReference?.shortName ?? "All")")
                    .font(GitVisual.toolbar)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .padding(.leading, 2)

                Spacer()

                HStack(spacing: 2) {
                    gitToolbarButton(systemImage: "arrow.left.arrow.right", help: "Compare current branch with working tree") {
                        guard let currentReference else { return }
                        Task { await model.showComparisonWithWorkingTree(for: currentReference) }
                    }
                    .disabled(currentReference == nil)
                    gitToolbarIcon(systemImage: "clock", help: "Show commit details")
                    gitToolbarButton(systemImage: "arrow.clockwise", help: "Refresh Git log") {
                        Task { await model.refreshGitHistory() }
                    }
                    gitToolbarButton(systemImage: showCommitDecorations ? "eye" : "eye.slash", help: "Toggle commit decorations") {
                        showCommitDecorations.toggle()
                    }
                    gitToolbarButton(systemImage: "magnifyingglass", help: "Find in log") {
                        gitLogSearchFocused = true
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: GitVisual.toolbarHeight)
            .background(LitheTheme.toolHeader)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if (visibleCommitHashes?.isEmpty == true || (visibleCommitHashes == nil && model.gitCommits.isEmpty)) && !model.isLoadingGitHistory {
                VStack(spacing: 8) {
                    LitheSystemIcon(systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 27, weight: .light))
                    Text("No commits match this view")
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            GitGraphView(
                                layout: graphLayout,
                                visibleHashes: visibleCommitHashes,
                                selectedHash: model.selectedGitCommit?.hash,
                                showCommitDecorations: showCommitDecorations,
                                onSelect: { commit in
                                    Task { await model.selectGitCommit(commit) }
                                },
                                onCherryPick: { commit in
                                    pendingCommitOperation = GitCommitOperationRequest(
                                        kind: .cherryPick,
                                        commit: commit
                                    )
                                },
                                onRevert: { commit in
                                    pendingCommitOperation = GitCommitOperationRequest(
                                        kind: .revert,
                                        commit: commit
                                    )
                                },
                                onReset: { commit in
                                    pendingCommitOperation = GitCommitOperationRequest(
                                        kind: .reset,
                                        commit: commit
                                    )
                                }
                            )

                            if model.canLoadMoreGitHistory {
                                Button {
                                    Task { await model.loadMoreGitHistory() }
                                } label: {
                                    HStack(spacing: 6) {
                                        if model.isLoadingMoreGitHistory {
                                            ProgressView().controlSize(.small)
                                        }
                                        Text(model.isLoadingMoreGitHistory ? "Loading commits…" : "Load more commits")
                                    }
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(LitheTheme.accent)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 32)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .lithePointer()
                            }
                        }
                    }
                    .litheScrollViewChrome(hideHorizontal: true)
                    .onChange(of: model.selectedGitCommit?.hash) {
                        guard let hash = model.selectedGitCommit?.hash else { return }
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(hash, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(LitheTheme.editor)
    }

    private var detailPane: some View {
        GeometryReader { geometry in
            let minimumFilesPaneHeight: CGFloat = 90
            let minimumCommitDetailHeight: CGFloat = 110
            let maximumFilesPaneHeight = max(
                minimumFilesPaneHeight,
                geometry.size.height - SplitHandleView.thickness - minimumCommitDetailHeight
            )
            let resolvedFilesPaneHeight = constrained(
                filesPaneHeight ?? (geometry.size.height - SplitHandleView.thickness - 156),
                minimum: minimumFilesPaneHeight,
                maximum: maximumFilesPaneHeight
            )

            VStack(spacing: 0) {
                commitFilesPane
                    .frame(height: resolvedFilesPaneHeight)

                SplitHandleView(
                    axis: .vertical,
                    onDragStarted: {
                        filesPaneDragStart = resolvedFilesPaneHeight
                    },
                    onDragChanged: { translation in
                        filesPaneHeight = constrained(
                            filesPaneDragStart + translation,
                            minimum: minimumFilesPaneHeight,
                            maximum: maximumFilesPaneHeight
                        )
                    },
                    onDragEnded: {}
                )

                commitDetail
                    .frame(maxHeight: .infinity)
            }
        }
        .background(LitheTheme.sidebar)
    }

    private var commitFilesPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                gitToolbarIcon(systemImage: "arrow.left.arrow.right", help: "Compare changes")
                gitToolbarIcon(systemImage: "clock", help: "Show file history")
                gitToolbarIcon(systemImage: "eye", help: "Toggle preview")
                Spacer()
                Text("\(model.selectedGitCommitFiles.count) files")
            }
            .font(GitVisual.meta)
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: GitVisual.toolbarHeight)
            .background(LitheTheme.toolHeader)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if model.selectedGitCommitFiles.isEmpty {
                Text(model.selectedGitCommit == nil ? "Select a commit" : "No changed files")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visibleCommitFileTreeItems) { item in
                                commitFileTreeItemRow(item)
                            }
                        }
                        .padding(.vertical, 5)
                        .frame(
                            minWidth: geometry.size.width,
                            minHeight: geometry.size.height,
                            alignment: .topLeading
                        )
                    }
                    .litheScrollViewChrome(hideHorizontal: true)
                }
            }
        }
    }

    private var commitDetail: some View {
        Group {
            if let commit = model.selectedGitCommit {
                VStack(alignment: .leading, spacing: 9) {
                    Text(commit.subject)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(2)
                    Text("\(commit.shortHash)  \(commit.authorName) <\(commit.authorEmail)>")
                        .font(GitVisual.meta)
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                    Text(commit.date)
                        .font(GitVisual.monoMeta)
                        .foregroundStyle(LitheTheme.secondaryText)
                    if !commit.decorations.isEmpty {
                        Text(commit.decorations)
                        .font(GitVisual.meta)
                            .foregroundStyle(LitheTheme.accent)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(11)
                .textSelection(.enabled)
            } else {
                Text("Commit details")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(LitheTheme.editor)
    }

    private var filteredCommits: [GitCommit] {
        let query = model.gitLogSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.gitCommits }
        return model.gitCommits.filter { commit in
            [commit.subject, commit.hash, commit.shortHash, commit.authorName, commit.authorEmail, commit.decorations]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var graphLayout: GitGraphLayout {
        GitGraphLayoutService.layout(commits: model.gitCommits)
    }

    private var visibleCommitHashes: Set<String>? {
        let query = model.gitLogSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        return Set(filteredCommits.map(\.hash))
    }

    private var commitFileTree: GitCommitFileTreeNode {
        GitCommitFileTreeNode.build(
            from: model.selectedGitCommitFiles,
            rootName: model.projectName
        )
    }

    private var visibleCommitFileTreeItems: [GitCommitFileTreeItem] {
        var items: [GitCommitFileTreeItem] = []
        appendVisibleCommitFileTreeItems(
            for: commitFileTree,
            depth: 0,
            into: &items
        )
        return items
    }

    private func appendVisibleCommitFileTreeItems(
        for node: GitCommitFileTreeNode,
        depth: Int,
        into items: inout [GitCommitFileTreeItem]
    ) {
        items.append(.folder(node, depth: depth))
        guard !collapsedFileGroups.contains(node.id) else { return }

        for directory in node.directories {
            appendVisibleCommitFileTreeItems(
                for: directory,
                depth: depth + 1,
                into: &items
            )
        }
        for file in node.files {
            items.append(.file(file, depth: depth + 1))
        }
    }

    @ViewBuilder
    private func commitFileTreeItemRow(_ item: GitCommitFileTreeItem) -> some View {
        switch item {
        case let .folder(node, depth):
            let isCollapsed = collapsedFileGroups.contains(node.id)
            Button {
                if isCollapsed {
                    collapsedFileGroups.remove(node.id)
                } else {
                    collapsedFileGroups.insert(node.id)
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 10)
                        .foregroundStyle(LitheTheme.secondaryText)
                    LitheSystemIcon(systemImage: "folder")
                        .frame(width: 14, height: 14)
                        .foregroundStyle(LitheTheme.secondaryText)
                    Text(node.name)
                        .font(GitVisual.bodyMedium)
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                    Text(node.fileCount == 1 ? "1 file" : "\(node.fileCount) files")
                        .font(GitVisual.meta)
                        .foregroundStyle(LitheTheme.secondaryText)
                    if depth == 0, let rootPath = commitFileRootSubtitle {
                        Text(rootPath)
                            .font(GitVisual.meta)
                            .foregroundStyle(LitheTheme.secondaryText.opacity(0.76))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.leading, 8 + CGFloat(depth * 16))
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: GitVisual.treeRowHeight, alignment: .leading)
                .contentShape(Rectangle())
                .litheRowHover(cornerRadius: 4)
            }
            .buttonStyle(.plain)
            .lithePointer()

        case let .file(file, depth):
            commitFileRow(file, depth: depth)
        }
    }

    private var commitFileRootSubtitle: String? {
        guard let root = model.gitRepositoryRoot else { return nil }
        let components = root.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }
        return components.suffix(2).joined(separator: "/")
    }

    private var currentReference: GitReference? {
        model.gitReferences.first(where: \.isCurrent)
    }

    private func referenceIcon(_ reference: GitReference) -> String {
        switch reference.kind {
        case .local: "point.3.connected.trianglepath.dotted"
        case .remote: "cloud"
        case .tag: "tag"
        }
    }

    private func fileStatusColor(_ status: String) -> Color {
        if status.hasPrefix("A") { return LitheTheme.success }
        if status.hasPrefix("D") { return .red.opacity(0.85) }
        if status.hasPrefix("R") { return LitheTheme.accent }
        return LitheTheme.warning
    }

    private func gitToolbarIcon(systemImage: String, help: String) -> some View {
        LitheSystemIcon(systemImage: systemImage, size: 15)
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .help(help)
    }

    private func gitToolbarButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            LitheSystemIcon(systemImage: systemImage, size: 15)
        }
        .litheIconButton()
        .help(help)
    }

    private func constrained(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }

    private func commitFileRow(_ file: GitCommitFile, depth: Int) -> some View {
        Button {
            model.showGitCommitDiff(for: file)
        } label: {
            HStack(spacing: 7) {
                Text(file.status)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(fileStatusColor(file.status))
                    .frame(width: 18)
                LitheSystemIcon(systemImage: "doc.text")
                    .frame(width: 14, height: 14)
                    .foregroundStyle(LitheTheme.accent)
                Text((file.path as NSString).lastPathComponent)
                    .font(GitVisual.body)
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.leading, 30 + CGFloat(max(depth - 1, 0) * 16))
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: GitVisual.treeRowHeight, alignment: .leading)
            .litheRowHover(
                isActive: model.selectedGitCommitFile?.id == file.id,
                cornerRadius: 4,
                activeBackground: LitheTheme.subtleSelection
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
    }
}

private struct GitReferenceTreeNode: Identifiable {
    let path: String
    let name: String
    let reference: GitReference?
    let children: [GitReferenceTreeNode]

    var id: String { path }

    static func build(from references: [GitReference]) -> [GitReferenceTreeNode] {
        let root = MutableGitReferenceTreeNode(name: "", path: "")

        for reference in references {
            let components = reference.shortName
                .split(separator: "/")
                .map(String.init)
            guard !components.isEmpty else { continue }

            var node = root
            var pathComponents: [String] = []
            for component in components {
                pathComponents.append(component)
                if node.children[component] == nil {
                    node.children[component] = MutableGitReferenceTreeNode(
                        name: component,
                        path: pathComponents.joined(separator: "/")
                    )
                }
                node = node.children[component]!
            }
            node.reference = reference
        }

        return makeNodes(from: root)
    }

    private static func makeNodes(from node: MutableGitReferenceTreeNode) -> [GitReferenceTreeNode] {
        node.children.values
            .map { child in
                GitReferenceTreeNode(
                    path: child.path,
                    name: child.name,
                    reference: child.reference,
                    children: makeNodes(from: child)
                )
            }
            .sorted { lhs, rhs in
                if (lhs.reference != nil) != (rhs.reference != nil) {
                    return lhs.reference != nil
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}

private final class MutableGitReferenceTreeNode {
    let name: String
    let path: String
    var reference: GitReference?
    var children: [String: MutableGitReferenceTreeNode] = [:]

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

private enum GitCommitFileTreeItem: Identifiable {
    case folder(GitCommitFileTreeNode, depth: Int)
    case file(GitCommitFile, depth: Int)

    var id: String {
        switch self {
        case let .folder(node, _): "folder:\(node.id)"
        case let .file(file, _): "file:\(file.id)"
        }
    }
}

private enum GitCommitOperationKind {
    case cherryPick
    case revert
    case reset

    var title: String {
        switch self {
        case .cherryPick: "Cherry-pick this commit?"
        case .revert: "Revert this commit?"
        case .reset: "Reset current branch?"
        }
    }

    var actionTitle: String {
        switch self {
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        case .reset: "Reset (Mixed)"
        }
    }

    func message(for commit: GitCommit) -> String {
        switch self {
        case .cherryPick:
            "Apply \(commit.shortHash) to the current branch."
        case .revert:
            "Create a new commit that reverses \(commit.shortHash)."
        case .reset:
            "Move the current branch to \(commit.shortHash) and keep changes unstaged."
        }
    }
}

private struct GitCommitOperationRequest: Identifiable {
    let kind: GitCommitOperationKind
    let commit: GitCommit

    var id: String { "\(kind.title):\(commit.hash)" }
}

private enum GitBranchDialogKind {
    case create
    case rename
}

private struct GitBranchDialogRequest: Identifiable {
    let id = UUID()
    let kind: GitBranchDialogKind
    let reference: GitReference
}

private enum GitBranchOperationKind {
    case delete
    case merge
    case rebase

    var title: String {
        switch self {
        case .delete: "Delete branch?"
        case .merge: "Merge branch?"
        case .rebase: "Rebase branch?"
        }
    }

    var actionTitle: String {
        switch self {
        case .delete: "Delete"
        case .merge: "Merge"
        case .rebase: "Rebase"
        }
    }

    func message(for reference: GitReference) -> String {
        switch self {
        case .delete:
            return "Delete the local branch \(reference.shortName)? Git will refuse if it contains unmerged work."
        case .merge:
            return "Merge \(reference.shortName) into the current branch. Conflicts may require terminal resolution."
        case .rebase:
            return "Replay the current branch onto \(reference.shortName). Conflicts may require terminal resolution."
        }
    }
}

private struct GitBranchOperationRequest: Identifiable {
    let kind: GitBranchOperationKind
    let reference: GitReference

    var id: String { "\(kind.title):\(reference.id)" }
}

private struct GitBranchNameDialog: View {
    @Environment(\.dismiss) private var dismiss
    let request: GitBranchDialogRequest
    let onSubmit: (String, Bool) -> Void

    @State private var name: String
    @State private var checkout: Bool
    @FocusState private var nameFieldFocused: Bool

    init(request: GitBranchDialogRequest, onSubmit: @escaping (String, Bool) -> Void) {
        self.request = request
        self.onSubmit = onSubmit
        _name = State(initialValue: request.kind == .rename ? request.reference.shortName : "")
        _checkout = State(initialValue: request.kind == .create)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            TextField("Branch name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .onSubmit(submit)

            if request.kind == .create {
                Toggle("Checkout branch after creation", isOn: $checkout)
                    .toggleStyle(.checkbox)
                    .lithePointer()
                    .font(.system(size: 12.5))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .lithePointer()
                Button(actionTitle, action: submit)
                    .buttonStyle(.borderedProminent)
                    .lithePointer()
                    .tint(LitheTheme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(LitheTheme.raised)
        .onAppear { nameFieldFocused = true }
    }

    private var title: String {
        switch request.kind {
        case .create: "New Branch"
        case .rename: "Rename Branch"
        }
    }

    private var message: String {
        switch request.kind {
        case .create: "Create from '\(request.reference.shortName)'."
        case .rename: "Rename '\(request.reference.shortName)'."
        }
    }

    private var actionTitle: String {
        request.kind == .create ? "Create" : "Rename"
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        onSubmit(trimmedName, checkout)
        dismiss()
    }
}
