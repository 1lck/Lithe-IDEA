import SwiftUI

@MainActor
enum ProjectSwitcherLayoutMetrics {
    static func width(projects: [(name: String, path: String)], branches: [String] = [], locale: Locale) -> CGFloat {
        let commands = ["New Project…", "Open…", "Clone Repository…"].map {
            LitheContextMenuItem.action($0, systemImage: "plus") {}
        }
        let projectWidth = projects.map { project in
            let name = (project.name as NSString).size(withAttributes: [.font: LitheTheme.uiNSFont(size: 13)]).width
            let path = (project.path as NSString).size(withAttributes: [.font: LitheTheme.uiNSFont(size: 12)]).width
            return max(name, path) + LitheDropdownMetrics.projectAvatarSize + 8 + 6
                + 2 * (LitheDropdownMetrics.popupPadding + LitheDropdownMetrics.itemHorizontalPadding)
        }.max() ?? 0
        let branchWidth = branches.map {
            ($0 as NSString).size(withAttributes: [.font: LitheTheme.uiNSFont(size: 12)]).width
                + LitheDropdownMetrics.iconSize + 4 + LitheDropdownMetrics.projectAvatarSize + 8 + 6
                + 2 * (LitheDropdownMetrics.popupPadding + LitheDropdownMetrics.itemHorizontalPadding)
        }.max() ?? 0
        return max(LitheContextMenuPresenter.menuWidth(for: commands, locale: locale), ceil(max(projectWidth, branchWidth)))
    }
    static let maximumHeight: CGFloat = 520
}

struct ProjectSwitcherPopover: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var projectSessions: ProjectSessionManager
    @Environment(\.projectWindowScope) private var projectWindowScope
    @Binding var isPresented: Bool
    @State private var projectBranches: [String: String] = [:]
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

    private var projectPaths: [String] {
        scopedOpenProjects.compactMap { $0.workspaceURL?.standardizedFileURL.path }
            + recentProjects.map { $0.url.standardizedFileURL.path }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) {
                    actionRow(icon: "expui/general/add.svg", title: "New Project…", action: onNewProject)
                    actionRow(icon: "expui/general/open.svg", title: "Open…", action: onOpenProject)
                    actionRow(
                        icon: "expui/general/vcs.svg",
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
        .frame(width: ProjectSwitcherLayoutMetrics.width(
            projects: scopedOpenProjects.map { ($0.projectName, displayPath($0.workspaceURL?.path ?? "")) }
                + recentProjects.map { ($0.name, displayPath($0.path)) }, branches: Array(projectBranches.values), locale: locale
        ))
        .frame(maxHeight: ProjectSwitcherLayoutMetrics.maximumHeight)
        .task(id: projectPaths) {
            projectBranches = [:]
            guard let git = await model.activateGitModule() else { return }
            for path in projectPaths {
                guard !Task.isCancelled else { return }
                let branch = await git.repositorySetup.branch(at: URL(fileURLWithPath: path))
                guard !Task.isCancelled else { return }
                projectBranches[path] = branch
            }
        }
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
            HStack(spacing: 8) {
                LitheIDEAIcon(resourcePath: icon, size: LitheDropdownMetrics.iconSize,
                              preservesOriginalColors: true)
                Text(LocalizedStringKey(title))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LitheDropdownRowStyle())
        .lithePointer()
    }

    private func openProjectRow(_ projectModel: AppModel) -> some View {
        return Button {
            isPresented = false
            projectSessions.activateSession(projectModel.id)
        } label: {
            projectRowContent(
                name: projectModel.projectName,
                path: projectModel.workspaceURL?.path ?? "",
                colorIndex: ProjectIdentityAppearance.colorIndex(for: projectModel.workspaceURL)
            )
        }
        .buttonStyle(LitheDropdownRowStyle())
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
                isEnabled: exists
            )
        }
        .buttonStyle(LitheDropdownRowStyle())
        .disabled(!exists)
        .lithePointer()
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func projectRowContent(
        name: String,
        path: String,
        colorIndex: Int,
        isEnabled: Bool = true
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ProjectAvatarBadge(name: name, colorIndex: colorIndex, size: LitheDropdownMetrics.projectAvatarSize, isEnabled: isEnabled)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .font(LitheTheme.uiFont(size: 13, weight: .regular))
                    .lineLimit(1)
                Text(verbatim: displayPath(path))
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let branch = projectBranches[URL(fileURLWithPath: path).standardizedFileURL.path] {
                    HStack(spacing: 4) {
                        LitheIDEAIcon(resourcePath: "expui/general/vcs.svg", size: LitheDropdownMetrics.iconSize)
                        Text(verbatim: branch).fixedSize(horizontal: true, vertical: false)
                    }
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 6)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .contentShape(Rectangle())
    }
}
