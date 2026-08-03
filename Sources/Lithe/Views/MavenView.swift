import SwiftUI

struct MavenView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: MavenFeatureModel
    @State private var selectedModuleID: String?
    @State private var enabledProfiles: Set<String> = []
    @State private var expandedNodeIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            toolWindowHeader

            if feature.isLoadingProject {
                ProgressView("Scanning Maven project...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(LitheTheme.secondaryText)
            } else if let project = feature.project {
                HStack(spacing: 0) {
                    projectPane(project)
                        .frame(width: 260)
                    Rectangle().fill(LitheTheme.divider).frame(width: 1)
                    buildOutputPane
                }
            } else {
                emptyState
            }
        }
        .background(LitheTheme.editor)
        .onAppear {
            if expandedNodeIDs.isEmpty {
                resetTreeState()
            }
        }
        .onChange(of: feature.project?.id) {
            resetTreeState()
        }
    }

    private var toolWindowHeader: some View {
        LitheToolWindowHeader(
            title: "Maven",
            systemImage: "shippingbox",
            ideaAssetPath: "maven/toolWindowMaven.svg",
            subtitle: feature.project?.displayName,
            onMinimize: { model.isMavenVisible = false }
        ) {
            if let runningTitle = feature.runningTitle {
                ProgressView()
                    .controlSize(.mini)
                Text(runningTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            } else if let exitCode = feature.lastExitCode {
                Label(
                    exitCode == 0 ? "Succeeded" : "Failed",
                    systemImage: exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(exitCode == 0 ? LitheTheme.success : LitheTheme.error)
            }

            Button(action: refreshProject) {
                LitheSystemIcon(systemImage: "arrow.clockwise")
            }
            .litheIconButton()
            .help("Reload Maven project")

            if feature.isRunning {
                Button(action: model.stopMaven) {
                    Image(systemName: "stop.fill")
                }
                .litheIconButton()
                .foregroundStyle(LitheTheme.warning)
                .help("Stop Maven task")
            }

            Button(action: feature.clearOutput) {
                Image(systemName: "trash")
            }
            .litheIconButton()
            .help("Clear build output")

        }
    }

    private func refreshProject() {
        guard let workspaceURL = model.workspaceURL else { return }
        Task { await feature.loadProject(at: workspaceURL) }
    }

    private func projectPane(_ project: MavenProject) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 1) {
                if !project.profiles.isEmpty {
                    treeNode(
                        id: profilesNodeID,
                        title: "Profiles",
                        systemImage: "folder",
                        onLabelAction: { toggleNode(profilesNodeID) }
                    ) {
                        ForEach(project.profiles) { profile in
                            profileRow(profile)
                        }
                    }
                }

                treeNode(
                    id: projectNodeID(project),
                    title: project.displayName,
                    subtitle: project.packaging,
                    systemImage: "m.circle",
                    isSelected: selectedModuleID == nil,
                    onLabelAction: { selectedModuleID = nil }
                ) {
                    lifecycleNode(ownerID: projectNodeID(project), module: nil)
                    ForEach(project.modules) { module in
                        moduleTreeNode(module)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
        .background(LitheTheme.sidebar)
    }

    private func moduleTreeNode(_ module: MavenModule) -> AnyView {
        AnyView(
            treeNode(
                id: moduleNodeID(module),
                title: module.displayName,
                subtitle: module.relativePath,
                systemImage: "m.circle",
                isSelected: selectedModuleID == module.id,
                onLabelAction: { selectedModuleID = module.id }
            ) {
                lifecycleNode(ownerID: moduleNodeID(module), module: module)
                ForEach(module.modules) { childModule in
                    moduleTreeNode(childModule)
                }
            }
        )
    }

    private func lifecycleNode(ownerID: String, module: MavenModule?) -> AnyView {
        let nodeID = childNodeID(ownerID: ownerID, name: "lifecycle")
        return AnyView(
            treeNode(
                id: nodeID,
                title: "Lifecycle",
                systemImage: "gearshape",
                onLabelAction: { toggleNode(nodeID) }
            ) {
                ForEach(MavenLifecyclePhase.allCases) { phase in
                    lifecycleRow(phase, module: module)
                }
            }
        )
    }

    private func profileRow(_ profile: MavenProfile) -> some View {
        Toggle(isOn: profileBinding(for: profile)) {
            HStack(spacing: 0) {
                Text(profile.id)
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .toggleStyle(.checkbox)
        .lithePointer()
        .padding(.leading, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 24)
    }

    private func lifecycleRow(_ phase: MavenLifecyclePhase, module: MavenModule?) -> some View {
        Button {
            model.runMaven(
                phase: phase,
                module: module,
                profiles: enabledProfiles
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: phase.systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 16)
                Text(LocalizedStringKey(phase.title))
                    .lineLimit(1)
                Spacer(minLength: 0)
                LitheSystemIcon(systemImage: "play.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(LitheTheme.accent)
            }
            .font(.system(size: 12))
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
        .disabled(feature.isRunning)
    }

    private func treeNode<Content: View>(
        id: String,
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        isSelected: Bool = false,
        onLabelAction: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Button {
                    toggleNode(id)
                } label: {
                    Image(systemName: isNodeExpanded(id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(width: 14, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .lithePointer()

                Button(action: onLabelAction) {
                    HStack(spacing: 6) {
                        Image(systemName: systemImage)
                            .font(.system(size: 12))
                            .foregroundStyle(LitheTheme.accent)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(LocalizedStringKey(title))
                                .font(.system(size: 12))
                                .foregroundStyle(LitheTheme.primaryText)
                                .lineLimit(1)
                            if let subtitle, !subtitle.isEmpty {
                                Text(LocalizedStringKey(subtitle))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 24)
                    .background(isSelected ? LitheTheme.subtleSelection : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .lithePointer()
            }

            if isNodeExpanded(id) {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .padding(.leading, 16)
            }
        }
    }

    private var mavenSearchRoots: [URL] {
        guard let project = feature.project else { return [] }
        return [project.rootURL] + moduleURLs(project.modules)
    }

    private func moduleURLs(_ modules: [MavenModule]) -> [URL] {
        modules.flatMap { [$0.url] + moduleURLs($0.modules) }
    }

    private var buildOutputPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Build Output")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if !feature.issues.isEmpty {
                    Label("\(feature.issues.count)", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(LitheTheme.warning)
                }
            }
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(LitheTheme.toolHeader)

            if !feature.issues.isEmpty {
                issueList
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }

            OutputTextView(
                output: feature.output,
                searchRoots: mavenSearchRoots,
                emptyMessage: "Run a Maven lifecycle phase to see output."
            ) { url, line, column in
                model.openSourceLocation(url: url, line: line, column: column)
            }
        }
    }

    private var issueList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(feature.issues) { issue in
                    Button {
                        model.openMavenIssue(issue)
                    } label: {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: issue.severity.systemImage)
                                .foregroundStyle(issue.severity == .error ? .red : LitheTheme.warning)
                                .frame(width: 15)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.locationTitle)
                                    .font(.system(size: 11.5, weight: .medium))
                                Text(issue.message)
                                    .font(.system(size: 11))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(LitheTheme.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .lithePointer()
                }
            }
            .padding(.vertical, 5)
        }
        .frame(maxHeight: 132)
        .background(LitheTheme.sidebar)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            LitheSystemIcon(systemImage: "shippingbox")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(LitheTheme.secondaryText)
            Text("No Maven project detected")
                .font(.system(size: 14, weight: .semibold))
            Text("Open a project containing a pom.xml file.")
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func profileBinding(for profile: MavenProfile) -> Binding<Bool> {
        Binding(
            get: { enabledProfiles.contains(profile.id) },
            set: { enabled in
                if enabled {
                    enabledProfiles.insert(profile.id)
                } else {
                    enabledProfiles.remove(profile.id)
                }
            }
        )
    }

    private var profilesNodeID: String { "profiles" }

    private func projectNodeID(_ project: MavenProject) -> String {
        "project:" + project.id
    }

    private func moduleNodeID(_ module: MavenModule) -> String {
        "module:" + module.id
    }

    private func childNodeID(ownerID: String, name: String) -> String {
        ownerID + ":" + name
    }

    private func isNodeExpanded(_ id: String) -> Bool {
        expandedNodeIDs.contains(id)
    }

    private func toggleNode(_ id: String) {
        if expandedNodeIDs.contains(id) {
            expandedNodeIDs.remove(id)
        } else {
            expandedNodeIDs.insert(id)
        }
    }

    private func resetTreeState() {
        selectedModuleID = nil
        enabledProfiles = Set(feature.project?.profiles.filter(\.isActiveByDefault).map(\.id) ?? [])
        expandedNodeIDs = feature.project.map { project in
            var ids: Set<String> = [projectNodeID(project)]
            if !project.profiles.isEmpty {
                ids.insert(profilesNodeID)
            }
            return ids
        } ?? []
    }
}
