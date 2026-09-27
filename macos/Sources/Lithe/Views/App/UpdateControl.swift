import SwiftUI

struct UpdateControl: View {
    let compact: Bool

    @EnvironmentObject private var updateChecker: UpdateChecker

    init(compact: Bool = false) {
        self.compact = compact
    }

    var body: some View {
        Group {
            switch updateChecker.status {
            case .available(let version, _):
                Button {
                    updateChecker.presentDetails()
                } label: {
                    if updateChecker.isPreview {
                        Label("Preview Update", systemImage: "arrow.down.circle.fill")
                    } else {
                        Label(compact ? "Update \(version)" : "Update to \(version)",
                              systemImage: "arrow.down.circle.fill")
                    }
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
                // The title bar has room for a single row; the Welcome sidebar does
                // not, so the version text wraps onto its own line below the bar.
                VStack(alignment: .leading, spacing: compact ? 0 : 5) {
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
                    }
                    if !compact {
                        Text("Downloading \(version)…")
                    }
                }
                .foregroundStyle(LitheTheme.secondaryText)
            case .waitingForTermination:
                Button {
                    Task { await updateChecker.retryInstallation() }
                } label: {
                    Label("Continue Installation", systemImage: "arrow.clockwise")
                }
                .buttonStyle(LitheSecondaryButtonStyle())
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
                        updateChecker.presentDetails()
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
    }

    private func checkForUpdates() {
        Task { await updateChecker.checkForUpdates(manual: true, presentingDetails: true) }
    }
}

/// Content of the single Software Update window. Every entry point opens it
/// through `UpdateChecker.presentDetails()`, so an update found from the menu
/// is offered in the same place as one found by the title bar control.
struct UpdateDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var updateChecker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(updateChecker.isPreview ? "Preview Update" : "Software Update"))
                        .font(.system(size: 16, weight: .semibold))
                    if let updateInfo = updateChecker.updateInfo {
                        if updateInfo.isPreview {
                            Text("Build \(updateInfo.currentBuild ?? "") → \(updateInfo.targetBuild ?? "")")
                                .font(LitheTheme.smallFont)
                                .foregroundStyle(LitheTheme.secondaryText)
                        } else {
                            Text("Lithe \(updateInfo.currentVersion) → \(updateInfo.targetVersion)")
                                .font(LitheTheme.smallFont)
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                        if let releaseDate = updateInfo.releaseDate {
                            Group {
                                if updateInfo.isPreview {
                                    Text("Built \(formattedDate(releaseDate))")
                                } else {
                                    Text("Released \(formattedDate(releaseDate))")
                                }
                            }
                            .font(LitheTheme.smallFont)
                            .foregroundStyle(LitheTheme.tertiaryText)
                        }
                    }
                }
                Spacer()
            }
            .padding(16)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            if let updateInfo = updateChecker.updateInfo {
                if updateInfo.isPreview {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("This preview contains changes that have not been officially released and may be unstable.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            statusContent()
                        }
                        .padding(16)
                    }
                    .frame(minHeight: 64, maxHeight: 100)
                } else {
                    let releaseNotes = updateInfo.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Release notes")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LitheTheme.secondaryText)
                        if releaseNotes.isEmpty {
                            Text("Release notes are not included with this update.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(LitheTheme.primaryText)
                        } else {
                            UpdateReleaseNotesView(markdown: releaseNotes)
                                .frame(height: 230)
                        }
                        statusContent()
                    }
                    .padding(16)
                    .frame(minHeight: 180, maxHeight: 360)
                }
            }

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 12) {
                Button("Open Release Page") {
                    updateChecker.openRelease(updateChecker.updateInfo?.releaseURL)
                }
                .buttonStyle(LitheSecondaryButtonStyle())

                HStack(spacing: 10) {
                    Spacer()
                    if case .available = updateChecker.status {
                        Button("Later") {
                            updateChecker.remindLater()
                            dismiss()
                        }
                        .buttonStyle(LitheSecondaryButtonStyle())
                        Button(LocalizedStringKey(updateChecker.isPreview ? "Skip Build" : "Skip Version")) {
                            updateChecker.skipVersion()
                            dismiss()
                        }
                        .buttonStyle(LitheSecondaryButtonStyle())
                        Button(LocalizedStringKey(updateChecker.isPreview ? "Install Preview" : "Install")) {
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
            }
            .padding(16)
        }
        .frame(width: 560)
        .background(LitheTheme.popupBackground)
        // The window has nothing to offer once the update cycle ends, including
        // when macOS restores it at launch.
        .onAppear { if updateChecker.updateInfo == nil { dismiss() } }
        .onChange(of: updateChecker.updateInfo) { updateInfo in
            if updateInfo == nil { dismiss() }
        }
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
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
        case .waitingForTermination:
            Button("Continue Installation") {
                dismiss()
                Task { await updateChecker.retryInstallation() }
            }
            .buttonStyle(LitheSecondaryButtonStyle())
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

private struct UpdateReleaseNotesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var renderedHTML: String?
    @State private var renderingError: String?

    let markdown: String

    var body: some View {
        Group {
            if let renderedHTML {
                ReleaseNotesWebView(html: renderedHTML, isDark: colorScheme == .dark)
            } else if renderingError != nil {
                Text("Release notes could not be displayed. Open the release page to read them.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(LitheTheme.secondaryText)
            } else {
                ProgressView("Loading release notes…")
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: markdown) {
            renderedHTML = nil
            renderingError = nil
            do {
                let rendered = try await model.renderMarkdown(markdown)
                guard !Task.isCancelled else { return }
                renderedHTML = rendered.html
            } catch {
                guard !Task.isCancelled else { return }
                renderingError = error.localizedDescription
            }
        }
    }
}
