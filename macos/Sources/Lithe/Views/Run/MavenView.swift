import SwiftUI

struct MavenView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: MavenFeatureModel
    @State private var selectedModuleID: String?
    @State private var selectedPhase: MavenLifecyclePhase?
    @State private var expandedNodeIDs: Set<String> = []
    @State private var isGoalSheetPresented = false
    @State private var isSettingsSheetPresented = false
    @State private var isAddProfilePresented = false
    @State private var customGoal = ""
    @State private var customProfile = ""
    @State private var settingsPath = ""
    @State private var localRepositoryPath = ""
    @State private var mavenExecutablePath = ""
    @State private var javaHomePath = ""

    var body: some View {
        VStack(spacing: 0) {
            toolWindowHeader

            if let error = feature.configurationSaveError {
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
        .litheWorkbenchSurface(LitheTheme.editor)
        .onAppear {
            if expandedNodeIDs.isEmpty {
                resetTreeState()
            }
        }
        .onChange(of: feature.project?.id) { _ in
            resetTreeState()
        }
        .sheet(isPresented: $isGoalSheetPresented) {
            goalSheet
        }
        .sheet(isPresented: $isSettingsSheetPresented) {
            settingsSheet
        }
    }

    private var toolWindowHeader: some View {
        LitheToolWindowHeader(
            title: "Maven",
            systemImage: "shippingbox",
            ideaAssetPath: "maven/toolWindowMaven.svg",
            subtitle: feature.project?.displayName,
            onMinimize: { model.workbenchFeature.setVisibility(.maven, isVisible: false) }
        ) {
            if let runningTitle = feature.runningTitle {
                ProgressView()
                    .controlSize(.mini)
                Text(runningTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            } else if feature.taskState == .cancelled {
                Label("Cancelled", systemImage: "stop.circle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.warning)
            } else if let exitCode = feature.lastExitCode {
                Label(
                    exitCode == 0 ? "Succeeded" : "Failed",
                    systemImage: exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(exitCode == 0 ? LitheTheme.success : LitheTheme.error)
            }

            Button(action: runSelected) {
                LitheSystemIcon(systemImage: "play.fill")
            }
            .litheIconButton()
            .disabled(selectedPhase == nil || feature.isRunning)
            .help("Run selected Maven lifecycle phase")

            Button {
                customGoal = ""
                isGoalSheetPresented = true
            } label: {
                LitheSystemIcon(systemImage: "terminal")
            }
            .litheIconButton()
            .disabled(feature.isRunning)
            .help("Execute Maven goal")

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

            Button(action: presentSettings) {
                LitheSystemIcon(systemImage: "slider.horizontal.3")
            }
            .litheIconButton()
            .help("Maven settings")

            Button(action: feature.clearOutput) {
                Image(systemName: "trash")
            }
            .litheIconButton()
            .help("Clear build output")

        }
    }

    private func refreshProject() {
        guard let workspaceURL = model.workspaceURL else { return }
        Task { await feature.loadProject(at: workspaceURL, files: model.projectFiles) }
    }

    private var reloadBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(LitheTheme.warning)
            Text("Maven configuration changed")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            Spacer(minLength: 8)
            Button("Reload JDT LS") {
                model.restartLanguageServers()
                feature.acknowledgeReload()
            }
            .buttonStyle(.borderless)
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
                title: "Source Roots",
                systemImage: "folder",
                onLabelAction: { toggleNode(nodeID) }
            ) {
                ForEach(sourceRoots) { sourceRoot in
                    sourceRootRow(sourceRoot)
                }
            }
        )
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
                title: "Dependencies",
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
                    Text("Resolving dependencies...")
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Cancel") {
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
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(LitheTheme.error)
                        .lineLimit(2)
                    Button("Retry") {
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
                    Text("Dependency resolution cancelled")
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Retry") {
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
                    Text("No dependencies")
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
        .help("Open module pom.xml")
    }

    private func dependencySubtitle(_ dependency: MavenDependency) -> String {
        let classifier = dependency.classifier.map { ":" + $0 } ?? ""
        let marker = switch dependency.resolution {
        case .resolved:
            ""
        case .omittedDuplicate:
            " (duplicate omitted)"
        case .omittedConflict:
            " (conflict -> " + (dependency.selectedVersion ?? "selected") + ")"
        }
        return dependency.groupID + ":" + dependency.version + ":" + dependency.type
            + classifier + " [" + dependency.scope + "]" + marker
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
            Text(sourceRoot.kind.title)
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
            guard !feature.isRunning else { return }
            feature.run(phase: phase, module: module)
        })
    }

    private func treeNode<Content: View>(
        id: String,
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        isSelected: Bool = false,
        onToggleAction: (() -> Void)? = nil,
        onLabelAction: @escaping () -> Void,
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
            .litheWorkbenchSurface(LitheTheme.toolHeader)

            if !feature.issues.isEmpty {
                issueList
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }

            OutputTextView(
                output: feature.output,
                searchRoots: mavenSearchRoots,
                fileExists: { model.fileExists(at: $0) },
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
        .litheWorkbenchSurface(LitheTheme.sidebar)
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

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Maven Settings")
                .font(.system(size: 16, weight: .semibold))

            settingsPathRow(
                title: "settings.xml",
                value: $settingsPath,
                choose: {
                    model.platformUI.chooseFile(title: "Choose Maven settings.xml", prompt: "Choose")
                }
            )
            settingsPathRow(
                title: "Local Repository",
                value: $localRepositoryPath,
                choose: {
                    model.platformUI.chooseDirectory(title: "Choose Maven Local Repository", prompt: "Choose")
                }
            )
            settingsPathRow(
                title: "Maven Home or Executable",
                value: $mavenExecutablePath,
                choose: {
                    model.platformUI.chooseDirectory(title: "Choose Maven Home", prompt: "Choose")
                }
            )
            settingsPathRow(
                title: "Maven JDK",
                value: $javaHomePath,
                choose: {
                    model.platformUI.chooseDirectory(title: "Choose Maven JDK", prompt: "Choose")
                }
            )

            if let error = feature.configurationSaveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.error)
            }

            HStack {
                Spacer()
                Button("Cancel") { isSettingsSheetPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: saveSettings)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func settingsPathRow(
        title: String,
        value: Binding<String>,
        choose: @escaping () -> URL?
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            HStack(spacing: 6) {
                TextField("Automatic", text: value)
                    .textFieldStyle(.roundedBorder)
                Button {
                    value.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark")
                }
                .litheIconButton()
                .help("Use automatic value")
                Button {
                    if let url = choose() {
                        value.wrappedValue = url.standardizedFileURL.path
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .litheIconButton()
                .help("Choose path")
            }
        }
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

    private func runSelected() {
        guard let phase = selectedPhase, !feature.isRunning else { return }
        feature.run(phase: phase, module: selectedModule)
    }

    private func executeCustomGoal() {
        let goal = customGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        isGoalSheetPresented = false
        feature.runCustomGoal(goal, module: selectedModule)
    }

    private func addCustomProfile() {
        if feature.addCustomProfile(customProfile) {
            customProfile = ""
            isAddProfilePresented = false
        }
    }

    private func presentSettings() {
        settingsPath = feature.settingsPath ?? ""
        localRepositoryPath = feature.localRepositoryPath ?? ""
        mavenExecutablePath = feature.mavenExecutablePath ?? ""
        javaHomePath = feature.javaHomePath ?? ""
        isSettingsSheetPresented = true
    }

    private func saveSettings() {
        feature.updateLocalConfiguration(
            settingsPath: settingsPath,
            localRepositoryPath: localRepositoryPath,
            mavenExecutablePath: mavenExecutablePath,
            javaHomePath: javaHomePath
        )
        isSettingsSheetPresented = false
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
