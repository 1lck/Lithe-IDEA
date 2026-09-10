import SwiftUI

struct UpdateControl: View {
    let compact: Bool

    @EnvironmentObject private var updateChecker: UpdateChecker
    @State private var isDetailsPresented = false

    init(compact: Bool = false) {
        self.compact = compact
    }

    var body: some View {
        Group {
            switch updateChecker.status {
            case .available(let version, _):
                Button {
                    isDetailsPresented = true
                } label: {
                    Label(
                        compact ? "Update \(version)" : "Update to \(version)",
                        systemImage: "arrow.down.circle.fill"
                    )
                }
                .buttonStyle(LitheSecondaryButtonStyle())
            case .checking:
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking for updates…")
                }
                .foregroundStyle(LitheTheme.secondaryText)
            case .downloading(let version, let progress):
                HStack(spacing: 6) {
                    if let fractionCompleted = progress.fractionCompleted {
                        ProgressView(value: fractionCompleted)
                            .frame(width: compact ? 64 : 92)
                        Text("\(progress.percentage ?? 0)%")
                            .monospacedDigit()
                    } else {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing…")
                    }
                    if !compact {
                        Text("Downloading \(version)…")
                    }
                }
                .foregroundStyle(LitheTheme.secondaryText)
            case .installing(let version):
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                    Text(compact ? "Installing…" : "Installing update \(version)…")
                }
                .foregroundStyle(LitheTheme.secondaryText)
            case .failed(_, let message):
                Button {
                    if updateChecker.updateInfo != nil {
                        isDetailsPresented = true
                    } else {
                        checkForUpdates()
                    }
                } label: {
                    Label(compact ? "Update failed" : "Retry update", systemImage: "exclamationmark.triangle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(LitheTheme.warning)
                .help(message)
            case .idle, .upToDate:
                Button {
                    checkForUpdates()
                } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(LitheTheme.secondaryText)
            }
        }
        .font(.system(size: compact ? 11.5 : 10.5, weight: .medium))
        .lithePointer()
        .sheet(isPresented: $isDetailsPresented) {
            UpdateDetailsView()
                .environmentObject(updateChecker)
        }
    }

    private func checkForUpdates() {
        Task { await updateChecker.checkForUpdates(manual: true) }
    }
}

private struct UpdateDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var updateChecker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Software Update")
                        .font(.system(size: 16, weight: .semibold))
                    if let updateInfo = updateChecker.updateInfo {
                        Text("Lithe \(updateInfo.currentVersion) → \(updateInfo.targetVersion)")
                            .font(LitheTheme.smallFont)
                            .foregroundStyle(LitheTheme.secondaryText)
                        if let releaseDate = updateInfo.releaseDate {
                            Text("Released \(releaseDate)")
                                .font(LitheTheme.smallFont)
                                .foregroundStyle(LitheTheme.tertiaryText)
                        }
                    }
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .litheIconButton()
                .help("Close")
            }
            .padding(16)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let updateInfo = updateChecker.updateInfo {
                        let releaseNotes = updateInfo.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        Text("Release notes")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LitheTheme.secondaryText)
                        Text(releaseNotes.isEmpty ? "Release notes are not included with this update." : releaseNotes)
                            .font(.system(size: 12.5))
                            .foregroundStyle(LitheTheme.primaryText)
                            .textSelection(.enabled)

                        statusContent()
                    }
                }
                .padding(16)
            }
            .frame(minHeight: 180, maxHeight: 360)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            HStack(spacing: 10) {
                Button("Open Release Page") {
                    updateChecker.openRelease(updateChecker.updateInfo?.releaseURL)
                }
                .buttonStyle(LitheSecondaryButtonStyle())

                Spacer()

                if case .available = updateChecker.status {
                    Button("Later") {
                        updateChecker.remindLater()
                        dismiss()
                    }
                    .buttonStyle(LitheSecondaryButtonStyle())
                    Button("Skip Version") {
                        updateChecker.skipVersion()
                        dismiss()
                    }
                    .buttonStyle(LitheSecondaryButtonStyle())
                    Button("Install") {
                        dismiss()
                        Task { await updateChecker.installAvailableUpdate() }
                    }
                    .buttonStyle(LithePrimaryButtonStyle())
                } else if case .failed = updateChecker.status {
                    Button("Retry") {
                        dismiss()
                        Task { await updateChecker.retryInstallation() }
                    }
                    .buttonStyle(LithePrimaryButtonStyle())
                }
            }
            .padding(16)
        }
        .frame(width: 560)
        .background(LitheTheme.popupBackground)
    }

    @ViewBuilder
    private func statusContent() -> some View {
        switch updateChecker.status {
        case .downloading(_, let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress.fractionCompleted ?? 0)
                Text("Downloading update… \(progress.byteCountDescription)")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
        case .installing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing update…")
            }
            .foregroundStyle(LitheTheme.secondaryText)
        case .failed(_, let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(LitheTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }
}
