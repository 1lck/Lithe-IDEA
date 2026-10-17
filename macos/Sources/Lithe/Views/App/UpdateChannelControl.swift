import SwiftUI

struct UpdateChannelControl: View {
    @EnvironmentObject private var updateChecker: UpdateChecker
    @State private var confirmingAutoBuild = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LitheSettingsSelect(selection: Binding(
                get: { updateChecker.selectedChannel },
                set: { channel in
                    if channel == .autobuild {
                        confirmingAutoBuild = true
                    } else {
                        updateChecker.selectChannel(.stable)
                    }
                }
            ), options: AppUpdateChannel.allCases, width: 240,
                accessibilityLabel: "Update channel", title: { $0.label }, expandsToFitOptions: true)
            .disabled(!updateChecker.canChangeChannel)

            Text("AutoBuild is rebuilt nightly and may contain unfinished features, serious bugs, or other problems. Stable releases are recommended for most users.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(updateChecker.selectedChannel == .autobuild ? LitheTheme.warning : LitheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if updateChecker.needsChannelInstallation {
                Text("Changing channels requires a full installation and may install an older version. On its first launch, Lithe-Dev copies Stable settings and workspaces if it has no user data. The apps then save settings and caches separately. Some accounts may need sign-in again. Your project files stay in their current locations.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button(LocalizedStringKey(updateChecker.selectedChannel == .autobuild
                    ? "Open AutoBuild Downloads" : "Open Stable Downloads")) {
                    updateChecker.openRelease(updateChecker.selectedReleaseURL)
                }
                .buttonStyle(LitheSecondaryButtonStyle())
                .disabled(!updateChecker.canChangeChannel)
            }
        }
        .alert("Use AutoBuild Rolling?", isPresented: $confirmingAutoBuild) {
            Button("Cancel", role: .cancel) {}
            Button("Use AutoBuild") {
                updateChecker.selectChannel(.autobuild, acknowledgingRisk: true)
            }
        } message: {
            Text("AutoBuild is rebuilt nightly and may contain unfinished features, serious bugs, or other problems. Stable releases are recommended for most users.")
        }
    }
}
