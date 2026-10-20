import SwiftUI

struct OpenProjectLocationDialog: View {
    let request: PendingProjectOpen
    let onResolve: (ProjectOpenPlacement, Bool) -> Void
    let onCancel: () -> Void
    @State private var doNotAskAgain = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                LitheIDEAIcon(resourcePath: "expui/general/questionMark.svg", size: 16, preservesOriginalColors: true)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Where would you like to open the project ‘\(request.projectName)’?")
                        .font(LitheTheme.uiFont(size: 13))
                        .foregroundStyle(LitheTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    LitheSettingsCheckbox(isOn: $doNotAskAgain, title: "Don't ask again")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 3)

            HStack(spacing: 0) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(LitheActionButtonStyle())
                    .keyboardShortcut(.cancelAction)

                Button("New Window") {
                    onResolve(.newWindow, doNotAskAgain)
                }
                .buttonStyle(LitheActionButtonStyle())

                Button("This Window") {
                    onResolve(.thisWindow, doNotAskAgain)
                }
                .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .frame(width: 470)
        .fixedSize(horizontal: false, vertical: true)
        .background(LitheCommitDialogStyle.background)
        .environment(\.lithePointingHandCursorEnabled, false)
        .onExitCommand(perform: onCancel)
    }
}
