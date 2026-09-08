import AppKit
import SwiftUI
import LitheGitModule

extension GitHistoryRewriteOperation {
    var menuTitle: String {
        switch self {
        case .undoCommit: "Undo Commit…"
        case .editCommitMessage: "Edit Commit Message…"
        case .squashCommits: "Squash Commits…"
        case .deleteCommit: "Drop Commit…"
        }
    }

    var actionTitle: String {
        switch self {
        case .undoCommit: "Undo Commit"
        case .editCommitMessage: "Save Message"
        case .squashCommits: "Squash Commits"
        case .deleteCommit: "Drop Commit"
        }
    }
}

struct GitHistoryEditingPresentation: ViewModifier {
    @ObservedObject var editor: GitHistoryEditingFeatureModel

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { editor.showsDialog },
            set: { if !$0 { editor.dismiss() } }
        )) {
            GitHistoryRewriteDialog(editor: editor)
        }
    }
}

/// Observing selection here leaves graph topology cached while rows update their highlighting.
struct GitHistorySelectionGraphView: View {
    @ObservedObject var editor: GitHistoryEditingFeatureModel
    let presentation: GitGraphPresentation
    let focusedHash: String?
    let showCommitDecorations: Bool
    let actions: GitGraphRowActions

    var body: some View {
        GitGraphView(
            presentation: presentation,
            selectedHash: focusedHash,
            showCommitDecorations: showCommitDecorations,
            actions: actions,
            selectedHashes: editor.selection.hashes
        )
    }
}

struct GitHistoryRewriteOutcomeView: View {
    @ObservedObject var editor: GitHistoryEditingFeatureModel
    let createRecoveryBranch: (String, GitHistoryRewriteResult) async -> String?
    @State private var showsRecoveryDialog = false
    @State private var recoveryBranchName = ""
    @State private var recoveryError: String?
    @State private var isCreatingRecoveryBranch = false

    var body: some View {
        if let outcome = editor.outcome {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: outcome.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(outcome.succeeded ? LitheTheme.accent : LitheTheme.warning)
                VStack(alignment: .leading, spacing: 5) {
                    Text(outcome.message).font(.system(size: 12, weight: .medium))
                    ForEach(Array(outcome.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning.message).font(.system(size: 11)).foregroundStyle(LitheTheme.warning)
                    }
                    if let rewrite = outcome.rewrite {
                        if rewrite.mutationApplied && !outcome.succeeded {
                            Text("History changed, but Git reported an incomplete step. Refresh the repository and inspect the recovery reference before retrying.")
                                .font(.system(size: 11)).foregroundStyle(LitheTheme.warning)
                        }
                        if rewrite.worktreeRefresh == "failed" {
                            Text("The working tree could not be refreshed. Keep your local files and inspect Git status before continuing.")
                                .font(.system(size: 11)).foregroundStyle(LitheTheme.warning)
                        }
                        if !rewrite.outcomeKnown {
                            Text("Git could not confirm the final state. Refresh history before performing another action.")
                                .font(.system(size: 11)).foregroundStyle(LitheTheme.warning)
                        }
                        HStack(spacing: 8) {
                            Text("Recovery reference: \(rewrite.recoveryReference)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(rewrite.recoveryReference, forType: .string)
                            }
                            .lithePointer()
                            Button("Create Recovery Branch…") {
                                recoveryBranchName = "recovery/\(rewrite.originalHead.prefix(9))"
                                recoveryError = nil
                                showsRecoveryDialog = true
                            }
                            .lithePointer()
                        }
                        Text("Original HEAD: \(rewrite.originalHead.prefix(12)). Create a branch from the recovery reference to inspect the original history.")
                            .font(.system(size: 10.5)).foregroundStyle(LitheTheme.secondaryText)
                    }
                }
                Spacer(minLength: 0)
                Button { editor.outcome = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Dismiss history operation result").lithePointer()
            }
            .padding(10)
            .background(LitheTheme.toolHeader)
            .textSelection(.enabled)
            .sheet(isPresented: $showsRecoveryDialog) {
                recoveryDialog
            }
        }
    }

    private var recoveryDialog: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Create Recovery Branch").font(.system(size: 16, weight: .semibold))
            Text("Create a branch at the original history so you can inspect it in Git Log. Your current checkout stays in place.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            TextField("Branch name", text: $recoveryBranchName).textFieldStyle(.roundedBorder)
                .disabled(isCreatingRecoveryBranch)
            if let recoveryError { Text(recoveryError).font(.system(size: 12)).foregroundStyle(LitheTheme.error) }
            HStack {
                if isCreatingRecoveryBranch { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { showsRecoveryDialog = false }.disabled(isCreatingRecoveryBranch)
                    .keyboardShortcut(.cancelAction).lithePointer()
                Button("Create Branch") {
                    guard let rewrite = editor.outcome?.rewrite else { return }
                    isCreatingRecoveryBranch = true
                    Task {
                        recoveryError = await createRecoveryBranch(recoveryBranchName, rewrite)
                        isCreatingRecoveryBranch = false
                        if recoveryError == nil { showsRecoveryDialog = false }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).lithePointer()
                .disabled(isCreatingRecoveryBranch || recoveryBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 460).background(LitheTheme.raised)
        .interactiveDismissDisabled(isCreatingRecoveryBranch)
    }
}

private struct GitHistoryRewriteDialog: View {
    @ObservedObject var editor: GitHistoryEditingFeatureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LocalizedStringKey(editor.operation.menuTitle.replacingOccurrences(of: "…", with: "")))
                .font(.system(size: 17, weight: .semibold))
            if editor.isLoading {
                HStack { ProgressView().controlSize(.small); Text("Checking selected commits and repository state…") }
                    .font(.system(size: 12))
            }
            if let preview = editor.preview {
                previewContent(preview)
            }
            if let error = editor.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(LitheTheme.error).textSelection(.enabled)
            }
            if editor.operation.editsMessage, editor.preview != nil {
                messageEditor
            }
            HStack(spacing: 10) {
                if !editor.isLoading {
                    Button("Refresh Preview") { editor.reloadPreview() }
                        .disabled(editor.isExecuting).lithePointer()
                }
                Spacer()
                Button("Cancel") { editor.dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(editor.isExecuting).lithePointer()
                Button(LocalizedStringKey(editor.operation.actionTitle), role: editor.operation == .deleteCommit ? .destructive : nil) {
                    Task { await editor.confirm() }
                }
                .buttonStyle(.borderedProminent)
                .tint(editor.operation == .deleteCommit ? LitheTheme.error : LitheTheme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!editor.canExecute)
                .lithePointer()
                if editor.isExecuting { ProgressView().controlSize(.small) }
            }
        }
        .padding(20)
        .frame(width: 640)
        .background(LitheTheme.raised)
        .interactiveDismissDisabled(editor.isExecuting)
    }

    @ViewBuilder
    private func previewContent(_ preview: GitHistoryRewritePreview) -> some View {
        if let branch = preview.branch {
            Text("Branch: \(branch)").font(.system(size: 11)).foregroundStyle(LitheTheme.secondaryText)
        }
        Text(impactDescription(preview)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        ForEach(Array(preview.blockers.enumerated()), id: \.offset) { _, blocker in
            Label(blocker.message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(LitheTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !preview.affectedCommits.isEmpty {
            Text("Affected history · oldest to newest").font(.system(size: 11, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(preview.affectedCommits) { commit in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(String(commit.hash.prefix(9))).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(LitheTheme.secondaryText)
                            Text(commit.subject).font(.system(size: 12)).lineLimit(2)
                            Spacer(minLength: 0)
                            Text(actionLabel(commit, preview: preview)).font(.system(size: 10.5))
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                    }
                }
                .padding(9)
            }
            .frame(maxHeight: 150)
            .background(LitheTheme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private var messageEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Title").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(editor.title.count) characters").font(.system(size: 10.5)).foregroundStyle(LitheTheme.secondaryText)
            }
            TextField("Commit title", text: $editor.title).textFieldStyle(.roundedBorder)
                .disabled(editor.isExecuting)
            Text("Description").font(.system(size: 12, weight: .medium))
            TextEditor(text: $editor.body)
                .font(.system(size: 12))
                .frame(height: 110)
                .padding(4)
                .background(LitheTheme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .disabled(editor.isExecuting)
            Text("\(editor.message.count) characters total").font(.system(size: 10.5)).foregroundStyle(LitheTheme.secondaryText)
        }
    }

    private func impactDescription(_ preview: GitHistoryRewritePreview) -> LocalizedStringKey {
        switch preview.operation {
        case .undoCommit:
            "HEAD will move to its parent. The index and working files stay as they are; staged differences will be compared with the parent commit."
        case .editCommitMessage:
            "Only the commit message changes. \(preview.affectedCommits.count) commits will receive new identities. Staged files are not included."
        case .squashCommits:
            "Squash \(preview.selectedCommits.count) commits into 1. Later commits in the affected history will be replayed."
        case .deleteCommit:
            "Remove the selected commit and its changes from this branch. Later commits will be replayed. A recovery reference will retain the original history."
        }
    }

    private func actionLabel(_ commit: GitHistoryRewriteCommit, preview: GitHistoryRewritePreview) -> LocalizedStringKey {
        guard preview.selectedCommits.contains(where: { $0.hash == commit.hash }) else { return "Replay" }
        switch preview.operation {
        case .undoCommit: return "Undo"
        case .editCommitMessage: return "Edit message"
        case .squashCommits: return "Squash → 1"
        case .deleteCommit: return "Drop"
        }
    }
}
