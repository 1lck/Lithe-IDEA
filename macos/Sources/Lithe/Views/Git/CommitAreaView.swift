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
    }

    private var stagedChanges: [GitChange] {
        feature.activeRepositoryChanges.filter(\.isStaged)
    }

    private var canCommit: Bool {
        !stagedChanges.isEmpty &&
            !draft.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !feature.isCommitting
    }

}
