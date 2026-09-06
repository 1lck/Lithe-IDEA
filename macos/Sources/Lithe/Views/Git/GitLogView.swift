import AppKit
import SwiftUI
import LitheGitModule

struct GitLogNavigation {
    let compareWithWorkingTree: (GitReference) async -> Void
    let compareReferences: (GitReference, GitReference) async -> Void
    let openCommitDiff: (GitCommitFile) -> Void
}

struct GitLogView: View {
    @ObservedObject var feature: GitFeatureModel
    @ObservedObject var workbench: WorkbenchFeatureModel
    @ObservedObject var background: WorkbenchBackgroundFeatureModel
    let projectName: String
    let navigation: GitLogNavigation
    let worktreeActions: GitWorktreeActions
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var localExpanded = true
    @State private var remoteExpanded = true
    @State private var tagsExpanded = true
    @State private var collapsedReferenceGroups: Set<String> = []
    @State private var collapsedFileGroups: Set<String> = []
    @State private var localReferenceRows: [GitReferenceRow] = []
    @State private var remoteReferenceRows: [GitReferenceRow] = []
    @State private var tagReferenceRows: [GitReferenceRow] = []
    @State private var currentReferenceCache = GitCurrentReferenceCache()
    @State private var branchDialogRequest: GitBranchDialogRequest?
    @State private var tagDialogRequest: GitTagDialogRequest?
    @State private var pendingPushReference: GitReference?
    @State private var pendingCommitOperation: GitCommitOperationRequest?
    @State private var pendingBranchOperation: GitBranchOperationRequest?
    @State private var pendingTagDeletion: GitReference?
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
    @State private var showsGitLogBranchFilterPopover = false
    @State private var showsGitLogAuthorFilterPopover = false
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
        case worktrees
        case console
    }

    var body: some View {
        let _ = LitheSignpost.bodyEvaluated("GitLogView")
        VStack(spacing: 0) {
            toolWindowHeader
            primaryContent
        }
        .background(background.hasImage ? Color.clear : LitheTheme.sidebar)
        .task(id: feature.gitCommitsVersion) {
            let commits = feature.gitCommits
            let updatedLayout = await Task.detached(priority: .userInitiated) {
                GitGraphLayoutService.layout(commits: commits)
            }.value
            guard feature.gitCommits == commits else { return }
            graphLayout = updatedLayout
        }
        // The three section arrays are derived, not user state. Rebuilding them
        // here rather than in `body` keeps the flattening off the render path
        // while still reacting to both inputs it depends on.
        .task(id: referenceRowsTaskIdentity) {
            rebuildReferenceRows()
        }
        .task(id: gitLogFilterTaskIdentity) {
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            // `Date()` is captured here — once, at the moment the debounced
            // task fires — so date-range boundaries are stable for this query.
            await feature.applyGitLogFilter(gitLogQuery(now: Date()))
        }
        .onChange(of: feature.gitRepositoryRoot) { _ in
            selectedGitLogAuthor = nil
            selectedGitLogDatePreset = .anyTime
            gitLogPathFilter = ""
            gitLogPathDraft = ""
        }
        .onChange(of: feature.gitConsoleEntries.last?.id) { _ in
            guard feature.gitConsoleEntries.last?.succeeded == false else { return }
            selectedGitToolTab = .console
        }
        .onAppear {
            if let commit = feature.selectedGitCommit {
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
                        await feature.createBranch(
                            named: name,
                            from: request.reference,
                            checkout: checkout
                        )
                    case .rename:
                        await feature.renameBranch(request.reference, to: name)
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
                Task { await feature.pushBranch(reference) }
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
                            await feature.cherryPick(operation.commit)
                        case .revert:
                            await feature.revert(operation.commit)
                        case .reset:
                            await feature.resetCurrentBranch(to: operation.commit)
                        }
                    }
                }
                .disabled(feature.isPerformingBranchOperation)
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
                            await feature.deleteBranch(operation.reference)
                        case .merge:
                            await feature.mergeBranch(operation.reference)
                        case .rebase:
                            await feature.rebaseCurrentBranch(onto: operation.reference)
                        case .checkoutAndRebase:
                            await feature.checkoutAndRebase(operation.reference)
                        case .pullRebase:
                            await feature.pullRemoteReference(operation.reference, strategy: .rebase)
                        case .pullMerge:
                            await feature.pullRemoteReference(operation.reference, strategy: .merge)
                        }
                    }
                }
                .disabled(feature.isPerformingBranchOperation)
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
        .modifier(GitTagDialogsModifier(
            feature: feature,
            tagDialogRequest: $tagDialogRequest,
            pendingTagDeletion: $pendingTagDeletion
        ))
    }

    /// The tab split lives outside `body` because the main expression is
    /// already close to the type-checker limit.
    @ViewBuilder
    private var primaryContent: some View {
        switch selectedGitToolTab {
        case .log:
            logTabContent
        case .worktrees:
            GitWorktreesView(feature: feature, background: background, actions: worktreeActions)
        case .console:
            gitConsolePane
        }
    }

    private var logTabContent: some View {
        Group {
            primaryActionBar
            if let deletedBranch = feature.recentlyDeletedBranch {
                deletedReferenceBanner(
                    icon: "arrow.triangle.branch",
                    message: "Deleted branch '\(deletedBranch.name)'",
                    onRestore: { await feature.restoreRecentlyDeletedBranch() },
                    onDismiss: { feature.dismissDeletedBranchBanner() }
                )
            }
            if let deletedTag = feature.recentlyDeletedTag {
                deletedReferenceBanner(
                    icon: "tag",
                    message: "Deleted tag '\(deletedTag.name)'",
                    onRestore: { await feature.restoreRecentlyDeletedTag() },
                    onDismiss: { feature.dismissDeletedTagBanner() }
                )
            }
            logPanes
        }
    }

    private var logPanes: some View {
        GeometryReader { geometry in
            GitLogThreePaneLayout(
                availableWidth: geometry.size.width,
                referencePane: { referencePane },
                commitPane: { commitPane },
                detailPane: { detailPane }
            )
        }
    }

    /// The New Tag sheet and its delete confirmation live in a modifier
    /// because the main `body` expression is already close to the type-checker
    /// limit; an explicit `ViewModifier` keeps both type-checkable.
    private struct GitTagDialogsModifier: ViewModifier {
        @ObservedObject var feature: GitFeatureModel
        @Binding var tagDialogRequest: GitTagDialogRequest?
        @Binding var pendingTagDeletion: GitReference?

        func body(content: Content) -> some View {
            content
                .sheet(item: $tagDialogRequest) { request in
                    GitTagNameDialog(request: request) { name, message in
                        // Returning the failure keeps the dialog open so the
                        // error appears where the user typed, like IntelliJ's
                        // New Tag dialog.
                        await feature.createTag(at: request.commit, name: name, message: message)
                    }
                }
                .confirmationDialog(
                    "Delete tag '\(pendingTagDeletion?.shortName ?? "")'?",
                    isPresented: Binding(
                        get: { pendingTagDeletion != nil },
                        set: { if !$0 { pendingTagDeletion = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        guard let reference = pendingTagDeletion else { return }
                        pendingTagDeletion = nil
                        Task { await feature.deleteTag(reference) }
                    }
                    .disabled(feature.isPerformingBranchOperation)
                    .lithePointer()
                    Button("Cancel", role: .cancel) {
                        pendingTagDeletion = nil
                    }
                    .lithePointer()
                } message: {
                    Text("This removes the tag from the repository and affects collaborators who reference it. You can restore it from the banner afterwards.")
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
                title: "Log: \(feature.isShowingAllGitReferences ? "All References" : (feature.selectedGitReference?.shortName ?? feature.currentBranch))"
            )
            gitToolTabButton(
                .worktrees,
                title: "Worktrees",
                detail: feature.gitRepositoryRoot?.path
            )
            gitToolTabButton(.console, title: "Console")

            if selectedGitToolTab == .log, !feature.isShowingAllGitReferences {
                Button {
                    selectedGitToolTab = .log
                    Task { await feature.showAllGitReferences() }
                } label: {
                    Image(systemName: "plus")
                }
                .litheIconButton()
                .help("Show all references")
            }

            Menu {
                Button("Fetch All Remotes") {
                    Task { await feature.fetchGit() }
                }
                Button("Update Current Branch") {
                    guard let currentReference else { return }
                    Task { await feature.updateCurrentBranch(currentReference) }
                }
                .disabled(currentReference == nil)
                Button("Refresh Log") {
                    Task { await feature.refreshGitHistory() }
                }
                Divider()
                Button("Show Changes") {
                    workbench.selectedSidebar = .changes
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
                workbench.setVisibility(.gitLog, isVisible: false)
            } label: {
                Image(systemName: "minus")
            }
            .litheIconButton()
            .help("Hide Git tool window")
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: 32)
        .background(background.hasImage ? Color.clear : LitheTheme.toolHeader)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
        }
    }

    private func gitToolTabButton(
        _ tab: GitToolTab,
        title: LocalizedStringKey,
        detail: String? = nil
    ) -> some View {
        let isSelected = selectedGitToolTab == tab
        let showsCloseButton = isSelected && tab == .console
        return HStack(spacing: 0) {
            Button {
                selectedGitToolTab = tab
                if tab == .console {
                    Task { await feature.loadGitConsoleIfNeeded() }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(title)
                    if let detail, !detail.isEmpty {
                        Text("·")
                            .foregroundStyle(LitheTheme.tertiaryText)
                        Text(detail)
                            .foregroundStyle(LitheTheme.secondaryText)
                            .truncationMode(.middle)
                    }
                }
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

                Button(action: feature.clearGitConsole) {
                    Image(systemName: "trash")
                }
                .litheIconButton()
                .foregroundStyle(LitheTheme.secondaryText)
                .disabled(feature.gitConsoleEntries.isEmpty)
                .help("Clear Git console")

                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .frame(width: 28)
            .background(background.hasImage ? Color.clear : LitheTheme.editor)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(width: 1)

            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(gitConsoleWrapsLines ? .vertical : [.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if feature.gitConsoleEntries.isEmpty {
                                Text("Git command output will appear here.")
                                    .font(GitVisual.monoMeta)
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .frame(height: 20, alignment: .leading)
                            } else {
                                ForEach(feature.gitConsoleEntries) { entry in
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
                    .onChange(of: feature.gitConsoleEntries.last?.id) { _ in
                        guard gitConsoleAutoScrolls else { return }
                        proxy.scrollTo("git-console-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .background(background.hasImage ? Color.clear : LitheTheme.editor)
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
        Self.gitConsoleTimestampFormatter.string(from: date)
    }

    // A DateFormatter is expensive to construct, so build it once instead of on
    // every console row of every body pass.
    private static let gitConsoleTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private var primaryActionBar: some View {
        HStack(spacing: 7) {
            Button {
                Task { await feature.fetchGit() }
            } label: {
                Label("Fetch", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .lithePointer()
            .disabled(feature.isPerformingBranchOperation)

            Button {
                showPrimaryComparison()
            } label: {
                Label("Compare", systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .lithePointer()
                .disabled(currentReference == nil || feature.isLoadingBranchComparison)

            Divider()
                .frame(height: 18)

            Button {
                guard let reference = checkoutReference else { return }
                Task { await feature.checkoutReference(reference) }
            } label: {
                Label("Checkout", systemImage: "arrow.right.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .lithePointer()
            .disabled(checkoutReference == nil || feature.isPerformingBranchOperation)

            Button {
                guard let commit = feature.selectedGitCommit else { return }
                pendingCommitOperation = GitCommitOperationRequest(kind: .cherryPick, commit: commit)
            } label: {
                Label("Cherry-pick", systemImage: "arrow.triangle.branch")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .lithePointer()
                .disabled(feature.selectedGitCommit == nil || feature.isPerformingBranchOperation)

            Spacer(minLength: 8)

            Text(primaryComparisonDescription)
                .font(GitVisual.meta)
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: GitVisual.toolbarHeight)
        .background(background.hasImage ? Color.clear : LitheTheme.toolHeader)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
        }
    }

    /// IntelliJ-style "deleted ref [Restore]" notice. The restore record lives
    /// in session state, so closing the banner ends the restore opportunity.
    private func deletedReferenceBanner(
        icon: String,
        message: String,
        onRestore: @escaping () async -> Void,
        onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 7) {
            LitheSystemIcon(systemImage: icon, size: 13)
                .foregroundStyle(LitheTheme.warning)
            Text(message)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Restore") {
                Task { await onRestore() }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(LitheTheme.accent)
            .disabled(feature.isPerformingBranchOperation)
            .lithePointer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .litheIconButton()
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(LitheTheme.raised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
        }
    }

    private var referencePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    Task { await feature.showAllGitReferences() }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .litheIconButton()
                .help("Back to all references")

                Button {
                    feature.gitLogSearchQuery = ""
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
        .background(background.hasImage ? Color.clear : LitheTheme.sidebar)
    }

    private func referenceSection(
        title: String,
        icon: String,
        kind: GitReferenceKind,
        expanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
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
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(referenceRows(for: kind)) { row in
                        GitReferenceRowView(
                            row: row,
                            isSelected: isReferenceRowSelected(row),
                            isPerformingBranchOperation: feature.isPerformingBranchOperation,
                            currentReferenceID: currentReference?.id,
                            comparisonSourceID: comparisonSourceReference?.id,
                            actions: referenceRowActions
                        )
                        .equatable()
                        .id(row.id)
                    }
                }
            }
        }
    }

    private func referenceRows(for kind: GitReferenceKind) -> [GitReferenceRow] {
        switch kind {
        case .local: localReferenceRows
        case .remote: remoteReferenceRows
        case .tag: tagReferenceRows
        }
    }

    private func isReferenceRowSelected(_ row: GitReferenceRow) -> Bool {
        guard case .reference(let reference) = row.content else { return false }
        return !feature.isShowingAllGitReferences && (
            feature.selectedGitReference?.id == reference.id
                || (feature.selectedGitReference == nil && reference.isCurrent)
        )
    }

    /// Rebuilt on each body pass, but every closure is stable in behavior, and
    /// `GitReferenceRowView.==` ignores this struct so it cannot by itself cause
    /// a row to re-render.
    private var referenceRowActions: GitReferenceRowActions {
        GitReferenceRowActions(
            select: { reference in
                Task { await feature.selectGitReference(reference) }
            },
            toggleGroup: { key in
                if collapsedReferenceGroups.contains(key) {
                    collapsedReferenceGroups.remove(key)
                } else {
                    collapsedReferenceGroups.insert(key)
                }
            },
            newBranch: { reference in
                branchDialogRequest = GitBranchDialogRequest(kind: .create, reference: reference)
            },
            renameBranch: { reference in
                branchDialogRequest = GitBranchDialogRequest(kind: .rename, reference: reference)
            },
            showDiffWithWorkingTree: { reference in
                Task { await navigation.compareWithWorkingTree(reference) }
            },
            compareWithCurrent: { reference in
                guard let currentReference else { return }
                Task { await navigation.compareReferences(reference, currentReference) }
            },
            compareWithSelectedSource: { reference in
                guard let source = comparisonSourceReference else { return }
                comparisonSourceReference = nil
                Task { await navigation.compareReferences(source, reference) }
            },
            selectForCompare: { reference in
                comparisonSourceReference = reference
            },
            comparisonSourceName: comparisonSourceReference?.shortName,
            checkout: { reference in
                Task { await feature.checkoutReference(reference) }
            },
            updateCurrentBranch: { reference in
                Task { await feature.updateCurrentBranch(reference) }
            },
            push: { reference in
                pendingPushReference = reference
            },
            branchOperation: { kind, reference in
                pendingBranchOperation = GitBranchOperationRequest(kind: kind, reference: reference)
            }
        )
    }

    private func referenceButton(_ reference: GitReference, title: String, icon: String) -> some View {
        Button {
            Task { await feature.selectGitReference(reference) }
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
                isActive: !feature.isShowingAllGitReferences && (
                    feature.selectedGitReference?.id == reference.id
                        || (feature.selectedGitReference == nil && reference.isCurrent)
                ),
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
                Task { await navigation.compareWithWorkingTree(reference) }
            }

            if let currentReference, currentReference.id != reference.id {
                Button("Compare with Current Branch") {
                    Task { await navigation.compareReferences(reference, currentReference) }
                }
            }

            if let source = comparisonSourceReference, source.id != reference.id {
                Button("Compare '\(source.shortName)' with '\(reference.shortName)'") {
                    comparisonSourceReference = nil
                    Task { await navigation.compareReferences(source, reference) }
                }
            } else {
                Button("Select for Compare") {
                    comparisonSourceReference = reference
                }
            }

            if !reference.isCurrent {
                Divider()

                Button("Checkout") {
                    Task { await feature.checkoutReference(reference) }
                }
                .disabled(feature.isPerformingBranchOperation)

                if reference.kind != .tag {
                    Button("Checkout and Rebase onto Current Branch") {
                        pendingBranchOperation = GitBranchOperationRequest(
                            kind: .checkoutAndRebase,
                            reference: reference
                        )
                    }
                    .disabled(feature.isPerformingBranchOperation)

                    Button("Merge into Current Branch") {
                        pendingBranchOperation = GitBranchOperationRequest(
                            kind: .merge,
                            reference: reference
                        )
                    }
                    .disabled(feature.isPerformingBranchOperation)
                    Button("Rebase Current Branch onto…") {
                        pendingBranchOperation = GitBranchOperationRequest(
                            kind: .rebase,
                            reference: reference
                        )
                    }
                    .disabled(feature.isPerformingBranchOperation)
                }
            }

            if reference.kind == .remote {
                Divider()

                Button("Pull with Rebase") {
                    pendingBranchOperation = GitBranchOperationRequest(
                        kind: .pullRebase,
                        reference: reference
                    )
                }
                .disabled(feature.isPerformingBranchOperation)
                Button("Pull with Merge") {
                    pendingBranchOperation = GitBranchOperationRequest(
                        kind: .pullMerge,
                        reference: reference
                    )
                }
                .disabled(feature.isPerformingBranchOperation)
            }

            if reference.kind == .local {
                Divider()

                Button("Update") {
                    Task { await feature.updateCurrentBranch(reference) }
                }
                .disabled(!reference.isCurrent || feature.isPerformingBranchOperation)

                Button("Push…") {
                    pendingPushReference = reference
                }
                .disabled(feature.isPerformingBranchOperation)

                if !reference.isCurrent {
                    Button("Delete Branch", role: .destructive) {
                        pendingBranchOperation = GitBranchOperationRequest(
                            kind: .delete,
                            reference: reference
                        )
                    }
                    .disabled(feature.isPerformingBranchOperation)
                }

                Divider()

                Button("Rename…") {
                    branchDialogRequest = GitBranchDialogRequest(kind: .rename, reference: reference)
                }
                .disabled(feature.isPerformingBranchOperation)
            }

            if reference.kind == .tag {
                Divider()

                if reference.supportsTagDeletion {
                    Button("Delete Tag…", role: .destructive) {
                        pendingTagDeletion = reference
                    }
                    .disabled(feature.isPerformingBranchOperation)
                } else {
                    Button("Delete Tag… (target is not a commit)") {}
                        .disabled(true)
                }
            }
        }
    }

    private var commitPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    LitheIDEAIcon(resourcePath: "actions/search.svg", size: 14, fallbackSystemImage: "magnifyingglass")
                        .foregroundStyle(LitheTheme.secondaryText)
                    TextField("Text, me, author:, branch:, path:", text: $feature.gitLogSearchQuery)
                        .textFieldStyle(.plain)
                        .font(GitVisual.toolbar)
                        .focused($gitLogSearchFocused)
                    if !feature.gitLogSearchQuery.isEmpty {
                        Button {
                            feature.gitLogSearchQuery = ""
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
                        Task { await navigation.compareWithWorkingTree(currentReference) }
                    }
                    .disabled(currentReference == nil)
                    gitToolbarIcon(systemImage: "clock", help: "Show commit details")
                    gitToolbarButton(systemImage: "arrow.clockwise", help: "Refresh Git log") {
                        Task { await feature.refreshGitHistory() }
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
            .background(background.hasImage ? Color.clear : LitheTheme.toolHeader)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if (visibleCommitHashes?.isEmpty == true || (visibleCommitHashes == nil && feature.gitCommits.isEmpty)) && !feature.isLoadingGitHistory {
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
                                selectedHash: feature.selectedGitCommit?.hash,
                                showCommitDecorations: showCommitDecorations,
                                actions: graphRowActions
                            )

                            if feature.canLoadMoreGitHistory {
                                Button {
                                        Task { await feature.loadMoreGitHistory() }
                                } label: {
                                    HStack(spacing: 6) {
                                        if feature.isLoadingMoreGitHistory {
                                            ProgressView().controlSize(.small)
                                        }
                                        Text(feature.isLoadingMoreGitHistory ? "Loading commits…" : "Load more commits")
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
                    .onChange(of: feature.selectedGitCommit?.hash) { _ in
                        guard let hash = feature.selectedGitCommit?.hash else { return }
                        proxy.scrollTo(hash)
                    }
                }
            }
        }
        .background(background.hasImage ? Color.clear : LitheTheme.editor)
    }

    private var detailPane: some View {
        GeometryReader { geometry in
            let minimumFilesPaneHeight: CGFloat = 90
            let minimumCommitDetailHeight: CGFloat = 110
            let maximumFilesPaneHeight = max(
                minimumFilesPaneHeight,
                geometry.size.height - SplitHandleView.thickness - minimumCommitDetailHeight
            )

            LitheSplitPaneView(
                axis: .vertical,
                placement: .leading,
                // Until the user drags, the files pane keeps tracking the
                // container so the detail area stays at its designed height.
                defaultSize: geometry.size.height - SplitHandleView.thickness - 156,
                minimum: minimumFilesPaneHeight,
                maximum: maximumFilesPaneHeight,
                sized: { commitFilesPane },
                flexible: { commitDetail }
            )
        }
        .background(background.hasImage ? Color.clear : LitheTheme.sidebar)
    }

    private var commitFilesPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                gitToolbarIcon(systemImage: "arrow.left.arrow.right", help: "Compare changes")
                gitToolbarIcon(systemImage: "clock", help: "Show file history")
                gitToolbarIcon(systemImage: "eye", help: "Toggle preview")
                Spacer()
                Text("\(feature.selectedGitCommitFiles.count) files")
            }
            .font(GitVisual.meta)
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: GitVisual.toolbarHeight)
            .background(background.hasImage ? Color.clear : LitheTheme.toolHeader)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            switch feature.selectedGitCommitFilesLoadState {
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
                    if let commit = feature.selectedGitCommit {
                        Button("Retry") {
                            scheduleGitCommitFileLoad(for: commit)
                        }
                    }
                }
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready where feature.selectedGitCommitFiles.isEmpty:
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
            if let commit = feature.selectedGitCommit {
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
        .background(background.hasImage ? Color.clear : LitheTheme.editor)
    }

    private var filteredCommits: [GitCommit] {
        guard let hashes = visibleCommitHashes else { return feature.gitCommits }
        return feature.gitCommits.filter { hashes.contains($0.hash) }
    }

    private func moveGitLogCommitSelection(by offset: Int) {
        guard let commit = GitLogCommitSelection.adjacentCommit(
            in: filteredCommits,
            selectedHash: feature.selectedGitCommit?.hash,
            offset: offset
        ) else { return }
        feature.previewGitCommitSelection(commit)
        scheduleGitCommitFileLoad(for: commit)
    }

    private func scheduleGitCommitFileLoad(for commit: GitCommit) {
        gitCommitFileLoadTask?.cancel()
        gitCommitFileLoadTask = Task { [feature] in
            do {
                try await Task.sleep(for: GitVisual.commitFileLoadDelay)
            } catch {
                return
            }
            await feature.loadGitCommitFiles(for: commit)
        }
    }

    private var checkoutReference: GitReference? {
        guard let reference = feature.selectedGitReference,
              reference.kind == .local,
              !reference.isCurrent else { return nil }
        return reference
    }

    private var primaryComparisonDescription: String {
        guard let currentReference else { return "No current branch" }
        if let target = feature.selectedGitReference, target.id != currentReference.id {
            return "\(currentReference.shortName) → \(target.shortName)"
        }
        return "\(currentReference.shortName) ↔ Working Tree"
    }

    private func showPrimaryComparison() {
        guard let currentReference else { return }
        if let target = feature.selectedGitReference, target.id != currentReference.id {
            Task { await navigation.compareReferences(currentReference, target) }
        } else {
            Task { await navigation.compareWithWorkingTree(currentReference) }
        }
    }

    /// Rows compare themselves by data and ignore these callbacks, so building
    /// the group once per pane redraw never invalidates a row.
    private var graphRowActions: GitGraphRowActions {
        let pendingOperation = $pendingCommitOperation
        return GitGraphRowActions(
            onSelect: { commit in
                gitLogCommitListFocused = true
                feature.previewGitCommitSelection(commit)
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
            },
            onCreateTag: { commit in
                tagDialogRequest = GitTagDialogRequest(commit: commit)
            }
        )
    }

    private var visibleCommitHashes: Set<String>? {
        guard hasActiveGitLogFilter else { return nil }
        return feature.gitLogMatchedCommitHashes
    }

    /// True when any filter is active, without calling `Date()`. Used to decide
    /// whether to show the filtered commit subset or the full log.
    private var hasActiveGitLogFilter: Bool {
        !feature.gitLogSearchQuery.isEmpty
            || selectedGitLogAuthor != nil
            || selectedGitLogDatePreset != .anyTime
            || !gitLogPathFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var gitLogFilterTaskIdentity: GitLogFilterTaskIdentity {
        GitLogFilterTaskIdentity(
            searchQuery: feature.gitLogSearchQuery,
            author: selectedGitLogAuthor,
            datePreset: selectedGitLogDatePreset,
            path: gitLogPathFilter,
            commitHashes: feature.gitCommits.map(\.hash)
        )
    }

    /// Builds the filter query with a caller-supplied `now`, so `Date()` is
    /// only called once at the task execution site rather than on every body pass.
    private func gitLogQuery(now: Date) -> GitLogQuery {
        let path = gitLogPathFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = GitLogQuery.parse(feature.gitLogSearchQuery).addingStructuredFilters(
            currentUserOnly: selectedGitLogAuthor == .currentUser,
            exactAuthor: selectedGitLogAuthor?.exactAuthor,
            paths: path.isEmpty ? [] : [path]
        )
        return selectedGitLogDatePreset.applying(to: query, now: now)
    }

    private var gitLogAuthorOptions: [GitLogAuthorOption] {
        var authorsByID: [String: GitLogAuthorOption] = [:]
        for commit in feature.gitCommits {
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
                Button {
                    showsGitLogBranchFilterPopover = true
                } label: {
                    gitLogFilterLabel(
                        title: "Branch",
                        selection: feature.selectedGitReference?.shortName
                    )
                }
                .buttonStyle(.plain)
                .lithePointer()
                .popover(isPresented: $showsGitLogBranchFilterPopover, arrowEdge: .bottom) {
                    GitLogBranchFilterPopover(
                        menu: GitLogFilterList.branchMenu(references: feature.gitReferences),
                        querySections: { query in
                            GitLogFilterList.branchSections(
                                references: feature.gitReferences,
                                query: query
                            )
                        },
                        isItemSelected: { item in
                            item.matches(selected: feature.selectedGitReference)
                        },
                        onSelect: { item in
                            showsGitLogBranchFilterPopover = false
                            Task { await feature.selectGitReference(item.reference) }
                        }
                    )
                }

                if feature.selectedGitReference != nil || feature.isShowingAllGitReferences {
                    gitLogFilterClearButton(help: "Clear branch filter") {
                        Task { await feature.showAllGitReferences() }
                    }
                }
            }

            HStack(spacing: 2) {
                Button {
                    showsGitLogAuthorFilterPopover = true
                } label: {
                    gitLogFilterLabel(title: "User", selection: selectedGitLogAuthor?.displayName)
                }
                .buttonStyle(.plain)
                .lithePointer()
                .popover(isPresented: $showsGitLogAuthorFilterPopover, arrowEdge: .bottom) {
                    GitLogFilterPopover(
                        sectionsForQuery: { query in
                            GitLogFilterList.authorSections(
                                authors: gitLogAuthorOptions,
                                query: query
                            )
                        },
                        searchPlaceholder: "Search users",
                        emptyText: "No matching users",
                        isItemSelected: { item in
                            item.matches(selected: selectedGitLogAuthor)
                        },
                        onSelect: { item in
                            showsGitLogAuthorFilterPopover = false
                            selectedGitLogAuthor = item.selection
                        }
                    )
                }

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
            from: feature.selectedGitCommitFiles,
            rootName: projectName
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
        guard let root = feature.gitRepositoryRoot else { return nil }
        let components = root.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }
        return components.suffix(2).joined(separator: "/")
    }

    /// Asked for from many places in one body pass, so the linear scan is
    /// memoized against the reference list it came from.
    private var currentReference: GitReference? {
        currentReferenceCache.reference(in: feature.gitReferences)
    }

    /// Both inputs the flattened rows depend on. `gitReferences` is compared by
    /// value because it is small and changes rarely; the collapse set changes
    /// only on an explicit disclosure toggle.
    private var referenceRowsTaskIdentity: GitReferenceRowsIdentity {
        GitReferenceRowsIdentity(
            references: feature.gitReferences,
            collapsedGroups: collapsedReferenceGroups
        )
    }

    private func rebuildReferenceRows() {
        let references = feature.gitReferences
        localReferenceRows = GitReferenceRowsBuilder.rows(
            from: references.filter { $0.kind == .local },
            kind: .local,
            collapsedGroups: collapsedReferenceGroups
        )
        remoteReferenceRows = GitReferenceRowsBuilder.rows(
            from: references.filter { $0.kind == .remote },
            kind: .remote,
            collapsedGroups: collapsedReferenceGroups
        )
        tagReferenceRows = GitReferenceRowsBuilder.rows(
            from: references.filter { $0.kind == .tag },
            kind: .tag,
            collapsedGroups: collapsedReferenceGroups
        )
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
            navigation.openCommitDiff(file)
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
                isActive: feature.selectedGitCommitFile?.id == file.id,
                cornerRadius: 4,
                activeBackground: LitheTheme.subtleSelection
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
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
    case checkoutAndRebase
    case pullRebase
    case pullMerge

    var title: String {
        switch self {
        case .delete: "Delete branch?"
        case .merge: "Merge branch?"
        case .rebase: "Rebase branch?"
        case .checkoutAndRebase: "Checkout and rebase branch?"
        case .pullRebase: "Pull remote branch with rebase?"
        case .pullMerge: "Pull remote branch with merge?"
        }
    }

    var actionTitle: String {
        switch self {
        case .delete: "Delete"
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .checkoutAndRebase: "Checkout and Rebase"
        case .pullRebase: "Pull with Rebase"
        case .pullMerge: "Pull with Merge"
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
        case .checkoutAndRebase:
            return "Checkout \(reference.shortName), then replay it onto the branch that is current now."
        case .pullRebase:
            return "Pull \(reference.shortName) into the current branch and replay local commits."
        case .pullMerge:
            return "Pull \(reference.shortName) into the current branch with a merge."
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

private struct GitTagDialogRequest: Identifiable {
    let id = UUID()
    let commit: GitCommit
}

/// New Tag dialog mirroring IntelliJ's: a required name plus an optional
/// message (annotated tag when non-empty). Local validation shows inline and
/// keeps the dialog open; a server-side failure returned by `onSubmit` (for
/// example a duplicate name) is shown here as well instead of a notification.
private struct GitTagNameDialog: View {
    @Environment(\.dismiss) private var dismiss
    let request: GitTagDialogRequest
    let onSubmit: (String, String) async -> String?

    @State private var name = ""
    @State private var message = ""
    @State private var submitError: String?
    @State private var isSubmitting = false
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("New Tag")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Text("Create on commit \(request.commit.shortHash). Leave the message empty for a lightweight tag.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            TextField("Tag name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .onSubmit(submit)

            VStack(alignment: .leading, spacing: 3) {
                TextField("Message (optional)", text: $message, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Text("A message creates an annotated tag.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            if let error = validationError ?? submitError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .lithePointer()
                Button("Create", action: submit)
                    .buttonStyle(.borderedProminent)
                    .lithePointer()
                    .tint(LitheTheme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || validationError != nil || isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(LitheTheme.raised)
        .onAppear { nameFieldFocused = true }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mirrors the refname rules the Rust core enforces so illegal names are
    /// rejected before a request is sent.
    private var validationError: String? {
        let name = trimmedName
        guard !name.isEmpty else { return nil }
        return GitTagNameValidator.validationError(for: name)
    }

    private func submit() {
        guard !trimmedName.isEmpty, validationError == nil, !isSubmitting else { return }
        isSubmitting = true
        submitError = nil
        Task {
            let error = await onSubmit(trimmedName, message)
            isSubmitting = false
            if let error {
                submitError = error
            } else {
                dismiss()
            }
        }
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
    @Environment(\.dismiss) private var dismiss
    let changes: [GitChange]
    let path: String
    let onShowDiff: (String) -> Void
    let onRollback: (String) -> Void

    private var change: GitChange? {
        changes.first(where: { $0.path == path })
    }

    var body: some View {
        HStack(spacing: 7) {
            if change != nil {
                Button {
                    dismiss()
                    onShowDiff(path)
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
    let changes: [GitChange]
    let onShowDiff: (String) -> Void
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
                        GitConflictPathRow(
                            changes: changes,
                            path: path,
                            onShowDiff: onShowDiff,
                            onRollback: onRollback
                        )
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Update Project")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
                .padding(.bottom, 24)

            Text("Updating \(request.upstream) (\(request.behind) incoming, \(request.ahead) local)")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.bottom, 14)

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

            if request.hasLocalChanges {
                Label(
                    "Rebase requires a clean working tree. Commit or stash local changes before choosing Rebase.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            }

            Spacer(minLength: 22)

            HStack(spacing: 10) {
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
        .frame(width: 560)
        .frame(minHeight: 248)
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

    var body: some View {
        let presentation = GitPushDialogPresentation(reference: reference)

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
                        Text(presentation.destination)
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
                Spacer(minLength: 16)

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .lithePointer()

                Button(presentation.actionTitle) {
                    onPush()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(LitheTheme.accent)
                .keyboardShortcut(.defaultAction)
                .lithePointer()
            }
            .padding(16)
        }
        .frame(width: 720, height: 430)
        .background(LitheTheme.raised)
    }
}

struct GitPushDialogPresentation {
    let destination: String
    let actionTitle: String

    init(reference: GitReference) {
        if let upstream = reference.upstreamShortName {
            destination = "Tracking \(upstream)"
            actionTitle = "Push"
        } else {
            destination = "Publish \(reference.shortName) (Core selects default remote)"
            actionTitle = "Publish Branch"
        }
    }
}

struct GitCheckoutConflictDialog: View {
    @Environment(\.dismiss) private var dismiss
    let request: GitCheckoutConflictRequest
    let savePolicy: GitSaveChangesPolicy
    let changes: [GitChange]
    let onShowDiff: (String) -> Void
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
                        GitConflictPathRow(
                            changes: changes,
                            path: path,
                            onShowDiff: onShowDiff,
                            onRollback: onRollback
                        )
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

// MARK: - Git Reference Row Actions & View

/// Combined `.task(id:)` key for the flattened reference rows, so the rows are
/// rebuilt when either the references or the collapse state changes.
private struct GitReferenceRowsIdentity: Equatable {
    let references: [GitReference]
    let collapsedGroups: Set<String>
}

private struct GitReferenceRowActions {
    let select: (GitReference) -> Void
    let toggleGroup: (String) -> Void
    let newBranch: (GitReference) -> Void
    let renameBranch: (GitReference) -> Void
    let showDiffWithWorkingTree: (GitReference) -> Void
    let compareWithCurrent: (GitReference) -> Void
    let compareWithSelectedSource: (GitReference) -> Void
    let selectForCompare: (GitReference) -> Void
    let comparisonSourceName: String?
    let checkout: (GitReference) -> Void
    let updateCurrentBranch: (GitReference) -> Void
    let push: (GitReference) -> Void
    let branchOperation: (GitBranchOperationKind, GitReference) -> Void
}

private struct GitReferenceRowView: View, Equatable {
    let row: GitReferenceRow
    let isSelected: Bool
    let isPerformingBranchOperation: Bool
    let currentReferenceID: String?
    let comparisonSourceID: String?
    let actions: GitReferenceRowActions

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row
            && lhs.isSelected == rhs.isSelected
            && lhs.isPerformingBranchOperation == rhs.isPerformingBranchOperation
            && lhs.currentReferenceID == rhs.currentReferenceID
            && lhs.comparisonSourceID == rhs.comparisonSourceID
    }

    var body: some View {
        switch row.content {
        case .group(let key, let isCollapsed):
            groupRow(key: key, isCollapsed: isCollapsed)
        case .reference(let reference):
            referenceRow(reference)
        }
    }

    private func groupRow(key: String, isCollapsed: Bool) -> some View {
        Button {
            actions.toggleGroup(key)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 10)
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                Text(row.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.leading, CGFloat(row.depth * 16))
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
            .litheRowHover(cornerRadius: 4)
        }
        .buttonStyle(.plain)
        .lithePointer()
    }

    private func referenceRow(_ reference: GitReference) -> some View {
        Button {
            actions.select(reference)
        } label: {
            HStack(spacing: 7) {
                LitheSystemIcon(systemImage: referenceIcon(reference), size: 14)
                    .foregroundStyle(reference.kind == .tag ? LitheTheme.warning : LitheTheme.secondaryText)
                    .frame(width: 16)
                Text(row.name)
                    .font(.system(size: 13))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                if reference.isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(LitheTheme.accent)
                }
                Spacer(minLength: 8)
            }
            .padding(.leading, CGFloat(row.depth * 16))
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .litheRowHover(
                isActive: isSelected,
                cornerRadius: 4,
                activeBackground: LitheTheme.subtleSelection
            )
        }
        .buttonStyle(.plain)
        .lithePointer()
        .contextMenu {
            Button("New Branch from '\(reference.shortName)'…") {
                actions.newBranch(reference)
            }

            Button("Show Diff with Working Tree") {
                actions.showDiffWithWorkingTree(reference)
            }

            if let currentReferenceID, currentReferenceID != reference.id {
                Button("Compare with Current Branch") {
                    actions.compareWithCurrent(reference)
                }
            }

            if let comparisonSourceID, comparisonSourceID != reference.id,
               let sourceName = actions.comparisonSourceName {
                Button("Compare '\(sourceName)' with '\(reference.shortName)'") {
                    actions.compareWithSelectedSource(reference)
                }
            } else {
                Button("Select for Compare") {
                    actions.selectForCompare(reference)
                }
            }

            if !reference.isCurrent {
                Divider()

                Button("Checkout") {
                    actions.checkout(reference)
                }
                .disabled(isPerformingBranchOperation)

                if reference.kind != .tag {
                    Button("Checkout and Rebase onto Current Branch") {
                        actions.branchOperation(.checkoutAndRebase, reference)
                    }
                    .disabled(isPerformingBranchOperation)

                    Button("Merge into Current Branch") {
                        actions.branchOperation(.merge, reference)
                    }
                    .disabled(isPerformingBranchOperation)

                    Button("Rebase Current Branch onto…") {
                        actions.branchOperation(.rebase, reference)
                    }
                    .disabled(isPerformingBranchOperation)
                }
            }

            if reference.kind == .remote {
                Divider()

                Button("Pull with Rebase") {
                    actions.branchOperation(.pullRebase, reference)
                }
                .disabled(isPerformingBranchOperation)

                Button("Pull with Merge") {
                    actions.branchOperation(.pullMerge, reference)
                }
                .disabled(isPerformingBranchOperation)
            }

            if reference.kind == .local {
                Divider()

                Button("Update") {
                    actions.updateCurrentBranch(reference)
                }
                .disabled(!reference.isCurrent || isPerformingBranchOperation)

                Button("Push…") {
                    actions.push(reference)
                }
                .disabled(isPerformingBranchOperation)

                if !reference.isCurrent {
                    Button("Delete Branch", role: .destructive) {
                        actions.branchOperation(.delete, reference)
                    }
                    .disabled(isPerformingBranchOperation)
                }

                Divider()

                Button("Rename…") {
                    actions.renameBranch(reference)
                }
                .disabled(isPerformingBranchOperation)
            }
        }
    }

    private func referenceIcon(_ reference: GitReference) -> String {
        switch reference.kind {
        case .local: "point.3.connected.trianglepath.dotted"
        case .remote: "cloud"
        case .tag: "tag"
        }
    }
}

// MARK: - Git Log Three-Pane Layout

private enum GitLogThreePaneMetrics {
    static let minimumReferencePaneWidth: CGFloat = 180
    static let minimumCommitPaneWidth: CGFloat = 340
    static let minimumDetailPaneWidth: CGFloat = 250
}

private struct GitLogThreePaneLayout<ReferencePane: View, CommitPane: View, DetailPane: View>: View {
    let availableWidth: CGFloat
    private let referencePane: ReferencePane
    private let commitPane: CommitPane
    private let detailPane: DetailPane

    init(
        availableWidth: CGFloat,
        @ViewBuilder referencePane: () -> ReferencePane,
        @ViewBuilder commitPane: () -> CommitPane,
        @ViewBuilder detailPane: () -> DetailPane
    ) {
        self.availableWidth = availableWidth
        self.referencePane = referencePane()
        self.commitPane = commitPane()
        self.detailPane = detailPane()
    }

    private var referencePaneMaximum: CGFloat {
        max(
            GitLogThreePaneMetrics.minimumReferencePaneWidth,
            min(
                availableWidth * 0.35,
                availableWidth
                    - (SplitHandleView.thickness * 2)
                    - GitLogThreePaneMetrics.minimumCommitPaneWidth
                    - GitLogThreePaneMetrics.minimumDetailPaneWidth
            )
        )
    }

    private var detailPaneMaximum: CGFloat {
        max(
            GitLogThreePaneMetrics.minimumDetailPaneWidth,
            min(
                availableWidth * 0.5,
                availableWidth
                    - (SplitHandleView.thickness * 2)
                    - GitLogThreePaneMetrics.minimumCommitPaneWidth
                    - referencePaneMaximum
            )
        )
    }

    var body: some View {
        LitheSplitPaneView(
            axis: .horizontal,
            placement: .leading,
            defaultSize: 220,
            minimum: GitLogThreePaneMetrics.minimumReferencePaneWidth,
            maximum: referencePaneMaximum,
            flexibleMinimum: GitLogThreePaneMetrics.minimumCommitPaneWidth,
            sized: { referencePane },
            flexible: {
                LitheSplitPaneView(
                    axis: .horizontal,
                    placement: .trailing,
                    defaultSize: 350,
                    minimum: GitLogThreePaneMetrics.minimumDetailPaneWidth,
                    maximum: detailPaneMaximum,
                    sized: { detailPane },
                    flexible: { commitPane }
                )
            }
        )
    }
}
