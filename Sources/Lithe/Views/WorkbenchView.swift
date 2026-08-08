import SwiftUI

struct WorkbenchView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var projectSessions: ProjectSessionManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var memoryUsageMonitor: MemoryUsageMonitor
    @EnvironmentObject private var runFeature: JavaRunFeatureModel
    @State private var sidebarWidth: CGFloat = 320
    @State private var sidebarDragStart: CGFloat = 320
    @State private var topPaneHeight: CGFloat?
    @State private var topPaneDragStart: CGFloat = 0
    @State private var isBranchSwitcherPresented = false
    @State private var newBranchReference: GitReference?
    @State private var isCheckoutRevisionPresented = false
    @State private var pendingTopBarPushReference: GitReference?
    @State private var isRunConfigurationPickerPresented = false
    @State private var isRunConfigurationEditorPresented = false
    @State private var isProjectSwitcherPresented = false
    @State private var isMemoryUsagePopoverPresented = false
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
        .onChange(of: sidebarWidth) { _, _ in
            saveLayout()
        }
        .onChange(of: topPaneHeight) { _, _ in
            saveLayout()
        }
        .onChange(of: model.workspaceURL?.standardizedFileURL.path) { _, _ in
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
                .onChange(of: projectSessions.activeSessionID) { _, id in
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

            HStack(spacing: 6) {
                Image(systemName: "leaf")
                    .foregroundStyle(LitheTheme.success)
                Text(model.projectName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(LitheTheme.primaryText)

            runControls

            Button {
                model.selectedSidebar = .search
            } label: {
                LitheIDEAIcon(resourcePath: "actions/search.svg", size: 16, fallbackSystemImage: "magnifyingglass")
            }
            .litheIconButton()
            .help("Search")

            Menu {
                Button("Open Project…", action: model.chooseProject)
                Button("Close Project", action: model.closeProject)
            } label: {
                LitheIDEAIcon(resourcePath: "actions/more.svg", size: 16, fallbackSystemImage: "ellipsis")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .lithePointer()
            .frame(width: 28, height: 28)
            .help("More actions")
        }
        .padding(.leading, 76)
        .padding(.trailing, 10)
        .frame(height: LitheTheme.Metrics.toolbarHeight)
        .background(LitheTheme.titlebar)
    }

    private var activityBar: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    ForEach(SidebarDestination.allCases) { destination in
                        Button {
                            model.selectedSidebar = destination
                        } label: {
                            LitheIDEAIcon(
                                resourcePath: destination.ideaAssetPath,
                                size: 16,
                                fallbackSystemImage: destination.systemImage
                            )
                                .frame(width: 40, height: 34)
                                .overlay(alignment: .leading) {
                                    if model.selectedSidebar == destination {
                                        Rectangle()
                                            .fill(LitheTheme.accent)
                                            .frame(width: 2, height: 21)
                                    }
                                }
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

                Spacer(minLength: 0)

                VStack(spacing: 6) {
                    activityToolButton(
                        systemImage: "terminal",
                        help: "Terminal",
                        isSelected: model.isTerminalVisible
                    ) {
                        model.toggleTerminal()
                    }

                    activityToolButton(
                        systemImage: "point.3.connected.trianglepath.dotted",
                        ideaAssetPath: "toolwindows/toolWindowVcs.svg",
                        help: "Git",
                        isSelected: model.isGitLogVisible
                    ) {
                        if !model.isGitLogVisible {
                            model.selectedSidebar = .changes
                        }
                        Task { await model.toggleGitLog() }
                    }

                    activityToolButton(
                        systemImage: "exclamationmark.triangle",
                        ideaAssetPath: "toolwindows/toolWindowProblems.svg",
                        help: "Problems",
                        isSelected: model.isProblemsVisible
                    ) {
                        model.toggleProblems()
                    }

                    activityToolButton(
                        systemImage: "shippingbox",
                        ideaAssetPath: "maven/toolWindowMaven.svg",
                        help: "Maven",
                        isSelected: model.isMavenVisible
                    ) {
                        model.toggleMaven()
                    }

                    activityToolButton(
                        systemImage: "ladybug",
                        ideaAssetPath: "toolwindows/toolWindowDebugger.svg",
                        help: "Debug",
                        isSelected: model.isDebugVisible
                    ) {
                        model.toggleDebug()
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
                .padding(.bottom, 8)
            }
            .frame(width: 48, height: geometry.size.height, alignment: .top)
            .background(LitheTheme.titlebar)
        }
        .frame(width: 48)
    }

    private var runControls: some View {
        HStack(spacing: 3) {
            Button {
                isRunConfigurationPickerPresented.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: runFeature.selectedConfiguration?.systemImage ?? "play.fill")
                        .font(.system(size: 13))
                        .frame(width: 17)
                    Text(LocalizedStringKey(runFeature.selectedConfiguration?.name ?? "Current File"))
                        .lineLimit(1)
                    Spacer(minLength: 5)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
                .padding(.horizontal, 8)
                .frame(width: 230, height: 28, alignment: .leading)
                .contentShape(Rectangle())
                .litheRowHover(
                    isActive: isRunConfigurationPickerPresented,
                    cornerRadius: 5,
                    activeBackground: LitheTheme.subtleSelection
                )
            }
            .buttonStyle(.plain)
            .lithePointer()
            .help("Select run configuration")
            .popover(isPresented: $isRunConfigurationPickerPresented, arrowEdge: .top) {
                RunConfigurationPickerPopover(
                    configurations: runFeature.configurations,
                    selectedConfigurationID: Binding(
                        get: { runFeature.selectedConfigurationID },
                        set: { runFeature.selectedConfigurationID = $0 }
                    ),
                    isPresented: $isRunConfigurationPickerPresented
                )
            }

            Button {
                isRunConfigurationEditorPresented = true
            } label: {
                LitheIDEAIcon(resourcePath: "general/gear.svg", size: 15, fallbackSystemImage: "gearshape")
            }
            .litheIconButton()
            .help("Edit run configuration")
            .popover(isPresented: $isRunConfigurationEditorPresented, arrowEdge: .bottom) {
                if let configuration = runFeature.selectedConfiguration {
                    JavaRunConfigurationEditorView(
                        feature: runFeature,
                        configuration: configuration
                    )
                }
            }

            Button {
                if runFeature.isRunning {
                    model.stopSelectedRun()
                } else {
                    model.runSelectedConfiguration()
                }
            } label: {
                if runFeature.isRunning {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(LitheTheme.warning)
                } else {
                    LitheIDEAIcon(resourcePath: "actions/execute.svg", size: 16, fallbackSystemImage: "play.fill")
                }
            }
            .litheIconButton()
            .help(LocalizedStringKey(
                runFeature.isRunning ? "Stop current run" : "Run selected configuration"
            ))
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
                        size: 17,
                        fallbackSystemImage: systemImage
                    )
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .medium))
                }
            }
            .frame(width: 40, height: 34)
                .overlay(alignment: .leading) {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(LitheTheme.accent)
                            .frame(width: 3, height: 22)
                    }
                }
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
                sidebarWidth,
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
                topPaneHeight ?? max(255, geometry.size.height * 0.40),
                minimum: minimumTopPaneHeight,
                maximum: maximumTopPaneHeight
            )

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    activeSidebar
                        .frame(width: resolvedSidebarWidth)

                    SplitHandleView(
                        axis: .horizontal,
                        onDragStarted: {
                            sidebarDragStart = resolvedSidebarWidth
                        },
                        onDragChanged: { translation in
                            sidebarWidth = constrained(
                                sidebarDragStart + translation,
                                minimum: minimumSidebarWidth,
                                maximum: maximumSidebarWidth
                            )
                        },
                        onDragEnded: {}
                    )

                    EditorAreaView()
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
                            topPaneHeight = constrained(
                                topPaneDragStart + translation,
                                minimum: minimumTopPaneHeight,
                                maximum: maximumTopPaneHeight
                            )
                        },
                        onDragEnded: {}
                    )
                    .padding(.horizontal, 6)

                    Group {
                        if model.isTerminalVisible, let session = model.activeTerminalSession {
                            TerminalView(session: session)
                                .id(session.id)
                        } else if model.isReferencesVisible {
                            JavaReferencesView()
                        } else if model.isProblemsVisible {
                            JavaProblemsView()
                        } else if model.isDebugVisible {
                            JavaDebugView(
                                feature: model.debugFeature,
                                runFeature: runFeature
                            )
                        } else if model.isRunVisible {
                            RunView(feature: runFeature)
                        } else if model.isMavenVisible {
                            MavenView(feature: model.mavenFeature)
                        } else {
                            GitLogView()
                        }
                    }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                        .frame(maxHeight: .infinity)
                }
            }
            .background(LitheTheme.titlebar)
        }
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
                DatabaseSidebarView()
            }
        }
        .background(LitheTheme.sidebar)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func constrained(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }

    private var isBottomToolVisible: Bool {
        model.isGitLogVisible || model.isTerminalVisible || model.isReferencesVisible || model.isProblemsVisible || model.isMavenVisible || model.isDebugVisible || model.isRunVisible
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
                        if index < components.count - 1 || !activeJavaBreadcrumbs.isEmpty {
                            breadcrumbSeparator
                        }
                    }

                    ForEach(Array(activeJavaBreadcrumbs.enumerated()), id: \.offset) { index, hint in
                        breadcrumbItem(
                            title: hint.symbol,
                            iconKind: index == activeJavaBreadcrumbs.count - 1 ? .javaGeneric : .javaClass,
                            isEmphasized: index == activeJavaBreadcrumbs.count - 1
                        ) {
                            model.editorNavigationTarget = EditorNavigationTarget(
                                url: document.url,
                                line: hint.line,
                                utf16Column: hint.utf16Column
                            )
                        }
                        if index < activeJavaBreadcrumbs.count - 1 {
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

    private var activeJavaBreadcrumbs: [JavaCodeVisionHint] {
        guard let document = model.activeDocument,
              document.url.pathExtension.lowercased() == "java" else { return [] }
        let caretLine = model.editorCaret?.url.standardizedFileURL == document.url.standardizedFileURL
            ? model.editorCaret?.line ?? Int.max
            : Int.max
        return Array(
            (model.javaCodeVisionHints[document.url] ?? [])
                .filter { $0.line <= caretLine }
                .suffix(2)
        )
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
                Label("\(model.javaNavigationLocations.count) usages", systemImage: "scope")
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
                    Text(memoryUsageMonitor.currentText)
                    Text("·")
                    Text("avg")
                    Text(memoryUsageMonitor.averageText)
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
                "Current application memory: \(memoryUsageMonitor.currentText)\n" +
                "Average since launch: \(memoryUsageMonitor.averageText)"
            )
        )
        .popover(isPresented: $isMemoryUsagePopoverPresented, arrowEdge: .top) {
            memoryUsagePopover
        }
    }

    private var memoryUsagePopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .foregroundStyle(LitheTheme.accent)
                Text("Application Memory")
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
                memoryMetric("Current", value: memoryUsageMonitor.currentText)
                memoryMetric("Average since launch", value: memoryUsageMonitor.averageText)
                memoryMetric("Peak this run", value: memoryUsageMonitor.peakText)
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
                Text("Resident memory of the Lithe process")
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

    private func saveLayout() {
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

private struct RunConfigurationPickerPopover: View {
    let configurations: [JavaRunConfiguration]
    @Binding var selectedConfigurationID: String
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 2) {
            ForEach(configurations) { configuration in
                Button {
                    selectedConfigurationID = configuration.id
                    isPresented = false
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: configuration.systemImage)
                            .font(.system(size: 13))
                            .foregroundStyle(
                                configuration.id == selectedConfigurationID
                                    ? LitheTheme.primaryText
                                    : LitheTheme.secondaryText
                            )
                            .frame(width: 18)

                        Text(LocalizedStringKey(configuration.name))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(LitheTheme.primaryText)
                            .lineLimit(1)

                        Spacer(minLength: 12)

                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(LitheTheme.accent)
                            .opacity(configuration.id == selectedConfigurationID ? 1 : 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                    .litheRowHover(
                        isActive: configuration.id == selectedConfigurationID,
                        cornerRadius: 5,
                        activeBackground: LitheTheme.subtleSelection
                    )
                }
                .buttonStyle(.plain)
                .lithePointer()
            }
        }
        .padding(6)
        .frame(width: 270)
        .background(LitheTheme.popupBackground)
    }
}
