import SwiftUI
import LitheGitModule

/// What the push dialog needs from the Git module. Closures keep the dialog's
/// destination logic free of the feature model so it can run without a repository.
struct GitPushDialogActions {
    /// Resolves the destination and commits for the current choice. Writes nothing.
    let preview: (GitPushTargetChoice?) async -> Result<GitPushPreview, GitPushFailure>
    let changedFiles: (GitCommit) async -> [GitCommitFile]?
    /// Pushes the reviewed preview and returns `nil` on success, otherwise why not.
    let push: (GitPushPreview, GitPushTargetChoice?) async -> GitPushFailure?

    @MainActor
    init(feature: GitFeatureModel, reference: GitReference) {
        preview = { await feature.previewPush(reference, pushTarget: $0) }
        changedFiles = { await feature.changedFiles(in: $0) }
        push = { await feature.pushReviewed(reference, preview: $0, pushTarget: $1) }
    }

    init(
        preview: @escaping (GitPushTargetChoice?) async -> Result<GitPushPreview, GitPushFailure>,
        changedFiles: @escaping (GitCommit) async -> [GitCommitFile]?,
        push: @escaping (GitPushPreview, GitPushTargetChoice?) async -> GitPushFailure?
    ) {
        self.preview = preview
        self.changedFiles = changedFiles
        self.push = push
    }
}

/// State of one push review. Every push is previewed first, and what is pushed is
/// exactly the preview the user saw, so a destination the user never looked at can
/// not be updated: a differently named upstream needs an explicit choice, and a
/// choice is dropped when the destination it was made for changes underneath it.
@MainActor
final class GitPushDialogModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready(GitPushPreview)
        case failed(String)
    }

    enum FilesPhase: Equatable {
        case idle
        case loading
        case loaded([GitCommitFile])
        case failed
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var pushTarget: GitPushTargetChoice?
    @Published private(set) var selectedCommit: GitCommit?
    @Published private(set) var files: FilesPhase = .idle
    @Published private(set) var isPushing = false
    @Published private(set) var pushError: String?

    private let actions: GitPushDialogActions
    /// `remote/branch` the first preview of the current choice showed.
    private var confirmedDestination: String?
    private var previewGeneration = 0
    private var filesTask: Task<Void, Never>?

    init(actions: GitPushDialogActions) {
        self.actions = actions
    }

    var preview: GitPushPreview? {
        if case .ready(let preview) = phase { return preview }
        return nil
    }

    /// A differently named upstream is never pushed implicitly.
    var needsTargetChoice: Bool {
        guard let preview else { return false }
        return preview.targetKind == .divergent && pushTarget == nil
    }

    /// Publishing a branch that has no remote counterpart yet is a push even when
    /// every commit already exists on the remote.
    var canPush: Bool {
        guard let preview, !isPushing, !needsTargetChoice else { return false }
        return preview.createsRemoteBranch || !preview.commits.isEmpty || !preview.tags.isEmpty
    }

    func load() async {
        previewGeneration += 1
        let generation = previewGeneration
        phase = .loading
        let result = await actions.preview(pushTarget)
        guard generation == previewGeneration else { return }
        switch result {
        case .failure(let failure):
            phase = .failed(failure.message)
            selectCommit(nil)
        case .success(let preview):
            if pushTarget != nil {
                if let confirmed = confirmedDestination, confirmed != preview.destination {
                    // The tracking configuration moved under the choice. Carrying the
                    // confirmation over would push to a branch the user never saw.
                    confirmedDestination = nil
                    pushTarget = nil
                    await load()
                    return
                }
                confirmedDestination = preview.destination
            }
            phase = .ready(preview)
            selectCommit(preview.commits.first)
        }
    }

    func choose(_ choice: GitPushTargetChoice) async {
        guard choice != pushTarget, !isPushing else { return }
        pushTarget = choice
        confirmedDestination = nil
        pushError = nil
        await load()
    }

    /// Returns whether the push succeeded. A failed push reloads the preview so the
    /// dialog shows the repository as it is now.
    func push() async -> Bool {
        guard canPush, let preview else { return false }
        isPushing = true
        pushError = nil
        let failure = await actions.push(preview, pushTarget)
        isPushing = false
        guard let failure else { return true }
        await load()
        pushError = failure.message
        return false
    }

    func selectCommit(_ commit: GitCommit?) {
        selectedCommit = commit
        filesTask?.cancel()
        guard let commit else {
            files = .idle
            filesTask = nil
            return
        }
        files = .loading
        filesTask = Task { [actions] in
            let loaded = await actions.changedFiles(commit)
            guard !Task.isCancelled, selectedCommit == commit else { return }
            files = loaded.map { .loaded($0) } ?? .failed
        }
    }
}

/// Wording derived from the destination Core resolved, never from the branch alone.
struct GitPushDialogPresentation: Equatable {
    /// `remote/branch`, the branch this push creates or updates.
    let destination: String
    let note: String?
    /// Localization key of the confirm button.
    let actionTitle: String

    init(preview: GitPushPreview, locale: Locale = .current, bundle: Bundle = .main) {
        destination = preview.destination
        if preview.createsRemoteBranch {
            note = gitLocalizedFormat("Creates a new branch on %@", preview.remote, locale: locale, bundle: bundle)
            actionTitle = "Publish Branch"
        } else if preview.upstream == nil {
            note = gitLocalizedFormat("Sets %@ as the upstream", preview.destination, locale: locale, bundle: bundle)
            actionTitle = "Push"
        } else {
            note = nil
            actionTitle = "Push"
        }
    }
}

/// An IDEA-style push review: it always shows which branch the push updates and
/// which commits it sends, and nothing is pushed until the user confirms.
struct GitPushDialog: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var feature: GitFeatureModel
    @StateObject private var model: GitPushDialogModel
    let projectName: String
    let reference: GitReference

    init(feature: GitFeatureModel, projectName: String, reference: GitReference) {
        self.feature = feature
        self.projectName = projectName
        self.reference = reference
        _model = StateObject(wrappedValue: GitPushDialogModel(
            actions: GitPushDialogActions(feature: feature, reference: reference)
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Push to \(projectName)")
                    .font(LitheTheme.uiFont(size: 16, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            divider

            content

            divider

            footer
        }
        .frame(width: 720, height: 460)
        .background(LitheTheme.raised)
        .task { await model.load() }
        .onChange(of: feature.gitRepositoryRoot) { _ in dismiss() }
    }

    private var divider: some View {
        Rectangle().fill(LitheTheme.divider).frame(height: 1)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            statusMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Resolving push destination…")
                }
            }
        case .failed(let message):
            statusMessage {
                VStack(spacing: 10) {
                    Text(verbatim: message).foregroundStyle(LitheTheme.error).multilineTextAlignment(.center)
                    Button("Retry") { Task { await model.load() } }
                        .buttonStyle(LitheActionButtonStyle()).lithePointer()
                }
            }
        case .ready(let preview):
            VStack(spacing: 0) {
                routeBar(preview)
                if preview.targetKind == .divergent { divergentChoice(preview) }
                HStack(spacing: 0) {
                    commitList(preview)
                        .frame(width: 360)
                        .background(LitheTheme.sidebar)
                    Rectangle().fill(LitheTheme.divider).frame(width: 1)
                    detailPane
                }
            }
        }
    }

    private func statusMessage<Message: View>(@ViewBuilder _ message: () -> Message) -> some View {
        message()
            .font(LitheTheme.uiFont(size: 13))
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func routeBar(_ preview: GitPushPreview) -> some View {
        let presentation = GitPushDialogPresentation(preview: preview, locale: locale)
        return HStack(spacing: 8) {
            Text(verbatim: preview.localBranch)
                .font(LitheTheme.uiFont(size: 13, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "arrow.right")
                .font(LitheTheme.uiFont(size: 12, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(verbatim: presentation.destination)
                .font(LitheTheme.uiFont(size: 13))
                .foregroundStyle(LitheTheme.accent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            if let note = presentation.note {
                Text(verbatim: note)
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 38)
        .background(LitheTheme.selection.opacity(0.72))
    }

    private func divergentChoice(_ preview: GitPushPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Branch '\(preview.localBranch)' tracks '\(preview.upstream ?? "")', which has a different name. Choose which branch to update.")
                .font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(LitheTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                choiceButton(.publish) {
                    Text("Publish to \(preview.remote)/\(preview.localBranch)")
                }
                choiceButton(.upstream) {
                    Text("Push to \(preview.upstream ?? "")")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.warning.opacity(0.12))
    }

    private func choiceButton<Label: View>(
        _ choice: GitPushTargetChoice,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            Task { await model.choose(choice) }
        } label: {
            label().lineLimit(1)
        }
        .buttonStyle(.bordered)
        .tint(model.pushTarget == choice ? LitheTheme.accent : nil)
        .disabled(model.isPushing)
        .lithePointer()
    }

    private func commitList(_ preview: GitPushPreview) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Commits")
                    .font(LitheTheme.uiFont(size: 12, weight: .medium))
                Spacer()
                Text(verbatim: "\(preview.commits.count)")
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .monospacedDigit()
            }
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 14)
            .frame(height: 30)

            divider

            if preview.commits.isEmpty {
                Spacer(minLength: 0)
                Text(preview.createsRemoteBranch
                    ? "No new commits. Pushing creates the remote branch."
                    : "Nothing to push")
                    .font(LitheTheme.uiFont(size: 13))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(preview.commits) { commit in
                            commitRow(commit)
                        }
                        if preview.hasMore {
                            Text("Older commits are not listed.")
                                .font(LitheTheme.uiFont(size: 11.5))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .padding(12)
                        }
                    }
                }
            }
        }
    }

    private func commitRow(_ commit: GitCommit) -> some View {
        let isSelected = model.selectedCommit == commit
        return Button {
            model.selectCommit(commit)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: commit.subject)
                    .font(LitheTheme.uiFont(size: 13))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(verbatim: commit.shortHash).font(LitheTheme.uiFont(size: 11.5, design: .monospaced))
                    Text(verbatim: commit.authorName).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(verbatim: commit.date).lineLimit(1)
                }
                .font(LitheTheme.uiFont(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? LitheTheme.selection.opacity(0.72) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .lithePointer()
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let commit = model.selectedCommit {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: commit.subject)
                        .font(LitheTheme.uiFont(size: 13, weight: .medium))
                        .foregroundStyle(LitheTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: "\(commit.shortHash) · \(commit.authorName) · \(commit.date)")
                        .font(LitheTheme.uiFont(size: 11.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                }
                .padding(14)

                divider

                switch model.files {
                case .idle, .loading:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed:
                    Text("Could not load the changed files.")
                        .font(LitheTheme.uiFont(size: 13))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let files):
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(files) { file in
                                HStack(spacing: 8) {
                                    Text(verbatim: file.status)
                                        .font(LitheTheme.uiFont(size: 11.5, design: .monospaced))
                                        .foregroundStyle(LitheTheme.secondaryText)
                                        .frame(width: 18)
                                    Text(verbatim: file.path)
                                        .font(LitheTheme.uiFont(size: 12.5))
                                        .foregroundStyle(LitheTheme.primaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 24)
                            }
                        }
                    }
                }
            } else {
                Text("No commit selected")
                    .font(LitheTheme.uiFont(size: 13))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        let presentation = model.preview.map { GitPushDialogPresentation(preview: $0, locale: locale) }
        return HStack(spacing: LitheTheme.ActionButton.spacing) {
            if let error = model.pushError {
                Text(verbatim: error)
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.error)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else if model.needsTargetChoice {
                Text("Choose which branch to update before pushing.")
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer(minLength: 16)

            Button("Cancel") { dismiss() }
                .buttonStyle(LitheActionButtonStyle())
                .keyboardShortcut(.cancelAction)
                .disabled(model.isPushing)
                .lithePointer()

            Button {
                Task { if await model.push() { dismiss() } }
            } label: {
                if model.isPushing {
                    ProgressView().controlSize(.small)
                } else {
                    Text(LocalizedStringKey(presentation?.actionTitle ?? "Push"))
                }
            }
            .buttonStyle(LitheActionButtonStyle(isPrimary: true))
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canPush)
            .lithePointer()
        }
        .padding(16)
    }
}
