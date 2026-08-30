import AppKit
import SwiftUI
import LitheGitModule

struct GitLogView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var localExpanded = true
    @State private var remoteExpanded = true
    @State private var tagsExpanded = true
    @State private var collapsedReferenceGroups: Set<String> = []
    @State private var collapsedFileGroups: Set<String> = []
    @State private var referencePaneWidth: CGFloat = 260
    @State private var referencePaneDragStart: CGFloat = 260
    @State private var detailPaneWidth: CGFloat = 350
    @State private var detailPaneDragStart: CGFloat = 350
    @State private var filesPaneHeight: CGFloat?
    @State private var filesPaneDragStart: CGFloat = 0
    @State private var branchDialogRequest: GitBranchDialogRequest?
    @State private var pendingPushReference: GitReference?
    @State private var pendingCommitOperation: GitCommitOperationRequest?
    @State private var pendingBranchOperation: GitBranchOperationRequest?
    @State private var comparisonSourceReference: GitReference?
    @State private var showCommitDecorations = false
    @State private var selectedGitToolTab = GitToolTab.log
    @State private var gitConsoleAutoScrolls = true
    @State private var gitConsoleWrapsLines = false
    @State private var selectedGitLogAuthor: GitLogAuthorSelection?
    @State private var selectedGitLogDatePreset = GitLogDatePreset.anyTime
    @State private var gitLogPathFilter = ""
    @State private var gitLogPathDraft = ""
    @State private var showsGitLogPathPopover = false
    @State private var gitCommitFileLoadTask: Task<Void, Never>?
    @State private var graphLayout = GitGraphLayout(
        rows: [],
        laneCount: 0,
        hasMissingParents: false
    )
    @FocusState private var gitLogSearchFocused: Bool
    @FocusState private var gitLogCommitListFocused: Bool

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
        static let commitFileLoadDelay = Duration.milliseconds(120)
        static let darkConsoleText = Color(red: 0.76, green: 0.77, blue: 0.79)
        static let darkConsoleMetadata = Color(red: 0.69, green: 0.70, blue: 0.72)
    }

    private enum GitToolTab {
        case log
        case console
    }

    var body: some View {
        VStack(spacing: 0) {
            toolWindowHeader
            if selectedGitToolTab == .log {
                primaryActionBar

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
                            onDragEnded: { translation in
                                referencePaneWidth = constrained(
                                    referencePaneDragStart + translation,
                                    minimum: minimumReferencePaneWidth,
                                    maximum: maximumReferencePaneWidth
                                )
                            }
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
                            onDragEnded: { translation in
                                detailPaneWidth = constrained(
                                    detailPaneDragStart - translation,
                                    minimum: minimumDetailPaneWidth,
                                    maximum: maximumDetailPaneWidth
                                )
                            }
                        )

                        detailPane
                            .frame(width: resolvedDetailPaneWidth)
                    }
                }
            } else {
                gitConsolePane
            }
        }
        .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.sidebar)
        .task(id: model.gitCommits) {
            let commits = model.gitCommits
            let updatedLayout = await Task.detached(priority: .userInitiated) {
                GitGraphLayoutService.layout(commits: commits)
            }.value
            guard model.gitCommits == commits else { return }
            graphLayout = updatedLayout
        }
        .task(id: gitLogFilterTaskIdentity) {
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            await model.applyGitLogFilter(gitLogQuery)
        }
        .onChange(of: model.gitRepositoryRoot) { _ in
            selectedGitLogAuthor = nil
            selectedGitLogDatePreset = .anyTime
            gitLogPathFilter = ""
            gitLogPathDraft = ""
        }
        .onChange(of: model.gitConsoleEntries.last?.id) { _ in
            guard model.gitConsoleEntries.last?.succeeded == false else { return }
            selectedGitToolTab = .console
        }
        .onAppear {
            if let commit = model.selectedGitCommit {
                scheduleGitCommitFileLoad(for: commit)
            }
        }
        .onDisappear {
            gitCommitFileLoadTask?.cancel()
        }
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
        HStack(spacing: 4) {
            LitheIDEAIcon(
                resourcePath: "toolwindows/toolWindowVcs.svg",
                size: 14,
                fallbackSystemImage: "point.3.connected.trianglepath.dotted"
            )
            .foregroundStyle(LitheTheme.secondaryText)

            Text("Git")
                .font(GitVisual.title)
                .foregroundStyle(LitheTheme.primaryText)
                .padding(.trailing, 4)

            gitToolTabButton(
                .log,
                title: "Log: \(model.selectedGitReference?.shortName ?? model.currentBranch)"
            )
            gitToolTabButton(.console, title: "Console")

            Button {
                selectedGitToolTab = .log
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
                model.isGitLogVisible = false
            } label: {
                Image(systemName: "minus")
            }
            .litheIconButton()
            .help("Hide Git tool window")
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: 32)
        .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.toolHeader)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
        }
    }

    private func gitToolTabButton(_ tab: GitToolTab, title: LocalizedStringKey) -> some View {
        let isSelected = selectedGitToolTab == tab
        let showsCloseButton = isSelected && tab == .console
        return HStack(spacing: 0) {
            Button {
                selectedGitToolTab = tab
                if tab == .console {
                    Task { await model.loadGitConsoleIfNeeded() }
                }
            } label: {
                Text(title)
                    .font(GitVisual.toolbar)
                    .foregroundStyle(isSelected ? LitheTheme.primaryText : LitheTheme.secondaryText)
                    .lineLimit(1)
                    .padding(.leading, 9)
                    .padding(.trailing, showsCloseButton ? 4 : 9)
                    .frame(height: 27)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()

            if showsCloseButton {
                Button {
                    selectedGitToolTab = .log
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(width: 20, height: 27)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .lithePointer()
                .help("Close Git console")
            }
        }
        .background(isSelected ? LitheTheme.subtleSelection : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected ? LitheTheme.inputFocusBorder.opacity(0.72) : .clear, lineWidth: 1)
        }
    }

    private var gitConsolePane: some View {
        HStack(spacing: 0) {
            VStack(spacing: 3) {
                Button {
                    gitConsoleWrapsLines.toggle()
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "text.justify.leading")
                            .font(.system(size: 12, weight: .regular))
                        Image(systemName: "arrow.turn.down.left")
                            .font(.system(size: 6.5, weight: .semibold))
                            .offset(x: 2, y: 1)
                    }
                }
                .litheIconButton()
                .foregroundStyle(gitConsoleWrapsLines ? LitheTheme.accent : LitheTheme.secondaryText)
                .help(gitConsoleWrapsLines ? "Disable soft wraps" : "Use soft wraps")

                Button {
                    gitConsoleAutoScrolls.toggle()
                } label: {
                    Image(systemName: gitConsoleAutoScrolls ? "arrow.down.to.line.compact" : "arrow.down.to.line")
                }
                .litheIconButton()
                .foregroundStyle(gitConsoleAutoScrolls ? LitheTheme.accent : LitheTheme.secondaryText)
                .help(gitConsoleAutoScrolls ? "Disable automatic scrolling" : "Scroll to new Git output")

                Button(action: model.clearGitConsole) {
                    Image(systemName: "trash")
                }
                .litheIconButton()
                .foregroundStyle(LitheTheme.secondaryText)
                .disabled(model.gitConsoleEntries.isEmpty)
                .help("Clear Git console")

                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .frame(width: 28)
            .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.editor)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(width: 1)

            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(gitConsoleWrapsLines ? .vertical : [.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if model.gitConsoleEntries.isEmpty {
                                Text("Git command output will appear here.")
                                    .font(GitVisual.monoMeta)
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .frame(height: 20, alignment: .leading)
                            } else {
                                ForEach(model.gitConsoleEntries) { entry in
                                    gitConsoleEntry(entry)
                                        .id(entry.id)
                                }
                            }

                            Color.clear
                                .frame(width: 1, height: 1)
                                .id("git-console-bottom")
                        }
                        .padding(.leading, 18)
                        .padding(.trailing, 8)
                        .padding(.top, 4)
                        .padding(.bottom, 8)
                        .frame(
                            minWidth: max(0, geometry.size.width),
                            minHeight: max(0, geometry.size.height),
                            alignment: .topLeading
                        )
                    }
                    .litheScrollViewChrome()
                    .onAppear {
                        guard gitConsoleAutoScrolls else { return }
                        proxy.scrollTo("git-console-bottom", anchor: .bottom)
                    }
                    .onChange(of: model.gitConsoleEntries.last?.id) { _ in
                        guard gitConsoleAutoScrolls else { return }
                        proxy.scrollTo("git-console-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.editor)
    }

    private func gitConsoleEntry(_ entry: GitConsoleEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            gitConsoleLine(gitConsoleCommandText(entry))

            if entry.outputLines.isEmpty {
                if !entry.succeeded {
                    gitConsoleLine(
                        Text("Git exited with code \(entry.exitCode)")
                            .foregroundColor(LitheTheme.error)
                    )
                }
            } else {
                ForEach(Array(entry.outputLines.enumerated()), id: \.offset) { _, line in
                    gitConsoleLine(
                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundColor(
                                line.stream == .standardError
                                    ? LitheTheme.error
                                    : gitConsoleTextColor
                            )
                    )
                }
            }
        }
        .font(.system(size: 13, weight: .regular, design: .monospaced))
        .textSelection(.enabled)
    }

    private func gitConsoleLine(_ text: Text) -> some View {
        text
            .frame(
                maxWidth: gitConsoleWrapsLines ? .infinity : nil,
                minHeight: 20,
                alignment: .leading
            )
            .fixedSize(horizontal: !gitConsoleWrapsLines, vertical: true)
    }

    private func gitConsoleCommandText(_ entry: GitConsoleEntry) -> Text {
        let location = Text("\(gitConsoleTimestamp(entry.timestamp)): [\(entry.workingDirectory.path)]")
            .foregroundColor(gitConsoleMetadataColor)
        let executable = Text(" git")
            .foregroundColor(gitConsoleTextColor)
        guard !entry.formattedArguments.isEmpty else { return location + executable }
        let arguments = Text(" \(entry.formattedArguments)")
            .foregroundColor(gitConsoleArgumentColor)
        return location + executable + arguments
    }

    private var gitConsoleTextColor: Color {
        colorScheme == .dark ? GitVisual.darkConsoleText : LitheTheme.primaryText
    }

    private var gitConsoleMetadataColor: Color {
        colorScheme == .dark ? GitVisual.darkConsoleMetadata : LitheTheme.link
    }

    private var gitConsoleArgumentColor: Color {
        colorScheme == .dark ? GitVisual.darkConsoleText : LitheTheme.link
    }

    private func gitConsoleTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private var primaryActionBar: some View {
        HStack(spacing: 7) {
            Button {
                Task { await model.fetchGit() }
            } label: {
                Label("Fetch", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .lithePointer()
            .disabled(model.isPerformingBranchOperation)

            Button {
                showPrimaryComparison()
            } label: {
                Label("Compare", systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .lithePointer()
            .disabled(currentReference == nil || model.isLoadingBranchComparison)

            Divider()
                .frame(height: 18)

            Button {
                guard let reference = checkoutReference else { return }
                Task { await model.checkoutReference(reference) }
            } label: {
                Label("Checkout", systemImage: "arrow.right.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .lithePointer()
            .disabled(checkoutReference == nil || model.isPerformingBranchOperation)

            Button {
                guard let commit = model.selectedGitCommit else { return }
                pendingCommitOperation = GitCommitOperationRequest(kind: .cherryPick, commit: commit)
            } label: {
                Label("Cherry-pick", systemImage: "arrow.triangle.branch")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .lithePointer()
            .disabled(model.selectedGitCommit == nil || model.isPerformingBranchOperation)

            Spacer(minLength: 8)

            Text(primaryComparisonDescription)
                .font(GitVisual.meta)
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: GitVisual.toolbarHeight)
        .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.toolHeader)
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
                .help("Back to all references")

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
        .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.sidebar)
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

            if let source = comparisonSourceReference, source.id != reference.id {
                Button("Compare '\(source.shortName)' with '\(reference.shortName)'") {
                    comparisonSourceReference = nil
                    Task { await model.showComparison(from: source, to: reference) }
                }
            } else {
                Button("Select for Compare") {
                    comparisonSourceReference = reference
                }
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
                    TextField("Text, me, author:, branch:, path:", text: $model.gitLogSearchQuery)
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

                gitLogFilterBar

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
                    gitToolbarButton(
                        systemImage: showCommitDecorations ? "eye" : "eye.slash",
                        help: showCommitDecorations ? "Hide commit decorations" : "Show commit decorations"
                    ) {
                        showCommitDecorations.toggle()
                    }
                    gitToolbarButton(systemImage: "magnifyingglass", help: "Find in log") {
                        gitLogSearchFocused = true
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: GitVisual.toolbarHeight)
            .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.toolHeader)

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
                                actions: graphRowActions
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
                    .focusable()
                    .focused($gitLogCommitListFocused)
                    .gitLogFocusEffectHidden()
                    .onMoveCommand { direction in
                        switch direction {
                        case .up:
                            moveGitLogCommitSelection(by: -1)
                        case .down:
                            moveGitLogCommitSelection(by: 1)
                        default:
                            break
                        }
                    }
                    .onChange(of: model.selectedGitCommit?.hash) { _ in
                        guard let hash = model.selectedGitCommit?.hash else { return }
                        proxy.scrollTo(hash)
                    }
                }
            }
        }
        .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.editor)
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
                    onDragEnded: { translation in
                        filesPaneHeight = constrained(
                            filesPaneDragStart + translation,
                            minimum: minimumFilesPaneHeight,
                            maximum: maximumFilesPaneHeight
                        )
                    }
                )

                commitDetail
                    .frame(maxHeight: .infinity)
            }
        }
        .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.sidebar)
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
            .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.toolHeader)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            switch model.selectedGitCommitFilesLoadState {
            case .idle:
                Text("Select a commit")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading:
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading changed files…")
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                VStack(spacing: 8) {
                    Text("Could not load changed files")
                    if let commit = model.selectedGitCommit {
                        Button("Retry") {
                            scheduleGitCommitFileLoad(for: commit)
                        }
                    }
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready where model.selectedGitCommitFiles.isEmpty:
                Text("No changed files")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .textSelection(.enabled)
            } else {
                Text("Commit details")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.editor)
    }

    private var filteredCommits: [GitCommit] {
        guard let hashes = visibleCommitHashes else { return model.gitCommits }
        return model.gitCommits.filter { hashes.contains($0.hash) }
    }

    private func moveGitLogCommitSelection(by offset: Int) {
        guard let commit = GitLogCommitSelection.adjacentCommit(
            in: filteredCommits,
            selectedHash: model.selectedGitCommit?.hash,
            offset: offset
        ) else { return }
        model.previewGitCommitSelection(commit)
        scheduleGitCommitFileLoad(for: commit)
    }

    private func scheduleGitCommitFileLoad(for commit: GitCommit) {
        gitCommitFileLoadTask?.cancel()
        gitCommitFileLoadTask = Task { [model] in
            do {
                try await Task.sleep(for: GitVisual.commitFileLoadDelay)
            } catch {
                return
            }
            await model.loadGitCommitFiles(for: commit)
        }
    }

    private var checkoutReference: GitReference? {
        guard let reference = model.selectedGitReference,
              reference.kind == .local,
              !reference.isCurrent else { return nil }
        return reference
    }

    private var primaryComparisonDescription: String {
        guard let currentReference else { return "No current branch" }
        if let target = model.selectedGitReference, target.id != currentReference.id {
            return "\(currentReference.shortName) → \(target.shortName)"
        }
        return "\(currentReference.shortName) ↔ Working Tree"
    }

    private func showPrimaryComparison() {
        guard let currentReference else { return }
        if let target = model.selectedGitReference, target.id != currentReference.id {
            Task { await model.showComparison(from: currentReference, to: target) }
        } else {
            Task { await model.showComparisonWithWorkingTree(for: currentReference) }
        }
    }

    /// Rows compare themselves by data and ignore these callbacks, so building
    /// the group once per pane redraw never invalidates a row.
    private var graphRowActions: GitGraphRowActions {
        let pendingOperation = $pendingCommitOperation
        return GitGraphRowActions(
            onSelect: { [model] commit in
                gitLogCommitListFocused = true
                model.previewGitCommitSelection(commit)
                scheduleGitCommitFileLoad(for: commit)
            },
            onCherryPick: { commit in
                pendingOperation.wrappedValue = GitCommitOperationRequest(kind: .cherryPick, commit: commit)
            },
            onRevert: { commit in
                pendingOperation.wrappedValue = GitCommitOperationRequest(kind: .revert, commit: commit)
            },
            onReset: { commit in
                pendingOperation.wrappedValue = GitCommitOperationRequest(kind: .reset, commit: commit)
            }
        )
    }

    private var visibleCommitHashes: Set<String>? {
        guard !gitLogQuery.isEmpty else { return nil }
        return model.gitLogMatchedCommitHashes
    }

    private var gitLogFilterTaskIdentity: GitLogFilterTaskIdentity {
        GitLogFilterTaskIdentity(
            searchQuery: model.gitLogSearchQuery,
            author: selectedGitLogAuthor,
            datePreset: selectedGitLogDatePreset,
            path: gitLogPathFilter,
            commitHashes: model.gitCommits.map(\.hash)
        )
    }

    private var gitLogQuery: GitLogQuery {
        let path = gitLogPathFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = GitLogQuery.parse(model.gitLogSearchQuery).addingStructuredFilters(
            currentUserOnly: selectedGitLogAuthor == .currentUser,
            exactAuthor: selectedGitLogAuthor?.exactAuthor,
            paths: path.isEmpty ? [] : [path]
        )
        return selectedGitLogDatePreset.applying(to: query, now: Date())
    }

    private var gitLogAuthorOptions: [GitLogAuthorOption] {
        var authorsByID: [String: GitLogAuthorOption] = [:]
        for commit in model.gitCommits {
            let id = "\(commit.authorName.lowercased())|\(commit.authorEmail.lowercased())"
            authorsByID[id] = GitLogAuthorOption(
                id: id,
                name: commit.authorName,
                email: commit.authorEmail
            )
        }
        return authorsByID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var gitLogFilterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Menu {
                    Button {
                        Task { await model.selectGitReference(nil) }
                    } label: {
                        gitLogMenuItem("All Branches", selected: model.selectedGitReference == nil)
                    }
                    Divider()
                    ForEach(model.gitReferences) { reference in
                        Button {
                            Task { await model.selectGitReference(reference) }
                        } label: {
                            gitLogMenuItem(
                                reference.shortName,
                                selected: model.selectedGitReference?.id == reference.id,
                                systemImage: referenceIcon(reference)
                            )
                        }
                    }
                } label: {
                    gitLogFilterLabel(
                        title: "Branch",
                        selection: model.selectedGitReference?.shortName
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .lithePointer()

                if model.selectedGitReference != nil {
                    gitLogFilterClearButton(help: "Clear branch filter") {
                        Task { await model.selectGitReference(nil) }
                    }
                }
            }

            HStack(spacing: 2) {
                Menu {
                    Button {
                        selectedGitLogAuthor = nil
                    } label: {
                        gitLogMenuItem("All Users", selected: selectedGitLogAuthor == nil)
                    }
                    Button {
                        selectedGitLogAuthor = .currentUser
                    } label: {
                        gitLogMenuItem("Me", selected: selectedGitLogAuthor == .currentUser)
                    }
                    if !gitLogAuthorOptions.isEmpty { Divider() }
                    ForEach(gitLogAuthorOptions) { author in
                        Button {
                            selectedGitLogAuthor = .author(name: author.name, email: author.email)
                        } label: {
                            gitLogMenuItem(
                                author.name,
                                selected: selectedGitLogAuthor == .author(name: author.name, email: author.email)
                            )
                        }
                    }
                } label: {
                    gitLogFilterLabel(title: "User", selection: selectedGitLogAuthor?.displayName)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .lithePointer()

                if selectedGitLogAuthor != nil {
                    gitLogFilterClearButton(help: "Clear user filter") {
                        selectedGitLogAuthor = nil
                    }
                }
            }

            HStack(spacing: 2) {
                Menu {
                    ForEach(GitLogDatePreset.allCases) { preset in
                        Button {
                            selectedGitLogDatePreset = preset
                        } label: {
                            gitLogMenuItem(
                                preset.menuTitle,
                                selected: selectedGitLogDatePreset == preset
                            )
                        }
                    }
                } label: {
                    gitLogFilterLabel(title: "Date", selection: selectedGitLogDatePreset.filterTitle)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .lithePointer()

                if selectedGitLogDatePreset != .anyTime {
                    gitLogFilterClearButton(help: "Clear date filter") {
                        selectedGitLogDatePreset = .anyTime
                    }
                }
            }

            HStack(spacing: 2) {
                Button {
                    gitLogPathDraft = gitLogPathFilter
                    showsGitLogPathPopover = true
                } label: {
                    gitLogFilterLabel(
                        title: "Path",
                        selection: gitLogPathFilter.isEmpty ? nil : gitLogPathFilter
                    )
                }
                .buttonStyle(.plain)
                .lithePointer()
                .popover(isPresented: $showsGitLogPathPopover, arrowEdge: .bottom) {
                    gitLogPathPopover
                }

                if !gitLogPathFilter.isEmpty {
                    gitLogFilterClearButton(help: "Clear path filter") {
                        gitLogPathFilter = ""
                        gitLogPathDraft = ""
                    }
                }
            }
        }
        .lineLimit(1)
    }

    private var gitLogPathPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filter by changed path")
                .font(GitVisual.bodyMedium)
                .foregroundStyle(LitheTheme.primaryText)
            TextField("Directory or file name", text: $gitLogPathDraft)
                .textFieldStyle(.roundedBorder)
                .font(GitVisual.body)
                .onSubmit { applyGitLogPathFilter() }
            HStack(spacing: 8) {
                Button("Clear") {
                    gitLogPathDraft = ""
                    gitLogPathFilter = ""
                    showsGitLogPathPopover = false
                }
                Spacer()
                Button("Cancel") {
                    showsGitLogPathPopover = false
                }
                Button("Apply") {
                    applyGitLogPathFilter()
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300)
    }

    private func gitLogFilterLabel(title: String, selection: String?) -> some View {
        HStack(spacing: 3) {
            Text(selection.map { "\(title): \($0)" } ?? title)
                .font(GitVisual.toolbar)
                .foregroundStyle(LitheTheme.secondaryText)
            if selection == nil {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.tertiaryText)
            }
        }
        .frame(height: 22)
        .contentShape(Rectangle())
    }

    private func gitLogFilterClearButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(LitheTheme.tertiaryText)
                .frame(width: 14, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
        .help(LocalizedStringKey(help))
    }

    private func gitLogMenuItem(
        _ title: String,
        selected: Bool,
        systemImage: String? = nil
    ) -> some View {
        HStack {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
            Spacer()
            if selected { Image(systemName: "checkmark") }
        }
    }

    private func applyGitLogPathFilter() {
        gitLogPathFilter = gitLogPathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        gitLogPathDraft = gitLogPathFilter
        showsGitLogPathPopover = false
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
            .help(LocalizedStringKey(help))
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
        .help(LocalizedStringKey(help))
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
                LitheIcon(kind: LitheIcons.kind(forFilePath: file.path), size: 14)
                    .frame(width: 14, height: 14)
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

private enum GitLogAuthorSelection: Hashable {
    case currentUser
    case author(name: String, email: String)

    var displayName: String {
        switch self {
        case .currentUser:
            return "Me"
        case .author(let name, _):
            return name
        }
    }

    var exactAuthor: GitIdentity? {
        switch self {
        case .currentUser:
            return nil
        case .author(let name, let email):
            return GitIdentity(name: name, email: email)
        }
    }
}

enum GitLogCommitSelection {
    static func adjacentCommit(
        in commits: [GitCommit],
        selectedHash: String?,
        offset: Int
    ) -> GitCommit? {
        guard !commits.isEmpty, offset == -1 || offset == 1 else { return nil }
        guard let selectedHash,
              let selectedIndex = commits.firstIndex(where: { $0.hash == selectedHash }) else {
            return offset < 0 ? commits.last : commits.first
        }
        let targetIndex = selectedIndex + offset
        guard commits.indices.contains(targetIndex) else { return nil }
        return commits[targetIndex]
    }
}

private extension View {
    @ViewBuilder
    func gitLogFocusEffectHidden() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}

private struct GitLogFilterTaskIdentity: Hashable {
    let searchQuery: String
    let author: GitLogAuthorSelection?
    let datePreset: GitLogDatePreset
    let path: String
    let commitHashes: [String]
}

private struct GitLogAuthorOption: Identifiable {
    let id: String
    let name: String
    let email: String
}

enum GitLogDatePreset: String, CaseIterable, Identifiable, Hashable {
    case anyTime
    case today
    case yesterday
    case lastSevenDays
    case lastThirtyDays

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .anyTime: return "Any Time"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .lastSevenDays: return "Last 7 Days"
        case .lastThirtyDays: return "Last 30 Days"
        }
    }

    var filterTitle: String? {
        self == .anyTime ? nil : menuTitle
    }

    func applying(to query: GitLogQuery, now: Date) -> GitLogQuery {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        switch self {
        case .anyTime:
            return query
        case .today:
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return query }
            return query.addingStructuredFilters(afterDate: today, beforeDate: tomorrow)
        case .yesterday:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return query }
            return query.addingStructuredFilters(afterDate: yesterday, beforeDate: today)
        case .lastSevenDays:
            guard let firstDay = calendar.date(byAdding: .day, value: -6, to: today),
                  let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return query }
            return query.addingStructuredFilters(afterDate: firstDay, beforeDate: tomorrow)
        case .lastThirtyDays:
            guard let firstDay = calendar.date(byAdding: .day, value: -29, to: today),
                  let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return query }
            return query.addingStructuredFilters(afterDate: firstDay, beforeDate: tomorrow)
        }
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

/// Offered when local changes would be overwritten by a checkout, so the user can pick a
/// resolution instead of being handed Git's raw refusal.
/// Offers to stash when uncommitted changes block a merge or rebase.
///
/// Stash-and-retry is the only action besides cancelling. A force equivalent would
/// mean `git reset --hard`, which discards commits rather than just working-tree
/// edits, so it is deliberately absent.
private struct GitConflictPathRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let path: String
    let onRollback: (String) -> Void

    private var change: GitChange? {
        model.gitChanges.first(where: { $0.path == path })
    }

    var body: some View {
        HStack(spacing: 7) {
            if change != nil {
                Button {
                    dismiss()
                    model.showGitConflictDiff(path: path)
                } label: {
                    Text(path)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.primaryText)
                        .underline()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .lithePointer()
                .help("Show Diff")

                Button {
                    dismiss()
                    onRollback(path)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(LitheTheme.warning)
                .lithePointer()
                .help("Discard this file and retry")
            } else {
                Text(path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }
}

struct GitIntegrationConflictDialog: View {
    @Environment(\.dismiss) private var dismiss
    let request: GitIntegrationConflictRequest
    let savePolicy: GitSaveChangesPolicy
    let onStash: () -> Void
    let onRollback: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(headline)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Text(explanation)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(request.blockingPaths, id: \.self) { path in
                        GitConflictPathRow(path: path, onRollback: onRollback)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 132)

            Text(LocalizedStringKey(savePolicy == .shelve
                ? "Shelving saves these changes in Lithe, runs the operation, then restores them. If conflicts stop the operation, the shelf stays saved until you finish it."
                : "Stashing sets these changes aside, runs the operation, then restores them. If conflicts stop the operation, the changes stay stashed until you finish it."))
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .lithePointer()
                Button(LocalizedStringKey(savePolicy == .shelve ? "Shelve and Continue" : "Stash and Continue")) {
                    onStash()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .lithePointer()
                .tint(LitheTheme.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(LitheTheme.raised)
    }

    private var headline: LocalizedStringKey {
        switch request.operation {
        case .merge: "Uncommitted changes block this merge"
        case .rebase: "Uncommitted changes block this rebase"
        case .cherryPick: "Uncommitted changes block this cherry-pick"
        case .revert: "Uncommitted changes block this revert"
        }
    }

    private var explanation: String {
        // A rebase refuses over any uncommitted change; the others only over the
        // files they would write. Saying which keeps the list from looking arbitrary.
        if request.blocksEntirely {
            return String(
                format: NSLocalizedString(
                    "A rebase cannot start with any uncommitted changes, including these unrelated to '%@':",
                    comment: "Rebase preflight explanation"
                ),
                request.target.displayName
            )
        }
        return String(
            format: NSLocalizedString(
                "Your changes to these files would be overwritten by '%@':",
                comment: "Merge preflight explanation"
            ),
            request.target.displayName
        )
    }
}

/// Asks how to reconcile a pull that cannot fast-forward.
///
/// No force option here: unlike a checkout, where forcing discards uncommitted
/// edits, forcing a divergent pull means discarding commits. Merge and rebase both
/// keep the local work, so there is no safe third choice to offer.
struct GitPullStrategyDialog: View {
    @Environment(\.dismiss) private var dismiss
    let request: GitPullStrategyRequest
    let onResolve: (GitPullStrategy) -> Void

    @State private var selectedStrategy: GitPullStrategy = .merge
    @State private var doNotShowAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Update Project")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
                .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 16) {
                strategyRow(
                    .merge,
                    title: "Integrate incoming changes into current branch (M)"
                )
                strategyRow(
                    .rebase,
                    title: "Rebase current branch onto incoming changes (R)"
                )
            }

            Spacer(minLength: 22)

            HStack(spacing: 10) {
                Button {
                    // Keep the same lightweight help affordance as IDEA's dialog.
                } label: {
                    Image(systemName: "questionmark")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .lithePointer()
                .help("Choose how incoming changes are applied")

                Toggle("Don't show", isOn: $doNotShowAgain)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5))
                    .lithePointer()

                Spacer(minLength: 16)

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .lithePointer()

                Button("OK") {
                    onResolve(selectedStrategy)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(LitheTheme.accent)
                .keyboardShortcut(.defaultAction)
                .lithePointer()
            }
        }
        .padding(20)
        .frame(width: 560, height: 248)
        .background(LitheTheme.raised)
    }

    private func strategyRow(_ strategy: GitPullStrategy, title: LocalizedStringKey) -> some View {
        Button {
            selectedStrategy = strategy
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedStrategy == strategy ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selectedStrategy == strategy ? LitheTheme.accent : LitheTheme.secondaryText)
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
    }
}

/// A compact IDEA-style push review. The branch row is deliberately separate
/// from the action so the user can verify the destination before pushing.
struct GitPushDialog: View {
    @Environment(\.dismiss) private var dismiss
    let projectName: String
    let reference: GitReference
    let onPush: () -> Void

    @State private var pushTags = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Push to \(projectName)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(LitheTheme.primaryText)
                        Text(reference.shortName)
                            .font(.system(size: 13))
                            .foregroundStyle(LitheTheme.primaryText)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LitheTheme.secondaryText)
                        Text(reference.upstreamShortName ?? "No configured remote")
                            .font(.system(size: 13))
                            .foregroundStyle(reference.upstreamShortName == nil ? LitheTheme.secondaryText : LitheTheme.accent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 38)
                    .background(LitheTheme.selection.opacity(0.72))

                    Spacer(minLength: 0)
                }
                .frame(width: 360)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(LitheTheme.sidebar)

                Rectangle()
                    .fill(LitheTheme.divider)
                    .frame(width: 1)

                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.left.arrow.right")
                        Image(systemName: "eye")
                        Image(systemName: "pencil")
                        Rectangle()
                            .fill(LitheTheme.divider)
                            .frame(width: 1, height: 20)
                        Image(systemName: "doc.text")
                        Spacer()
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .padding(.horizontal, 18)
                    .frame(height: 48)

                    Rectangle()
                        .fill(LitheTheme.divider)
                        .frame(height: 1)

                    Spacer(minLength: 0)
                    Text("No commit selected")
                        .font(.system(size: 13))
                        .foregroundStyle(LitheTheme.secondaryText)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            HStack(spacing: 12) {
                Button {
                    // Reserved for the same contextual help affordance as IDEA.
                } label: {
                    Image(systemName: "questionmark")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .lithePointer()
                .help("Review the branch that will be pushed")

                Toggle("Push tags", isOn: $pushTags)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5))
                    .lithePointer()

                Spacer(minLength: 16)

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .lithePointer()

                Button("Push") {
                    onPush()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(LitheTheme.accent)
                .keyboardShortcut(.defaultAction)
                .lithePointer()
                .disabled(reference.upstreamShortName == nil)
            }
            .padding(16)
        }
        .frame(width: 720, height: 430)
        .background(LitheTheme.raised)
    }
}

struct GitCheckoutConflictDialog: View {
    @Environment(\.dismiss) private var dismiss
    let request: GitCheckoutConflictRequest
    let savePolicy: GitSaveChangesPolicy
    let onResolve: (GitCheckoutConflictStrategy) -> Void
    let onRollback: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Local changes would be overwritten")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Text("Your changes to these files conflict with '\(request.reference.shortName)':")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(request.blockingPaths, id: \.self) { path in
                        GitConflictPathRow(path: path, onRollback: onRollback)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 132)

            Text(LocalizedStringKey(savePolicy == .shelve
                ? "Smart Checkout shelves your changes in Lithe, switches branch, then restores them. Force Checkout switches and discards them."
                : "Smart Checkout stashes your changes, switches branch, then restores them. Force Checkout switches and discards them."))
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Force Checkout", role: .destructive) { resolve(.force) }
                    .lithePointer()
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .lithePointer()
                Button(LocalizedStringKey(savePolicy == .shelve ? "Smart Checkout (Shelve)" : "Smart Checkout")) { resolve(.smart) }
                    .buttonStyle(.borderedProminent)
                    .lithePointer()
                    .tint(LitheTheme.accent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(LitheTheme.raised)
    }

    private func resolve(_ strategy: GitCheckoutConflictStrategy) {
        onResolve(strategy)
        dismiss()
    }
}
