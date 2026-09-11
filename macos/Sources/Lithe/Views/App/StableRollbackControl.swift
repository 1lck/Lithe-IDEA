import SwiftUI

struct StableRollbackControl: View {
    var compact = false
    @EnvironmentObject private var updateChecker: UpdateChecker
    @State private var confirming = false
    @State private var showingDetails = false

    var body: some View {
        if compact, updateChecker.isPreview {
            Button("Return to Stable") { showingDetails = true }
                .font(LitheTheme.smallFont)
                .buttonStyle(.plain)
                .sheet(isPresented: $showingDetails) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Return to Stable").font(.headline)
                        StableRollbackControl().environmentObject(updateChecker)
                        Button("Close") { showingDetails = false }
                    }
                    .padding(20)
                    .frame(width: 420)
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if updateChecker.isPreview {
            VStack(alignment: .leading, spacing: 8) {
                switch updateChecker.stableRollback.state {
                case .idle, .failed:
                    Button {
                        confirming = true
                    } label: {
                        Label("Return to Stable", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!updateChecker.canReturnToStable)
                case .downloading, .preparing:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(LocalizedStringKey(updateChecker.stableRollback.state == .downloading
                             ? "Downloading full stable release…" : "Verifying stable release…"))
                        Button("Cancel") { updateChecker.stableRollback.cancel() }
                    }
                case .cancelling:
                    Text("Cancelling…")
                case .ready(let version):
                    Text("Stable release \(version) is ready.")
                    HStack {
                        Button("Install and Restart") { updateChecker.stableRollback.install() }
                        Button("Cancel") { updateChecker.stableRollback.cancel() }
                    }
                case .requestingTermination, .installing:
                    Text("Waiting to quit to complete the update.")
                }
                if case .failed(let message) = updateChecker.stableRollback.state {
                    Text(message).foregroundStyle(LitheTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Release Page") { updateChecker.openRelease(UpdateChecker.releasePageURL) }
                }
            }
            .font(LitheTheme.smallFont)
            .buttonStyle(LitheSecondaryButtonStyle())
            .alert("Return to Stable?", isPresented: $confirming) {
                Button("Cancel", role: .cancel) {}
                Button("Download Stable Release") { updateChecker.returnToStable() }
            } message: {
                Text("The latest stable release will be downloaded in full and replace this preview after you confirm installation. Projects and settings are kept, but preview-only settings may not work in the stable release.")
            }
        }
    }
}
