import SwiftUI
import LitheGitModule

struct GitWorktreeActions {
    let openProject: (URL) -> Void
    let reveal: (URL) -> Void
    let copyPath: (URL) -> Void
    let chooseParentDirectory: () -> URL?
}

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
        .background(background.hasImage ? Color.clear : LitheTheme.editor)
        .task(id: feature.gitRepositoryRoot) {
            await feature.refreshWorktrees()
            selectAvailableWorktree()
        }
        .task(id: selectedWorktree?.id) {
            guard let worktree = selectedWorktree, !worktree.isPrunable else { return }
            await feature.inspectWorktree(worktree)
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
                    chooseParentDirectory: actions.chooseParentDirectory
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
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(filteredWorktrees) { worktree in
                            worktreeListRow(worktree)
                        }
                    }
                    .padding(10)
                }
                .litheScrollViewChrome()
            }
        }
        .background(background.hasImage ? Color.clear : LitheTheme.sidebar)
    }

    private func worktreeListRow(_ worktree: GitWorktree) -> some View {
        let isSelected = selectedWorktree?.id == worktree.id
        return Button {
            selectedWorktreeID = worktree.id
            activeSection = .overview
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(worktree.isPrimary ? String(localized: "Main Worktree") : worktree.displayName)
                        .font(Visual.bodyMedium)
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                    if worktree.isPrimary {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(LitheTheme.warning)
                    }
                    if worktree.isCurrent {
                        worktreeBadge("Current", color: LitheTheme.accent)
                    }
                    Spacer(minLength: 6)
                    worktreeStatusLabel(worktree)
                    Image(systemName: "ellipsis")
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Text(worktree.path)
                    .font(Visual.metadata)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(String(
                    format: String(localized: "Branch: %@"),
                    worktree.branchName ?? String(localized: "Detached HEAD")
                ))
                    .font(Visual.metadata)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? LitheTheme.subtleSelection : LitheTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? LitheTheme.inputFocusBorder : LitheTheme.panelBorder, lineWidth: 1)
        }
        .lithePointer()
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
        ScrollView {
            switch activeSection {
            case .overview:
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        basicInformationCard(worktree)
                        statusCard(worktree)
                    }
                    actionCard(worktree)
                }
            case .changes:
                changesSection(worktree)
            case .history:
                historySection(worktree)
            case .settings:
                settingsSection(worktree)
            }
        }
        .padding(14)
        .litheScrollViewChrome()
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
                worktreeCard(title: "Changes") {
                    VStack(spacing: 0) {
                        ForEach(inspection.changes) { change in
                            HStack(spacing: 10) {
                                Text(change.displayStatus)
                                    .font(Visual.mono)
                                    .foregroundStyle(changeColor(change))
                                    .frame(width: 22)
                                Text(change.path)
                                    .font(Visual.body)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(LocalizedStringKey(change.isStaged ? "Staged" : "Unstaged"))
                                    .font(Visual.metadata)
                                    .foregroundStyle(LitheTheme.secondaryText)
                            }
                            .padding(.vertical, 9)
                            if change.id != inspection.changes.last?.id { Divider() }
                        }
                    }
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
                worktreeCard(title: "Commit History") {
                    let query = historySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let commits = query.isEmpty ? inspection.commits : inspection.commits.filter {
                        $0.subject.localizedCaseInsensitiveContains(query)
                            || $0.authorName.localizedCaseInsensitiveContains(query)
                            || $0.hash.localizedCaseInsensitiveContains(query)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Search commits", text: $historySearchText)
                            .textFieldStyle(.roundedBorder)
                            .font(Visual.body)
                        if commits.isEmpty {
                            Text("No matching commits in the loaded history.")
                                .font(Visual.metadata)
                                .foregroundStyle(LitheTheme.secondaryText)
                                .padding(.vertical, 8)
                        }
                        VStack(spacing: 0) {
                        ForEach(commits) { commit in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 7))
                                    .foregroundStyle(LitheTheme.accent)
                                Text(commit.subject)
                                    .font(Visual.bodyMedium)
                                    .foregroundStyle(LitheTheme.primaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                                Text(commit.authorName)
                                    .font(Visual.metadata)
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .lineLimit(1)
                                Text(commit.date)
                                    .font(Visual.metadata)
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 8)
                            if commit.id != commits.last?.id { Divider() }
                        }
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
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return feature.gitWorktrees }
        return feature.gitWorktrees.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
                || ($0.branchName?.localizedCaseInsensitiveContains(query) ?? false)
        }
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

private struct GitWorktreeCreateView: View {
    @Environment(\.dismiss) private var dismiss
    let repositoryRoot: URL
    let references: [GitReference]
    let currentReference: GitReference?
    let chooseParentDirectory: () -> URL?
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
                        guard let parent = chooseParentDirectory() else { return }
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
