import AppKit
import SwiftUI
import LitheGitModule

/// A nonmodal sequencer surface stays available while files are edited and staged.
struct GitInteractiveRebaseStatusView: View {
    @ObservedObject var editor: GitInteractiveRebaseFeatureModel
    let createRecoveryBranch: (String, GitRebaseSession) async -> String?

    var body: some View {
        if let session = editor.session {
            GitInteractiveRebaseSessionBanner(editor: editor, session: session, createRecoveryBranch: createRecoveryBranch)
        }
    }
}

private struct GitInteractiveRebaseSessionBanner: View {
    @ObservedObject var editor: GitInteractiveRebaseFeatureModel
    let session: GitRebaseSession
    let createRecoveryBranch: (String, GitRebaseSession) async -> String?
    @State private var amendment: Amendment?
    @State private var showsRecoveryDialog = false
    @State private var recoveryName = ""
    @State private var recoveryError: String?
    @State private var isCreatingRecovery = false
    @State private var pendingControl: GitRebaseControlAction?

    private struct Amendment: Identifiable {
        let session: GitRebaseSession
        var id: String { session.sessionId + (session.head ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: session.status == .completed ? "checkmark.circle" : "arrow.triangle.branch")
                    .foregroundStyle(session.status == .completed ? LitheTheme.accent : LitheTheme.warning)
                Text(statusTitle).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if !session.isActive {
                    Button { editor.dismissSession() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Dismiss rebase result").accessibilityLabel("Dismiss rebase result").lithePointer()
                }
            }
            Text("\(session.branch) · \(session.completedSteps) of \(session.steps.count) steps processed")
                .font(.system(size: 11)).foregroundStyle(LitheTheme.secondaryText)
            Text(statusDescription).font(.system(size: 11)).foregroundStyle(LitheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let currentCommit = session.currentCommit {
                Text("Current commit: \(currentCommit.prefix(12))").font(.system(size: 10.5, design: .monospaced))
            }
            if let error = editor.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(LitheTheme.error).lineLimit(6).textSelection(.enabled)
            }
            ForEach(Array(editor.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning.message).font(.system(size: 11)).foregroundStyle(LitheTheme.warning)
            }
            if session.isActive {
                HStack(spacing: 7) {
                    Button("Continue") { Task { await editor.control(.continue) } }
                        .buttonStyle(.borderedProminent).disabled(editor.isBusy || !session.canContinue).lithePointer()
                    if session.canSkip {
                        Button("Skip Commit…") { pendingControl = .skip }.disabled(editor.isBusy).lithePointer()
                    }
                    if session.canAbort {
                        Button("Abort…") { pendingControl = .abort }.disabled(editor.isBusy).lithePointer()
                    }
                    if editor.isExecuting { ProgressView().controlSize(.small) }
                }
                .controlSize(.small).font(.system(size: 11))
                if session.status == .edit {
                    Button("Amend and Continue…") { amendment = Amendment(session: session) }
                        .controlSize(.small).font(.system(size: 11))
                        .disabled(editor.isBusy || !session.canContinue || session.currentMessage == nil).lithePointer()
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Button("Copy Recovery Reference") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.recoveryReference, forType: .string)
                }.lithePointer()
                Button("Create Recovery Branch…") {
                    recoveryName = "recovery/\(session.originalHead.prefix(9))"
                    recoveryError = nil
                    showsRecoveryDialog = true
                }.disabled(editor.isBusy).lithePointer()
            }
            .controlSize(.small).font(.system(size: 10.5))
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(LitheTheme.toolHeader)
        .confirmationDialog(pendingControl == .abort ? "Abort this rebase and restore its original branch?" : "Skip the current commit and its unresolved changes?", isPresented: Binding(
            get: { pendingControl != nil }, set: { if !$0 { pendingControl = nil } }
        ), titleVisibility: .visible) {
            if let action = pendingControl {
                Button(action == .abort ? "Abort Rebase" : "Skip Commit", role: .destructive) {
                    pendingControl = nil
                    Task { await editor.control(action) }
                }
            }
        }
        .sheet(item: $amendment) { request in
            GitRebaseAmendDialog(editor: editor, session: request.session)
        }
        .sheet(isPresented: $showsRecoveryDialog) { recoveryDialog }
    }

    private var statusTitle: String {
        switch session.status {
        case .starting: "Starting Interactive Rebase"
        case .conflict: "Interactive Rebase: Conflicts"
        case .edit: "Interactive Rebase: Edit Commit"
        case .paused: "Interactive Rebase Paused"
        case .completed: "Interactive Rebase Completed"
        case .aborted: "Interactive Rebase Aborted"
        case .failed: "Interactive Rebase Failed"
        case .interrupted: "Interactive Rebase Interrupted"
        }
    }

    private var statusDescription: String {
        switch session.status {
        case .starting: "Git is preparing the sequencer."
        case .conflict: "Resolve \(session.conflictedPaths.count) conflicted file(s), stage the result, then continue."
        case .edit: "Edit files and stage the changes you want to include. Amend and Continue updates this commit; Continue keeps the existing commit."
        case .paused: "Inspect Git status and the command output, then continue when ready."
        case .completed: "The branch now contains the completed plan. Its original history remains available through the recovery reference."
        case .aborted: "The rebase was aborted. Inspect the branch and working files before continuing your work."
        case .failed, .interrupted: "Inspect the current Git state before retrying. The recovery reference preserves the original history."
        }
    }

    private var recoveryDialog: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Recovery Branch").font(.system(size: 16, weight: .semibold))
            Text("Create a branch at the history saved before this rebase. Your current checkout stays in place.").font(.system(size: 12))
            TextField("Branch name", text: $recoveryName).textFieldStyle(.roundedBorder).disabled(isCreatingRecovery)
            if let recoveryError { Text(recoveryError).font(.system(size: 12)).foregroundStyle(LitheTheme.error) }
            HStack {
                if isCreatingRecovery { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { showsRecoveryDialog = false }.keyboardShortcut(.cancelAction).disabled(isCreatingRecovery)
                Button("Create Branch") {
                    isCreatingRecovery = true
                    Task {
                        recoveryError = await createRecoveryBranch(recoveryName, session)
                        isCreatingRecovery = false
                        if recoveryError == nil { showsRecoveryDialog = false }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(isCreatingRecovery || recoveryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 460).interactiveDismissDisabled(isCreatingRecovery)
    }
}

private struct GitRebaseAmendDialog: View {
    @ObservedObject var editor: GitInteractiveRebaseFeatureModel
    let session: GitRebaseSession
    @Environment(\.dismiss) private var dismiss
    @State private var message: String

    init(editor: GitInteractiveRebaseFeatureModel, session: GitRebaseSession) {
        self.editor = editor
        self.session = session
        _message = State(initialValue: session.currentMessage ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Amend and Continue").font(.system(size: 16, weight: .semibold))
            Text("Replace the message of the paused commit and include the currently staged changes, then continue the rebase.")
                .font(.system(size: 12))
            TextEditor(text: $message).font(.system(size: 12, design: .monospaced)).frame(height: 210)
                .overlay(Rectangle().stroke(LitheTheme.divider, lineWidth: 1)).disabled(editor.isBusy)
                .accessibilityLabel("Complete commit message")
            Text("\(message.count) characters").font(.system(size: 11)).foregroundStyle(LitheTheme.secondaryText)
            if let error = editor.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(LitheTheme.error) }
            HStack {
                if editor.isExecuting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(editor.isExecuting)
                Button("Amend and Continue") {
                    Task {
                        await editor.amendAndContinue(message, from: session)
                        if editor.errorMessage == nil || editor.session?.status != .edit { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(editor.isBusy || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 520).interactiveDismissDisabled(editor.isExecuting)
    }
}
