import SwiftUI

struct MavenView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: MavenFeatureModel
    @State private var treeActive = false
    @State private var selectedModuleID: String?
    @State private var selectedPhase: MavenLifecyclePhase?
    @State private var expandedNodeIDs: Set<String> = []
    @State private var isGoalSheetPresented = false
    @State private var isAddProfilePresented = false
    @State private var customGoal = ""
    @State private var customProfile = ""
    @State private var goalModule: MavenModule?
    @State private var goalProject: MavenProject?

    var body: some View {
        VStack(spacing: 0) {
            toolWindowHeader
            navigationToolbar

            if let error = feature.configurationSaveError {
                configurationErrorBanner(error)
            }
            if let error = feature.javaConfigurationError {
                configurationErrorBanner(String(
                    format: String(localized: "The Java language server did not take the Maven configuration: %@"),
                    error
                ))
            }
            MavenResolutionProblemsSection(diagnosticsStore: model.editorDiagnosticsStore)
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
        .workbenchHoverTooltipScope()
        .onAppear {
            if expandedNodeIDs.isEmpty {
                resetTreeState()
            }
        }
        .onChange(of: feature.project?.id) { _ in
            isGoalSheetPresented = false
            resetTreeState()
        }
        .sheet(isPresented: $isGoalSheetPresented) {
            goalSheet
        }
    }

    private var toolWindowHeader: some View {
        LitheToolWindowHeader(
            title: "Maven",
            systemImage: "shippingbox",
            ideaAssetPath: "maven/expui/toolwindow/maven.svg",
            subtitle: feature.project?.displayName
        ) {
            LitheSidebarHideButton(title: "Maven") {
                model.workbenchFeature.setVisibility(.maven, isVisible: false)
            }
        }
    }

    // Community ActionToolbarImpl: 22pt surface + 1/2pt button insets + 5/7pt toolbar insets.
    private var navigationToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                toolbarAction(.run) {
                    Button {
                        if isMavenTaskRunning {
                            model.stopMaven()
                        } else {
                            runSelected()
                        }
                    } label: {
                        mavenIcon(isMavenTaskRunning ? "expui/run/stop.svg" : "expui/run/run.svg")
                    }
                    .disabled(!isMavenTaskRunning && (selectedPhase == nil || model.isMavenOperationBusy))
                    .accessibilityLabel(toolbarHelp(for: .run))
                }

                toolbarAction(.goal) {
                    Button {
                        presentGoal(for: selectedModule)
                    } label: {
                        mavenIcon("expui/general/runAnything.svg")
                    }
                    .disabled(model.isMavenOperationBusy)
                    .accessibilityLabel(toolbarHelp(for: .goal))
                }

                toolbarAction(.reload) {
                    Button(action: refreshProject) {
                        mavenIcon("expui/general/refresh.svg")
                    }
                    .accessibilityLabel(toolbarHelp(for: .reload))
                    .disabled(model.isMavenOperationBusy)
                }

                toolbarAction(.skipTests) {
                    Button {
                        feature.setSkipTests(!feature.skipTests)
                    } label: {
                        mavenIcon("expui/run/showIgnored.svg")
                    }
                    .accessibilityLabel(toolbarHelp(for: .skipTests))
                    .accessibilityValue(feature.skipTests ? Text("On") : Text("Off"))
                }

                toolbarAction(.collapse) {
                    Button {
                        expandedNodeIDs.removeAll()
                    } label: {
                        mavenIcon("expui/general/collapseAll.svg")
                    }
                    .accessibilityLabel(toolbarHelp(for: .collapse))
                }

                toolbarAction(.settings) {
                    Button(action: { model.showSettings(category: .project) }) {
                        mavenIcon("expui/general/settings.svg")
                    }
                    .accessibilityLabel(toolbarHelp(for: .settings))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
        }
        .frame(height: LitheTheme.Metrics.toolbarIconButtonSize + 12)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private func toolbarAction<Content: View>(
        _ action: MavenToolbarAction,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let enabled = action == .run
            ? isMavenTaskRunning || (selectedPhase != nil && !model.isMavenOperationBusy)
            : !([.goal, .reload].contains(action) && model.isMavenOperationBusy)
        return content()
            .opacity(enabled ? 1 : 0.45)
            .buttonStyle(LitheIconButtonStyle(
                size: LitheTheme.Metrics.toolbarIconButtonSize, cornerRadius: 4,
                isSelected: action == .skipTests && feature.skipTests,
                hoverBackground: LitheTheme.toolbarHoverBackground,
                pressedBackground: LitheTheme.toolbarPressedBackground
            ))
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .workbenchHoverHelp(Text(toolbarHelp(for: action)))
    }

    private func mavenIcon(_ path: String) -> some View {
        // Maven Profiles is the upstream exception: 17×16, not a square glyph.
        LitheIDEAIcon(resourcePath: path, size: LitheTheme.Tree.iconSize,
                      width: path == "maven/expui/build/mavenProfiles.svg" ? 17 : nil,
                      preservesOriginalColors: true)
    }

    private func toolbarHelp(for action: MavenToolbarAction) -> String {
        switch action {
        case .run:
            isMavenTaskRunning
                ? String(localized: "Stop Maven task")
                : String(localized: "Run selected Maven lifecycle phase")
        case .goal: String(localized: "Execute Maven goal")
        case .reload: String(localized: "Reload Maven project")
        case .skipTests: String(localized: "Skip tests")
        case .collapse: String(localized: "Collapse all")
        case .settings: String(localized: "Maven settings")
        }
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
                .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            Spacer(minLength: 8)
            Button(feature.isReloading ? String(localized: "Reloading Maven...") : String(localized: "Reload")) {
                Task { await model.reloadMavenProject(rescan: feature.isProjectReloadRequired) }
            }
            .buttonStyle(.litheNoPress)
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
                .font(LitheTheme.uiFont(size: 11.5))
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
            VStack(alignment: .leading, spacing: 0) {
                if !feature.availableProfiles.isEmpty {
                    treeNode(
                        id: profilesNodeID,
                        title: "Profiles",
                        iconPath: "maven/expui/build/mavenProfiles.svg",
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
                    iconPath: "maven/expui/build/mavenProject.svg",
                    isSelected: selectedModuleID == nil,
                    hasModuleMenu: true,
                    onLabelAction: { selectedModuleID = nil }
                ) {
                    sourceRootsNode(
                        ownerID: projectNodeID(project),
                        sourceRoots: project.sourceRoots
                    )
                    lifecycleNode(ownerID: projectNodeID(project), module: nil)
                    dependencyNode(ownerID: projectNodeID(project), modulePath: ".")
                    ForEach(project.modules) { module in
                        moduleTreeNode(module)
                    }
                }
            }
            .padding(.horizontal, LitheTheme.Tree.horizontalInset)
            .padding(.vertical, LitheTheme.Tree.verticalInset)
        }
        .litheWorkbenchSurface(LitheTheme.sidebar)
        .background(LitheToolWindowActivityTracker(isActive: $treeActive))
    }

    private func moduleTreeNode(_ module: MavenModule) -> AnyView {
        AnyView(
            treeNode(
                id: moduleNodeID(module),
                title: module.displayName,
                subtitle: module.relativePath,
                iconPath: "maven/expui/build/mavenProject.svg",
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
                iconPath: "expui/build/taskGroup.svg",
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
                iconPath: "expui/nodes/folder.svg",
                onLabelAction: { toggleNode(nodeID) }
            ) {
                ForEach(sourceRoots) { sourceRoot in
                    sourceRootRow(sourceRoot)
                }
            }
        )
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
                iconPath: "expui/nodes/libraryFolder.svg",
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
                    .buttonStyle(.litheNoPress)
                }
                .font(LitheTheme.uiFont(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.horizontal, 4)
                .frame(minHeight: 28)
            )
        case .failed(let message):
            return AnyView(
                VStack(alignment: .leading, spacing: 4) {
                    Label(dependencyLocalization.error(message), systemImage: "exclamationmark.triangle.fill")
                        .font(LitheTheme.uiFont(size: 11.5))
                        .foregroundStyle(LitheTheme.error)
                        .lineLimit(2)
                    Button(dependencyLocalization.text("Retry")) {
                        feature.loadDependencies(for: modulePath)
                    }
                    .buttonStyle(.litheNoPress)
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
                    .buttonStyle(.litheNoPress)
                }
                .font(LitheTheme.uiFont(size: 11.5))
                .foregroundStyle(LitheTheme.warning)
                .padding(.horizontal, 4)
                .frame(minHeight: 28)
            )
        case .ready(let dependencies):
            if dependencies.isEmpty {
                return AnyView(
                    Text(dependencyLocalization.text("No dependencies"))
                        .font(LitheTheme.uiFont(size: 11.5))
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
                iconPath: "expui/nodes/library.svg",
                hasWarning: dependency.resolution != .resolved,
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
        Button { openDependencyPom(dependency) } label: {
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                if dependency.resolution == .resolved {
                    mavenIcon("expui/nodes/library.svg")
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LitheTheme.warning)
                        .frame(width: LitheTheme.Tree.iconSize)
                }
                Text(dependency.artifactID).lineLimit(1)
                Text(dependencySubtitle(dependency))
                    .foregroundStyle(dependency.resolution == .resolved ? LitheTheme.Tree.secondaryText : LitheTheme.warning)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, LitheTheme.Tree.indent)
            .litheTreeRow()
        }
        .buttonStyle(.litheNoPress)
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
        HStack(spacing: LitheTheme.Tree.iconTextGap) {
            mavenIcon("expui/nodes/folder.svg")
            Text(sourceRoot.path).lineLimit(1)
            Spacer(minLength: 0)
            Text(dependencyLocalization.text(sourceRoot.kind.title))
                .foregroundStyle(LitheTheme.Tree.secondaryText).lineLimit(1)
        }
        .padding(.leading, LitheTheme.Tree.indent)
        .litheTreeRow()
    }

    private func profileRow(_ profile: MavenProfile) -> some View {
        Toggle(isOn: profileBinding(for: profile)) {
            HStack(spacing: 0) {
                Text(profile.id)
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .toggleStyle(.checkbox)
        .padding(.leading, LitheTheme.Tree.indent)
        .litheTreeRow()
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
            .buttonStyle(.litheNoPress)
            .help("Add profile")
            .litheDropdown(isPresented: $isAddProfilePresented) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add Maven Profile")
                        .font(LitheTheme.uiFont(size: 13, weight: .semibold))
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
            .buttonStyle(.litheNoPress)
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
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                mavenIcon("maven/task.svg")
                Text(LocalizedStringKey(phase.title)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, LitheTheme.Tree.indent)
            .litheTreeRow(isSelected: selectedModuleID == module?.id && selectedPhase == phase,
                          isFocused: treeActive)
        }
        .buttonStyle(.litheNoPress)
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
        iconPath: String,
        hasWarning: Bool = false,
        isSelected: Bool = false,
        hasModuleMenu: Bool = false,
        menuModule: MavenModule? = nil,
        onToggleAction: (() -> Void)? = nil,
        onLabelAction: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                Button {
                    if let onToggleAction { onToggleAction() } else { toggleNode(id) }
                } label: {
                    mavenIcon(isNodeExpanded(id) ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg")
                        .frame(width: LitheTheme.Tree.disclosureSlot, height: LitheTheme.Tree.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .accessibilityLabel(Text(LocalizedStringKey(title)))
                .accessibilityValue(isNodeExpanded(id) ? Text("Expanded") : Text("Collapsed"))

                Button(action: onLabelAction) {
                    HStack(spacing: LitheTheme.Tree.iconTextGap) {
                        if hasWarning {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LitheTheme.warning)
                                .frame(width: LitheTheme.Tree.iconSize)
                        } else {
                            mavenIcon(iconPath)
                        }
                        Text(LocalizedStringKey(title)).lineLimit(1)
                        if let subtitle, !subtitle.isEmpty {
                            Text("(\(subtitle))").foregroundStyle(LitheTheme.Tree.secondaryText).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: LitheTheme.Tree.rowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
            }
            .litheTreeRow(isSelected: isSelected, isFocused: treeActive)
            .litheContextMenu(items: {
                hasModuleMenu ? moduleContextMenu(menuModule) : []
            })

            if isNodeExpanded(id) {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .padding(.leading, LitheTheme.Tree.indent)
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
                .font(LitheTheme.uiFont(size: 30, weight: .light))
                .foregroundStyle(LitheTheme.secondaryText)
            Text("No Maven project detected")
                .font(LitheTheme.uiFont(size: 14, weight: .semibold))
            Text("Open a project containing a pom.xml file.")
                .font(LitheTheme.uiFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.octagon")
                .font(LitheTheme.uiFont(size: 28, weight: .light))
                .foregroundStyle(LitheTheme.error)
            Text("Unable to load Maven project")
                .font(LitheTheme.uiFont(size: 14, weight: .semibold))
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
                .font(LitheTheme.uiFont(size: 16, weight: .semibold))
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

private enum MavenToolbarAction: Hashable {
    case run
    case goal
    case reload
    case skipTests
    case collapse
    case settings
}

/// Lists the Maven problems JDT LS reports on workspace `pom.xml` files.
/// Observes the diagnostics store directly so publish storms do not rebuild
/// the whole Maven tool window.
private struct MavenResolutionProblemsSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var diagnosticsStore: EditorDiagnosticsStore

    var body: some View {
        let problems = MavenResolutionProblems.problems(
            workspaceURL: model.workspaceURL,
            diagnosticsByURL: diagnosticsStore.diagnosticsByURL
        )
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    String(
                        format: String(localized: "Maven could not resolve this project (%lld problems)"),
                        problems.count
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
                .foregroundStyle(LitheTheme.error)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(problems) { problem in
                            Button {
                                model.openDiagnostic(problem)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(problem.locationTitle)
                                        .foregroundStyle(LitheTheme.secondaryText)
                                    Text(problem.message)
                                        .foregroundStyle(LitheTheme.primaryText)
                                        .lineLimit(2)
                                    Spacer(minLength: 0)
                                }
                                .font(LitheTheme.uiFont(size: 11))
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(problem.message)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LitheTheme.error.opacity(0.06))
        }
    }
}
