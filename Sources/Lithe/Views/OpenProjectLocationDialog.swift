import SwiftUI

struct OpenProjectLocationDialog: View {
    @Environment(\.dismiss) private var dismiss
    let request: PendingProjectOpen
    let onResolve: (ProjectOpenPlacement, Bool) -> Void
    @State private var doNotAskAgain = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(LitheTheme.accent)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Open Project")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)

                    Text("Where would you like to open the project ‘\(request.projectName)’?")
                        .font(.system(size: 12.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Don't ask again", isOn: $doNotAskAgain)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lithePointer()
                        .padding(.top, 4)
                }

                Spacer(minLength: 0)
            }
            .padding(20)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            HStack(spacing: 9) {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .lithePointer()

                Button("New Window") {
                    onResolve(.newWindow, doNotAskAgain)
                }
                .buttonStyle(.bordered)
                .lithePointer()

                Button("This Window") {
                    onResolve(.thisWindow, doNotAskAgain)
                }
                .buttonStyle(.borderedProminent)
                .tint(LitheTheme.accent)
                .lithePointer()
            }
            .controlSize(.regular)
            .padding(14)
            .background(LitheTheme.toolHeader)
        }
        .frame(width: 470)
        .background(LitheTheme.window)
    }
}
