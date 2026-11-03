import LitheModuleAPI
import SwiftUI

struct CommitFileDeletionPresentation: ViewModifier {
    @ObservedObject var feature: CommitFileDeletionFeatureModel

    func body(content: Content) -> some View {
        content.background(LitheCenteredPopup(isPresented: Binding(
            get: { feature.pending != nil }, set: { if !$0 { feature.cancel() } }),
            dialogTitle: L10n.string("Delete Files")) {
                if let request = feature.pending {
                    CommitFileDeletionDialog(request: request, onCancel: { feature.cancel() },
                                             onDelete: { feature.beginConfirmation(request) })
                }
            }.frame(width: 0, height: 0).allowsHitTesting(false))
    }
}

struct CommitFileDeletionDialog: View {
    let request: CommitFileDeletionFeatureModel.Request
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if request.usesVcs {
                    Text("The version control provider will delete these files and record their removal. They may not be moved to Trash.")
                } else {
                    Text("These files will be moved to the macOS Trash.")
                }
            }
                .font(LitheTheme.uiFont(size: 13))
                .accessibilityIdentifier("commit-files-delete-warning")
            ScrollView {
                Text(verbatim: request.urls.map(\.path).joined(separator: "\n"))
                    .font(LitheTheme.uiFont(size: 12)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.litheScrollViewChrome().frame(maxHeight: 200)
            HStack(spacing: LitheTheme.ActionButton.spacing) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(LitheActionButtonStyle()).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("commit-files-delete-cancel")
                Button("Delete", action: onDelete)
                    .buttonStyle(LitheActionButtonStyle(isPrimary: true)).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("commit-files-delete-confirm")
            }
        }.padding(20).frame(width: 520).background(LitheCommitDialogStyle.background)
    }
}
