import SwiftUI

enum ProjectSwitcherLayoutMetrics {
    static let width: CGFloat = 390
    static let maximumHeight: CGFloat = 520
}

struct ProjectSwitcherPopover: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var projectSessions: ProjectSessionManager
    @Environment(\.projectWindowScope) private var projectWindowScope
    @Binding var isPresented: Bool
    let onNewProject: () -> Void
    let onOpenProject: () -> Void
    let onCloneRepository: () -> Void
    let onOpenRecentProject: (RecentProject) -> Void

    private var scopedOpenProjects: [AppModel] {
        projectSessions.openProjects(in: projectWindowScope)
    }

    private var openProjectPaths: Set<String> {
        Set(scopedOpenProjects.compactMap { $0.workspaceURL?.standardizedFileURL.path })
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
                ForEach(scopedOpenProjects) { projectModel in
                    openProjectRow(projectModel)
                }

                divider

                sectionTitle("Recent Projects")
                if recentProjects.isEmpty {
                    Text("No recent projects")
                        .font(LitheTheme.uiFont(size: 12))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                } else {
                    ForEach(recentProjects) { project in
                        recentProjectRow(project)
                    }
                }
            }
            .padding(LitheDropdownMetrics.popupPadding)
        }
        .frame(width: ProjectSwitcherLayoutMetrics.width)
        .frame(maxHeight: ProjectSwitcherLayoutMetrics.maximumHeight)
    }

    private var divider: some View {
        Rectangle()
            .fill(LitheTheme.divider)
            .frame(height: 1)
            .padding(.vertical, 8)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .font(LitheTheme.uiFont(size: 12, weight: .semibold))
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.bottom, 5)
    }

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                LitheSystemIcon(systemImage: icon)
                    .font(LitheTheme.uiFont(size: 16, weight: .regular))
                    .frame(width: 20)
                Text(LocalizedStringKey(title))
                Spacer(minLength: 0)
            }
            .foregroundStyle(LitheTheme.primaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(LitheDropdownRowStyle())
        .lithePointer()
    }

    private func openProjectRow(_ projectModel: AppModel) -> some View {
        let isCurrent = projectModel.id == projectSessions.activeSessionID(in: projectWindowScope)
        return Button {
            isPresented = false
            projectSessions.activateSession(projectModel.id)
        } label: {
            projectRowContent(
                name: projectModel.projectName,
                path: projectModel.workspaceURL?.path ?? "",
                colorIndex: ProjectIdentityAppearance.colorIndex(for: projectModel.workspaceURL),
                isCurrent: isCurrent
            )
        }
        .buttonStyle(LitheDropdownRowStyle(isSelected: isCurrent))
        .lithePointer()
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
                colorIndex: ProjectIdentityAppearance.colorIndex(for: project.url),
                isEnabled: exists,
                isCurrent: false
            )
        }
        .buttonStyle(LitheDropdownRowStyle())
        .disabled(!exists)
        .lithePointer()
    }

    private func projectRowContent(
        name: String,
        path: String,
        colorIndex: Int,
        isEnabled: Bool = true,
        isCurrent: Bool
    ) -> some View {
        HStack(spacing: 10) {
            ProjectAvatarBadge(name: name, colorIndex: colorIndex, size: 30, isEnabled: isEnabled)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(LitheTheme.uiFont(size: 13, weight: .medium))
                    .foregroundStyle(model.fileExists(at: URL(fileURLWithPath: path)) ? LitheTheme.primaryText : LitheTheme.secondaryText)
                    .lineLimit(1)
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            if isCurrent {
                Image(systemName: "checkmark")
                    .font(LitheTheme.uiFont(size: 11, weight: .semibold))
                    .foregroundStyle(LitheTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .contentShape(Rectangle())
    }
}
