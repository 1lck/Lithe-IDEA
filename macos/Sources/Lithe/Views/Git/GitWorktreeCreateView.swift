import SwiftUI
import LitheGitModule

struct GitWorktreeCreateView: View {
    @Environment(\.dismiss) private var dismiss
    let repositoryRoot: URL
    let references: [GitReference]
    let currentReference: GitReference?
    let worktrees: [GitWorktree]
    let actions: GitWorktreeActions
    let onSubmit: (GitWorktreeCreation) async -> String?

    @State private var mode = GitWorktreeMode.newBranch
    @State private var branchName = ""
    @State private var selectedReferenceID = ""
    @State private var destinationPath = ""
    @State private var destinationWasEdited = false
    @State private var revision = ""
    @State private var useTemporaryDirectory = false
    @State private var noCheckout = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Worktree").font(.system(size: 16, weight: .semibold))
            Picker("Checkout", selection: $mode) {
                Text("New branch").tag(GitWorktreeMode.newBranch)
                Text("Existing local branch").tag(GitWorktreeMode.existingBranch)
                Text("Detached HEAD").tag(GitWorktreeMode.detached)
            }
            .disabled(isSubmitting)
            if !availableReferences.isEmpty {
                Picker(LocalizedStringKey(mode == .existingBranch ? "Branch" : "Start from"), selection: $selectedReferenceID) {
                    ForEach(availableReferences) { Text($0.shortName).tag($0.id) }
                }
                .disabled(isSubmitting)
            } else if mode == .existingBranch {
                Text("No available local branch. Branches already checked out in another worktree cannot be reused.")
                    .font(.system(size: 11.5)).foregroundStyle(LitheTheme.warning)
            }
            if mode == .newBranch {
                TextField("New branch name", text: $branchName).textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
            }
            if mode != .existingBranch {
                TextField("Starting commit (optional)", text: $revision).textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
            }
            if mode == .detached {
                Text("The worktree will point directly to a commit. Create a branch there before keeping new commits.")
                    .font(.system(size: 11)).foregroundStyle(LitheTheme.secondaryText)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Checkout path").font(.system(size: 11.5, weight: .medium))
                HStack {
                    TextField("Worktree destination", text: Binding(
                        get: { destinationPath },
                        set: { destinationPath = $0; destinationWasEdited = true }
                    )).textFieldStyle(.roundedBorder)
                    Button("Choose Parent…") {
                        guard let parent = actions.chooseParentDirectory() else { return }
                        destinationPath = parent.appendingPathComponent(suggestedDirectoryName).path
                        destinationWasEdited = true
                    }.lithePointer()
                }
                .disabled(isSubmitting)
                Toggle("Use temporary directory", isOn: $useTemporaryDirectory)
                    .toggleStyle(.checkbox).disabled(isSubmitting || actions.temporaryDirectory == nil)
                Text("Use a persistent folder for ongoing work. Temporary checkouts may be removed by the system.")
                    .font(.system(size: 10.5)).foregroundStyle(LitheTheme.secondaryText)
            }
            Toggle("Create without checking out files", isOn: $noCheckout)
                .toggleStyle(.checkbox).disabled(isSubmitting)
                .help("Registers the worktree and prepares its HEAD while leaving its files unchecked out.")
            if let errorMessage {
                Text(LocalizedStringKey(errorMessage)).font(.system(size: 12)).foregroundStyle(LitheTheme.error).textSelection(.enabled)
            }
            HStack {
                if isSubmitting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSubmitting).lithePointer()
                Button("Create") {
                    guard canSubmit else { return }
                    isSubmitting = true
                    errorMessage = nil
                    let revision = trimmedRevision.isEmpty ? nil : trimmedRevision
                    let request = GitWorktreeCreation(
                        mode: mode,
                        name: mode == .newBranch ? trimmedBranchName : nil,
                        reference: mode == .detached && revision != nil ? nil : selectedReference,
                        revision: mode == .existingBranch ? nil : revision,
                        destination: URL(fileURLWithPath: destinationPath),
                        noCheckout: noCheckout
                    )
                    Task {
                        errorMessage = await onSubmit(request)
                        isSubmitting = false
                        if errorMessage == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent).tint(LitheTheme.accent)
                .keyboardShortcut(.defaultAction).disabled(isSubmitting || !canSubmit).lithePointer()
            }
        }
        .padding(20).frame(width: 540).background(LitheTheme.raised)
        .interactiveDismissDisabled(isSubmitting)
        .onAppear { chooseAvailableReference(); updateSuggestedDestination(force: true) }
        .onChange(of: mode) { _ in
            revision = ""
            chooseAvailableReference()
            updateSuggestedDestination()
        }
        .onChange(of: branchName) { _ in updateSuggestedDestination() }
        .onChange(of: selectedReferenceID) { _ in updateSuggestedDestination() }
        .onChange(of: revision) { _ in updateSuggestedDestination() }
        .onChange(of: useTemporaryDirectory) { _ in
            destinationWasEdited = false
            updateSuggestedDestination(force: true)
        }
    }

    private var availableReferences: [GitReference] {
        guard mode == .existingBranch else { return references }
        let occupied = Set(worktrees.compactMap(\.branch))
        return references.filter { $0.kind == .local && !occupied.contains($0.fullName) }
    }

    private var selectedReference: GitReference? { availableReferences.first { $0.id == selectedReferenceID } }
    private var trimmedBranchName: String { branchName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedRevision: String { revision.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool {
        guard destinationPath.hasPrefix("/") else { return false }
        switch mode {
        case .newBranch: return !trimmedBranchName.isEmpty && selectedReference != nil
        case .existingBranch: return selectedReference != nil
        case .detached: return selectedReference != nil || !trimmedRevision.isEmpty
        }
    }

    private func chooseAvailableReference() {
        selectedReferenceID = availableReferences.first(where: { $0.id == currentReference?.id })?.id
            ?? availableReferences.first?.id ?? ""
    }

    private var suggestedDirectoryName: String {
        let sourceName = mode == .newBranch ? trimmedBranchName
            : mode == .detached && !trimmedRevision.isEmpty ? String(trimmedRevision.prefix(9))
            : selectedReference?.shortName ?? "worktree"
        let leaf = sourceName.split(separator: "/").last.map(String.init) ?? "worktree"
        let safeLeaf = leaf.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        return "\(repositoryRoot.lastPathComponent)-\(String(safeLeaf))"
    }

    private func updateSuggestedDestination(force: Bool = false) {
        guard force || !destinationWasEdited else { return }
        let parent = useTemporaryDirectory ? actions.temporaryDirectory?() ?? repositoryRoot.deletingLastPathComponent()
            : repositoryRoot.deletingLastPathComponent()
        destinationPath = parent.appendingPathComponent(suggestedDirectoryName).path
        destinationWasEdited = false
    }
}
