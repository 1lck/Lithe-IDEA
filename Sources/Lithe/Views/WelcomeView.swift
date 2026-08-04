import AppKit
import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updateChecker: UpdateChecker
    @State private var projectFilter = ""
    @State private var hoveredProjectID: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text("Welcome to Lithe")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(LitheTheme.window)

            HStack(spacing: 0) {
                welcomeSidebar
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                projectsContent
            }
        }
        .background(LitheTheme.window)
    }

    private var welcomeSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                LitheIcons.appLogo(size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lithe")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                    Text("\(updateChecker.currentVersion) · macOS")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                    updatePrompt
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 38)
            .padding(.bottom, 38)

            HStack(spacing: 9) {
                LitheIcon(kind: .folder, size: 15)
                Text("Projects")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 36)
            .background(LitheTheme.selection)
            .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius))
            .padding(.horizontal, 14)

            Spacer()

            Button {
                model.isSettingsPresented = true
            } label: {
                HStack(spacing: 9) {
                    LitheSystemIcon(systemImage: "gearshape")
                        .font(.system(size: 14))
                    Text("Settings")
                        .font(.system(size: 12.5))
                    Spacer()
                }
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()
            .litheRowHover()
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: 280)
        .background(LitheTheme.sidebar)
    }

    @ViewBuilder
    private var updatePrompt: some View {
        Group {
            switch updateChecker.status {
            case .available(let version, _):
                Button {
                    Task { await updateChecker.installAvailableUpdate() }
                } label: {
                    Label("Update to \(version)", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(LitheTheme.accent)
            case .checking:
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking for updates…")
                }
                .foregroundStyle(LitheTheme.secondaryText)
            case .downloading(let version, let progress):
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        if let fractionCompleted = progress.fractionCompleted {
                            ProgressView(value: fractionCompleted)
                                .frame(width: 92)
                            Text("\(progress.percentage ?? 0)%")
                                .monospacedDigit()
                        } else {
                            ProgressView()
                                .controlSize(.small)
                            Text("Preparing…")
                        }
                    }
                    Text("Downloading update \(version)…")
                    Text(progress.byteCountDescription)
                        .foregroundStyle(LitheTheme.tertiaryText)
                }
                .foregroundStyle(LitheTheme.secondaryText)
            case .installing(let version):
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing update \(version)…")
                }
                .foregroundStyle(LitheTheme.secondaryText)
            case .upToDate:
                Button {
                    checkForUpdates()
                } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(LitheTheme.secondaryText)
            case .failed:
                Button {
                    checkForUpdates()
                } label: {
                    Label("Retry update check", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(LitheTheme.secondaryText)
            case .idle, .noRelease:
                Button {
                    checkForUpdates()
                } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(LitheTheme.secondaryText)
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .lithePointer()
    }

    private func checkForUpdates() {
        Task { await updateChecker.checkForUpdates(manual: true) }
    }

    private var projectsContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    LitheSystemIcon(systemImage: "magnifyingglass")
                        .font(.system(size: 12.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                    TextField("Search projects", text: $projectFilter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($searchFocused)
                }
                .litheSearchField(isFocused: searchFocused, height: 30)
                .frame(maxWidth: 360)

                Spacer()

                Button("Clone") {
                    model.showCloneRepository()
                }
                .buttonStyle(.bordered)
                .lithePointer()

                Button("Open") {
                    model.chooseProject()
                }
                .buttonStyle(LithePrimaryButtonStyle())
            }
            .padding(.horizontal, 30)
            .frame(height: 76)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
                .padding(.horizontal, 24)

            if filteredProjects.isEmpty {
                emptyProjectsState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredProjects) { project in
                            projectRow(project)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
            }
        }
        .background(LitheTheme.window)
    }

    private var emptyProjectsState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(model.recentProjects.isEmpty ? "No recent projects" : "No matching projects")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            Text("Open a local folder to start working.")
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func projectRow(_ project: RecentProject) -> some View {
        HStack(spacing: 12) {
            Button {
                if project.exists { model.openProject(project.url) }
            } label: {
                HStack(spacing: 12) {
                    Text(initials(for: project.name))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(project.exists ? color(for: project.name) : LitheTheme.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.name)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(project.exists ? LitheTheme.primaryText : LitheTheme.secondaryText)
                        Text(project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()
            .disabled(!project.exists)

            Menu {
                if project.exists {
                    Button("Open") { model.openProject(project.url) }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([project.url])
                    }
                }
                Button("Remove from Recent Projects", role: .destructive) {
                    model.removeRecentProject(project)
                }
            } label: {
                LitheSystemIcon(systemImage: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .lithePointer()
            .foregroundStyle(LitheTheme.secondaryText)
            .opacity(hoveredProjectID == project.id ? 1 : 0)
            .allowsHitTesting(hoveredProjectID == project.id)
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(hoveredProjectID == project.id ? LitheTheme.hoverBackground : .clear)
        .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius))
        .onHover { isHovering in
            hoveredProjectID = isHovering ? project.id : nil
        }
        .contextMenu {
            if project.exists {
                Button("Open") { model.openProject(project.url) }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([project.url])
                }
            }
            Button("Remove from Recent Projects", role: .destructive) {
                model.removeRecentProject(project)
            }
        }
    }

    private var filteredProjects: [RecentProject] {
        guard !projectFilter.isEmpty else { return model.recentProjects }
        return model.recentProjects.filter {
            $0.name.localizedCaseInsensitiveContains(projectFilter) ||
                $0.path.localizedCaseInsensitiveContains(projectFilter)
        }
    }

    private func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let characters = words.prefix(2).compactMap(\.first)
        return characters.isEmpty ? "LI" : String(characters).uppercased()
    }

    private func color(for value: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.90, green: 0.43, blue: 0.28),
            Color(red: 0.12, green: 0.63, blue: 0.68),
            Color(red: 0.28, green: 0.53, blue: 0.88),
            Color(red: 0.30, green: 0.66, blue: 0.48),
            Color(red: 0.70, green: 0.52, blue: 0.12)
        ]
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
