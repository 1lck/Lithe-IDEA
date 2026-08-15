import AppKit
import SwiftUI
import LitheGitModule

private enum ActivityBarMetrics {
    static let width: CGFloat = 38
    static let buttonWidth: CGFloat = 30
    static let buttonHeight: CGFloat = 30
    static let spacing: CGFloat = 4
    static let edgeInset: CGFloat = 4
}

struct WorkbenchView: View {
    private let moduleUIRegistry = WorkbenchModuleUIComposition.builtIn
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var projectSessions: ProjectSessionManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var memoryUsageMonitor: MemoryUsageMonitor
    @State private var sidebarWidth: CGFloat = 320
    @State private var topPaneHeight: CGFloat?
    @State private var isBranchSwitcherPresented = false
    @State private var newBranchReference: GitReference?
    @State private var isCheckoutRevisionPresented = false
    @State private var pendingTopBarPushReference: GitReference?
    @State private var isProjectSwitcherPresented = false
    @State private var isMemoryUsagePopoverPresented = false
    @State private var isPluginPanelPresented = false
    @State private var didRestoreLayout = false
    @State private var hoveredProjectTabID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if projectSessions.openProjects.count > 1 {
                projectTabBar
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }

            HStack(spacing: 0) {
                activityBar
                workspaceArea
                pluginActivityBar
            }
            .frame(maxHeight: .infinity)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            statusBar
        }
        .sheet(item: $newBranchReference) { reference in
            TopBarNewBranchDialog(reference: reference) { name, checkout in
                Task {
                    await model.createBranch(named: name, from: reference, checkout: checkout)
                }
            }
        }
        .sheet(isPresented: $isCheckoutRevisionPresented) {
            CheckoutRevisionDialog { revision in
                Task { await model.checkoutRevision(revision) }
            }
        }
        .confirmationDialog(
            runConfigurationSetupTitle,
            isPresented: Binding(
                get: { model.runFeatureIfActive?.isGenerationConfirmationPresented ?? false },
                set: { model.runFeatureIfActive?.isGenerationConfirmationPresented = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button(model.runFeatureIfActive?.configurationStatus == .ready ? "Rescan" : "Identify and Generate") {
                continueAfterRunConfigurationGeneration()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(runConfigurationSetupMessage)
        }
        .sheet(item: $model.pendingCheckoutConflict) { request in
            GitCheckoutConflictDialog(
                request: request,
                savePolicy: model.gitSaveChangesPolicy,
                onResolve: { strategy in
                    Task { await model.resolveCheckoutConflict(request, strategy: strategy) }
                },
                onRollback: { path in
                    model.requestConflictRollback(path: path, resume: .checkout(request.reference))
                }
            )
        }
        .sheet(item: $model.pendingPullStrategy) { request in
            GitPullStrategyDialog(request: request) { strategy in
                Task { await model.resolvePullStrategy(strategy) }
            }
            .onDisappear { model.cancelPullStrategy() }
        }
        .sheet(item: $model.pendingIntegrationConflict) { request in
            GitIntegrationConflictDialog(
                request: request,
                savePolicy: model.gitSaveChangesPolicy,
                onStash: { Task { await model.resolveIntegrationConflict(request) } },
                onRollback: { path in
                    model.requestConflictRollback(
                        path: path,
                        resume: .integration(target: request.target, operation: request.operation)
                    )
                }
            )
            .onDisappear { model.cancelIntegrationConflict() }
        }
        .confirmationDialog(
            "Save changes before closing?",
            isPresented: Binding(
                get: { model.pendingCloseDocument != nil },
                set: { if !$0 { model.cancelPendingClose() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Save") { model.closePendingDocument(discardingChanges: false) }
                .lithePointer()
            Button("Discard Changes", role: .destructive) { model.closePendingDocument(discardingChanges: true) }
                .lithePointer()
            Button("Cancel", role: .cancel) { model.cancelPendingClose() }
                .lithePointer()
        } message: {
            Text(model.pendingCloseDocument?.url.lastPathComponent ?? "")
        }
        .confirmationDialog(
            model.pendingDiscardChange?.isUntracked == true ? "Delete this untracked file?" : "Discard changes to this file?",
            isPresented: Binding(
                get: { model.pendingDiscardChange != nil },
                set: { if !$0 { model.cancelDiscardChange() } }
            ),
            titleVisibility: .visible
        ) {
            Button(model.pendingDiscardChange?.isUntracked == true ? "Delete File" : "Discard Changes", role: .destructive) {
                Task { await model.confirmDiscardChange() }
            }
            .lithePointer()
            Button("Cancel", role: .cancel) { model.cancelDiscardChange() }
                .lithePointer()
        } message: {
            Text("This action cannot be undone by Lithe.")
        }
        .confirmationDialog(
            "Discard changes to '\(model.pendingConflictRollback?.path ?? "this file")'?",
            isPresented: Binding(
                get: { model.pendingConflictRollback != nil },
                set: { if !$0 { model.cancelConflictRollback() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard and Retry", role: .destructive) {
                guard let request = model.pendingConflictRollback else { return }
                Task { await model.confirmConflictRollback(request) }
            }
            .lithePointer()
            Button("Cancel", role: .cancel) { model.cancelConflictRollback() }
                .lithePointer()
        } message: {
            Text("This discards the file's staged and working-tree changes, then retries the blocked Git operation.")
        }
        .confirmationDialog(
            "Discard this change block?",
            isPresented: Binding(
                get: { model.pendingDiscardHunk != nil },
                set: { if !$0 { model.cancelDiscardHunk() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard Block", role: .destructive) {
                Task { await model.confirmDiscardHunk() }
            }
            .lithePointer()
            Button("Cancel", role: .cancel) { model.cancelDiscardHunk() }
                .lithePointer()
        } message: {
            Text(model.pendingDiscardHunk?.change.path ?? "This action cannot be undone by Lithe.")
        }
        .confirmationDialog(
            "Push '\(pendingTopBarPushReference?.shortName ?? "")'?",
            isPresented: Binding(
                get: { pendingTopBarPushReference != nil },
                set: { if !$0 { pendingTopBarPushReference = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Push") {
                guard let reference = pendingTopBarPushReference else { return }
                pendingTopBarPushReference = nil
                Task { await model.pushBranch(reference) }
            }
            .lithePointer()
            Button("Cancel", role: .cancel) {
                pendingTopBarPushReference = nil
            }
            .lithePointer()
        } message: {
            Text("This sends the current branch to its configured remote.")
        }
        .overlay(alignment: .bottom) {
            if let message = model.notificationMessage {
                Text(LocalizedStringKey(message))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(LitheTheme.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                    .padding(.bottom, 38)
            }
        }
        .overlay {
            if model.isSearchEverywhereVisible {
                SearchEverywhereView()
                    .environmentObject(model)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.isSearchEverywhereVisible)
        // Replace in Files 挂在工作台层：搜索侧栏未打开时快捷键也能直接弹出。
        .sheet(isPresented: $model.isProjectReplaceVisible) {
            ProjectReplaceView()
                .environmentObject(model)
        }
        .onAppear {
            restoreLayout()
        }
        .onChange(of: model.workspaceURL?.standardizedFileURL.path) { _ in
            didRestoreLayout = false
            restoreLayout()
        }
    }

    private var projectTabBar: some View {
        GeometryReader { geometry in
            let horizontalPadding: CGFloat = 6
            let tabSpacing: CGFloat = 6
            let minimumTabWidth: CGFloat = 180
            let projectCount = CGFloat(max(projectSessions.openProjects.count, 1))
            let availableWidth = geometry.size.width
                - horizontalPadding * 2
                - tabSpacing * (projectCount - 1)
            let tabWidth = max(minimumTabWidth, floor(availableWidth / projectCount))

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: tabSpacing) {
                        ForEach(projectSessions.openProjects) { projectModel in
                            projectTab(projectModel, width: tabWidth)
                                .id(projectModel.id)
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                    .frame(minWidth: geometry.size.width, alignment: .leading)
                }
                .onAppear {
                    proxy.scrollTo(projectSessions.activeSessionID, anchor: .center)
                }
                .onChange(of: projectSessions.activeSessionID) { id in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .frame(height: LitheTheme.Metrics.tabHeight + 4)
        .background(LitheTheme.toolHeader)
    }

    private func projectTab(_ projectModel: AppModel, width: CGFloat) -> some View {
        let isActive = projectModel.id == projectSessions.activeSessionID
        let isHovered = projectModel.id == hoveredProjectTabID

        return ZStack(alignment: .trailing) {
            Button {
                projectSessions.activateSession(projectModel.id)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isActive ? LitheTheme.accent : LitheTheme.secondaryText)

                    Text(projectModel.projectName)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(isActive ? LitheTheme.primaryText : LitheTheme.secondaryText)

                    if let documentName = projectModel.activeDocument?.displayName {
                        Text("· \(documentName)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 38)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()
            .accessibilityIdentifier("project-tab-\(projectModel.id.uuidString)")

            Button {
                projectSessions.closeProject(projectModel.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .buttonStyle(LitheIconButtonStyle())
            .lithePointer()
            .help("Close Project")
            .opacity(isActive || isHovered ? 1 : 0)
            .allowsHitTesting(isActive || isHovered)
            .padding(.trailing, 3)
        }
        .frame(width: width, height: 30)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isActive
                        ? LitheTheme.activeTabBackground
                        : (isHovered ? LitheTheme.hoverBackground : LitheTheme.inactiveTabBackground)
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    isActive
                        ? LitheTheme.inputFocusBorder.opacity(0.7)
                        : (isHovered ? LitheTheme.panelBorder : .clear),
                    lineWidth: 1
                )
        }
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(isActive ? LitheTheme.tabUnderline : .clear)
                .frame(width: min(56, max(28, width * 0.12)), height: 2)
                .padding(.bottom, 1)
        }
        .onHover { hovering in
            hoveredProjectTabID = hovering ? projectModel.id : nil
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private var topBar: some View {
        HStack(spacing: 9) {
            Button {
                isProjectSwitcherPresented.toggle()
            } label: {
                HStack(spacing: 8) {
                    LitheLogo(size: 28)

                    Text(model.projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .padding(.horizontal, 8)
                .frame(height: 32)
                .litheRowHover(
                    isActive: isProjectSwitcherPresented,
                    cornerRadius: 6,
                    activeBackground: LitheTheme.subtleSelection
                )
            }
            .buttonStyle(.plain)
            .lithePointer()
            .accessibilityIdentifier("project-switcher-\(model.id.uuidString)")
            .popover(isPresented: $isProjectSwitcherPresented, arrowEdge: .bottom) {
                ProjectSwitcherPopover(
                    isPresented: $isProjectSwitcherPresented,
                    onNewProject: {
                        isProjectSwitcherPresented = false
                        model.chooseProject(title: "New Project", prompt: "Choose Folder")
                    },
                    onOpenProject: {
                        isProjectSwitcherPresented = false
                        model.chooseProject()
                    },
                    onCloneRepository: {
                        isProjectSwitcherPresented = false
                        model.showCloneRepository()
                    },
                    onOpenRecentProject: { project in
                        isProjectSwitcherPresented = false
                        model.openProject(project.url)
                    }
                )
                .environmentObject(model)
            }

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(width: 1, height: 20)
                .padding(.horizontal, 5)

            Button {
                isBranchSwitcherPresented.toggle()
                if isBranchSwitcherPresented {
                    Task { await model.refreshGitHistory() }
                }
            } label: {
                HStack(spacing: 7) {
                    LitheIDEAIcon(
                        resourcePath: "toolwindows/toolWindowVcs.svg",
                        size: 14,
                        fallbackSystemImage: "point.3.connected.trianglepath.dotted"
                    )
                        .foregroundStyle(LitheTheme.secondaryText)
                    Text(model.currentBranch)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .padding(.horizontal, 9)
                .frame(height: 32)
                .litheRowHover(
                    isActive: isBranchSwitcherPresented,
                    cornerRadius: 6,
                    activeBackground: LitheTheme.subtleSelection
                )
            }
            .buttonStyle(.plain)
            .lithePointer()
            .popover(isPresented: $isBranchSwitcherPresented, arrowEdge: .bottom) {
                BranchSwitcherPopover(
                    isPresented: $isBranchSwitcherPresented,
                    onCommit: {
                        isBranchSwitcherPresented = false
                        model.selectedSidebar = .changes
                    },
                    onPush: { reference in
                        isBranchSwitcherPresented = false
                        pendingTopBarPushReference = reference
                    },
                    onNewBranch: { reference in
                        isBranchSwitcherPresented = false
                        newBranchReference = reference
                    },
                    onCheckoutRevision: {
                        isBranchSwitcherPresented = false
                        isCheckoutRevisionPresented = true
                    },
                    onManageBranches: {
                        isBranchSwitcherPresented = false
                        if !model.isGitLogVisible {
                            model.selectedSidebar = .changes
                            Task { await model.toggleGitLog() }
                        }
                    }
                )
                .environmentObject(model)
            }

            Spacer(minLength: 22)

        }
        .padding(.leading, 76)
        .padding(.trailing, 10)
        .frame(height: LitheTheme.Metrics.toolbarHeight)
        .background {
            LitheTheme.titlebar
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    (NSApplication.shared.keyWindow?.delegate as? LitheWindowCoordinator)?
                        .toggleWorkspaceZoom()
                }
        }
    }

    private var activityBar: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                VStack(spacing: ActivityBarMetrics.spacing) {
                    ForEach(model.availableSidebarDestinations) { destination in
                        Button {
                            if destination == .database {
                                Task { await model.activateDatabaseModule() }
                            } else {
                                model.selectedSidebar = destination
                            }
                        } label: {
                            LitheIDEAIcon(
                                resourcePath: destination.ideaAssetPath,
                                size: 18,
                                fallbackSystemImage: destination.systemImage
                            )
                                .frame(
                                    width: ActivityBarMetrics.buttonWidth,
                                    height: ActivityBarMetrics.buttonHeight
                                )
                                .litheRowHover(
                                    isActive: model.selectedSidebar == destination,
                                    cornerRadius: 4,
                                    activeBackground: LitheTheme.subtleSelection
                                )
                        }
                        .buttonStyle(.plain)
                        .lithePointer()
                        .foregroundStyle(model.selectedSidebar == destination ? LitheTheme.primaryText : LitheTheme.secondaryText)
                        .help(LocalizedStringKey(destination.title))
                    }
                }
                .padding(.top, ActivityBarMetrics.edgeInset)

                Spacer(minLength: 0)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: ActivityBarMetrics.spacing) {
                    ForEach(model.activityBarContributions) { contribution in
                        if let renderer = moduleUIRegistry.renderer(for: contribution),
                           renderer.isVisible(model) {
                            activityToolButton(
                                systemImage: contribution.icon ?? "square.grid.2x2",
                                ideaAssetPath: renderer.ideaAssetPath,
                                help: contribution.title,
                                isSelected: renderer.isSelected(model)
                            ) {
                                moduleUIRegistry.perform(contribution, model: model)
                            }
                        }
                    }

                    activityToolButton(
                        systemImage: "gearshape",
                        ideaAssetPath: "general/gear.svg",
                        help: "Settings",
                        isSelected: model.isSettingsPresented
                    ) {
                        model.showSettings()
                    }
                    }
                }
                .frame(height: 292)
                .padding(.bottom, ActivityBarMetrics.edgeInset)
            }
            .frame(width: ActivityBarMetrics.width, height: geometry.size.height, alignment: .top)
            .background(LitheTheme.titlebar)
        }
        .frame(width: ActivityBarMetrics.width)
    }

    private var pluginActivityBar: some View {
        VStack {
            Button { isPluginPanelPresented.toggle() } label: {
                Image(systemName: "puzzlepiece.extension")
                    .frame(width: ActivityBarMetrics.buttonWidth, height: ActivityBarMetrics.buttonHeight)
                    .litheRowHover(isActive: isPluginPanelPresented, cornerRadius: 4, activeBackground: LitheTheme.subtleSelection)
            }
            .buttonStyle(.plain)
            .lithePointer()
            .foregroundStyle(isPluginPanelPresented ? LitheTheme.primaryText : LitheTheme.secondaryText)
            .help("Plugins")
            Spacer()
        }
        .padding(.top, ActivityBarMetrics.edgeInset)
        .frame(width: ActivityBarMetrics.width)
        .background(LitheTheme.titlebar)
    }

    private var runConfigurationSetupTitle: String {
        switch model.runFeatureIfActive?.configurationStatus ?? .missing {
        case .missing:
            String(localized: "Project run configuration not found")
        case .invalid:
            String(localized: "Project run configuration is invalid")
        case .ready:
            String(localized: "Rescan the project for services")
        }
    }

    /// The dialog doubles as first-time setup and as an explicit rescan. Only
    /// the first case can claim Run is unavailable until it completes.
    private var runConfigurationSetupMessage: String {
        model.runFeatureIfActive?.configurationStatus == .ready
            ? String(localized: "Lithe will look for services again and refresh .lithe/run/generated.json. Project and local overrides will not be changed.")
            : String(localized: "Lithe needs to identify the project and generate .lithe/run/generated.json before Run and Debug are available. Project and local overrides will not be changed.")
    }

    private func continueAfterRunConfigurationGeneration() {
        guard let runFeature = model.runFeatureIfActive else { return }
        let intent = runFeature.generationIntent
        Task {
            await runFeature.generateRunConfigurations()
            guard runFeature.configurationStatus == .ready else { return }
            switch intent {
            case .identifyOnly:
                break
            case .run:
                model.runSelectedConfiguration()
            case .debug:
                model.startDebugging()
            }
        }
    }

    private func activityToolButton(
        systemImage: String,
        ideaAssetPath: String? = nil,
        help: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let ideaAssetPath {
                    LitheIDEAIcon(
                        resourcePath: ideaAssetPath,
                        size: 18,
                        fallbackSystemImage: systemImage
                    )
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .medium))
                }
            }
            .frame(
                width: ActivityBarMetrics.buttonWidth,
                height: ActivityBarMetrics.buttonHeight
            )
            .litheRowHover(
                isActive: isSelected,
                cornerRadius: 4,
                activeBackground: LitheTheme.subtleSelection
            )
        }
        .buttonStyle(.plain)
        .lithePointer()
        .foregroundStyle(isSelected ? LitheTheme.primaryText : LitheTheme.secondaryText)
        .help(LocalizedStringKey(help))
        .accessibilityLabel(Text(LocalizedStringKey(help)))
    }

    private var workspaceArea: some View {
        WorkbenchWorkspaceSplitView(
            sidebarWidth: sidebarWidth,
            topPaneHeight: topPaneHeight,
            isBottomToolVisible: isBottomToolVisible,
            onSidebarWidthCommitted: { width in
                sidebarWidth = width
                saveLayout(sidebarWidth: width, topPaneHeight: topPaneHeight)
            },
            onTopPaneHeightCommitted: { height in
                topPaneHeight = height
                saveLayout(sidebarWidth: sidebarWidth, topPaneHeight: height)
            },
            sidebar: {
                activeSidebar
            },
            editor: {
                Group {
                    if isPluginPanelPresented {
                        PluginManagementView()
                            .environmentObject(model)
                    } else {
                        EditorAreaView()
                    }
                }
            },
            bottomTool: {
                Group {
                    if model.isReferencesVisible {
                        LanguageReferencesView()
                    } else {
                        moduleUIRegistry.selectedToolContent(
                            from: model.activityBarContributions,
                            model: model
                        )
                    }
                }
            }
        )
    }

    @ViewBuilder
    private var activeSidebar: some View {
        Group {
            switch model.selectedSidebar {
            case .project:
                ProjectSidebarView()
            case .changes:
                ChangesSidebarView()
            case .search:
                SearchSidebarView()
            case .database:
                if model.isDatabaseModuleActive {
                    DatabaseSidebarView()
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .task { await model.activateDatabaseModule() }
                }
            }
        }
        .background(LitheTheme.sidebar)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var isBottomToolVisible: Bool {
        model.isGitLogVisible || model.isTerminalVisible || model.isReferencesVisible || model.isProblemsVisible || model.isMavenVisible || model.isDebugVisible || model.isRunVisible || model.isTestsVisible
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            editorBreadcrumbs
                .frame(maxWidth: .infinity, alignment: .leading)

            ViewThatFits(in: .horizontal) {
                detailedStatusItems
                compactStatusItems
            }
        }
        .font(LitheTheme.smallFont)
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(.horizontal, 9)
        .frame(height: LitheTheme.Metrics.statusBarHeight)
        .background(LitheTheme.titlebar)
    }

    private var editorBreadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let document = model.activeDocument {
                    let path = document.displayPath ?? model.relativePath(for: document.url)
                    let components = path.split(separator: "/")
                    ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                        breadcrumbItem(
                            title: String(component),
                            iconKind: index == components.count - 1
                                ? LitheIcons.kind(for: document.url, isDirectory: false)
                                : nil,
                            isEmphasized: index == components.count - 1
                        ) {
                            model.selectedSidebar = .project
                        }
                        if index < components.count - 1 {
                            breadcrumbSeparator
                        }
                    }
                } else {
                    HStack(spacing: 5) {
                        LitheIcon(kind: .folder, size: 13)
                        Text(model.projectName)
                    }
                }
            }
        }
    }

    private func breadcrumbItem(
        title: String,
        iconKind: LitheIconKind?,
        isEmphasized: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let iconKind {
                    LitheIcon(kind: iconKind, size: 12)
                        .opacity(isEmphasized ? 1 : 0.72)
                }
                Text(LocalizedStringKey(title))
                    .lineLimit(1)
            }
            .foregroundStyle(isEmphasized ? LitheTheme.primaryText : LitheTheme.secondaryText)
        }
        .buttonStyle(.plain)
        .lithePointer()
        .help(LocalizedStringKey(title))
    }

    private var breadcrumbSeparator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(LitheTheme.secondaryText.opacity(0.72))
    }

    private var detailedStatusItems: some View {
        HStack(spacing: 14) {
            caretPosition
            Text("UTF-8")
            Text("\(settings.tabWidth) spaces")
            Button {
                model.saveActiveDocument()
            } label: {
                Image(systemName: model.activeDocument?.isReadOnly == true ? "lock.fill" : "lock.open")
            }
            .litheIconButton()
            .disabled(model.activeDocument?.isReadOnly == true)
            .help(LocalizedStringKey(
                model.activeDocument?.isReadOnly == true ? "Read-only document" : "Save"
            ))
            memoryStatus
            gitStatus
        }
    }

    private var compactStatusItems: some View {
        HStack(spacing: 10) {
            caretPosition
            memoryStatus
            gitStatus
        }
    }

    private var caretPosition: some View {
        Text(model.editorCaret.map { "\($0.line + 1):\($0.utf16Column + 1)" } ?? "1:1")
            .monospacedDigit()
    }

    private var gitStatus: some View {
        HStack(spacing: 7) {
            if model.isReferencesVisible {
                Label("\(model.languageNavigationResults.count) usages", systemImage: "scope")
            }
            Text(model.gitChanges.isEmpty ? "No changes" : "\(model.gitChanges.count) changes")
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(LitheTheme.success)
        }
    }

    private var memoryStatus: some View {
        Button {
            isMemoryUsagePopoverPresented.toggle()
        } label: {
            Label {
                HStack(spacing: 4) {
                    Text("Total \(memoryUsageMonitor.totalText)")
                    Text("·")
                    Text("Lithe \(memoryUsageMonitor.litheText)")
                }
                .monospacedDigit()
            } icon: {
                Image(systemName: "memorychip")
            }
        }
        .buttonStyle(.plain)
        .lithePointer()
        .help(
            Text(
                "Total managed memory: \(memoryUsageMonitor.totalText)\n" +
                "Lithe: \(memoryUsageMonitor.litheText) · LSP: \(memoryUsageMonitor.lspText) · Services: \(memoryUsageMonitor.serviceText)"
            )
        )
        .popover(isPresented: $isMemoryUsagePopoverPresented, arrowEdge: .top) {
            memoryUsagePopover
        }
        .onChange(of: isMemoryUsagePopoverPresented) { isPresented in
            memoryUsageMonitor.setDetailedUsageVisible(isPresented)
        }
    }

    private var memoryUsagePopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .foregroundStyle(LitheTheme.accent)
                Text("Managed Memory")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Spacer(minLength: 8)
                Button {
                    isMemoryUsagePopoverPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .litheIconButton()
                .help("Close")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            VStack(spacing: 0) {
                memoryMetric("Lithe", value: memoryUsageMonitor.litheText)
                memoryMetric(
                    "Language servers",
                    value: memoryUsageMonitor.languageServerProcessCount == 0
                        ? String(localized: "Not running")
                        : memoryUsageMonitor.lspText
                )
                memoryMetric(
                    "Running services",
                    value: memoryUsageMonitor.serviceProcessCount == 0
                        ? String(localized: "Not running")
                        : memoryUsageMonitor.serviceText
                )
                memoryMetric("Total", value: memoryUsageMonitor.totalText)
                memoryMetric("Average total", value: memoryUsageMonitor.averageText)
                memoryMetric("Peak total", value: memoryUsageMonitor.peakText)
                memoryMetric("Runtime", value: memoryUsageMonitor.runtimeText)
                memoryMetric("Sample interval", value: memoryUsageMonitor.samplingIntervalText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                Text("Resident memory of Lithe and its managed process trees")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(LitheTheme.smallFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(12)
        }
        .frame(width: 280)
        .background(LitheTheme.popupBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func memoryMetric(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(LitheTheme.primaryText)
                .monospacedDigit()
        }
        .frame(minHeight: 27)
    }

    private var projectInitials: String {
        let words = model.projectName.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let initials = words.prefix(2).compactMap(\.first)
        return initials.isEmpty ? "LI" : String(initials).uppercased()
    }

    private func restoreLayout() {
        guard !didRestoreLayout, let workspaceURL = model.workspaceURL else { return }
        let layout = model.loadWorkbenchLayout(for: workspaceURL)
        sidebarWidth = CGFloat(layout.sidebarWidth)
        topPaneHeight = layout.topPaneHeight.map { CGFloat($0) }
        didRestoreLayout = true
    }

    private func saveLayout(sidebarWidth: CGFloat, topPaneHeight: CGFloat?) {
        guard didRestoreLayout, let workspaceURL = model.workspaceURL else { return }
        model.saveWorkbenchLayout(
            WorkbenchLayout(
                sidebarWidth: Double(sidebarWidth),
                topPaneHeight: topPaneHeight.map(Double.init)
            ),
            for: workspaceURL
        )
    }
}

private struct WorkbenchWorkspaceSplitView<Sidebar: View, Editor: View, BottomTool: View>: View {
    let sidebarWidth: CGFloat
    let topPaneHeight: CGFloat?
    let isBottomToolVisible: Bool
    let onSidebarWidthCommitted: (CGFloat) -> Void
    let onTopPaneHeightCommitted: (CGFloat) -> Void
    let sidebar: Sidebar
    let editor: Editor
    let bottomTool: BottomTool

    @State private var liveSidebarWidth: CGFloat
    @State private var sidebarDragStart: CGFloat
    @State private var liveTopPaneHeight: CGFloat?
    @State private var topPaneDragStart: CGFloat = 0

    init(
        sidebarWidth: CGFloat,
        topPaneHeight: CGFloat?,
        isBottomToolVisible: Bool,
        onSidebarWidthCommitted: @escaping (CGFloat) -> Void,
        onTopPaneHeightCommitted: @escaping (CGFloat) -> Void,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder editor: () -> Editor,
        @ViewBuilder bottomTool: () -> BottomTool
    ) {
        self.sidebarWidth = sidebarWidth
        self.topPaneHeight = topPaneHeight
        self.isBottomToolVisible = isBottomToolVisible
        self.onSidebarWidthCommitted = onSidebarWidthCommitted
        self.onTopPaneHeightCommitted = onTopPaneHeightCommitted
        self.sidebar = sidebar()
        self.editor = editor()
        self.bottomTool = bottomTool()
        _liveSidebarWidth = State(initialValue: sidebarWidth)
        _sidebarDragStart = State(initialValue: sidebarWidth)
        _liveTopPaneHeight = State(initialValue: topPaneHeight)
    }

    var body: some View {
        GeometryReader { geometry in
            let horizontalPadding: CGFloat = 6
            let availableTopWidth = max(0, geometry.size.width - (horizontalPadding * 2))
            let minimumSidebarWidth: CGFloat = 220
            let minimumEditorWidth: CGFloat = 400
            let maximumSidebarWidth = max(
                minimumSidebarWidth,
                min(520, availableTopWidth - SplitHandleView.thickness - minimumEditorWidth)
            )
            let resolvedSidebarWidth = constrained(
                liveSidebarWidth,
                minimum: minimumSidebarWidth,
                maximum: maximumSidebarWidth
            )

            let minimumTopPaneHeight: CGFloat = 220
            let minimumGitPaneHeight: CGFloat = 260
            let maximumTopPaneHeight = max(
                minimumTopPaneHeight,
                geometry.size.height - SplitHandleView.thickness - minimumGitPaneHeight
            )
            let resolvedTopPaneHeight = constrained(
                liveTopPaneHeight ?? max(255, geometry.size.height * 0.40),
                minimum: minimumTopPaneHeight,
                maximum: maximumTopPaneHeight
            )

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: resolvedSidebarWidth)

                    SplitHandleView(
                        axis: .horizontal,
                        onDragStarted: {
                            sidebarDragStart = resolvedSidebarWidth
                        },
                        onDragChanged: { translation in
                            liveSidebarWidth = constrained(
                                sidebarDragStart + translation,
                                minimum: minimumSidebarWidth,
                                maximum: maximumSidebarWidth
                            )
                        },
                        onDragEnded: {
                            liveSidebarWidth = resolvedSidebarWidth
                            onSidebarWidthCommitted(resolvedSidebarWidth)
                        }
                    )

                    editor
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.top, 6)
                .padding(.horizontal, 6)
                .padding(.bottom, isBottomToolVisible ? 0 : 6)
                .frame(height: isBottomToolVisible ? resolvedTopPaneHeight : geometry.size.height)

                if isBottomToolVisible {
                    SplitHandleView(
                        axis: .vertical,
                        onDragStarted: {
                            topPaneDragStart = resolvedTopPaneHeight
                        },
                        onDragChanged: { translation in
                            liveTopPaneHeight = constrained(
                                topPaneDragStart + translation,
                                minimum: minimumTopPaneHeight,
                                maximum: maximumTopPaneHeight
                            )
                        },
                        onDragEnded: {
                            liveTopPaneHeight = resolvedTopPaneHeight
                            onTopPaneHeightCommitted(resolvedTopPaneHeight)
                        }
                    )
                    .padding(.horizontal, 6)

                    bottomTool
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                        .frame(maxHeight: .infinity)
                }
            }
            .background(LitheTheme.titlebar)
            .drawingGroup() // Composite the split view as a single layer during drag
        }
        .onChange(of: sidebarWidth) { newWidth in
            liveSidebarWidth = newWidth
        }
        .onChange(of: topPaneHeight) { newHeight in
            liveTopPaneHeight = newHeight
        }
    }

    private func constrained(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}
