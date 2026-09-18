import LitheCoreContracts
import SwiftUI

struct MavenView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: MavenFeatureModel
    @State private var selectedModuleID: String?
    @State private var selectedPhase: MavenLifecyclePhase?
    @State private var expandedNodeIDs: Set<String> = []
    @State private var isGoalSheetPresented = false
    @State private var isAddProfilePresented = false
    @State private var customGoal = ""
    @State private var customProfile = ""
    @State private var goalModule: MavenModule?
    @State private var goalProject: MavenProject?
    @State private var javaDependencyGraph: DependencyGraph?
    @State private var isResolvingJavaDependencies = false
    @State private var isJavaPathConfigurationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            toolWindowHeader
            navigationToolbar

            if let error = feature.configurationSaveError {
                configurationErrorBanner(error)
            }
            if let error = feature.reloadError {
                configurationErrorBanner(error)
            }
            if feature.isReloadRequired {
                reloadBanner
            }

            if feature.isLoadingProject {
                ProgressView("Scanning Maven project...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(LitheTheme.secondaryText)
            } else if case .failed(let message) = feature.projectState {
                failedState(message)
            } else if let project = feature.project {
                projectPane(project)
            } else {
                emptyState
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .onAppear {
            if expandedNodeIDs.isEmpty {
                resetTreeState()
            }
        }
        .onChange(of: feature.project?.id) { _ in
            isGoalSheetPresented = false
            javaDependencyGraph = nil
            resetTreeState()
        }
        .onChange(of: feature.javaDependencyRevision) { _ in
            javaDependencyGraph = nil
            if isNodeExpanded(javaNodeID) {
                loadJavaDependencies()
            }
        }
        .sheet(isPresented: $isGoalSheetPresented) {
            goalSheet
        }
        .popover(isPresented: $isJavaPathConfigurationPresented, arrowEdge: .trailing) {
            JavaDependencyPathConfigurationEditor(configuration: feature.javaDependencyPaths) {
                feature.updateJavaDependencyPaths($0)
                javaDependencyGraph = nil
                if isNodeExpanded(javaNodeID) {
                    loadJavaDependencies()
                }
            }
        }
    }

    private var toolWindowHeader: some View {
        LitheToolWindowHeader(
            title: "Maven",
            systemImage: "shippingbox",
            ideaAssetPath: "maven/toolWindowMaven.svg",
            subtitle: feature.project?.displayName,
            onMinimize: { model.workbenchFeature.setVisibility(.maven, isVisible: false) }
        )
    }

    private var navigationToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    if isMavenTaskRunning {
                        model.stopMaven()
                    } else {
                        runSelected()
                    }
                } label: {
                    LitheSystemIcon(systemImage: isMavenTaskRunning ? "stop.fill" : "play.fill")
                }
                .litheIconButton()
                .foregroundStyle(isMavenTaskRunning ? LitheTheme.warning : LitheTheme.secondaryText)
                .disabled(!isMavenTaskRunning && (selectedPhase == nil || model.isMavenOperationBusy))
                .help(isMavenTaskRunning
                      ? String(localized: "Stop Maven task")
                      : String(localized: "Run selected Maven lifecycle phase"))

                Button {
                    presentGoal(for: selectedModule)
                } label: {
                    LitheSystemIcon(systemImage: "terminal")
                }
                .litheIconButton()
                .disabled(model.isMavenOperationBusy)
                .help("Execute Maven goal")

                Button(action: refreshProject) {
                    LitheSystemIcon(systemImage: "arrow.clockwise")
                }
                .litheIconButton()
                .help("Reload Maven project")
                .disabled(model.isMavenOperationBusy)

                Button {
                    feature.setSkipTests(!feature.skipTests)
                } label: {
                    LitheSystemIcon(systemImage: feature.skipTests ? "checkmark.square.fill" : "square")
                }
                .litheIconButton()
                .foregroundStyle(feature.skipTests ? LitheTheme.accent : LitheTheme.secondaryText)
                .help("Skip tests")

                Button {
                    expandedNodeIDs.removeAll()
                } label: {
                    LitheSystemIcon(systemImage: "rectangle.compress.vertical")
                }
                .litheIconButton()
                .help("Collapse all")

                Button(action: { model.showSettings(category: .project) }) {
                    LitheSystemIcon(systemImage: "slider.horizontal.3")
                }
                .litheIconButton()
                .help("Maven settings")
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 36)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private func refreshProject() {
        Task { await model.reloadMavenProject(rescan: true) }
    }

    private var isMavenTaskRunning: Bool {
        feature.isRunning || model.runWorkflowCoordinator.isModuleOperationStarting
    }

    private var reloadBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(LitheTheme.warning)
            Text(feature.isProjectReloadRequired
                 ? String(localized: "Maven POM changed")
                 : String(localized: "Maven configuration changed"))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            Spacer(minLength: 8)
            Button(feature.isReloading ? String(localized: "Reloading Maven...") : String(localized: "Reload")) {
                Task { await model.reloadMavenProject(rescan: feature.isProjectReloadRequired) }
            }
            .buttonStyle(.borderless)
            .disabled(feature.isReloading)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(LitheTheme.warning.opacity(0.1))
        .overlay(alignment: .bottom) {
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
        }
    }

    private func configurationErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LitheTheme.error)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(LitheTheme.error.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
        }
    }

    private func projectPane(_ project: MavenProject) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 1) {
                if !feature.availableProfiles.isEmpty {
                    treeNode(
                        id: profilesNodeID,
                        title: "Profiles",
                        systemImage: "folder",
                        onLabelAction: { toggleNode(profilesNodeID) }
                    ) {
                        profileActions
                        ForEach(feature.availableProfiles) { profile in
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
                    hasModuleMenu: true,
                    onLabelAction: { selectedModuleID = nil }
                ) {
                    javaDependencyNode(ownerID: projectNodeID(project))
                    lifecycleNode(ownerID: projectNodeID(project), module: nil)
                    dependencyNode(ownerID: projectNodeID(project), modulePath: ".")
                    ForEach(project.modules) { module in
                        moduleTreeNode(module)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    private func moduleTreeNode(_ module: MavenModule) -> AnyView {
        AnyView(
            treeNode(
                id: moduleNodeID(module),
                title: module.displayName,
                subtitle: module.relativePath,
                systemImage: "m.circle",
                isSelected: selectedModuleID == module.id,
                hasModuleMenu: true,
                menuModule: module,
                onLabelAction: { selectedModuleID = module.id }
            ) {
                sourceRootsNode(ownerID: moduleNodeID(module), sourceRoots: module.sourceRoots)
                lifecycleNode(ownerID: moduleNodeID(module), module: module)
                dependencyNode(ownerID: moduleNodeID(module), modulePath: module.relativePath)
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

    private func sourceRootsNode(
        ownerID: String,
        sourceRoots: [MavenSourceRoot]
    ) -> AnyView {
        let nodeID = childNodeID(ownerID: ownerID, name: "source-roots")
        guard !sourceRoots.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            treeNode(
                id: nodeID,
                title: dependencyLocalization.text("Source Roots"),
                systemImage: "folder",
                onLabelAction: { toggleNode(nodeID) }
            ) {
                ForEach(sourceRoots) { sourceRoot in
                    sourceRootRow(sourceRoot)
                }
            }
        )
    }

    private var javaNodeID: String {
        guard let project = feature.project else { return "java" }
        return childNodeID(ownerID: projectNodeID(project), name: "java")
    }

    private func javaDependencyNode(ownerID: String) -> AnyView {
        let nodeID = childNodeID(ownerID: ownerID, name: "java")
        let toggle = {
            let shouldLoad = !isNodeExpanded(nodeID)
            toggleNode(nodeID)
            if shouldLoad {
                loadJavaDependencies()
            }
        }
        return AnyView(
            treeNode(
                id: nodeID,
                title: "Java",
                subtitle: feature.javaDependencyPaths.additionalSearchPaths.isEmpty
                    && feature.javaDependencyPaths.excludedPaths.isEmpty
                    ? nil
                    : String(localized: "Configured"),
                systemImage: "cup.and.saucer",
                onToggleAction: toggle,
                onLabelAction: toggle,
                trailingSystemImage: "gearshape",
                onTrailingAction: { isJavaPathConfigurationPresented = true }
            ) {
                javaDependencyContent
            }
        )
    }

    private var javaDependencyContent: AnyView {
        if isResolvingJavaDependencies {
            return AnyView(
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Resolving Java paths...")
                        .font(.system(size: 11.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .padding(.horizontal, 5)
                .frame(minHeight: 28)
            )
        }
        guard let javaDependencyGraph,
              let javaRoot = javaDependencyGraph.roots.first else {
            return AnyView(
                Text("No Java paths configured")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .padding(.horizontal, 5)
                    .frame(minHeight: 28)
            )
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                ForEach(javaRoot.children) { group in
                    javaDependencyTreeNode(group)
                }
            }
        )
    }

    private func javaDependencyTreeNode(_ node: DependencyNode) -> AnyView {
        if node.children.isEmpty {
            return AnyView(javaDependencyPathRow(node))
        }
        return AnyView(
            treeNode(
                id: node.id,
                title: node.title,
                systemImage: node.title == "Maven" ? "shippingbox" : "folder",
                onLabelAction: { toggleNode(node.id) }
            ) {
                ForEach(node.children) { child in
                    javaDependencyTreeNode(child)
                }
            }
        )
    }

    private func javaDependencyPathRow(_ node: DependencyNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.kind == .packageNode ? "shippingbox" : "folder")
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                if let subtitle = node.subtitle {
                    Text(subtitle)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 28)
        .litheContextMenu(items: {
            guard let path = javaDependencyPath(for: node) else { return [] }
            return [
                .action(String(localized: "Exclude from Java dependency tree")) {
                    feature.excludeJavaDependencyPath(path)
                    javaDependencyGraph = nil
                    if isNodeExpanded(javaNodeID) { loadJavaDependencies() }
                }
            ]
        })
    }

    private func javaDependencyPath(for node: DependencyNode) -> String? {
        switch node.source {
        case .directory(let url), .archive(let url): return url.path
        case .generated, .unavailable: return nil
        }
    }

    private func loadJavaDependencies() {
        guard !isResolvingJavaDependencies else { return }
        isResolvingJavaDependencies = true
        Task { @MainActor in
            defer { isResolvingJavaDependencies = false }
            javaDependencyGraph = try? await feature.resolveJavaDependencies(
                serviceID: "workspace",
                serviceDisplayName: feature.project?.displayName,
                classpath: []
            )
        }
    }

    private var dependencyLocalization: MavenDependencyLocalization {
        MavenDependencyLocalization(language: model.settings.language)
    }

    private func dependencyNode(ownerID: String, modulePath: String) -> AnyView {
        let nodeID = childNodeID(ownerID: ownerID, name: "dependencies")
        let toggle = {
            let shouldLoad = !isNodeExpanded(nodeID)
            toggleNode(nodeID)
            if shouldLoad {
                feature.loadDependencies(for: modulePath)
            }
        }
        return AnyView(
            treeNode(
                id: nodeID,
                title: dependencyLocalization.text("Dependencies"),
                systemImage: "shippingbox",
                onToggleAction: toggle,
                onLabelAction: toggle
            ) {
                dependencyContent(
                    feature.dependencyState(for: modulePath),
                    modulePath: modulePath,
                    ownerID: nodeID
                )
            }
        )
    }

    private func dependencyContent(
        _ state: MavenDependencyLoadState,
        modulePath: String,
        ownerID: String
    ) -> AnyView {
        switch state {
        case .idle:
            return AnyView(EmptyView())
        case .loading:
            return AnyView(
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(dependencyLocalization.text("Resolving dependencies..."))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button(dependencyLocalization.text("Cancel")) {
                        feature.cancelDependencies(for: modulePath)
                    }
                    .buttonStyle(.borderless)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.horizontal, 4)
                .frame(minHeight: 28)
            )
        case .failed(let message):
            return AnyView(
                VStack(alignment: .leading, spacing: 4) {
                    Label(dependencyLocalization.error(message), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(LitheTheme.error)
                        .lineLimit(2)
                    Button(dependencyLocalization.text("Retry")) {
                        feature.loadDependencies(for: modulePath)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
            )
        case .cancelled:
            return AnyView(
                HStack(spacing: 6) {
                    Text(dependencyLocalization.text("Dependency resolution cancelled"))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button(dependencyLocalization.text("Retry")) {
                        feature.loadDependencies(for: modulePath)
                    }
                    .buttonStyle(.borderless)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.warning)
                .padding(.horizontal, 4)
                .frame(minHeight: 28)
            )
        case .ready(let dependencies):
            if dependencies.isEmpty {
                return AnyView(
                    Text(dependencyLocalization.text("No dependencies"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .padding(.horizontal, 4)
                        .frame(minHeight: 28)
                )
            }
            return AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(dependencies.enumerated()), id: \.offset) { index, dependency in
                        dependencyTreeNode(
                            dependency,
                            id: ownerID + ":" + dependency.groupID + ":" + dependency.artifactID + ":" + String(index)
                        )
                    }
                }
            )
        }
    }

    private func dependencyTreeNode(_ dependency: MavenDependency, id: String) -> AnyView {
        if dependency.children.isEmpty {
            return AnyView(dependencyRow(dependency))
        }
        return AnyView(
            treeNode(
                id: id,
                title: dependency.artifactID,
                subtitle: dependencySubtitle(dependency),
                systemImage: dependency.resolution == .resolved
                    ? "shippingbox"
                    : "exclamationmark.triangle.fill",
                onLabelAction: { openDependencyPom(dependency) }
            ) {
                ForEach(Array(dependency.children.enumerated()), id: \.offset) { index, child in
                    dependencyTreeNode(
                        child,
                        id: id + ":" + child.groupID + ":" + child.artifactID + ":" + String(index)
                    )
                }
            }
            .help(dependencyLocalization.text("Open module pom.xml"))
        )
    }

    private func dependencyRow(_ dependency: MavenDependency) -> some View {
        Button {
            openDependencyPom(dependency)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: dependency.resolution == .resolved
                    ? "shippingbox"
                    : "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(
                        dependency.resolution == .resolved ? LitheTheme.accent : LitheTheme.warning
                    )
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(dependency.artifactID)
                        .font(.system(size: 12))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                    Text(dependencySubtitle(dependency))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
        .padding(.leading, 16)
        .help(dependencyLocalization.text("Open module pom.xml"))
    }

    private func dependencySubtitle(_ dependency: MavenDependency) -> String {
        dependencyLocalization.subtitle(dependency)
    }

    private func openDependencyPom(_ dependency: MavenDependency) {
        guard let project = feature.project else { return }
        if dependency.modulePath == "." {
            model.openFile(project.pomURL)
            return
        }
        guard let module = project.allModules.first(where: {
            $0.relativePath == dependency.modulePath
        }) else { return }
        model.openFile(module.url.appendingPathComponent("pom.xml"))
    }

    private func sourceRootRow(_ sourceRoot: MavenSourceRoot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 16)
            Text(sourceRoot.path)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(dependencyLocalization.text(sourceRoot.kind.title))
                .font(.system(size: 10))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 24)
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

    private var profileActions: some View {
        HStack(spacing: 4) {
            Button {
                customProfile = ""
                isAddProfilePresented = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 18, height: 20)
            }
            .buttonStyle(.plain)
            .help("Add profile")
            .popover(isPresented: $isAddProfilePresented, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add Maven Profile")
                        .font(.system(size: 13, weight: .semibold))
                    TextField("Profile ID", text: $customProfile)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit(addCustomProfile)
                    HStack {
                        Spacer()
                        Button("Cancel") { isAddProfilePresented = false }
                        Button("Add", action: addCustomProfile)
                            .keyboardShortcut(.defaultAction)
                            .disabled(customProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(14)
            }

            Button(action: feature.restoreDefaultProfiles) {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 18, height: 20)
            }
            .buttonStyle(.plain)
            .help("Restore default profiles")
            Spacer(minLength: 0)
        }
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(.leading, 2)
    }

    private func lifecycleRow(_ phase: MavenLifecyclePhase, module: MavenModule?) -> some View {
        Button {
            selectedModuleID = module?.id
            selectedPhase = phase
        } label: {
            HStack(spacing: 6) {
                Image(systemName: phase.systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 16)
                Text(LocalizedStringKey(phase.title))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selectedModuleID == module?.id, selectedPhase == phase {
                    LitheSystemIcon(systemImage: "play.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(LitheTheme.accent)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 24)
            .background(
                selectedModuleID == module?.id && selectedPhase == phase
                    ? LitheTheme.subtleSelection
                    : .clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard !model.isMavenOperationBusy else { return }
            runPhase(phase: phase, module: module)
        })
        .litheContextMenu(items: {
            [.action(dependencyLocalization.text("Run"), isEnabled: !model.isMavenOperationBusy) {
                runPhase(phase: phase, module: module)
            }]
        })
    }

    private func treeNode<Content: View>(
        id: String,
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        isSelected: Bool = false,
        hasModuleMenu: Bool = false,
        menuModule: MavenModule? = nil,
        onToggleAction: (() -> Void)? = nil,
        onLabelAction: @escaping () -> Void,
        trailingSystemImage: String? = nil,
        onTrailingAction: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Button {
                    if let onToggleAction {
                        onToggleAction()
                    } else {
                        toggleNode(id)
                    }
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

                if let trailingSystemImage, let onTrailingAction {
                    Button(action: onTrailingAction) {
                        LitheSystemIcon(systemImage: trailingSystemImage)
                            .font(.system(size: 11))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .frame(width: 22, height: 24)
                    }
                    .buttonStyle(.plain)
                    .lithePointer()
                    .help("Configure Java search paths")
                }
            }
            .litheContextMenu(items: {
                hasModuleMenu ? moduleContextMenu(menuModule) : []
            })

            if isNodeExpanded(id) {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .padding(.leading, 16)
            }
        }
    }

    private func moduleContextMenu(_ module: MavenModule?) -> [LitheContextMenuItem] {
        [
            .action(dependencyLocalization.text("Run"),
                    isEnabled: !model.isMavenOperationBusy && model.mavenModuleConfiguration(module, debug: false) != nil) {
                model.startMavenModule(module, debug: false)
            },
            .action(dependencyLocalization.text("Debug"),
                    isEnabled: !model.isMavenOperationBusy && model.genericDebugFeatureIfActive?.isSessionActive != true
                        && model.mavenModuleConfiguration(module, debug: true) != nil) {
                model.startMavenModule(module, debug: true)
            },
            .separator,
            .action(dependencyLocalization.text("Test"), isEnabled: !model.isMavenOperationBusy) {
                runPhase(phase: .test, module: module)
            },
            .action(dependencyLocalization.text("Package"), isEnabled: !model.isMavenOperationBusy) {
                runPhase(phase: .packagePhase, module: module)
            },
            .action(dependencyLocalization.text("Execute Maven Goal"), isEnabled: !model.isMavenOperationBusy) {
                presentGoal(for: module)
            },
            .separator,
            .action(dependencyLocalization.text("Open pom.xml")) {
                if let pom = module?.url.appendingPathComponent("pom.xml") ?? feature.project?.pomURL {
                    model.openFile(pom)
                }
            },
            .action(dependencyLocalization.text("Reload"), isEnabled: !model.isMavenOperationBusy, action: refreshProject)
        ]
    }

    private func presentGoal(for module: MavenModule?) {
        goalModule = module
        goalProject = feature.project
        customGoal = ""
        isGoalSheetPresented = true
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

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.octagon")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(LitheTheme.error)
            Text("Unable to load Maven project")
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Retry", action: refreshProject)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var goalSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Execute Maven Goal")
                .font(.system(size: 16, weight: .semibold))
            TextField("Goal", text: $customGoal, prompt: Text("spring-boot:run"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(executeCustomGoal)
            HStack {
                Spacer()
                Button("Cancel") { isGoalSheetPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Run", action: executeCustomGoal)
                    .keyboardShortcut(.defaultAction)
                    .disabled(customGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func profileBinding(for profile: MavenProfile) -> Binding<Bool> {
        Binding(
            get: { feature.selectedProfiles.contains(profile.id) },
            set: { enabled in
                var profiles = feature.selectedProfiles
                if enabled {
                    profiles.insert(profile.id)
                } else {
                    profiles.remove(profile.id)
                }
                feature.setSelectedProfiles(profiles)
            }
        )
    }

    private func runPhase(phase: MavenLifecyclePhase, module: MavenModule?) {
        guard !model.isMavenOperationBusy else { return }
        model.showToolWindow(.mavenOutput)
        feature.run(phase: phase, module: module)
    }

    private func runSelected() {
        guard let phase = selectedPhase, !model.isMavenOperationBusy else { return }
        runPhase(phase: phase, module: selectedModule)
    }

    private func executeCustomGoal() {
        let goal = customGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, !model.isMavenOperationBusy,
              goalProject == feature.project else { return }
        isGoalSheetPresented = false
        model.showToolWindow(.mavenOutput)
        feature.runCustomGoal(goal, module: goalModule)
    }

    private func addCustomProfile() {
        if feature.addCustomProfile(customProfile) {
            customProfile = ""
            isAddProfilePresented = false
        }
    }

    private var selectedModule: MavenModule? {
        guard let selectedModuleID else { return nil }
        return feature.project?.allModules.first(where: { $0.id == selectedModuleID })
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
        selectedPhase = .compile
        expandedNodeIDs = feature.project.map { project in
            var ids: Set<String> = [projectNodeID(project)]
            if !feature.availableProfiles.isEmpty {
                ids.insert(profilesNodeID)
            }
            return ids
        } ?? []
    }
}

private struct JavaDependencyPathConfigurationEditor: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (JavaDependencyPathConfiguration) -> Void
    @State private var sourcePaths: String
    @State private var binaryPaths: String
    @State private var mavenPaths: String
    @State private var additionalPaths: String
    @State private var excludedPaths: [String]

    init(
        configuration: JavaDependencyPathConfiguration,
        onSave: @escaping (JavaDependencyPathConfiguration) -> Void
    ) {
        self.onSave = onSave
        _sourcePaths = State(initialValue: configuration.sourcePaths.joined(separator: "\n"))
        _binaryPaths = State(initialValue: configuration.binaryPaths.joined(separator: "\n"))
        _mavenPaths = State(initialValue: configuration.mavenPaths.joined(separator: "\n"))
        _additionalPaths = State(
            initialValue: configuration.additionalSearchPaths.joined(separator: "\n")
        )
        _excludedPaths = State(initialValue: configuration.excludedPaths)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Java Search Paths")
                .font(.system(size: 14, weight: .semibold))
            Text("One path per line. Relative paths are resolved from the workspace.")
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)

            pathEditor(title: "Source Code", text: $sourcePaths)
            pathEditor(title: "bin", text: $binaryPaths)
            pathEditor(title: "Maven", text: $mavenPaths)
            pathEditor(title: "Additional Search Paths", text: $additionalPaths)

            if !excludedPaths.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Excluded Paths")
                        .font(.system(size: 11, weight: .medium))
                    ForEach(excludedPaths, id: \.self) { path in
                        HStack(spacing: 6) {
                            Text(path)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Button {
                                excludedPaths.removeAll { $0 == path }
                            } label: {
                                LitheSystemIcon(systemImage: "arrow.uturn.backward")
                            }
                            .buttonStyle(.borderless)
                            .help("Restore path")
                        }
                    }
                }
            }

            HStack {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(JavaDependencyPathConfiguration(
                        sourcePaths: lines(sourcePaths),
                        binaryPaths: lines(binaryPaths),
                        mavenPaths: lines(mavenPaths),
                        additionalSearchPaths: lines(additionalPaths),
                        excludedPaths: excludedPaths
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func pathEditor(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            TextEditor(text: text)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 42)
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(LitheTheme.divider, lineWidth: 1)
                }
        }
    }

    private func lines(_ value: String) -> [String] {
        value
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }
}
