import SwiftUI
import LitheGitModule

struct CommitAreaView: View {
    @ObservedObject var feature: GitFeatureModel
    @ObservedObject var draft: CommitDraftFeatureModel
    let commitWorkflow: CommitWorkflowCoordinator
    let hasBackgroundImage: Bool
    let showSettings: (SettingsCategory) -> Void
    @State private var commitMessageFocused = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Toggle(isOn: $draft.amend) {
                    Text("Amend") + Text(" last commit").foregroundColor(LitheTheme.accent)
                }
                    .toggleStyle(.checkbox)
                    .lithePointer()
                    .font(.system(size: LitheTheme.Commit.amendFontSize))
                LitheSystemIcon(systemImage: "clock", size: LitheTheme.Commit.actionIconSize)
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer()
                Button {
                    Task { await commitWorkflow.generateMessage() }
                } label: {
                    HStack(spacing: 4) {
                        if draft.isGenerating {
                            ProgressView().controlSize(.mini)
                        } else {
                            LitheSystemIcon(systemImage: "wand.and.stars", size: LitheTheme.Commit.actionIconSize)
                        }
                        Text("AI")
                    }
                }
                .buttonStyle(
                    LitheSecondaryButtonStyle(
                        horizontalPadding: LitheTheme.Commit.compactButtonPadding,
                        height: LitheTheme.Commit.compactButtonHeight,
                        fontSize: LitheTheme.Commit.compactButtonFontSize
                    )
                )
                .disabled(
                    stagedChanges.isEmpty ||
                        feature.isLoadingDiff ||
                        draft.isGenerating
                )
                .help("Generate a commit message from staged diffs")
                Text("\(stagedChanges.count) staged")
                    .font(.system(size: LitheTheme.Commit.metadataFontSize))
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            CommitMessageEditor(text: $draft.message, focused: $commitMessageFocused)
            .frame(maxWidth: .infinity, minHeight: 50, maxHeight: .infinity, alignment: .topLeading)
            .litheRoundedControlBackground(LitheTheme.editor)
            .overlay {
                RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                    .strokeBorder(
                        commitMessageFocused ? LitheTheme.selection : LitheTheme.divider,
                        lineWidth: commitMessageFocused ? 2 : 1
                    )
                    .allowsHitTesting(false)
            }

            if !feature.workspaceCommitResults.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(feature.workspaceCommitResults) { result in
                            (Text("\(result.root.lastPathComponent): ") + Text(LocalizedStringKey(result.detail))
                                + Text(verbatim: result.diagnostic.isEmpty ? "" : ": \(result.diagnostic)"))
                                .font(.caption).help(result.root.path)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 90)
                Button("Dismiss Results") { feature.dismissWorkspaceCommitResults() }
                    .disabled(feature.isCommitting)
                if feature.canRetryWorkspaceCommit {
                    Button("Review and Retry Unfinished Steps…") {
                        Task { await feature.prepareWorkspaceCommitRetry() }
                    }.disabled(feature.isCommitting)
                }
            }

            HStack(spacing: 8) {
                Button {
                    Task { await commitWorkflow.commit() }
                } label: {
                    HStack(spacing: 6) {
                        if feature.isCommitting {
                            ProgressView().controlSize(.mini)
                        }
                        Text("Commit")
                    }
                }
                .buttonStyle(LithePrimaryButtonStyle())
                .disabled(!canCommit)

                Button("Commit and Push…") {
                    Task { await commitWorkflow.commit(push: true) }
                }
                .buttonStyle(LitheSecondaryButtonStyle())
                .disabled(!canCommit)

                Spacer(minLength: 0)
                Button {
                    showSettings(.ai)
                } label: {
                    LitheSystemIcon(systemImage: "gearshape")
                }
                .litheIconButton()
                .help("Open AI & Commit settings")
            }
        }
        .padding(LitheTheme.Commit.panelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(hasBackgroundImage ? Color.clear : LitheTheme.toolHeader)
        .confirmationDialog(
            "Replace current commit message?",
            isPresented: Binding(
                get: { draft.pendingGeneratedMessage != nil },
                set: { if !$0 { draft.discardGeneratedMessage() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Replace") {
                commitWorkflow.applyGeneratedMessage()
            }
            .lithePointer()
            Button("Keep Current", role: .cancel) {
                draft.discardGeneratedMessage()
            }
            .lithePointer()
        } message: {
            Text("The generated message will replace the text currently in the editor.")
        }
        .sheet(isPresented: Binding(
            get: { feature.pendingSubmoduleCommitPlan != nil },
            set: { if !$0 { feature.cancelPendingSubmoduleCommit() } }
        )) {
            WorkspaceCommitPlanView(feature: feature, commitWorkflow: commitWorkflow)
        }
    }

    private var stagedChanges: [GitChange] {
        // Commit operates on every repository in the workspace, not only the
        // repository selected by the branch toolbar.
        feature.gitChanges.filter(\.isStaged)
    }

    private var canCommit: Bool {
        !stagedChanges.isEmpty &&
            !draft.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !feature.isCommitting && !feature.isStagingChanges && feature.pendingSubmoduleCommitPlan == nil && !feature.canRetryWorkspaceCommit
    }

}

/// Observe the plan directly so a changed selection updates the open sheet.
private struct WorkspaceCommitPlanView: View {
    @ObservedObject var feature: GitFeatureModel
    let commitWorkflow: CommitWorkflowCoordinator

    var body: some View {
        if let plan = feature.pendingSubmoduleCommitPlan {
            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizedStringKey(plan.isRetry ? "Review remaining steps" : "Review repository commits")).font(.headline)
                Text("Each repository has its own commit. Completed steps are kept if another repository fails.")
                Text("Commit message: \(plan.message)").font(.caption)
                if plan.amend { Text("Amend applies to repositories with selected files.").font(.caption) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(plan.orderedRoots.enumerated()), id: \.element) { index, root in
                            VStack(alignment: .leading, spacing: 2) {
                                let action = plan.committedRoots.contains(root) ? "Push only" : (plan.push ? "Commit and push" : "Commit")
                                (Text("\(index + 1). ") + Text(LocalizedStringKey(action)) + Text(": \(root.path)"))
                                if let state = plan.states[root] {
                                    Text("\(state.branch ?? "Detached HEAD") · \(state.head?.prefix(10) ?? "New repository")")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !plan.committedRoots.contains(root) {
                                        ForEach(state.stagedPaths, id: \.self) { path in
                                            Text(path).font(.caption)
                                        }
                                    }
                                }
                            }
                        }
                        ForEach(plan.propagatedRelations, id: \.self) { relation in
                            Text("Update \(relation.parent.lastPathComponent)/\(relation.path) after \(relation.child.lastPathComponent)")
                                .font(.caption)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 260)
                Toggle("Update parent repository references", isOn: Binding(
                    get: { plan.includeParentReferences },
                    set: { include in Task { await feature.setCommitPlanParentReferences(include) } }
                )).disabled(feature.isCommitting)
                if plan.push { Text("Each submodule is pushed before its parent.").font(.caption) }
                HStack {
                    Spacer()
                    Button("Cancel") { feature.cancelPendingSubmoduleCommit() }
                    Button("Continue") { Task { await commitWorkflow.confirmPendingSubmoduleCommit() } }
                        .keyboardShortcut(.defaultAction)
                }.disabled(feature.isCommitting)
            }.padding(20).frame(width: 540)
        }
    }
}
