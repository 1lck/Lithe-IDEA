import SwiftUI
import LitheCoreContracts

private enum GitHubDetailSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case files = "Files"
    case conversation = "Conversation"

    var id: String { rawValue }
}

private enum GitHubReviewAction: String, CaseIterable, Identifiable {
    case comment = "Comment"
    case approve = "Approve"
    case requestChanges = "Request changes"

    var id: String { rawValue }

    var event: String? {
        switch self {
        case .comment: nil
        case .approve: "APPROVE"
        case .requestChanges: "REQUEST_CHANGES"
        }
    }

    var buttonTitle: String {
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

    var title: String {
        switch self {
        case .merge: "Create a merge commit"
        case .squash: "Squash and merge"
        case .rebase: "Rebase and merge"
        }
    }

    var explanation: String {
        switch self {
        case .merge: "Preserves every commit and adds a merge commit to the base branch."
        case .squash: "Combines the pull request into one commit on the base branch."
        case .rebase: "Replays every commit onto the base branch without a merge commit."
        }
    }
}

struct GitHubPullRequestsSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var personalAccessToken = ""
    @State private var isCreatePresented = false
    @State private var searchQuery = ""

    var body: some View {
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
        .sheet(isPresented: $isCreatePresented) {
            GitHubCreatePullRequestView(isPresented: $isCreatePresented)
                .environmentObject(model)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(LitheTheme.accent)
                    Text("Connect GitHub")
                        .font(.system(size: 19, weight: .semibold))
                    Text("Review and manage pull requests without creating a Lithe account.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                securityNote

                if let message {
                    GitHubInlineNotice(
                        icon: "exclamationmark.triangle.fill",
                        color: LitheTheme.error,
                        title: "Connection failed",
                        message: message
                    ) {
                        Button("Forget saved connection") {
                            Task { await model.disconnectGitHub() }
                        }
                        .controlSize(.small)
                    }
                }

                if model.githubFeature.canUseDeviceFlow {
                    Button {
                        Task { await model.connectGitHubWithDeviceFlow() }
                    } label: {
                        Label("Continue with GitHub", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    GitHubInlineNotice(
                        icon: "info.circle",
                        color: LitheTheme.secondaryText,
                        title: "Device Flow is not configured",
                        message: "Add LitheGitHubOAuthClientID to the product configuration to enable browser authorization."
                    )
                }

                Divider()

                DisclosureGroup("Use a fine-grained token") {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Use a token with Pull requests and Issues read/write access. It will be validated before Lithe saves it to Keychain.")
                            .font(.system(size: 11))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        SecureField("github_pat_…", text: $personalAccessToken)
                            .textFieldStyle(.roundedBorder)
                        Button("Connect with Token") {
                            let token = personalAccessToken
                            personalAccessToken = ""
                            Task { await model.connectGitHub(personalAccessToken: token) }
                        }
                        .disabled(trimmedToken.isEmpty)
                    }
                    .padding(.top, 10)
                }
                .font(.system(size: 12, weight: .medium))
            }
            .padding(20)
        }
    }

    private var securityNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.shield")
                .foregroundStyle(LitheTheme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stored in macOS Keychain")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("Lithe never asks for your GitHub password or stores the token in project files.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                Text(model.githubFeature.repository?.fullName ?? "No GitHub origin")
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

                Button { isCreatePresented = true } label: {
                    Image(systemName: "plus")
                }
                .litheIconButton()
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

    private var trimmedToken: String {
        personalAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
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
            if let request = model.githubFeature.selectedPullRequest {
                detail(request)
            } else {
                GitHubEmptyState(
                    icon: "arrow.triangle.pull",
                    title: "Select a pull request",
                    message: "Choose a pull request to review its context, files, and conversation."
                )
            }
        }
        .background(LitheTheme.editor)
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
            request.state == "open" ? "Close pull request #\(request.number)?" : "Reopen pull request #\(request.number)?",
            isPresented: $shouldConfirmClose,
            titleVisibility: .visible
        ) {
            Button(request.state == "open" ? "Close Pull Request" : "Reopen Pull Request", role: request.state == "open" ? .destructive : nil) {
                Task { await model.githubFeature.setOpen(request.state != "open") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(request.state == "open"
                ? "This does not delete the branch or commits. The pull request can be reopened later."
                : "The pull request will return to the open list and can receive new reviews.")
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
            Text("\(pendingMergeChoice?.explanation ?? "") This updates \(request.baseRef) on GitHub and cannot be undone from Lithe.")
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
                    Button(request.state == "open" ? "Close pull request" : "Reopen pull request") {
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
        .background(LitheTheme.toolHeader)
    }

    private func sectionBar(_ request: GitHubPullRequest) -> some View {
        HStack(spacing: 3) {
            ForEach(GitHubDetailSection.allCases) { section in
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { selectedSection = section }
                } label: {
                    HStack(spacing: 5) {
                        Text(section.rawValue)
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
        .background(LitheTheme.sidebar)
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
                                Text(action.rawValue).tag(action)
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
                                Text(composerAction == .approve
                                    ? "Optional approval summary"
                                    : "Write a clear, actionable comment…")
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
            .help(statusText)
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
            metric(title: "Status", value: status)
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

    private func metric(title: String, value: String, color: Color = LitheTheme.primaryText) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(LitheTheme.tertiaryText)
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
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(detail)
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
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 72, alignment: .trailing)
            TextField(placeholder, text: $text)
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
                    GitHubPill(text: file.status, color: statusColor)
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

    var body: some View {
        Text(text)
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
    let value: String

    var body: some View {
        Text(relativeText)
            .help(value)
    }

    private var relativeText: String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        let formatter = RelativeDateTimeFormatter()
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
            Text(message)
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
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Text(message)
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
}

private struct GitHubAuthorizationStep: View {
    let number: Int
    let title: String
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(isComplete ? LitheTheme.success : LitheTheme.secondaryText)
            Text(title)
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
            Text(title).font(.system(size: 12, weight: .semibold))
            if let detail {
                Text(detail)
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
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).padding(.top, 3)
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

private struct GitHubCreatePullRequestView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var title = ""
    @State private var descriptionText = ""
    @State private var head = ""
    @State private var base = "main"
    @State private var draft = false

    var body: some View {
        GitHubPullRequestForm(
            heading: "Create pull request",
            caption: model.githubFeature.repository?.fullName ?? "Current GitHub repository",
            title: $title,
            descriptionText: $descriptionText,
            head: $head,
            base: $base,
            draft: $draft,
            primaryTitle: draft ? "Create Draft" : "Create Pull Request",
            isPrimaryDisabled: trimmedTitle.isEmpty || trimmedHead.isEmpty || trimmedBase.isEmpty,
            cancel: { isPresented = false },
            submit: {
                Task {
                    if await model.githubFeature.createPullRequest(
                        title: trimmedTitle,
                        body: descriptionText,
                        head: trimmedHead,
                        base: trimmedBase,
                        draft: draft
                    ) {
                        isPresented = false
                    }
                }
            }
        )
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedHead: String { head.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBase: String { base.trimmingCharacters(in: .whitespacesAndNewlines) }
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
                    Text(heading).font(.system(size: 17, weight: .semibold))
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
                Button(primaryTitle, action: submit)
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
            Text(required ? "\(label) *" : label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
