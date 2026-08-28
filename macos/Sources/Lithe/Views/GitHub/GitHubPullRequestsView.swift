import SwiftUI
import LitheCoreContracts

private enum GitHubDetailSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case files = "Files"
    case conversation = "Conversation"

    var id: String { rawValue }
    var title: LocalizedStringKey { LocalizedStringKey(rawValue) }
}

private enum GitHubReviewAction: String, CaseIterable, Identifiable {
    case comment = "Comment"
    case approve = "Approve"
    case requestChanges = "Request changes"

    var id: String { rawValue }
    var title: LocalizedStringKey { LocalizedStringKey(rawValue) }

    var event: String? {
        switch self {
        case .comment: nil
        case .approve: "APPROVE"
        case .requestChanges: "REQUEST_CHANGES"
        }
    }

    var buttonTitle: LocalizedStringKey {
        switch self {
        case .comment: "Comment"
        case .approve: "Approve pull request"
        case .requestChanges: "Request changes"
        }
    }
}

private enum GitHubMergeChoice: String, Identifiable {
    case merge
    case squash
    case rebase

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .merge: "Create a merge commit"
        case .squash: "Squash and merge"
        case .rebase: "Rebase and merge"
        }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .merge: "Preserves every commit and adds a merge commit to the base branch."
        case .squash: "Combines the pull request into one commit on the base branch."
        case .rebase: "Replays every commit onto the base branch without a merge commit."
        }
    }
}

struct GitHubPullRequestsSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchQuery = ""

    var body: some View {
        Group {
            if LitheFeatureAvailability.githubPullRequests {
                VStack(spacing: 0) {
                    LitheToolWindowHeader(title: "Pull Requests") {
                        if case .connected = model.githubFeature.connectionState {
                            Button {
                                Task { await model.githubFeature.refresh(workspaceURL: model.workspaceURL) }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .litheIconButton()
                            .disabled(isContentLoading)
                            .help("Refresh pull requests")
                        }
                    }
                    Rectangle().fill(LitheTheme.divider).frame(height: 1)
                    content
                }
            } else {
                GitHubFeatureUnavailableView()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.githubFeature.connectionState {
        case .restoring:
            GitHubCenteredProgress(
                title: "Restoring GitHub connection",
                detail: "Validating the credential stored in Keychain…"
            )
        case .disconnected:
            connectionForm(message: nil)
        case .failed(let message):
            connectionForm(message: message)
        case .authorizing(let authorization):
            authorizationView(authorization)
        case .connected(let user):
            connectedContent(user: user)
        }
    }

    private func connectionForm(message: String?) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 12) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 29, weight: .light))
                    .foregroundStyle(LitheTheme.accent)

                VStack(spacing: 5) {
                    Text("Sign in to GitHub")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Sign in to view and manage pull requests.")
                        .font(.system(size: 12))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Sign in to GitHub") {
                    Task { await model.connectGitHubWithDeviceFlow() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: 220)

                if message != nil {
                    Text("Unable to sign in. Please try again.")
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.error)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 300)
            .padding(.horizontal, 24)

            Spacer(minLength: 24)
        }
    }

    private func authorizationView(_ authorization: GitHubDeviceAuthorization) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Authorize in your browser")
                    .font(.system(size: 18, weight: .semibold))
                Text("The verification page is open and the code is already on your clipboard.")
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("ONE-TIME CODE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(LitheTheme.tertiaryText)
                HStack {
                    Text(authorization.userCode)
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        model.platformUI.copyToClipboard(authorization.userCode)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .litheIconButton()
                    .help("Copy code")
                }
                .padding(12)
                .background(LitheTheme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(LitheTheme.inputBorder))
            }

            authorizationSteps

            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for GitHub…")
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Button("Open again") {
                    if let url = URL(string: authorization.verificationURI) {
                        model.platformUI.open(url)
                    }
                }
                Button("Cancel") { Task { await model.disconnectGitHub() } }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var authorizationSteps: some View {
        VStack(alignment: .leading, spacing: 9) {
            GitHubAuthorizationStep(number: 1, title: "Open GitHub", isComplete: true)
            GitHubAuthorizationStep(number: 2, title: "Enter the one-time code", isComplete: false)
            GitHubAuthorizationStep(number: 3, title: "Return to Lithe", isComplete: false)
        }
    }

    private func connectedContent(user: GitHubUser) -> some View {
        VStack(spacing: 0) {
            accountHeader(user)
            filters
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            pullRequestList
        }
    }

    private func accountHeader(_ user: GitHubUser) -> some View {
        HStack(spacing: 9) {
            GitHubIdentityMark(login: user.login, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Group {
                    if let repository = model.githubFeature.repository {
                        Text(repository.fullName)
                    } else {
                        Text("No GitHub origin")
                    }
                }
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                Text("Connected as @\(user.login)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer(minLength: 4)
            Menu {
                if let url = URL(string: user.url), !user.url.isEmpty {
                    Button("Open GitHub profile") { model.platformUI.open(url) }
                }
                Divider()
                Button("Disconnect", role: .destructive) {
                    Task { await model.disconnectGitHub() }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.horizontal, 11)
        .frame(height: 46)
        .background(LitheTheme.toolHeader)
    }

    private var filters: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Picker("State", selection: Binding(
                    get: { model.githubFeature.listState },
                    set: { value in
                        model.githubFeature.listState = value
                        Task { await model.githubFeature.refresh(workspaceURL: model.workspaceURL) }
                    }
                )) {
                    Text("Open").tag("open")
                    Text("Closed").tag("closed")
                    Text("All").tag("all")
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Button { model.githubFeature.beginCreatingPullRequest() } label: {
                    Label("Create pull request", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.githubFeature.repository == nil)
                .help("Create pull request")
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(LitheTheme.tertiaryText)
                TextField("Filter by title, author, or label", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LitheTheme.tertiaryText)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(LitheTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(LitheTheme.inputBorder))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var pullRequestList: some View {
        if isContentLoading, model.githubFeature.pullRequests.isEmpty {
            GitHubCenteredProgress(title: "Loading pull requests", detail: nil)
        } else if case .failed(let message) = model.githubFeature.contentState {
            GitHubEmptyState(
                icon: "exclamationmark.triangle",
                title: "Pull requests unavailable",
                message: message,
                actionTitle: "Try Again"
            ) {
                Task { await model.githubFeature.refresh(workspaceURL: model.workspaceURL) }
            }
        } else if filteredPullRequests.isEmpty {
            GitHubEmptyState(
                icon: searchQuery.isEmpty ? "arrow.triangle.pull" : "magnifyingglass",
                title: searchQuery.isEmpty ? "No pull requests" : "No matches",
                message: searchQuery.isEmpty
                    ? "No pull requests match the selected state."
                    : "Try another title, author, number, or label."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredPullRequests) { request in
                        GitHubPullRequestRow(
                            request: request,
                            isSelected: model.githubFeature.selectedPullRequest?.number == request.number
                        ) {
                            model.githubFeature.clearOperationStatus()
                            Task { await model.githubFeature.selectPullRequest(number: request.number) }
                        }
                    }
                }
                .padding(5)
            }
            .overlay(alignment: .top) {
                if isContentLoading {
                    ProgressView().controlSize(.small).padding(.top, 6)
                }
            }
        }
    }

    private var filteredPullRequests: [GitHubPullRequest] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.githubFeature.pullRequests }
        return model.githubFeature.pullRequests.filter { request in
            request.title.lowercased().contains(query)
                || request.author.login.lowercased().contains(query)
                || String(request.number).contains(query)
                || request.labels.contains { $0.name.lowercased().contains(query) }
        }
    }

    private var isContentLoading: Bool {
        if case .loading = model.githubFeature.contentState { return true }
        return false
    }

}

struct GitHubPullRequestDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedSection = GitHubDetailSection.overview
    @State private var composerAction = GitHubReviewAction.comment
    @State private var composerBody = ""
    @State private var labels = ""
    @State private var assignees = ""
    @State private var isEditPresented = false
    @State private var shouldConfirmClose = false
    @State private var pendingMergeChoice: GitHubMergeChoice?

    var body: some View {
        Group {
            if !LitheFeatureAvailability.githubPullRequests {
                GitHubFeatureUnavailableView()
            } else if model.githubFeature.isCreatingPullRequest {
                GitHubCreatePullRequestWorkspaceView()
            } else if let request = model.githubFeature.selectedPullRequest {
                detail(request)
            } else {
                GitHubEmptyState(
                    icon: "arrow.triangle.pull",
                    title: "Select a pull request",
                    message: "Choose a pull request to review its context, files, and conversation."
                )
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .animation(.easeOut(duration: 0.16), value: model.githubFeature.isCreatingPullRequest)
        .animation(.easeOut(duration: 0.16), value: model.githubFeature.selectedPullRequest?.number)
    }

    private func detail(_ request: GitHubPullRequest) -> some View {
        VStack(spacing: 0) {
            detailHeader(request)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            sectionBar(request)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            operationBanner
            sectionContent(request)
                .id("\(request.number)-\(selectedSection.rawValue)")
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
        .onAppear { loadMetadata(request) }
        .onChange(of: request.number) { _ in
            selectedSection = .overview
            loadMetadata(request)
        }
        .animation(.easeOut(duration: 0.16), value: model.githubFeature.operationState)
        .sheet(isPresented: $isEditPresented) {
            GitHubEditPullRequestView(request: request, isPresented: $isEditPresented)
                .environmentObject(model)
        }
        .confirmationDialog(
            LocalizedStringKey(
                request.state == "open"
                    ? "Close pull request?"
                    : "Reopen pull request?"
            ),
            isPresented: $shouldConfirmClose,
            titleVisibility: .visible
        ) {
            Button(
                LocalizedStringKey(request.state == "open" ? "Close Pull Request" : "Reopen Pull Request"),
                role: request.state == "open" ? .destructive : nil
            ) {
                Task { await model.githubFeature.setOpen(request.state != "open") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(
                request.state == "open"
                    ? "This does not delete the branch or commits. The pull request can be reopened later."
                    : "The pull request will return to the open list and can receive new reviews."
            ))
        }
        .confirmationDialog(
            pendingMergeChoice?.title ?? "Merge pull request?",
            isPresented: Binding(
                get: { pendingMergeChoice != nil },
                set: { if !$0 { pendingMergeChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingMergeChoice?.title ?? "Merge") {
                guard let choice = pendingMergeChoice else { return }
                pendingMergeChoice = nil
                Task { _ = await model.githubFeature.merge(method: choice.rawValue) }
            }
            Button("Cancel", role: .cancel) { pendingMergeChoice = nil }
        } message: {
            if let choice = pendingMergeChoice {
                Text(choice.explanation)
                    + Text(" This updates \(request.baseRef) on GitHub and cannot be undone from Lithe.")
            }
        }
    }

    private func detailHeader(_ request: GitHubPullRequest) -> some View {
        HStack(spacing: 12) {
            GitHubStateMark(request: request)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(request.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text("#\(request.number)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(LitheTheme.tertiaryText)
                }
                HStack(spacing: 5) {
                    Text(request.headRef)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(request.baseRef)
                    Text("·")
                    Text("@\(request.author.login)")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button("Checkout") { Task { await model.checkoutSelectedPullRequest() } }
                .disabled(isOperationRunning)
            Button {
                if let url = URL(string: request.url) { model.platformUI.open(url) }
            } label: {
                Label("GitHub", systemImage: "arrow.up.right.square")
            }
            Menu {
                Button("Edit title and description") { isEditPresented = true }
                if !request.isMerged {
                    Button(LocalizedStringKey(request.state == "open" ? "Close pull request" : "Reopen pull request")) {
                        shouldConfirmClose = true
                    }
                }
                if request.state == "open", !request.isMerged, !request.isDraft {
                    Divider()
                    Button("Create a merge commit") { pendingMergeChoice = .merge }
                    Button("Squash and merge") { pendingMergeChoice = .squash }
                    Button("Rebase and merge") { pendingMergeChoice = .rebase }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 26)
            .disabled(isOperationRunning)
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private func sectionBar(_ request: GitHubPullRequest) -> some View {
        HStack(spacing: 3) {
            ForEach(GitHubDetailSection.allCases) { section in
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { selectedSection = section }
                } label: {
                    HStack(spacing: 5) {
                        Text(section.title)
                        if section == .files {
                            Text("\(model.githubFeature.files.count)")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(LitheTheme.badgeBackground)
                                .clipShape(Capsule())
                        } else if section == .conversation {
                            Text("\(model.githubFeature.comments.count)")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(LitheTheme.badgeBackground)
                                .clipShape(Capsule())
                        }
                    }
                    .font(.system(size: 11.5, weight: selectedSection == section ? .semibold : .regular))
                    .foregroundStyle(selectedSection == section ? LitheTheme.primaryText : LitheTheme.secondaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(selectedSection == section ? LitheTheme.subtleSelection : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .lithePointer()
            }
            Spacer()
            if request.isMergeable == false, request.state == "open" {
                Label("Conflicts", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LitheTheme.warning)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    @ViewBuilder
    private var operationBanner: some View {
        switch model.githubFeature.operationState {
        case .idle:
            EmptyView()
        case .running(let message):
            GitHubOperationBanner(icon: nil, color: LitheTheme.accent, message: message, isProgress: true)
        case .succeeded(let message):
            GitHubOperationBanner(icon: "checkmark.circle.fill", color: LitheTheme.success, message: message) {
                model.githubFeature.clearOperationStatus()
            }
        case .failed(let message):
            GitHubOperationBanner(icon: "exclamationmark.triangle.fill", color: LitheTheme.error, message: message) {
                model.githubFeature.clearOperationStatus()
            }
        }
    }

    @ViewBuilder
    private func sectionContent(_ request: GitHubPullRequest) -> some View {
        switch selectedSection {
        case .overview:
            overview(request)
        case .files:
            filesView
        case .conversation:
            conversationView(request)
        }
    }

    private func overview(_ request: GitHubPullRequest) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GitHubMetricsStrip(request: request)

                GitHubSection(title: "Description") {
                    if request.body.isEmpty {
                        Text("No description provided.")
                            .foregroundStyle(LitheTheme.tertiaryText)
                            .italic()
                    } else {
                        Text(request.body)
                            .textSelection(.enabled)
                            .lineSpacing(3)
                    }
                }

                GitHubSection(title: "Labels and assignees", detail: "Saving replaces the current GitHub metadata.") {
                    VStack(spacing: 10) {
                        GitHubLabeledField(title: "Labels", placeholder: "bug, macOS, ready for review", text: $labels)
                        GitHubLabeledField(title: "Assignees", placeholder: "octocat, monalisa", text: $assignees)
                        HStack {
                            Spacer()
                            Button("Save Metadata") {
                                Task {
                                    _ = await model.githubFeature.updateMetadata(
                                        labels: commaSeparated(labels),
                                        assignees: commaSeparated(assignees)
                                    )
                                }
                            }
                            .disabled(isOperationRunning || !metadataChanged(from: request))
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var filesView: some View {
        Group {
            if model.githubFeature.files.isEmpty {
                GitHubEmptyState(
                    icon: "doc.text.magnifyingglass",
                    title: "No changed files",
                    message: "GitHub did not return any file changes for this pull request."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.githubFeature.files) { file in
                            GitHubFileRow(file: file)
                            Rectangle().fill(LitheTheme.divider).frame(height: 1)
                        }
                    }
                    .frame(maxWidth: 980)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func conversationView(_ request: GitHubPullRequest) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.githubFeature.comments.isEmpty {
                    GitHubInlineNotice(
                        icon: "bubble.left",
                        color: LitheTheme.secondaryText,
                        title: "No conversation yet",
                        message: "Start the discussion or submit the first review."
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.githubFeature.comments.enumerated()), id: \.element.id) { index, comment in
                            GitHubCommentRow(
                                comment: comment,
                                showsRail: index < model.githubFeature.comments.count - 1,
                                onOpen: {
                                    if let url = URL(string: comment.url) {
                                        model.platformUI.open(url)
                                    }
                                }
                            )
                        }
                    }
                }

                GitHubSection(title: "Leave a review", detail: reviewDetail) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Review action", selection: $composerAction) {
                            ForEach(GitHubReviewAction.allCases) { action in
                                Text(action.title).tag(action)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $composerBody)
                                .font(.system(size: 12))
                                .scrollContentBackground(.hidden)
                                .padding(5)
                                .frame(minHeight: 112)
                            if composerBody.isEmpty {
                                Text(LocalizedStringKey(
                                    composerAction == .approve
                                        ? "Optional approval summary"
                                        : "Write a clear, actionable comment…"
                                ))
                                    .font(.system(size: 12))
                                    .foregroundStyle(LitheTheme.tertiaryText)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 12)
                                    .allowsHitTesting(false)
                            }
                        }
                        .background(LitheTheme.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.inputBorder))

                        HStack {
                            Text("Markdown is supported on GitHub")
                                .font(.system(size: 9.5))
                                .foregroundStyle(LitheTheme.tertiaryText)
                            Spacer()
                            Button(composerAction.buttonTitle) { submitComposer() }
                                .buttonStyle(.borderedProminent)
                                .disabled(!canSubmitComposer || isOperationRunning)
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func submitComposer() {
        let body = composerBody.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let succeeded: Bool
            if let event = composerAction.event {
                succeeded = await model.githubFeature.submitReview(event: event, body: body)
            } else {
                succeeded = await model.githubFeature.addComment(body)
            }
            if succeeded { composerBody = "" }
        }
    }

    private func loadMetadata(_ request: GitHubPullRequest) {
        labels = request.labels.map(\.name).joined(separator: ", ")
        assignees = request.assignees.map(\.login).joined(separator: ", ")
    }

    private func metadataChanged(from request: GitHubPullRequest) -> Bool {
        commaSeparated(labels) != request.labels.map(\.name)
            || commaSeparated(assignees) != request.assignees.map(\.login)
    }

    private func commaSeparated(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var canSubmitComposer: Bool {
        let hasBody = !composerBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if composerAction == .comment { return hasBody }
        guard model.githubFeature.selectedPullRequest?.state == "open" else { return false }
        return composerAction == .approve || hasBody
    }

    private var reviewDetail: String {
        switch composerAction {
        case .comment: "Adds to the pull request conversation without an approval decision."
        case .approve: "Signals that the changes are ready to merge. A summary is optional."
        case .requestChanges: "Explain what must change before this pull request can be approved."
        }
    }

    private var isOperationRunning: Bool {
        if case .running = model.githubFeature.operationState { return true }
        return false
    }
}

struct GitHubFeatureUnavailableView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(LitheTheme.secondaryText)
            Text("Pull Requests integration is under development")
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)
            Text("GitHub sign-in and pull request management are temporarily unavailable.")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .litheWorkbenchSurface(LitheTheme.editor)
        .accessibilityElement(children: .combine)
    }
}

private struct GitHubPullRequestRow: View {
    let request: GitHubPullRequest
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                GitHubStateMark(request: request, compact: true)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(request.title)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Text("#\(request.number)")
                            .monospacedDigit()
                        Text("@\(request.author.login)")
                        Spacer(minLength: 2)
                        GitHubRelativeDate(value: request.updatedAt)
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    if !request.labels.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(request.labels.prefix(2), id: \.name) { label in
                                GitHubPill(text: label.name, color: LitheTheme.secondaryText)
                            }
                            if request.labels.count > 2 {
                                Text("+\(request.labels.count - 2)")
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(LitheTheme.tertiaryText)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
        .litheRowHover(
            isActive: isSelected,
            activeBackground: LitheTheme.subtleSelection
        )
    }
}

private struct GitHubStateMark: View {
    let request: GitHubPullRequest
    var compact = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: compact ? 12 : 16, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: compact ? 15 : 24, height: compact ? 15 : 24)
            .help(Text(LocalizedStringKey(statusText)))
    }

    private var symbol: String {
        if request.isMerged { return "arrow.triangle.merge" }
        if request.isDraft { return "circle.dashed" }
        if request.state == "closed" { return "xmark.circle.fill" }
        return "arrow.triangle.pull"
    }

    private var color: Color {
        if request.isMerged { return LitheTheme.skill }
        if request.isDraft { return LitheTheme.secondaryText }
        if request.state == "closed" { return LitheTheme.error }
        return LitheTheme.success
    }

    private var statusText: String {
        if request.isMerged { return "Merged" }
        if request.isDraft { return "Draft" }
        return request.state.capitalized
    }
}

private struct GitHubMetricsStrip: View {
    let request: GitHubPullRequest

    var body: some View {
        HStack(spacing: 0) {
            metric(title: "Status", value: status, localizesValue: true)
            divider
            metric(title: "Files", value: request.changedFiles.map(String.init) ?? "—")
            divider
            metric(title: "Additions", value: request.additions.map { "+\($0)" } ?? "—", color: LitheTheme.success)
            divider
            metric(title: "Deletions", value: request.deletions.map { "−\($0)" } ?? "—", color: LitheTheme.error)
            divider
            metric(title: "Comments", value: "\(request.commentsCount)")
        }
        .padding(.vertical, 11)
        .background(LitheTheme.sidebar.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func metric(
        title: String,
        value: String,
        color: Color = LitheTheme.primaryText,
        localizesValue: Bool = false
    ) -> some View {
        VStack(spacing: 3) {
            Group {
                if localizesValue {
                    Text(LocalizedStringKey(value))
                } else {
                    Text(value)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            Text(LocalizedStringKey(title))
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(LitheTheme.tertiaryText)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(LitheTheme.divider).frame(width: 1, height: 25)
    }

    private var status: String {
        if request.isMerged { return "Merged" }
        if request.isDraft { return "Draft" }
        return request.state.capitalized
    }
}

private struct GitHubSection<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let content: () -> Content

    init(title: String, detail: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(LocalizedStringKey(detail))
                        .font(.system(size: 10.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }
            content()
        }
    }
}

private struct GitHubLabeledField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 72, alignment: .trailing)
            TextField(LocalizedStringKey(placeholder), text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct GitHubFileRow: View {
    let file: GitHubPullRequestFile
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                guard file.patch != nil else { return }
                withAnimation(.easeOut(duration: 0.14)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: file.patch == nil ? "doc" : (isExpanded ? "chevron.down" : "chevron.right"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .frame(width: 12)
                    Text(file.path)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                    GitHubPill(text: file.status.capitalized, color: statusColor, localizesText: true)
                    Spacer()
                    Text("+\(file.additions)").foregroundStyle(LitheTheme.success)
                    Text("−\(file.deletions)").foregroundStyle(LitheTheme.error)
                }
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 15)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()

            if isExpanded, let patch = file.patch {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(patch)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(LitheTheme.inputBackground)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var statusColor: Color {
        switch file.status {
        case "added": LitheTheme.success
        case "removed": LitheTheme.error
        default: LitheTheme.warning
        }
    }
}

private struct GitHubCommentRow: View {
    let comment: GitHubComment
    let showsRail: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 0) {
                GitHubIdentityMark(login: comment.author.login, size: 27)
                if showsRail {
                    Rectangle().fill(LitheTheme.divider).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("@\(comment.author.login)")
                        .font(.system(size: 11.5, weight: .semibold))
                    GitHubRelativeDate(value: comment.updatedAt)
                        .font(.system(size: 9.5))
                        .foregroundStyle(LitheTheme.tertiaryText)
                    Spacer()
                    if !comment.url.isEmpty {
                        Button(action: onOpen) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(LitheTheme.tertiaryText)
                    }
                }
                Text(comment.body)
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, showsRail ? 18 : 0)
        }
    }
}

private struct GitHubIdentityMark: View {
    let login: String
    let size: CGFloat

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.34, weight: .bold))
            .foregroundStyle(LitheTheme.primaryText)
            .frame(width: size, height: size)
            .background(LitheTheme.badgeBackground)
            .clipShape(Circle())
            .overlay(Circle().stroke(LitheTheme.panelBorder))
            .accessibilityLabel("GitHub user \(login)")
    }

    private var initials: String {
        String(login.prefix(2)).uppercased()
    }
}

private struct GitHubPill: View {
    let text: String
    let color: Color
    var localizesText = false

    var body: some View {
        Group {
            if localizesText {
                Text(LocalizedStringKey(text))
            } else {
                Text(text)
            }
        }
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.11))
            .clipShape(Capsule())
            .lineLimit(1)
    }
}

private struct GitHubRelativeDate: View {
    @Environment(\.locale) private var locale
    let value: String

    var body: some View {
        Text(relativeText)
            .help(value)
    }

    private var relativeText: String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct GitHubOperationBanner: View {
    let icon: String?
    let color: Color
    let message: String
    var isProgress = false
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if isProgress {
                ProgressView().controlSize(.small)
            } else if let icon {
                Image(systemName: icon).foregroundStyle(color)
            }
            Text(LocalizedStringKey(message))
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(2)
            Spacer()
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .litheIconButton()
                    .help("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .background(color.opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(color.opacity(0.2)).frame(height: 1) }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct GitHubInlineNotice<Actions: View>: View {
    let icon: String
    let color: Color
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    init(
        icon: String,
        color: Color,
        title: String,
        message: String,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.icon = icon
        self.color = color
        self.title = title
        self.message = message
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(.system(size: 11.5, weight: .semibold))
                localizedMessage
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var localizedMessage: some View {
        let authorizationFailurePrefix = "GitHub authorization failed: "
        if message.hasPrefix(authorizationFailurePrefix) {
            Text("GitHub authorization failed:")
                + Text(" ")
                + Text(message.dropFirst(authorizationFailurePrefix.count))
        } else {
            Text(LocalizedStringKey(message))
        }
    }
}

private struct GitHubAuthorizationStep: View {
    let number: Int
    let title: String
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(isComplete ? LitheTheme.success : LitheTheme.secondaryText)
            Text(LocalizedStringKey(title))
                .font(.system(size: 11.5, weight: isComplete ? .medium : .regular))
                .foregroundStyle(isComplete ? LitheTheme.primaryText : LitheTheme.secondaryText)
        }
    }
}

private struct GitHubCenteredProgress: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(LocalizedStringKey(title)).font(.system(size: 12, weight: .semibold))
            if let detail {
                Text(LocalizedStringKey(detail))
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GitHubEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 27, weight: .light))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .semibold))
            Text(LocalizedStringKey(message))
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(LocalizedStringKey(actionTitle), action: action).padding(.top, 3)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GitHubEditPullRequestView: View {
    @EnvironmentObject private var model: AppModel
    let request: GitHubPullRequest
    @Binding var isPresented: Bool
    @State private var title: String
    @State private var descriptionText: String
    @State private var base: String

    init(request: GitHubPullRequest, isPresented: Binding<Bool>) {
        self.request = request
        _isPresented = isPresented
        _title = State(initialValue: request.title)
        _descriptionText = State(initialValue: request.body)
        _base = State(initialValue: request.baseRef)
    }

    var body: some View {
        GitHubPullRequestForm(
            heading: "Edit pull request",
            caption: "#\(request.number) · \(request.headRef) → \(request.baseRef)",
            title: $title,
            descriptionText: $descriptionText,
            head: nil,
            base: $base,
            draft: nil,
            primaryTitle: "Save Changes",
            isPrimaryDisabled: trimmedTitle.isEmpty || trimmedBase.isEmpty,
            cancel: { isPresented = false },
            submit: {
                Task {
                    if await model.githubFeature.updatePullRequest(
                        title: trimmedTitle,
                        body: descriptionText,
                        base: trimmedBase
                    ) {
                        isPresented = false
                    }
                }
            }
        )
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBase: String { base.trimmingCharacters(in: .whitespacesAndNewlines) }
}

private struct GitHubCreatePullRequestWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var title = ""
    @State private var descriptionText = ""
    @State private var head = ""
    @State private var base = ""
    @State private var draft = false
    @State private var isGeneratingDescription = false
    @State private var generationError: String?
    @State private var pendingGeneratedContent: PullRequestDescriptionOutput?
    @State private var isGeneratedContentConfirmationPresented = false
    @State private var publishBranchName = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case title
        case description
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeading
                comparisonCard
                creationCard
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .onExitCommand { model.githubFeature.cancelCreatingPullRequest() }
        .task {
            // The feature model immediately reuses a fresh branch cache and
            // refreshes stale data without hiding the existing choices.
            await model.githubFeature.loadBranches()
            applyPublicationDefaults()
            applyDefaultBranches(from: model.githubFeature.branches)
        }
        .onChange(of: model.githubFeature.branches) { branches in
            applyDefaultBranches(from: branches)
        }
        .onChange(of: model.githubFeature.pullRequestBranchDefaults) { _ in
            applyPublicationDefaults()
            applyDefaultBranches(from: model.githubFeature.branches)
        }
        .onAppear {
            applyPublicationDefaults()
            applyDefaultBranches(from: model.githubFeature.branches)
        }
        .confirmationDialog(
            "Apply AI-generated content?",
            isPresented: $isGeneratedContentConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Replace existing content") {
                applyGeneratedContent(replacingExisting: true)
            }
            Button("Keep existing content") {
                applyGeneratedContent(replacingExisting: false)
            }
            Button("Cancel", role: .cancel) {
                pendingGeneratedContent = nil
            }
        } message: {
            Text("The generated title or description would replace text you already entered.")
        }
    }

    private var pageHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Comparing changes")
                .font(.system(size: 24, weight: .semibold))
            Text("Choose a base and compare branch, then describe the pull request.")
                .font(.system(size: 12.5))
                .foregroundStyle(LitheTheme.secondaryText)
        }
    }

    private var comparisonCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.githubFeature.pullRequestBranchDefaults.requiresPublish {
                branchPublicationPanel
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LitheTheme.secondaryText)
                    branchPicker(label: "Base", selection: $base)
                    Image(systemName: "arrow.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LitheTheme.tertiaryText)
                    branchPicker(label: "Compare", selection: $head)
                    Spacer(minLength: 12)
                    comparisonStatus
                }

                VStack(alignment: .leading, spacing: 10) {
                    branchPicker(label: "Base", selection: $base)
                    branchPicker(label: "Compare", selection: $head)
                    comparisonStatus
                }
            }

            Text("Changes from the compare branch will be proposed for the base branch.")
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.tertiaryText)
        }
        .padding(16)
        .background(LitheTheme.toolHeader)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(LitheTheme.inputBorder))
    }

    private var branchPublicationPanel: some View {
        let defaults = model.githubFeature.pullRequestBranchDefaults
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: defaults.isDetached ? "arrow.triangle.branch" : "icloud.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LitheTheme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(defaults.isDetached ? "Publish this worktree" : "Push this branch to GitHub")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(
                        defaults.isDetached
                            ? "This worktree has a detached HEAD. Publish it as a branch before creating a pull request."
                            : "Push the latest commits before comparing or creating a pull request."
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }

            HStack(spacing: 9) {
                TextField("Branch name", text: $publishBranchName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(LitheTheme.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                            .stroke(LitheTheme.inputBorder, lineWidth: 1)
                    }
                    .disabled(!defaults.isDetached || model.githubFeature.isPublishingPullRequestBranch)

                Button {
                    publishPullRequestBranch()
                } label: {
                    HStack(spacing: 6) {
                        if model.githubFeature.isPublishingPullRequestBranch {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.githubFeature.isPublishingPullRequestBranch ? "Publishing…" : "Publish Branch")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(
                    publishBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.githubFeature.isPublishingPullRequestBranch
                )
                .lithePointer()
            }

            if defaults.hasUncommittedChanges {
                Label(
                    "Uncommitted changes stay in this worktree and are not included in the pull request.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.warning)
            }

            if let error = model.githubFeature.branchPublicationError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(LitheTheme.accent.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func branchPicker(
        label: LocalizedStringKey,
        selection: Binding<String>
    ) -> some View {
        GitHubBranchPicker(
            label: label,
            selection: selection,
            branches: model.githubFeature.branches,
            contentState: model.githubFeature.branchContentState,
            retry: {
                Task { await model.githubFeature.loadBranches(force: true) }
            }
        )
    }

    private func applyDefaultBranches(from branches: [GitHubBranch]) {
        guard !branches.isEmpty else { return }
        let branchNames = Set(branches.map(\.name))
        let defaults = model.githubFeature.pullRequestBranchDefaults

        if !defaults.requiresPublish, head.isEmpty, let suggestedHead = defaults.head,
           branchNames.contains(suggestedHead) {
            head = suggestedHead
        }

        guard base.isEmpty || !branchNames.contains(base) else { return }
        let candidates = [defaults.base, "main", "master"]
            .compactMap { $0 }
        base = candidates.first { branchNames.contains($0) && $0 != head }
            ?? branches.first(where: { $0.name != head })?.name
            ?? ""
    }

    private func applyPublicationDefaults() {
        let defaults = model.githubFeature.pullRequestBranchDefaults
        guard defaults.requiresPublish,
              let suggestion = defaults.suggestedPublishBranch,
              publishBranchName.isEmpty || !defaults.isDetached else { return }
        publishBranchName = suggestion
    }

    private func publishPullRequestBranch() {
        let name = publishBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            if let published = await model.publishGitHubPullRequestBranch(named: name) {
                head = published
                publishBranchName = published
                applyDefaultBranches(from: model.githubFeature.branches)
            }
        }
    }

    @ViewBuilder
    private var comparisonStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: comparisonStatusIcon)
            Text(comparisonStatusTitle)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(comparisonStatusColor)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var creationCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if case .connected(let user) = model.githubFeature.connectionState {
                    GitHubIdentityMark(login: user.login, size: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create pull request")
                        .font(.system(size: 15, weight: .semibold))
                    Text(model.githubFeature.repository?.fullName ?? "Current GitHub repository")
                        .font(.system(size: 10.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer()
            }
            .padding(16)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            VStack(alignment: .leading, spacing: 15) {
                workspaceFormField("Title", required: true) {
                    TextField("What does this pull request change?", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focusedField, equals: .title)
                        .padding(.horizontal, 11)
                        .frame(height: 36)
                        .background(LitheTheme.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(focusedField == .title ? LitheTheme.accent : LitheTheme.inputBorder)
                        )
                }

                pullRequestDescriptionField

                operationMessage

                HStack {
                    Toggle("Create as draft", isOn: $draft)
                        .font(.system(size: 11.5, weight: .medium))
                        .toggleStyle(.checkbox)
                    Spacer()
                    Button("Cancel") { model.githubFeature.cancelCreatingPullRequest() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isOperationRunning)
                    Button {
                        submit()
                    } label: {
                        HStack(spacing: 7) {
                            if isOperationRunning {
                                ProgressView().controlSize(.small)
                            }
                            Text(draft ? "Create Draft" : "Create Pull Request")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitDisabled)
                }
            }
            .padding(16)
        }
        .background(LitheTheme.sidebar)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(LitheTheme.inputBorder))
    }

    private var pullRequestDescriptionField: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Description")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer()
                Button {
                    generatePullRequestDescription()
                } label: {
                    HStack(spacing: 6) {
                        if isGeneratingDescription {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text(isGeneratingDescription ? "Generating…" : "Generate with AI")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isGenerateDescriptionDisabled)
                .help("Generate a title and description from the selected branch changes")
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $descriptionText)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 12.5))
                    .focused($focusedField, equals: .description)
                    .padding(7)
                    .frame(minHeight: 210)
                if descriptionText.isEmpty {
                    Text("Explain the intent, testing, and anything reviewers should know…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .padding(13)
                        .allowsHitTesting(false)
                }
            }
            .background(LitheTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(focusedField == .description ? LitheTheme.accent : LitheTheme.inputBorder)
            )

            if let generationError {
                Label(generationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var operationMessage: some View {
        switch model.githubFeature.operationState {
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.error)
        case .running(let message):
            Text(LocalizedStringKey(message))
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
        case .idle, .succeeded:
            EmptyView()
        }
    }

    private func workspaceFormField<Content: View>(
        _ label: String,
        required: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 0) {
                Text(LocalizedStringKey(label))
                if required { Text(" *") }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(LitheTheme.secondaryText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func submit() {
        focusedField = nil
        Task {
            _ = await model.githubFeature.createPullRequest(
                title: trimmedTitle,
                body: descriptionText,
                head: trimmedHead,
                base: trimmedBase,
                draft: draft
            )
        }
    }

    private func generatePullRequestDescription() {
        guard !isGenerateDescriptionDisabled else { return }
        focusedField = nil
        generationError = nil
        isGeneratingDescription = true
        Task {
            defer { isGeneratingDescription = false }
            do {
                let output = try await model.generatePullRequestDescription(
                    base: trimmedBase,
                    head: trimmedHead
                )
                if trimmedTitle.isEmpty && descriptionText.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty {
                    title = output.title
                    descriptionText = output.description
                } else {
                    pendingGeneratedContent = output
                    isGeneratedContentConfirmationPresented = true
                }
            } catch {
                generationError = error.localizedDescription
            }
        }
    }

    private func applyGeneratedContent(replacingExisting: Bool) {
        guard let output = pendingGeneratedContent else { return }
        if replacingExisting || trimmedTitle.isEmpty {
            title = output.title
        }
        if replacingExisting || descriptionText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            descriptionText = output.description
        }
        pendingGeneratedContent = nil
    }

    private var comparisonStatusIcon: String {
        if model.githubFeature.pullRequestBranchDefaults.requiresPublish { return "icloud.and.arrow.up" }
        if trimmedHead.isEmpty || trimmedBase.isEmpty { return "circle.dashed" }
        if branchesAreEqual { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private var comparisonStatusTitle: LocalizedStringKey {
        if model.githubFeature.pullRequestBranchDefaults.requiresPublish { return "Publish branch first" }
        if trimmedHead.isEmpty || trimmedBase.isEmpty { return "Choose two branches" }
        if branchesAreEqual { return "Branches must be different" }
        return "Ready to create"
    }

    private var comparisonStatusColor: Color {
        if model.githubFeature.pullRequestBranchDefaults.requiresPublish { return LitheTheme.accent }
        if trimmedHead.isEmpty || trimmedBase.isEmpty { return LitheTheme.tertiaryText }
        if branchesAreEqual { return .orange }
        return LitheTheme.success
    }

    private var isSubmitDisabled: Bool {
        trimmedTitle.isEmpty || trimmedHead.isEmpty || trimmedBase.isEmpty || branchesAreEqual
            || model.githubFeature.pullRequestBranchDefaults.requiresPublish
            || isOperationRunning
    }

    private var isGenerateDescriptionDisabled: Bool {
        trimmedHead.isEmpty || trimmedBase.isEmpty || branchesAreEqual
            || model.githubFeature.pullRequestBranchDefaults.requiresPublish
            || isGeneratingDescription || isOperationRunning
    }

    private var isOperationRunning: Bool {
        if case .running = model.githubFeature.operationState { return true }
        return false
    }

    private var branchesAreEqual: Bool {
        trimmedHead.caseInsensitiveCompare(trimmedBase) == .orderedSame
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedHead: String { head.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBase: String { base.trimmingCharacters(in: .whitespacesAndNewlines) }
}

private struct GitHubBranchPicker: View {
    let label: LocalizedStringKey
    @Binding var selection: String
    let branches: [GitHubBranch]
    let contentState: GitHubFeatureModel.ContentState
    let retry: () -> Void
    @State private var isPresented = false
    @State private var query = ""

    var body: some View {
        Button {
            query = ""
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                Text(selection.isEmpty ? "Select branch" : selection)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(selection.isEmpty ? LitheTheme.tertiaryText : LitheTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LitheTheme.tertiaryText)
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 170, idealWidth: 205, maxWidth: 240, minHeight: 32)
            .background(LitheTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isPresented ? LitheTheme.accent : LitheTheme.inputBorder)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(selection.isEmpty ? Text("Select branch") : Text(selection))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        VStack(spacing: 10) {
            TextField("Search branches", text: $query)
                .textFieldStyle(.roundedBorder)

            branchContent
        }
        .padding(12)
        .frame(width: 300, height: 340)
        .background(LitheTheme.sidebar)
    }

    @ViewBuilder
    private var branchContent: some View {
        switch contentState {
        case .idle, .loading:
            Spacer()
            ProgressView("Loading branches")
                .controlSize(.small)
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
        case .failed(let message):
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Branches unavailable")
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button("Retry", action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Spacer()
        case .ready:
            if filteredBranches.isEmpty {
                Spacer()
                Text("No branches found")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredBranches) { branch in
                            branchRow(branch)
                        }
                    }
                }
            }
        }
    }

    private func branchRow(_ branch: GitHubBranch) -> some View {
        Button {
            selection = branch.name
            isPresented = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                    .foregroundStyle(LitheTheme.secondaryText)
                Text(branch.name)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                if selection == branch.name {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LitheTheme.accent)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var filteredBranches: [GitHubBranch] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return branches }
        return branches.filter { $0.name.localizedCaseInsensitiveContains(trimmedQuery) }
    }
}

private struct GitHubPullRequestForm: View {
    let heading: String
    let caption: String
    @Binding var title: String
    @Binding var descriptionText: String
    var head: Binding<String>?
    @Binding var base: String
    var draft: Binding<Bool>?
    let primaryTitle: String
    let isPrimaryDisabled: Bool
    let cancel: () -> Void
    let submit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(heading)).font(.system(size: 17, weight: .semibold))
                    Text(caption)
                        .font(.system(size: 10.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer()
            }
            .padding(18)
            .background(LitheTheme.toolHeader)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            VStack(alignment: .leading, spacing: 15) {
                formField("Title", required: true) {
                    TextField("What does this pull request change?", text: $title)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(alignment: .top, spacing: 12) {
                    if let head {
                        formField("Head branch", required: true) {
                            TextField("feature/my-change", text: head)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    formField("Base branch", required: true) {
                        TextField("main", text: $base)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                formField("Description", required: false) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $descriptionText)
                            .scrollContentBackground(.hidden)
                            .padding(5)
                            .frame(height: 170)
                        if descriptionText.isEmpty {
                            Text("Explain the intent, testing, and anything reviewers should know…")
                                .font(.system(size: 12))
                                .foregroundStyle(LitheTheme.tertiaryText)
                                .padding(10)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(LitheTheme.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.inputBorder))
                }
                if let draft {
                    Toggle("Create as draft", isOn: draft)
                        .font(.system(size: 11.5, weight: .medium))
                }
            }
            .padding(18)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack {
                Text("Required fields are marked with *")
                    .font(.system(size: 9.5))
                    .foregroundStyle(LitheTheme.tertiaryText)
                Spacer()
                Button("Cancel", action: cancel)
                Button(LocalizedStringKey(primaryTitle), action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(isPrimaryDisabled)
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(LitheTheme.sidebar)
        }
        .frame(width: 590)
        .background(LitheTheme.editor)
    }

    private func formField<Content: View>(
        _ label: String,
        required: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text(LocalizedStringKey(label))
                if required { Text(" *") }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(LitheTheme.secondaryText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
