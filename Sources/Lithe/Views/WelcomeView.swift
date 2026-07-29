import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var projectFilter = ""

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
                TextField("Search projects", text: $projectFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))

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

            if filteredProjects.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(LitheTheme.secondaryText)
                    Text(model.recentProjects.isEmpty ? "No recent projects" : "No matching projects")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(LitheTheme.primaryText)
                    Text("Open a local folder. Lithe will remember it here.")
                        .font(LitheTheme.uiFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredProjects) { project in
                            Button {
                                if project.exists { model.openProject(project.url) }
                            } label: {
                                HStack(spacing: 14) {
                                    Text(initials(for: project.name))
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .frame(width: 38, height: 38)
                                        .background(project.exists ? color(for: project.name) : Color.gray)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(project.name)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(project.exists ? LitheTheme.primaryText : LitheTheme.secondaryText)
                                        Text(project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(LitheTheme.secondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 34)
                                .frame(height: 68)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!project.exists)
                            .contextMenu {
                                if project.exists {
                                    Button("Open") { model.openProject(project.url) }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                                }
                                Button("Remove from Recent Projects", role: .destructive) {
                                    model.removeRecentProject(project)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 14)
                }
            }
        }
        .background(LitheTheme.window)
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
        return palette[abs(value.hashValue) % palette.count]
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
