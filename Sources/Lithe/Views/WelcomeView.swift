import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Text("Welcome to Lithe")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(LitheTheme.window)
                .overlay(alignment: .bottom) {
                    Divider().overlay(LitheTheme.divider)
                }

            HStack(spacing: 0) {
                welcomeSidebar
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                projectsContent
            }
        }
    }

    private var welcomeSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(LitheTheme.accent)
                    Text("LI")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Lithe")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                    Text("0.1.0 · macOS")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 48)
            .padding(.bottom, 44)

            Label("Projects", systemImage: "folder")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 48)
                .background(LitheTheme.selection)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 20)

            Spacer()

            Button {
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17))
            }
            .litheIconButton()
            .padding(22)
        }
        .frame(width: 330)
        .background(LitheTheme.sidebar)
    }

    private var projectsContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundStyle(LitheTheme.secondaryText)
                Text("Open a project to begin reviewing changes")
                    .font(.system(size: 15))
                    .foregroundStyle(LitheTheme.secondaryText)

                Spacer()

                Button("Open") {
                    model.chooseProject()
                }
                .buttonStyle(LitheSecondaryButtonStyle())
            }
            .padding(.horizontal, 34)
            .frame(height: 92)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
                .padding(.horizontal, 24)

            VStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(LitheTheme.secondaryText)
                Text("No recent projects")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                Text("Open a local folder. Lithe will remember it here.")
                    .font(LitheTheme.uiFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LitheTheme.window)
    }
}

private struct LitheSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 24)
            .frame(height: 36)
            .background(configuration.isPressed ? LitheTheme.subtleSelection : LitheTheme.raised)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
