import SwiftUI

enum ProjectSwitcherLayoutMetrics {
    static let width: CGFloat = 390
    static let maximumHeight: CGFloat = 520
    static let leadingOverlap: CGFloat = 10
    static let anchorOffsetFromLeading = (width / 2) - leadingOverlap
}

struct ProjectSwitcherPopover: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var projectSessions: ProjectSessionManager
    @Binding var isPresented: Bool
    let onNewProject: () -> Void
    let onOpenProject: () -> Void
    let onCloneRepository: () -> Void
    let onOpenRecentProject: (RecentProject) -> Void

    private var openProjectPaths: Set<String> {
        Set(projectSessions.openProjects.compactMap { $0.workspaceURL?.standardizedFileURL.path })
    }

    private var recentProjects: [RecentProject] {
        model.recentProjects.filter { !openProjectPaths.contains($0.url.standardizedFileURL.path) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 2) {
                    actionRow(icon: "plus", title: "New Project…", action: onNewProject)
                    actionRow(icon: "folder", title: "Open…", action: onOpenProject)
                    actionRow(
                        icon: "point.3.connected.trianglepath.dotted",
                        title: "Clone Repository…",
                        action: onCloneRepository
                    )
                }

                divider

                sectionTitle("Open Projects")
                ForEach(projectSessions.openProjects) { projectModel in
                    openProjectRow(projectModel)
                }

                divider

                sectionTitle("Recent Projects")
                if recentProjects.isEmpty {
                    Text("No recent projects")
                        .font(.system(size: 12))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                } else {
                    ForEach(recentProjects) { project in
                        recentProjectRow(project)
                    }
                }
            }
            .padding(8)
        }
        .frame(width: ProjectSwitcherLayoutMetrics.width)
        .frame(maxHeight: ProjectSwitcherLayoutMetrics.maximumHeight)
        .background(LitheTheme.popupBackground)
    }

    private var divider: some View {
        Rectangle()
            .fill(LitheTheme.divider)
            .frame(height: 1)
            .padding(.vertical, 8)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.bottom, 5)
    }

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                LitheSystemIcon(systemImage: icon)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 20)
                Text(LocalizedStringKey(title))
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 30)
            .contentShape(Rectangle())
            .litheRowHover(cornerRadius: 5)
        }
        .buttonStyle(.plain)
        .lithePointer()
    }

    private func openProjectRow(_ projectModel: AppModel) -> some View {
        let isCurrent = projectModel.id == projectSessions.activeSessionID
        return Button {
            isPresented = false
            projectSessions.activateSession(projectModel.id)
        } label: {
            projectRowContent(
                name: projectModel.projectName,
                path: projectModel.workspaceURL?.path ?? "",
                badge: initials(for: projectModel.projectName),
                badgeColor: color(for: projectModel.projectName),
                isCurrent: isCurrent
            )
        }
        .buttonStyle(.plain)
        .lithePointer()
        .litheRowHover(
            isActive: isCurrent,
            cornerRadius: 5,
            activeBackground: LitheTheme.subtleSelection
        )
    }

    private func recentProjectRow(_ project: RecentProject) -> some View {
        let exists = model.fileExists(at: project.url)
        return Button {
            guard exists else { return }
            onOpenRecentProject(project)
        } label: {
            projectRowContent(
                name: project.name,
                path: project.path,
                badge: initials(for: project.name),
                badgeColor: exists ? color(for: project.name) : LitheTheme.raised,
                isCurrent: false
            )
        }
        .buttonStyle(.plain)
        .disabled(!exists)
        .lithePointer()
        .litheRowHover(cornerRadius: 5)
    }

    private func projectRowContent(
        name: String,
        path: String,
        badge: String,
        badgeColor: Color,
        isCurrent: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Text(badge)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(badgeColor)
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(model.fileExists(at: URL(fileURLWithPath: path)) ? LitheTheme.primaryText : LitheTheme.secondaryText)
                    .lineLimit(1)
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LitheTheme.accent)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let characters = words.prefix(2).compactMap(\.first)
        return characters.isEmpty ? "LI" : String(characters).uppercased()
    }

    private func color(for value: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.24, green: 0.49, blue: 0.88),
            Color(red: 0.24, green: 0.63, blue: 0.43),
            Color(red: 0.86, green: 0.39, blue: 0.20),
            Color(red: 0.56, green: 0.34, blue: 0.82),
            Color(red: 0.72, green: 0.52, blue: 0.10)
        ]
        let hash = value.utf8.reduce(0) { ($0 * 31 + Int($1)) & 0x7fffffff }
        return palette[hash % palette.count]
    }
}
