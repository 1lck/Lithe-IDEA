import SwiftUI
import LitheGitModule

struct GitWorktreesView: View {
    private enum WorktreeSection: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case changes = "Changes"
        case history = "Commit History"
        case settings = "Settings"

        var id: String { rawValue }
    }

    private enum Visual {
        static let title = Font.system(size: 18, weight: .semibold)
        static let section = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13)
        static let bodyMedium = Font.system(size: 13, weight: .medium)
        static let metadata = Font.system(size: 12.5)
        static let mono = Font.system(size: 12.5, design: .monospaced)
        static let listWidth: CGFloat = 360
        static let quickInfoWidth: CGFloat = 282
        static let quickInfoThreshold: CGFloat = 1_080
    }

    fileprivate enum WorktreeStatusKind: Equatable {
        case pathMissing
        case locked
        case modified
        case current
        case available

        var title: LocalizedStringKey {
            switch self {
            case .pathMissing: return "Path Missing"
            case .locked: return "Locked"
            case .modified: return "Modified"
            case .current: return "Current"
            case .available: return "Available"
            }
        }

        var color: Color {
            switch self {
            case .pathMissing: return LitheTheme.error
            case .locked: return LitheTheme.warning
            case .modified: return LitheTheme.warning
            case .current, .available: return LitheTheme.success
            }
        }

        init(_ status: GitWorktreeStatusKind) {
            switch status {
            case .pathMissing: self = .pathMissing
            case .locked: self = .locked
            case .modified: self = .modified
            case .current: self = .current
            case .available: self = .available
            }
        }
    }

    private enum WorktreeConfirmation: Identifiable {
        case removal(GitWorktree, force: Bool)
        case prune

        var id: String {
            switch self {
            case .removal(let worktree, let force):
                "\(force ? "force" : "regular")-removal:\(worktree.id)"
            case .prune:
                "prune"
            }
        }
    }

    private struct WorktreeActionNotice: Identifiable {
        let id = UUID()
        let message: String
    }

    @ObservedObject var feature: GitFeatureModel
    @ObservedObject var background: WorkbenchBackgroundFeatureModel
    let actions: GitWorktreeActions
    @State private var showsCreateSheet = false
    @State private var worktreeConfirmation: WorktreeConfirmation?
    @State private var worktreeActionNotice: WorktreeActionNotice?
    @State private var searchText = ""
    @State private var historySearchText = ""
    @State private var isLoadingMoreHistory = false
    @State private var selectedWorktreeID: String?
    @State private var activeSection = WorktreeSection.overview
    @State private var projectedWorktrees: [GitWorktreeListItem] = []
    @State private var projectedChangesSnapshot = GitWorktreeRowsSnapshot(
        identity: .changes(inspectionVersion: 0),
        rows: []
    )
    @State private var projectedHistorySnapshot = GitWorktreeRowsSnapshot(
        identity: .history(inspectionVersion: 0, query: ""),
        rows: []
    )

    var body: some View {
        GeometryReader { geometry in
            let showsQuickInfo = geometry.size.width >= Visual.quickInfoThreshold
            let detailMinimum: CGFloat = showsQuickInfo ? 500 : 420
            let quickInfoMinimum: CGFloat = 220
            let listMaximum = max(
                286,
                geometry.size.width
                    - SplitHandleView.thickness
                    - detailMinimum
                    - (showsQuickInfo ? SplitHandleView.thickness + quickInfoMinimum : 0)
            )

            LitheSplitPaneView(
                axis: .horizontal,
                placement: .leading,
                defaultSize: Visual.listWidth,
                minimum: 286,
                maximum: listMaximum,
                flexibleMinimum: detailMinimum + (showsQuickInfo ? SplitHandleView.thickness + quickInfoMinimum : 0),
                sized: { worktreeListPane },
                flexible: {
                    if showsQuickInfo {
                        LitheSplitPaneView(
                            axis: .horizontal,
                            placement: .trailing,
                            defaultSize: Visual.quickInfoWidth,
                            minimum: quickInfoMinimum,
                            maximum: max(
                                quickInfoMinimum,
                                geometry.size.width - Visual.listWidth
                                    - SplitHandleView.thickness - detailMinimum
                            ),
                            flexibleMinimum: detailMinimum,
                            sized: { quickInfoPane },
                            flexible: { worktreeDetailPane }
                        )
                    } else {
                        worktreeDetailPane
                    }
                }
            )
        }
        // Window resizing continuously proposes new sizes. Keep those layout
        // passes transactional so SwiftUI does not animate pane bounds or
        // replay content transitions while the pointer is moving.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        // Avoid a page-wide offscreen texture while the window is resized.
        // Native list/detail surfaces remain in the live hierarchy, and the
        // split pane still coalesces direct-manipulation updates above.
        .background(background.hasImage ? Color.clear : LitheTheme.editor)
        .task(id: feature.gitRepositoryRoot) {
            await feature.refreshWorktrees()
            selectAvailableWorktree()
        }
        .task(id: selectedWorktree?.id) {
            guard let worktree = selectedWorktree, !worktree.isPrunable else { return }
            await feature.inspectWorktree(worktree)
        }
        .task(id: worktreeListProjectionIdentity) {
            let taskIdentity = worktreeListProjectionIdentity
            let worktrees = feature.gitWorktrees
            let query = searchText
            let inspection = feature.gitWorktreeInspection
            let currentChangeCount = feature.gitChanges.count
            let projection = await Task.detached(priority: .userInitiated) {
                GitWorktreeListProjection.items(
                    worktrees: worktrees,
                    query: query,
                    inspection: inspection,
                    currentChangeCount: currentChangeCount
                )
            }.value
            guard taskIdentity == worktreeListProjectionIdentity else { return }
            projectedWorktrees = projection
        }
        .task(id: worktreeChangesProjectionIdentity) {
            let taskIdentity = worktreeChangesProjectionIdentity
            let changes: [GitChange]
            if let selectedWorktree,
               let inspection = matchingInspection(for: selectedWorktree) {
                changes = inspection.changes
            } else {
                changes = []
            }
            let rows = await Task.detached(priority: .userInitiated) {
                changes.map { change in
                    GitWorktreeRowsSnapshot.Row.change(
                        status: change.displayStatus,
                        path: change.path,
                        isStaged: change.isStaged,
                        color: Self.nativeStatusColor(for: change.kind)
                    )
                }
            }.value
            guard taskIdentity == worktreeChangesProjectionIdentity else { return }
            projectedChangesSnapshot = GitWorktreeRowsSnapshot(
                identity: .changes(inspectionVersion: taskIdentity.inspectionVersion),
                rows: rows
            )
        }
        .task(id: worktreeHistoryProjectionIdentity) {
            let taskIdentity = worktreeHistoryProjectionIdentity
            guard let inspection = feature.gitWorktreeInspection else {
                projectedHistorySnapshot = GitWorktreeRowsSnapshot(
                    identity: .history(
                        inspectionVersion: taskIdentity.inspectionVersion,
                        query: taskIdentity.query
                    ),
                    rows: []
                )
                return
            }
            let query = historySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let commits = inspection.commits
            let rows = await Task.detached(priority: .userInitiated) {
                let projection = query.isEmpty ? commits : commits.filter {
                    $0.subject.localizedCaseInsensitiveContains(query)
                        || $0.authorName.localizedCaseInsensitiveContains(query)
                        || $0.hash.localizedCaseInsensitiveContains(query)
                }
                return projection.map { commit in
                    GitWorktreeRowsSnapshot.Row.commit(
                        subject: commit.subject,
                        author: commit.authorName,
                        date: commit.date
                    )
                }
            }.value
            guard taskIdentity == currentWorktreeHistoryProjectionIdentity else { return }
            projectedHistorySnapshot = GitWorktreeRowsSnapshot(
                identity: .history(
                    inspectionVersion: taskIdentity.inspectionVersion,
                    query: taskIdentity.query
                ),
                rows: rows
            )
        }
        .onChange(of: feature.gitWorktrees.map(\.id)) { _ in
            selectAvailableWorktree()
        }
        .sheet(isPresented: $showsCreateSheet) {
            if let repositoryRoot = feature.gitRepositoryRoot {
                GitWorktreeCreateView(
                    repositoryRoot: repositoryRoot,
                    references: feature.gitReferences,
                    currentReference: feature.gitReferences.first(where: \.isCurrent),
                    actions: actions
                ) { name, reference, revision, destination in
                    Task {
                        await feature.createWorktree(
                            named: name,
                            from: reference,
                            revision: revision,
                            at: destination
                        )
                    }
                }
            }
        }
        .confirmationDialog(
            worktreeConfirmationTitle,
            isPresented: Binding(
                get: { worktreeConfirmation != nil },
                set: { if !$0 { worktreeConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let confirmation = worktreeConfirmation {
                switch confirmation {
                case .removal(let worktree, force: true):
                    Button("Force Remove", role: .destructive) {
                        worktreeConfirmation = nil
                        Task { await feature.removeWorktree(worktree, force: true) }
                    }
                case .removal(let worktree, force: false):
                    Button("Remove", role: .destructive) {
                        worktreeConfirmation = nil
                        Task { await feature.removeWorktree(worktree, force: false) }
                    }
                    Button("Review Force Remove…") {
                        // Let the current confirmation finish dismissing before
                        // presenting the force-removal warning.
                        worktreeConfirmation = nil
                        DispatchQueue.main.async {
                            worktreeConfirmation = .removal(worktree, force: true)
                        }
                    }
                case .prune:
                    Button("Prune Stale Records", role: .destructive) {
                        worktreeConfirmation = nil
                        Task { await feature.pruneWorktrees() }
                    }
                }
                Button("Cancel", role: .cancel) { worktreeConfirmation = nil }
            }
        } message: {
            if let confirmation = worktreeConfirmation {
                switch confirmation {
                case .removal(let worktree, force: true):
                    Text(String(
                        format: String(localized: "This permanently deletes uncommitted and untracked files in '%@'. The branch itself is kept."),
                        worktree.displayName
                    ))
                case .removal(let worktree, force: false):
                    Text(String(
                        format: String(localized: "Remove '%@' and its checkout directory? The branch is kept. If Git refuses because files have changed, review the force-removal warning."),
                        worktree.displayName
                    ))
                case .prune:
                    Text("This removes Git registrations whose checkout directories no longer exist. It does not delete branches.")
                }
            }
        }
        .alert(item: $worktreeActionNotice) { notice in
            Alert(
                title: Text("Worktree action unavailable"),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var worktreeListPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    showsCreateSheet = true
                } label: {
                    Label("New Worktree", systemImage: "plus")
                        .font(Visual.bodyMedium)
                        .padding(.horizontal, 5)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(LitheTheme.accent)
                .lithePointer()
                .disabled(feature.gitReferences.isEmpty || feature.isPerformingWorktreeOperation)

                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(LitheTheme.tertiaryText)
                    TextField("Search worktree or path", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(Visual.body)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(LitheTheme.inputBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(LitheTheme.inputBorder, lineWidth: 1)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 52)

            HStack {
                Text("Worktrees")
                    .font(Visual.section)
                Text(String(format: String(localized: "%lld worktrees"), filteredWorktrees.count))
                    .font(Visual.metadata)
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer()
                if feature.isPerformingWorktreeOperation || feature.gitWorktreeLoadState == .loading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await feature.refreshWorktrees() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .lithePointer()
                .disabled(feature.isPerformingWorktreeOperation)
                .help("Refresh worktrees")
            }
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 14)
            .frame(height: 34)

            Divider()

            if filteredWorktrees.isEmpty {
                listEmptyState
            } else {
                GitWorktreeListScrollView(
                    items: projectedWorktrees,
                    selectedWorktreeID: selectedWorktreeID,
                    onSelect: { worktreeID in
                        selectedWorktreeID = worktreeID
                        activeSection = .overview
                    }
                )
            }
        }
        .background(background.hasImage ? Color.clear : LitheTheme.sidebar)
    }

    private func worktreeStatusKind(_ worktree: GitWorktree) -> WorktreeStatusKind {
        if worktree.isPrunable { return .pathMissing }
        if worktree.isLocked { return .locked }
        if let inspection = matchingInspection(for: worktree), !inspection.changes.isEmpty { return .modified }
        if worktree.isCurrent && !feature.gitChanges.isEmpty { return .modified }
        if worktree.isCurrent { return .current }
        return .available
    }

    @ViewBuilder
    private var worktreeDetailPane: some View {
        if let worktree = selectedWorktree {
            VStack(spacing: 0) {
                detailHeader(worktree)
                detailTabs
                Divider()
                sectionContent(worktree)
                if feature.gitWorktrees.contains(where: \.isPrunable) {
                    staleWorktreeBanner
                }
            }
        } else {
            detailEmptyState
        }
    }

    private func detailHeader(_ worktree: GitWorktree) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text(worktree.isPrimary ? String(localized: "Main Worktree") : worktree.displayName)
                    .font(Visual.title)
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                worktreeBadge("Worktree", color: LitheTheme.accent)
                worktreeStatusLabel(worktree)
                Spacer()
            }
            HStack(spacing: 8) {
                Text(worktree.path)
                    .font(Visual.metadata)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text("·")
                    .foregroundStyle(LitheTheme.tertiaryText)
                Text(String(
                    format: String(localized: "Branch: %@"),
                    worktree.branchName ?? String(localized: "Detached HEAD")
                ))
                    .font(Visual.metadata)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                Button {
                    actions.copyPath(worktree.url)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .lithePointer()
                .help("Copy worktree path")
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 74)
    }

    private var detailTabs: some View {
        HStack(spacing: 28) {
            ForEach(WorktreeSection.allCases) { section in
                detailTab(section)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 40)
    }

    private func detailTab(_ section: WorktreeSection) -> some View {
        Button {
            activeSection = section
        } label: {
            Text(LocalizedStringKey(section.rawValue))
                .font(Visual.bodyMedium)
                .foregroundStyle(activeSection == section ? LitheTheme.primaryText : LitheTheme.secondaryText)
                .frame(height: 40)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(activeSection == section ? LitheTheme.tabUnderline : .clear)
                        .frame(height: 2)
                }
        }
        .buttonStyle(.plain)
        .lithePointer()
    }

    @ViewBuilder
    private func sectionContent(_ worktree: GitWorktree) -> some View {
        switch activeSection {
        case .overview:
            ScrollView {
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        basicInformationCard(worktree)
                        statusCard(worktree)
                    }
                    actionCard(worktree)
                }
                // Keep every overview card on the same content width. Without
                // an explicit width, the adaptive action grid can make its
                // card hug its intrinsic button width after a pane resize,
                // leaving a blank strip beside it until another layout pass.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .litheScrollViewChrome()
        case .changes:
            changesSection(worktree)
                .padding(14)
        case .history:
            historySection(worktree)
                .padding(14)
        case .settings:
            ScrollView {
                settingsSection(worktree)
            }
            .padding(14)
            .litheScrollViewChrome()
        }
    }

    private func basicInformationCard(_ worktree: GitWorktree) -> some View {
        worktreeCard(title: "Basic Information") {
            informationRow("Path") {
                HStack(spacing: 6) {
                    Text(worktree.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        actions.copyPath(worktree.url)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .lithePointer()
                }
            }
            informationRow("Branch", value: worktree.branchName ?? "Detached HEAD")
            informationRow("HEAD") {
                Text(worktree.shortHead)
                    .font(Visual.mono)
                    .foregroundStyle(LitheTheme.link)
                    .textSelection(.enabled)
            }
            informationRow("Role", value: worktree.isPrimary ? "Primary worktree" : "Linked worktree")
        }
    }

    private func statusCard(_ worktree: GitWorktree) -> some View {
        worktreeCard(title: "Status") {
            informationRow("Worktree") {
                worktreeStatusLabel(worktree)
            }
            informationRow("Registration", value: worktree.isPrunable ? "Stale record" : "Valid")
            informationRow("Protection", value: worktree.isLocked ? (worktree.lockReason ?? "Locked") : "Unlocked")
            informationRow("Local changes", value: localChangesDescription(for: worktree))
        }
    }

    private func actionCard(_ worktree: GitWorktree) -> some View {
        worktreeCard(title: "Actions") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                worktreeAction("Open in Lithe", icon: "macwindow") {
                    actions.openProject(worktree.url)
                }
                .disabled(worktree.isPrunable)
                .help(pathActionHelp(for: worktree))
                worktreeAction("Show in Finder", icon: "folder") {
                    actions.reveal(worktree.url)
                }
                .disabled(worktree.isPrunable)
                .help(pathActionHelp(for: worktree))
                worktreeAction("Copy Path", icon: "doc.on.doc") {
                    actions.copyPath(worktree.url)
                }
                worktreeAction(worktree.isLocked ? "Unlock Worktree" : "Lock Worktree", icon: worktree.isLocked ? "lock.open" : "lock") {
                    toggleLock(for: worktree)
                }
                .help(lockHelp(for: worktree))
                worktreeAction("Remove Worktree…", icon: "trash", destructive: true) {
                    requestRemoval(for: worktree)
                }
                .help(removalHelp(for: worktree))
                if worktree.isPrunable {
                    worktreeAction("Repair Worktree Records", icon: "wrench.and.screwdriver") {
                        Task { await feature.repairWorktrees() }
                    }
                }
                worktreeAction("Prune Stale Records", icon: "trash.slash", destructive: worktree.isPrunable) {
                    worktreeConfirmation = .prune
                }
                .disabled(!feature.gitWorktrees.contains(where: \.isPrunable))
            }
        }
    }

    @ViewBuilder
    private func changesSection(_ worktree: GitWorktree) -> some View {
        if worktree.isPrunable {
            missingPathState
        } else if let inspection = matchingInspection(for: worktree) {
            if !inspection.hasLoadedChanges {
                inspectionState
            } else if inspection.changes.isEmpty {
                worktreeMessage(icon: "checkmark.circle", title: "No local changes", detail: "This worktree has no uncommitted changes.")
            } else {
                worktreeScrollableCard(title: "Changes") {
                    GitWorktreeRowsScrollView(snapshot: projectedChangesSnapshot)
                }
            }
        } else {
            inspectionState
        }
    }

    @ViewBuilder
    private func historySection(_ worktree: GitWorktree) -> some View {
        if worktree.isPrunable {
            missingPathState
        } else if let inspection = matchingInspection(for: worktree) {
            if inspection.commits.isEmpty {
                worktreeMessage(icon: "clock.arrow.circlepath", title: "No commits", detail: "No commits were found for this branch.")
            } else {
                worktreeScrollableCard(title: "Commit History") {
                    let query = historySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let snapshot = projectedHistorySnapshot
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Search commits", text: $historySearchText)
                            .textFieldStyle(.roundedBorder)
                            .font(Visual.body)
                        if snapshot.rows.isEmpty {
                            Text("No matching commits in the loaded history.")
                                .font(Visual.metadata)
                                .foregroundStyle(LitheTheme.secondaryText)
                                .padding(.vertical, 8)
                        } else {
                            GitWorktreeRowsScrollView(snapshot: snapshot)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if query.isEmpty && inspection.hasMoreCommits {
                            Button {
                                guard !isLoadingMoreHistory else { return }
                                isLoadingMoreHistory = true
                                Task {
                                    await feature.loadMoreWorktreeHistory(for: worktree)
                                    isLoadingMoreHistory = false
                                }
                            } label: {
                                HStack {
                                    Spacer()
                                    if isLoadingMoreHistory {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text("Load More")
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isLoadingMoreHistory)
                        }
                    }
                }
            }
        } else {
            inspectionState
        }
    }

    private func settingsSection(_ worktree: GitWorktree) -> some View {
        VStack(spacing: 12) {
            worktreeCard(title: "Worktree Settings") {
                informationRow("Protection", value: worktree.isLocked ? "Locked" : "Unlocked")
                worktreeAction(worktree.isLocked ? "Unlock Worktree" : "Lock Worktree", icon: worktree.isLocked ? "lock.open" : "lock") {
                    toggleLock(for: worktree)
                }
                .help(lockHelp(for: worktree))
            }
            worktreeCard(title: "Maintenance") {
                if worktree.isPrunable {
                    worktreeAction("Repair Worktree Records", icon: "wrench.and.screwdriver") {
                        Task { await feature.repairWorktrees() }
                    }
                }
                worktreeAction("Prune Stale Records", icon: "trash.slash") {
                    worktreeConfirmation = .prune
                }
                .disabled(!feature.gitWorktrees.contains(where: \.isPrunable))
            }
            worktreeCard(title: "Danger Zone") {
                worktreeAction("Remove Worktree…", icon: "trash", destructive: true) {
                    requestRemoval(for: worktree)
                }
                .help(removalHelp(for: worktree))
            }
        }
    }

    private func worktreeCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(LocalizedStringKey(title))
                .font(Visual.section)
                .foregroundStyle(LitheTheme.primaryText)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(LitheTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(LitheTheme.panelBorder, lineWidth: 1)
        }
    }

    private func worktreeScrollableCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(LocalizedStringKey(title))
                .font(Visual.section)
                .foregroundStyle(LitheTheme.primaryText)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Keep the native scrolling surface out of a SwiftUI mask. A rounded
        // clip on a card containing NSScrollView can force an offscreen
        // compositing pass for every wheel frame; the scroll view already
        // clips its document content to the viewport.
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(LitheTheme.raised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(LitheTheme.panelBorder, lineWidth: 1)
        }
    }

    private func informationRow(_ label: String, value: String) -> some View {
        informationRow(label) {
            Text(LocalizedStringKey(value))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func informationRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(LocalizedStringKey(label))
                .font(Visual.metadata)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 92, alignment: .leading)
            content()
                .font(Visual.body)
                .foregroundStyle(LitheTheme.primaryText)
            Spacer(minLength: 0)
        }
    }

    private func worktreeAction(
        _ title: String,
        icon: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                Text(LocalizedStringKey(title))
            } icon: {
                Image(systemName: icon)
            }
            .font(Visual.body)
            .foregroundStyle(destructive ? LitheTheme.error : LitheTheme.primaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .lithePointer()
        .disabled(feature.isPerformingWorktreeOperation)
    }

    private var staleWorktreeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(LitheTheme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(
                    format: String(localized: "%lld worktree records need attention"),
                    feature.gitWorktrees.filter(\.isPrunable).count
                ))
                    .font(Visual.bodyMedium)
                    .foregroundStyle(LitheTheme.primaryText)
                Text("A missing checkout can make the worktree list inaccurate.")
                    .font(Visual.metadata)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer()
            Button("Prune Stale Records") { worktreeConfirmation = .prune }
                .buttonStyle(.bordered)
                .lithePointer()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
        .background(LitheTheme.warning.opacity(0.10))
        .overlay(alignment: .top) {
            Rectangle().fill(LitheTheme.warning.opacity(0.25)).frame(height: 1)
        }
    }

    private var quickInfoPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Quick Information")
                    .font(Visual.section)
                Spacer()
                Image(systemName: "pin")
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Divider()
            if let worktree = selectedWorktree {
                VStack(alignment: .leading, spacing: 18) {
                    quickInformationRow("Type", value: worktree.isPrimary ? "Primary" : "Worktree", accent: true)
                    quickInformationRow("Path", value: worktree.path)
                    quickInformationRow("Branch", value: worktree.branchName ?? "Detached HEAD")
                    quickInformationRow("HEAD", value: worktree.shortHead, accent: true, monospaced: true)
                    quickInformationRow("State", value: statusText(worktree))
                    if let reason = worktree.lockReason ?? worktree.pruneReason {
                        quickInformationRow("Reason", value: reason)
                    }
                    Button {
                        actions.copyPath(worktree.url)
                    } label: {
                        Label("Copy worktree path", systemImage: "arrow.right")
                            .font(Visual.bodyMedium)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LitheTheme.link)
                    .lithePointer()
                }
                .padding(16)
            }
            Spacer()
        }
        .background(background.hasImage ? Color.clear : LitheTheme.sidebar)
    }

    private func quickInformationRow(
        _ label: String,
        value: String,
        accent: Bool = false,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(LocalizedStringKey(label))
                .font(Visual.metadata)
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 62, alignment: .leading)
            Text(LocalizedStringKey(value))
                .font(monospaced ? Visual.mono : Visual.body)
                .foregroundStyle(accent ? LitheTheme.link : LitheTheme.primaryText)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func worktreeStatusLabel(_ worktree: GitWorktree) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor(worktree))
                .frame(width: 8, height: 8)
            Text(LocalizedStringKey(statusText(worktree)))
                .font(Visual.metadata)
                .foregroundStyle(LitheTheme.primaryText)
        }
    }

    private func worktreeBadge(_ title: String, color: Color) -> some View {
        Text(LocalizedStringKey(title))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.11))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var filteredWorktrees: [GitWorktree] {
        projectedWorktrees.map(\.worktree)
    }

    private var worktreeListProjectionIdentity: WorktreeListProjectionIdentity {
        WorktreeListProjectionIdentity(
            worktreesVersion: feature.gitWorktreesVersion,
            inspectionVersion: feature.gitWorktreeInspectionVersion,
            currentChangeCount: feature.gitChanges.count,
            query: searchText
        )
    }

    private var worktreeHistoryProjectionIdentity: WorktreeHistoryProjectionIdentity {
        WorktreeHistoryProjectionIdentity(
            worktreeID: selectedWorktree?.id,
            inspectionVersion: feature.gitWorktreeInspectionVersion,
            query: historySearchText
        )
    }

    private var worktreeChangesProjectionIdentity: WorktreeChangesProjectionIdentity {
        WorktreeChangesProjectionIdentity(
            worktreeID: selectedWorktree?.id,
            inspectionVersion: feature.gitWorktreeInspectionVersion
        )
    }

    private var currentWorktreeHistoryProjectionIdentity: WorktreeHistoryProjectionIdentity {
        worktreeHistoryProjectionIdentity
    }

    private var selectedWorktree: GitWorktree? {
        if let selectedWorktreeID,
           let selected = feature.gitWorktrees.first(where: { $0.id == selectedWorktreeID }) {
            return selected
        }
        return feature.gitWorktrees.first(where: \.isCurrent) ?? feature.gitWorktrees.first
    }

    private func selectAvailableWorktree() {
        if let selectedWorktreeID,
           feature.gitWorktrees.contains(where: { $0.id == selectedWorktreeID }) {
            return
        }
        selectedWorktreeID = feature.gitWorktrees.first(where: \.isCurrent)?.id
            ?? feature.gitWorktrees.first?.id
    }

    private func statusText(_ worktree: GitWorktree) -> String {
        if worktree.isPrunable { return "Path Missing" }
        if worktree.isLocked { return "Locked" }
        if let inspection = matchingInspection(for: worktree), !inspection.changes.isEmpty {
            return "Modified"
        }
        if worktree.isCurrent && !feature.gitChanges.isEmpty { return "Modified" }
        if worktree.isCurrent { return "Current" }
        return "Available"
    }

    private func statusColor(_ worktree: GitWorktree) -> Color {
        if worktree.isPrunable { return LitheTheme.error }
        if worktree.isLocked { return LitheTheme.warning }
        if let inspection = matchingInspection(for: worktree), !inspection.changes.isEmpty {
            return LitheTheme.warning
        }
        if worktree.isCurrent && !feature.gitChanges.isEmpty { return LitheTheme.warning }
        return LitheTheme.success
    }

    private func localChangesDescription(for worktree: GitWorktree) -> String {
        let count: Int
        if let inspection = matchingInspection(for: worktree) {
            count = inspection.changes.count
        } else if worktree.isCurrent {
            count = feature.gitChanges.count
        } else {
            return "Loading…"
        }
        if count == 0 { return String(localized: "No changes") }
        return String(format: String(localized: "%lld changed files"), count)
    }

    private func matchingInspection(for worktree: GitWorktree) -> GitWorktreeInspection? {
        guard feature.gitWorktreeInspection?.worktreeID == worktree.id else { return nil }
        return feature.gitWorktreeInspection
    }

    @ViewBuilder
    private var inspectionState: some View {
        switch feature.gitWorktreeInspectionLoadState {
        case .idle, .loading:
            worktreeMessage(icon: "arrow.clockwise", title: "Loading worktree details", detail: "Reading changes and recent commits.")
        case .failed(let message):
            worktreeMessage(icon: "exclamationmark.triangle", title: "Could not inspect this worktree", detail: message)
        case .ready:
            worktreeMessage(icon: "arrow.clockwise", title: "Loading worktree details", detail: "Reading changes and recent commits.")
        }
    }

    private var missingPathState: some View {
        worktreeCard(title: "Checkout Path Missing") {
            Text("The checkout directory no longer exists. Repair moved worktree metadata or prune the stale Git record.")
                .font(Visual.body)
                .foregroundStyle(LitheTheme.secondaryText)
            HStack(spacing: 10) {
                worktreeAction("Repair Worktree Records", icon: "wrench.and.screwdriver") {
                    Task { await feature.repairWorktrees() }
                }
                worktreeAction("Prune Stale Records", icon: "trash.slash", destructive: true) {
                    worktreeConfirmation = .prune
                }
            }
        }
    }

    private func removalHelp(for worktree: GitWorktree) -> String {
        if worktree.isPrimary { return String(localized: "The primary worktree cannot be removed.") }
        if worktree.isCurrent { return String(localized: "The current worktree cannot be removed here.") }
        if worktree.isLocked { return String(localized: "Unlock the worktree before removing it.") }
        if worktree.isPrunable { return String(localized: "Prune the stale record instead.") }
        return ""
    }

    private func lockHelp(for worktree: GitWorktree) -> String {
        if worktree.isPrimary { return String(localized: "The primary worktree cannot be locked.") }
        if worktree.isPrunable { return String(localized: "Repair or prune the missing checkout before changing its lock.") }
        return ""
    }

    private func toggleLock(for worktree: GitWorktree) {
        if worktree.isPrimary {
            worktreeActionNotice = WorktreeActionNotice(message: String(localized: "The primary worktree cannot be locked."))
        } else if worktree.isPrunable {
            worktreeActionNotice = WorktreeActionNotice(message: String(localized: "Repair or prune the missing checkout before changing its lock."))
        } else {
            Task { await feature.setWorktreeLocked(worktree, locked: !worktree.isLocked) }
        }
    }

    private func requestRemoval(for worktree: GitWorktree) {
        let reason = removalHelp(for: worktree)
        if !reason.isEmpty {
            worktreeActionNotice = WorktreeActionNotice(message: reason)
        } else {
            worktreeConfirmation = .removal(worktree, force: false)
        }
    }

    private var worktreeConfirmationTitle: String {
        switch worktreeConfirmation {
        case .removal(_, force: true):
            String(localized: "Force remove worktree?")
        case .removal(_, force: false):
            String(localized: "Remove worktree?")
        case .prune:
            String(localized: "Prune stale worktree records?")
        case nil:
            String(localized: "Worktree action")
        }
    }

    private func pathActionHelp(for worktree: GitWorktree) -> String {
        worktree.isPrunable ? String(localized: "The checkout path does not exist") : ""
    }

    private func changeColor(_ change: GitChange) -> Color {
        switch change.kind {
        case .added: LitheTheme.success
        case .deleted, .conflicted: LitheTheme.error
        case .modified, .moved, .copied: LitheTheme.warning
        }
    }

    nonisolated private static func nativeStatusColor(
        for kind: GitChangeKind
    ) -> GitWorktreeRowsSnapshot.StatusColor {
        switch kind {
        case .added: .success
        case .deleted, .conflicted: .error
        case .modified, .moved, .copied: .warning
        }
    }

    @ViewBuilder
    private var listEmptyState: some View {
        switch feature.gitWorktreeLoadState {
        case .idle, .loading:
            worktreeMessage(icon: "arrow.clockwise", title: "Loading worktrees", detail: "Reading registered checkouts.")
        case .failed(let message):
            worktreeMessage(icon: "exclamationmark.triangle", title: "Worktrees are unavailable", detail: message)
        case .ready where !searchText.isEmpty:
            worktreeMessage(icon: "magnifyingglass", title: "No matches", detail: "Try a branch name or checkout path.")
        case .ready:
            worktreeMessage(icon: "point.3.connected.trianglepath.dotted", title: "No worktrees", detail: "Create a checkout to get started.")
        }
    }

    private var detailEmptyState: some View {
        worktreeMessage(icon: "point.3.connected.trianglepath.dotted", title: "Select a worktree", detail: "Its details and actions will appear here.")
    }

    private func worktreeMessage(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(LocalizedStringKey(title))
                .font(Visual.section)
                .foregroundStyle(LitheTheme.primaryText)
            Text(LocalizedStringKey(detail))
                .font(Visual.metadata)
                .foregroundStyle(LitheTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WorktreeListProjectionIdentity: Hashable {
    let worktreesVersion: Int
    let inspectionVersion: Int
    let currentChangeCount: Int
    let query: String
}

private struct WorktreeHistoryProjectionIdentity: Hashable {
    let worktreeID: String?
    let inspectionVersion: Int
    let query: String
}

private struct WorktreeChangesProjectionIdentity: Hashable {
    let worktreeID: String?
    let inspectionVersion: Int
}

private struct GitWorktreeCreateView: View {
    @Environment(\.dismiss) private var dismiss
    let repositoryRoot: URL
    let references: [GitReference]
    let currentReference: GitReference?
    let actions: GitWorktreeActions
    let onSubmit: (String, GitReference, String?, URL) -> Void

    @State private var branchName = ""
    @State private var selectedReferenceID = ""
    @State private var destinationPath = ""
    @State private var destinationWasEdited = false
    @State private var revision = ""
    @State private var useAIWorktreeDirectory = false
    @FocusState private var branchFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("New Worktree")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Text("Create an independent checkout and a new branch from the selected reference.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Start from")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                Picker("Start from", selection: $selectedReferenceID) {
                    ForEach(references) { reference in
                        Text(reference.shortName).tag(reference.id)
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("New branch")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                TextField("feature/my-task", text: $branchName)
                    .textFieldStyle(.roundedBorder)
                    .focused($branchFieldFocused)
                    .onChange(of: branchName) { _ in updateSuggestedDestination() }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Checkout path")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                HStack(spacing: 8) {
                    TextField("Worktree destination", text: destinationBinding)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose Parent…") {
                        guard let parent = actions.chooseParentDirectory() else { return }
                        destinationWasEdited = true
                        destinationPath = parent.appendingPathComponent(suggestedDirectoryName).path
                    }
                    .lithePointer()
                }
                Toggle("Use AI worktree directory (/private/tmp)", isOn: $useAIWorktreeDirectory)
                    .toggleStyle(.checkbox)
                    .onChange(of: useAIWorktreeDirectory) { _ in
                        destinationWasEdited = false
                        updateSuggestedDestination(force: true)
                    }
                Text("Recommended: keep worktrees in a persistent folder next to the repository. You can choose /private/tmp manually for disposable checkouts.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Starting commit (optional)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                TextField("Use the selected branch tip", text: $revision)
                    .textFieldStyle(.roundedBorder)
                Text("Enter a commit hash to create the new branch from that exact point.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.tertiaryText)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .lithePointer()
                Button("Create") {
                    guard let selectedReference else { return }
                    onSubmit(trimmedBranchName, selectedReference, revision.isEmpty ? nil : revision, URL(fileURLWithPath: destinationPath))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(LitheTheme.accent)
                .keyboardShortcut(.defaultAction)
                .lithePointer()
                .disabled(trimmedBranchName.isEmpty || destinationPath.isEmpty || selectedReference == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(LitheTheme.raised)
        .onAppear {
            selectedReferenceID = currentReference?.id ?? references.first?.id ?? ""
            updateSuggestedDestination(force: true)
            branchFieldFocused = true
        }
    }

    private var selectedReference: GitReference? {
        references.first(where: { $0.id == selectedReferenceID })
    }

    private var destinationBinding: Binding<String> {
        Binding(
            get: { destinationPath },
            set: {
                destinationPath = $0
                destinationWasEdited = true
            }
        )
    }

    private var trimmedBranchName: String {
        branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var suggestedDirectoryName: String {
        let leaf = trimmedBranchName
            .split(separator: "/")
            .last
            .map(String.init) ?? "worktree"
        let safeLeaf = leaf.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "-"
        }
        return "\(repositoryRoot.lastPathComponent)-\(String(safeLeaf))"
    }

    private func updateSuggestedDestination(force: Bool = false) {
        guard force || !destinationWasEdited else { return }
        let parent = useAIWorktreeDirectory
            ? URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            : repositoryRoot.deletingLastPathComponent()
        destinationPath = parent
            .appendingPathComponent(suggestedDirectoryName)
            .path
        destinationWasEdited = false
    }
}
