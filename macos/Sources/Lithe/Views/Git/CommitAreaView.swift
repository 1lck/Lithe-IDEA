import SwiftUI
import LitheGitModule

struct CommitAreaView: View {
    @ObservedObject var feature: GitFeatureModel
    @ObservedObject var draft: CommitDraftFeatureModel
    let commitWorkflow: CommitWorkflowCoordinator
    let hasBackgroundImage: Bool
    let showSettings: (SettingsCategory) -> Void
    @State private var commitMessageFocused = false
    @State private var showsSubmoduleCommitPlan = false

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
        .onChange(of: feature.pendingSubmoduleCommitPlan?.id) { planID in
            showsSubmoduleCommitPlan = planID != nil
        }
        .confirmationDialog(
            "Commit parent repository and submodule separately?",
            isPresented: $showsSubmoduleCommitPlan,
            titleVisibility: .visible
        ) {
            Button("Continue") {
                Task { await commitWorkflow.confirmPendingSubmoduleCommit() }
            }
            .lithePointer()
            Button("Cancel", role: .cancel) {
                feature.cancelPendingSubmoduleCommit()
            }
            .lithePointer()
        } message: {
            if let plan = feature.pendingSubmoduleCommitPlan {
                Text(submoduleCommitPlanMessage(plan))
            }
        }
    }

    private func submoduleCommitPlanMessage(_ plan: GitSubmoduleCommitPlan) -> String {
        let order = plan.orderedRoots.enumerated().map { index, root in
            "\(index + 1). \(root.lastPathComponent)"
        }.joined(separator: "\n")
        let propagation = plan.propagatedRelations.isEmpty
            ? "The selected changes do not include a parent submodule reference; only the selected repositories will be committed."
            : "The selected parent submodule reference will be restaged after the child commit, then committed in the parent repository."
        let push = plan.push
            ? "For Commit and Push, each child is pushed before its parent."
            : "Repositories are committed in child-to-parent order."
        return "This selection includes a Git submodule relationship.\n\nCommit order:\n\(order)\n\n\(propagation) \(push)\n\nThese are separate Git commits; if one repository fails, earlier commits are kept."
    }

    private var stagedChanges: [GitChange] {
        // Commit operates on every repository in the workspace, not only the
        // repository selected by the branch toolbar.
        feature.gitChanges.filter(\.isStaged)
    }

    private var canCommit: Bool {
        !stagedChanges.isEmpty &&
            !draft.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !feature.isCommitting
    }

}
