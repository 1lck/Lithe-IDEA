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
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Toggle(isOn: $draft.amend) {
                    Text("Amend") + Text(" last commit").foregroundColor(LitheTheme.accent)
                }
                    .toggleStyle(.checkbox)
                    .font(LitheTheme.uiFont(size: LitheTheme.Commit.amendFontSize))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("git-commit-amend")
                LitheIDEAIcon(resourcePath: "expui/general/history.svg", size: LitheTheme.Commit.actionIconSize,
                              fallbackSystemImage: "clock", preservesOriginalColors: true)
                Spacer()
                Button {
                    Task { await commitWorkflow.generateMessage() }
                } label: {
                    HStack(spacing: 4) {
                        if draft.isGenerating {
                            ProgressView().controlSize(.mini)
                        } else {
                            LitheIDEAIcon(resourcePath: "expui/diff/magicResolveToolbar.svg", size: LitheTheme.Commit.actionIconSize,
                                          fallbackSystemImage: "wand.and.stars", preservesOriginalColors: true)
                        }
                        Text("AI")
                    }
                }
                .buttonStyle(
                    LitheActionButtonStyle()
                )
                .disabled(
                    stagedChanges.isEmpty ||
                        feature.isLoadingDiff ||
                        draft.isGenerating
                )
                .help("Generate a commit message from staged diffs")
                .accessibilityIdentifier("git-commit-ai")
                Text("\(stagedChanges.count) staged")
                    .font(LitheTheme.uiFont(size: LitheTheme.Commit.metadataFontSize))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, LitheTheme.Commit.contentInset)
            .padding(.top, LitheTheme.Commit.messageVerticalGap)

            CommitMessageEditor(text: $draft.message, focused: $commitMessageFocused)
            .frame(maxWidth: .infinity, minHeight: LitheTheme.Commit.messageMinimumHeight, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: LitheTheme.Commit.controlCornerRadius)
                    .fill(LitheTheme.editor)
                    .padding(1.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: LitheTheme.Commit.controlCornerRadius)
                    .strokeBorder(
                        commitMessageFocused ? LitheTheme.searchFieldFocusBorder : LitheTheme.searchFieldBorder,
                        lineWidth: commitMessageFocused ? 2 : 1
                    )
                    .padding(commitMessageFocused ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, LitheTheme.Commit.messageHorizontalGap)
            .padding(.vertical, LitheTheme.Commit.messageVerticalGap)

            if !feature.workspaceCommitResults.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: LitheTheme.ActionButton.spacing) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(feature.workspaceCommitResults) { result in
                                (Text("\(result.root.lastPathComponent): ") + Text(LocalizedStringKey(result.detail))
                                    + Text(verbatim: result.diagnostic.isEmpty ? "" : ": \(result.diagnostic)"))
                                    .font(LitheTheme.uiFont(.caption)).help(result.root.path)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button("Dismiss Results") { feature.dismissWorkspaceCommitResults() }
                            .buttonStyle(LitheActionButtonStyle())
                            .disabled(feature.isCommitting)
                        if feature.canRetryWorkspaceCommit {
                            Button("Review and Retry…") {
                                Task { await feature.prepareWorkspaceCommitRetry() }
                            }
                            .buttonStyle(LitheActionButtonStyle())
                            .help("Review and Retry Unfinished Steps…")
                            .disabled(feature.isCommitting)
                            .accessibilityIdentifier("git-commit-retry")
                        }
                    }
                }.frame(minHeight: 0, maxHeight: LitheTheme.Commit.resultsMaximumHeight)
            }

            HStack(spacing: LitheTheme.ActionButton.spacing) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LitheTheme.ActionButton.spacing) { commitActionButtons }
                    VStack(alignment: .leading, spacing: LitheTheme.ActionButton.spacing) { commitActionButtons }
                }

                Spacer(minLength: 0)
                Button {
                    showSettings(.ai)
                } label: {
                    LitheIDEAIcon(resourcePath: "expui/general/settings.svg", size: LitheTheme.Commit.actionIconSize,
                                  fallbackSystemImage: "gearshape", preservesOriginalColors: true)
                }
                .buttonStyle(LitheIconButtonStyle(size: 22, cornerRadius: 4))
                .workbenchHoverHelp(Text("Open AI & Commit settings"))
                .accessibilityLabel("Open AI & Commit settings")
                .accessibilityIdentifier("git-commit-settings")
            }
            .padding(.leading, LitheTheme.Commit.contentInset)
            .padding(.trailing, LitheTheme.Commit.contentInset)
            .padding(.vertical, LitheTheme.ActionButton.spacing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(hasBackgroundImage ? Color.clear : LitheTheme.toolHeader)
        .onChange(of: draft.commitEditorRequestVersion) { _ in commitMessageFocused = true }
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

    @ViewBuilder
    private var commitActionButtons: some View {
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
        .buttonStyle(LitheActionButtonStyle(isPrimary: true))
        .accessibilityIdentifier("git-commit-submit")
        .disabled(!canCommit)

        Button("Commit and Push…") {
            Task { await commitWorkflow.commit(push: true) }
        }
        .buttonStyle(LitheActionButtonStyle())
        .accessibilityIdentifier("git-commit-and-push")
        .disabled(!canCommit)
    }

    private var stagedChanges: [GitChange] {
        // Commit operates on every repository in the workspace, not only the
        // repository selected by the branch toolbar.
        feature.activeChangelistChanges.filter(\.isStaged)
    }

    private var canCommit: Bool {
        feature.changelistCommitError == nil && !feature.changelistEditingDisabled && !stagedChanges.isEmpty &&
            !draft.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !feature.isCommitting && !feature.isStagingChanges && !feature.isWorktreeCommitBlocked && feature.pendingSubmoduleCommitPlan == nil && !feature.canRetryWorkspaceCommit
    }

}

/// Observe the plan directly so a changed selection updates the open sheet.
private struct WorkspaceCommitPlanView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var feature: GitFeatureModel
    let commitWorkflow: CommitWorkflowCoordinator

    var body: some View {
        if let plan = feature.pendingSubmoduleCommitPlan {
            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizedStringKey(plan.isRetry ? "Review remaining steps" : (plan.push ? "Review commit and push" : "Review repository commits")))
                    .font(LitheTheme.uiFont(.headline))
                Text("Each repository has its own commit. Completed steps are kept if another repository fails.")
                Text("Commit message: \(plan.message)").font(LitheTheme.uiFont(.caption))
                if plan.amend { Text("Amend applies to repositories with selected files.").font(LitheTheme.uiFont(.caption)) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(plan.orderedRoots.enumerated()), id: \.element) { index, root in
                            VStack(alignment: .leading, spacing: 2) {
                                let action = plan.committedRoots.contains(root) ? "Push only" : (plan.push ? "Commit and push" : "Commit")
                                (Text("\(index + 1). ") + Text(LocalizedStringKey(action)) + Text(": \(root.path)"))
                                if let state = plan.states[root] {
                                    Text("\(state.branch ?? "Detached HEAD") · \(state.head?.prefix(10) ?? "New repository")")
                                        .font(LitheTheme.uiFont(.caption)).foregroundStyle(.secondary)
                                    if plan.push { pushTargetRow(plan: plan, root: root) }
                                    if !plan.committedRoots.contains(root) {
                                        ForEach(state.stagedPaths, id: \.self) { path in
                                            Text(path).font(LitheTheme.uiFont(.caption))
                                        }
                                    }
                                }
                            }
                        }
                        ForEach(plan.propagatedRelations, id: \.self) { relation in
                            Text("Update \(relation.parent.lastPathComponent)/\(relation.path) after \(relation.child.lastPathComponent)")
                                .font(LitheTheme.uiFont(.caption))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 260)
                Toggle("Update parent repository references", isOn: Binding(
                    get: { plan.includeParentReferences },
                    set: { include in Task { await feature.setCommitPlanParentReferences(include) } }
                )).disabled(feature.isCommitting)
                if plan.push { Text("Each submodule is pushed before its parent.").font(LitheTheme.uiFont(.caption)) }
                HStack(spacing: LitheTheme.ActionButton.spacing) {
                    if plan.needsPushTargetChoice {
                        Text("Choose which branch to update before pushing.")
                            .font(LitheTheme.uiFont(.caption))
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                    Spacer()
                    Button("Cancel") { feature.cancelPendingSubmoduleCommit() }.buttonStyle(LitheActionButtonStyle())
                    Button(LocalizedStringKey(plan.push ? "Commit and Push" : "Continue")) {
                        Task { await commitWorkflow.confirmPendingSubmoduleCommit() }
                    }
                    .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.needsPushTargetChoice)
                }.disabled(feature.isCommitting)
            }.padding(20).frame(width: 540)
        }
    }

    /// Where this repository's branch goes. A differently named upstream is never
    /// pushed to implicitly: the user picks the branch, and Continue stays off until
    /// every such repository has an answer.
    @ViewBuilder
    private func pushTargetRow(plan: GitSubmoduleCommitPlan, root: URL) -> some View {
        if let question = plan.pushQuestion(for: root) {
            let chosen = plan.confirmedPushTarget(for: root)?.choice
            VStack(alignment: .leading, spacing: 6) {
                Text("Branch '\(question.localBranch)' tracks '\(question.upstream)', which has a different name. Choose which branch to update.")
                    .font(LitheTheme.uiFont(.caption))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    pushChoiceButton(.publish, chosen: chosen, question: question) {
                        Text("Publish to \(question.remote)/\(question.localBranch)")
                    }
                    pushChoiceButton(.upstream, chosen: chosen, question: question) {
                        Text("Push to \(question.upstream)")
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LitheTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        } else if let confirmed = plan.confirmedPushTarget(for: root) {
            pushDestinationLabel("\(confirmed.remote)/\(confirmed.remoteBranch)", note: nil)
        } else if let preview = plan.pushDestinations[root] {
            pushDestinationLabel(preview.destination, note: GitPushDialogPresentation(preview: preview, locale: locale).note)
        }
    }

    private func pushDestinationLabel(_ destination: String, note: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.right").font(LitheTheme.uiFont(.caption))
            Text(verbatim: destination).foregroundStyle(LitheTheme.accent)
            if let note { Text(verbatim: note).foregroundStyle(LitheTheme.secondaryText) }
        }
        .font(LitheTheme.uiFont(.caption))
    }

    private func pushChoiceButton<Label: View>(
        _ choice: GitPushTargetChoice,
        chosen: GitPushTargetChoice?,
        question: GitWorkspacePushTargetQuestion,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            Task { await feature.choosePushTarget(choice, for: question) }
        } label: {
            label().lineLimit(1)
        }
        .buttonStyle(.bordered)
        .tint(chosen == choice ? LitheTheme.accent : nil)
        .lithePointer()
    }
}
