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
                    .font(LitheTheme.uiFont(size: LitheTheme.Commit.metadataFontSize))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .padding(.horizontal, LitheTheme.Commit.contentInset)
            .padding(.top, LitheTheme.Commit.messageVerticalGap)

            CommitMessageEditor(text: $draft.message, focused: $commitMessageFocused)
            .frame(maxWidth: .infinity, minHeight: 50, maxHeight: .infinity, alignment: .topLeading)
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
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(feature.workspaceCommitResults) { result in
                            (Text("\(result.root.lastPathComponent): ") + Text(LocalizedStringKey(result.detail))
                                + Text(verbatim: result.diagnostic.isEmpty ? "" : ": \(result.diagnostic)"))
                                .font(LitheTheme.uiFont(.caption)).help(result.root.path)
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

            HStack(spacing: 0) {
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
                .buttonStyle(CommitActionButtonStyle(isPrimary: true))
                .disabled(!canCommit)

                Button("Commit and Push…") {
                    Task { await commitWorkflow.commit(push: true) }
                }
                .buttonStyle(CommitActionButtonStyle())
                .disabled(!canCommit)

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
            }
            .padding(.leading, LitheTheme.Commit.contentInset - LitheTheme.Commit.buttonBorderInset)
            .padding(.trailing, LitheTheme.Commit.contentInset)
            .padding(.vertical, LitheTheme.Commit.buttonBorderInset)
        }
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

/// IDEA DarculaButtonUI/Painter: 28pt visible control, 3pt border insets,
/// 14pt label padding, 72pt minimum width, and regular UI font on macOS.
struct CommitActionButtonStyle: ButtonStyle {
    var isPrimary = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: LitheTheme.Commit.controlCornerRadius)
        configuration.label
            .font(LitheTheme.uiFont(size: 13, weight: .regular))
            .foregroundStyle(isEnabled ? (isPrimary ? Color.white : LitheTheme.searchFieldText) : LitheTheme.Commit.disabledText)
            .padding(.horizontal, LitheTheme.Commit.buttonHorizontalPadding)
            .frame(minWidth: LitheTheme.Commit.buttonMinimumWidth, minHeight: LitheTheme.Commit.buttonHeight)
            .background(shape.fill(isPrimary && isEnabled ? LitheTheme.searchFieldFocusBorder
                                                          : isEnabled ? LitheTheme.Commit.buttonBackground(for: colorScheme) : .clear))
            .overlay(shape.strokeBorder(isEnabled ? (isPrimary ? LitheTheme.searchFieldFocusBorder : LitheTheme.searchFieldBorder)
                                                  : LitheTheme.Commit.disabledBorder, lineWidth: 1))
            .padding(LitheTheme.Commit.buttonBorderInset)
            .contentShape(Rectangle())
    }
}

/// Observe the plan directly so a changed selection updates the open sheet.
private struct WorkspaceCommitPlanView: View {
    @ObservedObject var feature: GitFeatureModel
    let commitWorkflow: CommitWorkflowCoordinator

    var body: some View {
        if let plan = feature.pendingSubmoduleCommitPlan {
            VStack(alignment: .leading, spacing: 12) {
                Text(LocalizedStringKey(plan.isRetry ? "Review remaining steps" : "Review repository commits")).font(LitheTheme.uiFont(.headline))
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
