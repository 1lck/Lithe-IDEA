import SwiftUI
import LitheGitModule

struct GitInteractiveRebasePresentation: ViewModifier {
    @ObservedObject var editor: GitInteractiveRebaseFeatureModel

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { editor.showsPlan }, set: { if !$0 { editor.dismissPlan() } })) {
            GitInteractiveRebasePlanView(editor: editor)
        }
    }
}

private struct GitInteractiveRebasePlanView: View {
    @ObservedObject var editor: GitInteractiveRebaseFeatureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Interactive Rebase").font(.system(size: 17, weight: .semibold))
            Text("Rewrite commits after the selected base through HEAD. The base commit stays in place. Steps run from top to bottom.")
                .font(.system(size: 12)).foregroundStyle(LitheTheme.secondaryText)
            if let preview = editor.preview {
                HStack {
                    Text("Branch: \(preview.branch ?? "—")")
                    Spacer()
                    Text("Base: \(preview.base.map { String($0.prefix(12)) } ?? "—")")
                    Text("HEAD: \(preview.head.map { String($0.prefix(12)) } ?? "—")")
                }
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                ForEach(Array(preview.blockers.enumerated()), id: \.offset) { _, blocker in
                    Text(blocker.message).font(.system(size: 12)).foregroundStyle(LitheTheme.warning)
                }
            }
            if editor.isLoading {
                HStack { ProgressView().controlSize(.small); Text("Checking the branch and affected commits…") }.font(.system(size: 12))
            }
            stepList
            messageEditor
            Text("\(editor.steps.count) affected commits → \(editor.outputCommitCount) commits. Core creates a recovery reference before starting.")
                .font(.system(size: 11)).foregroundStyle(LitheTheme.secondaryText)
            if let message = editor.validationMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(LitheTheme.warning)
            }
            if let error = editor.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(LitheTheme.error).textSelection(.enabled)
            }
            HStack {
                Button("Reload Range") { editor.reloadPreview() }.disabled(editor.isBusy).lithePointer()
                    .help("Reload the Core preview and reset the step plan")
                if editor.isExecuting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { editor.dismissPlan() }.keyboardShortcut(.cancelAction).disabled(editor.isExecuting).lithePointer()
                Button("Start Rebase") { Task { await editor.start() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!editor.canStart).lithePointer()
            }
        }
        .padding(20).frame(width: 720).background(LitheTheme.raised)
        .interactiveDismissDisabled(editor.isExecuting)
    }

    private var stepList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(editor.steps.enumerated()), id: \.element.hash) { index, step in
                    HStack(spacing: 8) {
                        Text("\(index + 1)").frame(width: 24, alignment: .trailing).foregroundStyle(LitheTheme.secondaryText)
                        Picker("Action for \(step.hash.prefix(9))", selection: Binding(
                            get: { step.action }, set: { editor.setAction($0, for: step.hash) }
                        )) {
                            ForEach(GitRebaseAction.allCases, id: \.self) { action in
                                Text(action.rawValue.capitalized).tag(action)
                            }
                        }
                        .labelsHidden().frame(width: 102)
                        Text(String(step.hash.prefix(9))).font(.system(size: 11, design: .monospaced))
                        Text(editor.subject(for: step.hash)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Button { editor.move(step.hash, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0).help("Move commit earlier").accessibilityLabel("Move commit earlier").lithePointer()
                        Button { editor.move(step.hash, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == editor.steps.count - 1).help("Move commit later").accessibilityLabel("Move commit later").lithePointer()
                    }
                    .font(.system(size: 12)).controlSize(.small).padding(6)
                    .background(editor.selectedHash == step.hash ? LitheTheme.accent.opacity(0.13) : Color.clear)
                    .contentShape(Rectangle()).onTapGesture { editor.selectedHash = step.hash }
                    .accessibilityAddTraits(editor.selectedHash == step.hash ? .isSelected : [])
                }
            }
        }
        .frame(height: 230).background(LitheTheme.inputBackground)
        .overlay(Rectangle().stroke(LitheTheme.divider, lineWidth: 1)).disabled(editor.isBusy)
    }

    @ViewBuilder private var messageEditor: some View {
        if let step = editor.selectedStep, step.action == .reword || step.action == .squash {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(step.action == .squash ? "Combined commit message" : "Commit message")
                    if step.action == .squash {
                        Button("Use Default Messages") { editor.useDefaultSquashMessage(for: step.hash) }
                            .controlSize(.small).disabled(editor.isBusy).lithePointer()
                            .help("Combine the messages when the rebase runs, including changes made at earlier Edit stops")
                    }
                    Spacer()
                    Text("\((step.message ?? "").count) characters").foregroundStyle(LitheTheme.secondaryText)
                }.font(.system(size: 11))
                TextEditor(text: Binding(get: { step.message ?? "" }, set: { editor.setMessage($0, for: step.hash) }))
                    .font(.system(size: 12, design: .monospaced)).frame(height: 125)
                    .overlay(Rectangle().stroke(LitheTheme.divider, lineWidth: 1)).disabled(editor.isBusy)
                    .accessibilityLabel("Complete commit message")
            }
        } else {
            Text("Pick preserves the commit. Edit pauses so you can amend staged changes. Squash combines messages; Fixup keeps the preceding message. Drop removes the commit.")
                .font(.system(size: 11)).foregroundStyle(LitheTheme.secondaryText)
                .frame(height: 60, alignment: .topLeading)
        }
    }
}
