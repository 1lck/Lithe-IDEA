import SwiftUI

/// Shown by Open when SSH connections are saved: the project is either a
/// folder on this Mac or a folder on one of those hosts.
struct OpenTargetChooserView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open Project")
                .font(LitheTheme.uiFont(size: 15, weight: .semibold))

            VStack(spacing: 8) {
                target(title: "Local Folder", detail: "Open a folder on this Mac", systemImage: "folder") {
                    dismiss()
                    // The sheet must be gone before the panel opens.
                    DispatchQueue.main.async { model.chooseLocalProject() }
                }
                target(title: "Remote Development", detail: "Open a folder on a saved SSH host",
                       systemImage: "server.rack") {
                    dismiss()
                    DispatchQueue.main.async { model.showRemoteConnections() }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(LitheActionButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(LitheTheme.window)
    }

    private func target(
        title: LocalizedStringKey, detail: LocalizedStringKey, systemImage: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(LitheTheme.uiFont(size: 18, weight: .regular))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(LitheTheme.uiFont(size: 13, weight: .medium))
                    Text(detail).font(LitheTheme.uiFont(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6).fill(LitheTheme.settingsSidebar))
    }
}
