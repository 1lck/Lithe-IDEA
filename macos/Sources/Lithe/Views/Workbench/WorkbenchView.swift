import AppKit
import SwiftUI
import LitheGitModule

enum WorkbenchLayoutMetrics {
    static let rightActivityBarWidth: CGFloat = 40
    static let rightActivityBarDividerWidth: CGFloat = 1
    static let workspaceTrailingInset = rightActivityBarWidth + rightActivityBarDividerWidth
}

private enum ActivityBarMetrics {
    static let width: CGFloat = 38
    static let rightWidth = WorkbenchLayoutMetrics.rightActivityBarWidth
    static let buttonWidth: CGFloat = 30
    static let buttonHeight: CGFloat = 30
    static let spacing: CGFloat = 4
    static let edgeInset: CGFloat = 4
    static let toolViewportHeight: CGFloat = 292
}

private enum WorkbenchWorkspaceMetrics {
    static let paneInset: CGFloat = 6
    static let paneSpacing: CGFloat = 6
    static let paneCornerRadius: CGFloat = 10
}

struct WorkbenchView: View {
    private let moduleUIRegistry = WorkbenchModuleUIComposition.builtIn
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var projectSessions: ProjectSessionManager
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var linuxDoWebSession = LinuxDoAnonymousWebSession()
    @State private var sidebarWidth: CGFloat = 320
    @State private var rightSidebarWidth: CGFloat = 380
    @State private var hoveredRightSidebarContributionID: String?
    @State private var isRightSidebarPanelHovered = false
    @State private var rightSidebarDismissTask: Task<Void, Never>?
    @State private var topPaneHeight: CGFloat?
    @State private var isBranchSwitcherPresented = false
    @State private var newBranchReference: GitReference?
    @State private var isCheckoutRevisionPresented = false
    @State private var pendingTopBarPushReference: GitReference?
    @State private var isProjectSwitcherPresented = false
    @State private var isPluginPanelPresented = false
    @State private var isNotificationCenterPresented = false
    @State private var didRestoreLayout = false
    @State private var hoveredProjectTabID: UUID?
    @State private var workbenchBackgroundImage: NSImage?
    @State private var isBackgroundPickerPresented = false

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
                Rectangle()
                    .fill(LitheTheme.divider)
                    .frame(width: 1)
                workspaceArea
                    .padding(.trailing, WorkbenchLayoutMetrics.workspaceTrailingInset)
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .trailing) {
                rightHoverRegion
            }

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            statusBar
        }
        .background {
            WorkbenchBackgroundImageView(
                image: workbenchBackgroundImage,
                opacity: settings.workbenchBackgroundOpacity
            )
        }
        .sheet(item: $newBranchReference) { reference in
            TopBarNewBranchDialog(reference: reference) { name, checkout in
                Task {
                    await model.createBranch(named: name, from: reference, checkout: checkout)
                }
            }
        }
        .onAppear {
            updateWorkbenchBackgroundImage(model.workbenchBackgroundFeature.imageData)
        }
        .onReceive(model.workbenchBackgroundFeature.$imageData) { data in
            updateWorkbenchBackgroundImage(data)
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
        .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.toolHeader)
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
                    LitheLogo(size: 24)

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

            backgroundPickerButton

        }
        .padding(.leading, 76)
        .padding(.trailing, 10)
        .frame(height: LitheTheme.Metrics.toolbarHeight)
        .background {
            (model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.titlebar)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    (NSApplication.shared.keyWindow?.delegate as? LitheWindowCoordinator)?
                        .toggleWorkspaceZoom()
                }
        }
    }

    private var backgroundPickerButton: some View {
        Button {
            isBackgroundPickerPresented.toggle()
        } label: {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .litheRowHover(
                    isActive: isBackgroundPickerPresented,
                    cornerRadius: 6,
                    activeBackground: LitheTheme.subtleSelection
                )
        }
        .buttonStyle(.plain)
        .lithePointer()
        .foregroundStyle(LitheTheme.secondaryText)
        .help("Change workbench background")
        .accessibilityLabel("Change workbench background")
        .accessibilityIdentifier("workbench-background-picker")
        .popover(isPresented: $isBackgroundPickerPresented, arrowEdge: .bottom) {
            WorkbenchBackgroundPicker {
                isBackgroundPickerPresented = false
            }
            .environmentObject(model)
            .environmentObject(settings)
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
                            Group {
                                if let ideaAssetPath = destination.ideaAssetPath {
                                    LitheIDEAIcon(
                                        resourcePath: ideaAssetPath,
                                        size: 18,
                                        fallbackSystemImage: destination.systemImage
                                    )
                                } else {
                                    Image(systemName: destination.systemImage)
                                        .font(.system(size: 16, weight: .medium))
                                }
                            }
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
                        .disabled(!destination.isAvailable)
                        .foregroundStyle(model.selectedSidebar == destination ? LitheTheme.primaryText : LitheTheme.secondaryText)
                        .help(
                            destination.isAvailable
                                ? LocalizedStringKey(destination.title)
                                : LocalizedStringKey("Pull Requests integration is under development")
                        )
                        .accessibilityLabel(LocalizedStringKey(destination.title))
                        .accessibilityHint(
                            destination.isAvailable
                                ? LocalizedStringKey("")
                                : LocalizedStringKey("Pull Requests integration is under development")
                        )
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
                    // Keep short tool lists against the status bar while preserving
                    // vertical scrolling when modules add more activity buttons.
                    .frame(
                        minHeight: ActivityBarMetrics.toolViewportHeight,
                        alignment: .bottom
                    )
                }
                .frame(height: ActivityBarMetrics.toolViewportHeight)
                .padding(.bottom, ActivityBarMetrics.edgeInset)
            }
            .frame(width: ActivityBarMetrics.width, height: geometry.size.height, alignment: .top)
            .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.titlebar)
        }
        .frame(width: ActivityBarMetrics.width)
    }

    private var pluginActivityBar: some View {
        VStack {
            Button {
                isNotificationCenterPresented.toggle()
                if isNotificationCenterPresented {
                    model.markAllNotificationsRead()
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: unreadNotificationCount > 0 ? "bell.fill" : "bell")
                        .frame(width: ActivityBarMetrics.buttonWidth, height: ActivityBarMetrics.buttonHeight)
                        .litheRowHover(
                            isActive: isNotificationCenterPresented,
                            cornerRadius: 4,
                            activeBackground: LitheTheme.subtleSelection
                        )

                    if unreadNotificationCount > 0 {
                        Circle()
                            .fill(LitheTheme.error)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(LitheTheme.titlebar, lineWidth: 1))
                            .offset(x: -2, y: 3)
                    }
                }
            }
            .buttonStyle(.plain)
            .lithePointer()
            .foregroundStyle(
                unreadNotificationCount > 0 || isNotificationCenterPresented
                    ? LitheTheme.primaryText
                    : LitheTheme.secondaryText
            )
            .help(LocalizedStringKey("Notifications"))
            .accessibilityLabel("Notifications")
            .popover(isPresented: $isNotificationCenterPresented, arrowEdge: .trailing) {
                WorkbenchNotificationCenterView()
                    .environmentObject(model)
            }

            ForEach(model.rightSidebarContributions) { contribution in
                if let renderer = moduleUIRegistry.renderer(for: contribution),
                   renderer.isVisible(model) {
                    Button { moduleUIRegistry.perform(contribution, model: model) } label: {
                        Image(systemName: contribution.icon ?? "rectangle.rightthird.inset.filled")
                            .frame(width: ActivityBarMetrics.buttonWidth, height: ActivityBarMetrics.buttonHeight)
                            .litheRowHover(
                                isActive: renderer.isSelected(model),
                                cornerRadius: 4,
                                activeBackground: LitheTheme.subtleSelection
                            )
                    }
                    .buttonStyle(.plain)
                    .lithePointer()
                    .foregroundStyle(renderer.isSelected(model) ? LitheTheme.primaryText : LitheTheme.secondaryText)
                    .help(contribution.title)
                    .accessibilityLabel(contribution.title)
                    .onHover { isHovering in
                        if isHovering {
                            rightSidebarDismissTask?.cancel()
                            hoveredRightSidebarContributionID = contribution.id
                            if !renderer.isSelected(model) {
                                moduleUIRegistry.perform(contribution, model: model)
                            }
                        } else {
                            hoveredRightSidebarContributionID = nil
                            scheduleRightSidebarDismissal()
                        }
                    }
                }
            }
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
        .frame(width: ActivityBarMetrics.rightWidth)
        .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.titlebar)
    }

    private var unreadNotificationCount: Int {
        model.notifications.lazy.filter { !$0.isRead }.count
    }

    private var rightHoverRegion: some View {
        HStack(spacing: 0) {
            if isRightSidebarVisible {
                moduleUIRegistry.selectedToolContent(
                    from: model.rightSidebarContributions,
                    model: model
                )
                .environmentObject(linuxDoWebSession)
                .frame(width: rightSidebarWidth)
                .frame(maxHeight: .infinity)
                .workbenchPaneChrome(
                    background: model.workbenchBackgroundFeature.hasImage
                        ? Color.clear
                        : LitheTheme.editor,
                    surrounding: model.workbenchBackgroundFeature.hasImage
                        ? Color.clear
                        : LitheTheme.titlebar,
                    roundsCorners: !model.workbenchBackgroundFeature.hasImage
                )
                .padding(WorkbenchWorkspaceMetrics.paneInset)
                .background(
                    model.workbenchBackgroundFeature.hasImage
                        ? Color.clear
                        : LitheTheme.titlebar
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .trailing).combined(with: .opacity)
                )
                .onHover { isHovering in
                    isRightSidebarPanelHovered = isHovering
                    if isHovering {
                        rightSidebarDismissTask?.cancel()
                    } else {
                        scheduleRightSidebarDismissal()
                    }
                }
            }
            Rectangle()
                .fill(LitheTheme.divider)
                .frame(width: 1)
            pluginActivityBar
        }
        .fixedSize(horizontal: true, vertical: false)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.14),
            value: isRightSidebarVisible
        )
    }

    private func scheduleRightSidebarDismissal() {
        rightSidebarDismissTask?.cancel()
        rightSidebarDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled,
                  hoveredRightSidebarContributionID == nil,
                  !isRightSidebarPanelHovered else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.10)) {
                model.isDiscourseCommunityVisible = false
            }
        }
    }

    private var isRightSidebarVisible: Bool {
        model.rightSidebarContributions.contains { contribution in
            moduleUIRegistry.renderer(for: contribution)?.isSelected(model) == true
        }
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
            showsBottomToolMinimize: model.isGitLogVisible,
            hasWorkbenchBackground: model.workbenchBackgroundFeature.hasImage,
            onBottomToolMinimize: {
                model.closeGitLog()
            },
            sidebar: {
                activeSidebar(projectTreeRowHeight: settings.projectTreeRowHeight)
            },
            editor: {
                Group {
                    if isPluginPanelPresented {
                        PluginManagementView()
                            .environmentObject(model)
                    } else if model.selectedSidebar == .pullRequests {
                        if LitheFeatureAvailability.githubPullRequests {
                            GitHubPullRequestDetailView()
                        } else {
                            GitHubFeatureUnavailableView()
                        }
                    } else {
                        EditorAreaView()
                    }
                }
            },
            bottomTool: {
                Group {
                    if model.isReferencesVisible {
                        LanguageReferencesView()
                    } else if model.isSpringVisible {
                        SpringEndpointsView()
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
    private func activeSidebar(projectTreeRowHeight: CGFloat) -> some View {
        Group {
            switch model.selectedSidebar {
            case .project:
                ProjectSidebarView(rowHeight: projectTreeRowHeight)
            case .changes:
                ChangesSidebarView()
            case .pullRequests:
                if LitheFeatureAvailability.githubPullRequests {
                    GitHubPullRequestsSidebarView()
                } else {
                    GitHubFeatureUnavailableView()
                }
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
    }

    private var isBottomToolVisible: Bool {
        model.isGitLogVisible || model.isTerminalVisible || model.isReferencesVisible || model.isProblemsVisible || model.isMavenVisible || model.isSpringVisible || model.isDebugVisible || model.isRunVisible || model.isTestsVisible
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
        .background(model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.titlebar)
    }

    private var editorBreadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let document = model.activeDocument {
                    let path = document.displayPath ?? model.relativePath(for: document.url)
                    let components = path.split(separator: "/")
                    ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                        let isFile = index == components.count - 1
                        breadcrumbItem(
                            title: String(component),
                            iconKind: isFile
                                ? LitheIcons.kind(for: document.url, isDirectory: false)
                                : nil,
                            isEmphasized: isFile
                        ) {
                            guard let itemURL = breadcrumbURL(
                                for: document,
                                componentIndex: index,
                                componentCount: components.count
                            ) else { return }
                            model.revealInProjectTree(itemURL, isDirectory: !isFile)
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

    private func breadcrumbURL(
        for document: EditorDocument,
        componentIndex: Int,
        componentCount: Int
    ) -> URL? {
        guard componentIndex >= 0, componentIndex < componentCount else { return nil }
        if componentIndex == componentCount - 1 {
            return document.url
        }
        guard let workspaceURL = model.workspaceURL else { return nil }
        return (0...componentIndex).reduce(workspaceURL) { url, index in
            let path = document.displayPath ?? model.relativePath(for: document.url)
            let components = path.split(separator: "/")
            return url.appendingPathComponent(String(components[index]), isDirectory: true)
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
            EditorCaretPositionLabel(chrome: model.editorChrome) {
                model.showGoToLineBar()
            }
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
            MemoryUsageStatusView()
            FrameRateStatusView()
            gitStatus
        }
    }

    private var compactStatusItems: some View {
        HStack(spacing: 10) {
            EditorCaretPositionLabel(chrome: model.editorChrome) {
                model.showGoToLineBar()
            }
            MemoryUsageStatusView()
            FrameRateStatusView()
            gitStatus
        }
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

    private func updateWorkbenchBackgroundImage(_ data: Data?) {
        workbenchBackgroundImage = data.flatMap(NSImage.init(data:))
    }

}

private struct WorkbenchNotificationCenterView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notifications")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)

                Spacer()

                Button("Clear All") {
                    model.clearNotifications()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(
                    model.notifications.isEmpty
                        ? LitheTheme.tertiaryText
                        : LitheTheme.accent
                )
                .disabled(model.notifications.isEmpty)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            if model.notifications.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(LitheTheme.tertiaryText)
                    Text("No notifications")
                        .font(.system(size: 12))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.notifications) { notification in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "info.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(LitheTheme.accent)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(LocalizedStringKey(notification.message))
                                        .font(.system(size: 12))
                                        .foregroundStyle(LitheTheme.primaryText)
                                        .fixedSize(horizontal: false, vertical: true)

                                    Text(notification.createdAt.formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(LitheTheme.tertiaryText)
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)

                            Rectangle()
                                .fill(LitheTheme.divider.opacity(0.7))
                                .frame(height: 1)
                                .padding(.leading, 37)
                        }
                    }
                }
            }
        }
        .frame(width: 340, height: 360)
        .background(LitheTheme.raised)
        .onAppear {
            model.markAllNotificationsRead()
        }
        .onChange(of: model.notifications.count) { _ in
            model.markAllNotificationsRead()
        }
    }
}

private struct WorkbenchWorkspaceSplitView<Sidebar: View, Editor: View, BottomTool: View>: View {
    let sidebarWidth: CGFloat
    let topPaneHeight: CGFloat?
    let isBottomToolVisible: Bool
    let onSidebarWidthCommitted: (CGFloat) -> Void
    let onTopPaneHeightCommitted: (CGFloat) -> Void
    let showsBottomToolMinimize: Bool
    let hasWorkbenchBackground: Bool
    let onBottomToolMinimize: () -> Void
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
        showsBottomToolMinimize: Bool,
        hasWorkbenchBackground: Bool,
        onBottomToolMinimize: @escaping () -> Void,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder editor: () -> Editor,
        @ViewBuilder bottomTool: () -> BottomTool
    ) {
        self.sidebarWidth = sidebarWidth
        self.topPaneHeight = topPaneHeight
        self.isBottomToolVisible = isBottomToolVisible
        self.onSidebarWidthCommitted = onSidebarWidthCommitted
        self.onTopPaneHeightCommitted = onTopPaneHeightCommitted
        self.showsBottomToolMinimize = showsBottomToolMinimize
        self.hasWorkbenchBackground = hasWorkbenchBackground
        self.onBottomToolMinimize = onBottomToolMinimize
        self.sidebar = sidebar()
        self.editor = editor()
        self.bottomTool = bottomTool()
        _liveSidebarWidth = State(initialValue: sidebarWidth)
        _sidebarDragStart = State(initialValue: sidebarWidth)
        _liveTopPaneHeight = State(initialValue: topPaneHeight)
    }

    var body: some View {
        GeometryReader { geometry in
            let availableTopWidth = max(
                0,
                geometry.size.width
                    - (WorkbenchWorkspaceMetrics.paneInset * 2)
                    - WorkbenchWorkspaceMetrics.paneSpacing
            )
            let minimumSidebarWidth: CGFloat = 220
            let minimumEditorWidth: CGFloat = 400
            let maximumSidebarWidth = max(
                minimumSidebarWidth,
                min(520, availableTopWidth - minimumEditorWidth)
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
                geometry.size.height
                    - WorkbenchWorkspaceMetrics.paneSpacing
                    - minimumGitPaneHeight
            )
            let resolvedTopPaneHeight = constrained(
                liveTopPaneHeight ?? max(255, geometry.size.height * 0.40),
                minimum: minimumTopPaneHeight,
                maximum: maximumTopPaneHeight
            )

            ZStack(alignment: .topLeading) {
                VStack(spacing: isBottomToolVisible ? WorkbenchWorkspaceMetrics.paneSpacing : 0) {
                    HStack(spacing: WorkbenchWorkspaceMetrics.paneSpacing) {
                        sidebar
                            .frame(width: resolvedSidebarWidth)
                            .frame(maxHeight: .infinity)
                            .workbenchPaneChrome(
                                background: hasWorkbenchBackground ? Color.clear : LitheTheme.editor,
                                surrounding: hasWorkbenchBackground ? Color.clear : LitheTheme.titlebar,
                                roundsCorners: !hasWorkbenchBackground
                            )
                        editor
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .workbenchPaneChrome(
                                background: hasWorkbenchBackground ? Color.clear : LitheTheme.editor,
                                surrounding: hasWorkbenchBackground ? Color.clear : LitheTheme.titlebar,
                                roundsCorners: !hasWorkbenchBackground
                            )
                    }
                    .padding(.horizontal, WorkbenchWorkspaceMetrics.paneInset)
                    .padding(.top, WorkbenchWorkspaceMetrics.paneInset)
                    .padding(
                        .bottom,
                        isBottomToolVisible ? 0 : WorkbenchWorkspaceMetrics.paneInset
                    )
                    .overlay(alignment: .topLeading) {
                        SplitHandleView(
                            axis: .horizontal,
                            showsIdleDivider: false,
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
                            onDragEnded: { translation in
                                let finalWidth = constrained(
                                    sidebarDragStart + translation,
                                    minimum: minimumSidebarWidth,
                                    maximum: maximumSidebarWidth
                                )
                                liveSidebarWidth = finalWidth
                                onSidebarWidthCommitted(finalWidth)
                            }
                        )
                        .padding(.top, WorkbenchWorkspaceMetrics.paneInset)
                        .padding(
                            .bottom,
                            isBottomToolVisible ? 0 : WorkbenchWorkspaceMetrics.paneInset
                        )
                        .offset(
                            x: WorkbenchWorkspaceMetrics.paneInset
                                + resolvedSidebarWidth
                                + WorkbenchWorkspaceMetrics.paneSpacing / 2
                                - SplitHandleView.thickness / 2
                        )
                    }
                    .frame(height: isBottomToolVisible ? resolvedTopPaneHeight : geometry.size.height)

                    if isBottomToolVisible {
                        bottomTool
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .workbenchPaneChrome(
                                background: hasWorkbenchBackground ? Color.clear : LitheTheme.editor,
                                surrounding: hasWorkbenchBackground ? Color.clear : LitheTheme.titlebar,
                                roundsCorners: !hasWorkbenchBackground
                            )
                            .padding(.horizontal, WorkbenchWorkspaceMetrics.paneInset)
                            .padding(.bottom, WorkbenchWorkspaceMetrics.paneInset)
                            .frame(maxHeight: .infinity)
                    }
                }

                if isBottomToolVisible {
                    SplitHandleView(
                        axis: .vertical,
                        showsIdleDivider: false,
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
                        onDragEnded: { translation in
                            let finalHeight = constrained(
                                topPaneDragStart + translation,
                                minimum: minimumTopPaneHeight,
                                maximum: maximumTopPaneHeight
                            )
                            liveTopPaneHeight = finalHeight
                            onTopPaneHeightCommitted(finalHeight)
                        }
                    )
                    .padding(.horizontal, WorkbenchWorkspaceMetrics.paneInset)
                    .offset(
                        y: resolvedTopPaneHeight
                            + WorkbenchWorkspaceMetrics.paneSpacing / 2
                            - SplitHandleView.thickness / 2
                    )
                }

                if isBottomToolVisible, showsBottomToolMinimize {
                    Button(action: onBottomToolMinimize) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .litheIconButton()
                    .help("Collapse tool window")
                    .accessibilityLabel("Collapse tool window")
                    .position(
                        x: geometry.size.width - ActivityBarMetrics.rightWidth - 20,
                        y: resolvedTopPaneHeight + WorkbenchWorkspaceMetrics.paneSpacing + 16
                    )
                }
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .topLeading
            )
            .background(hasWorkbenchBackground ? Color.clear : LitheTheme.titlebar)
            // Keep the workspace as a live view hierarchy. `drawingGroup()`
            // cannot composite AppKit-backed editors, fields, checkboxes, or
            // terminals and replaces them with unavailable placeholders. It
            // also rasterizes vector activity-bar icons at inconsistent sizes.
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

private extension View {
    /// Draws pane rounding without masking AppKit-backed editor and tool views.
    func workbenchPaneChrome(
        background: Color,
        surrounding: Color,
        roundsCorners: Bool = true
    ) -> some View {
        modifier(
            WorkbenchPaneChromeModifier(
                background: background,
                surrounding: surrounding,
                roundsCorners: roundsCorners
            )
        )
    }
}

private struct WorkbenchPaneChromeModifier: ViewModifier {
    let background: Color
    let surrounding: Color
    let roundsCorners: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if roundsCorners {
            content
                .background(background)
                .overlay {
                    WorkbenchPaneCornerCutouts(
                        cornerRadius: WorkbenchWorkspaceMetrics.paneCornerRadius
                    )
                    .fill(surrounding, style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        } else {
            content.background(background)
        }
    }
}

private struct WorkbenchPaneCornerCutouts: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRoundedRect(
            in: rect,
            cornerSize: CGSize(width: cornerRadius, height: cornerRadius),
            style: .continuous
        )
        return path
    }
}

private struct WorkbenchBackgroundImageView: View {
    let image: NSImage?
    let opacity: Double
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LitheTheme.window

            GeometryReader { geometry in
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .opacity(opacity)
                }
            }

            // Preserve the source image's colour while keeping text legible.
            // Soft-light compositing against the dark theme muted bright images
            // twice, so a single contrast veil produces the intended wallpaper
            // effect at the full 100% setting.
            (colorScheme == .dark ? Color.black.opacity(0.46) : Color.white.opacity(0.25))
        }
        .compositingGroup()
        .allowsHitTesting(false)
    }
}

struct WorkbenchBackgroundPicker: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    let dismiss: () -> Void

    private var availablePresets: [WorkbenchBackgroundPreset] {
        model.workbenchBackgroundFeature.availablePresets
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Workbench background", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .litheIconButton()
                .help("Close")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Built-in backgrounds")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                    spacing: 10
                ) {
                    ForEach(availablePresets) { preset in
                        presetButton(preset)
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button("Choose Image…") {
                    model.workbenchBackgroundFeature.chooseCustomImage()
                }
                .buttonStyle(LitheSecondaryButtonStyle())

                if settings.hasConfiguredWorkbenchBackground {
                    Button("Remove") {
                        model.workbenchBackgroundFeature.clear()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LitheTheme.accent)
                    .lithePointer()
                }

                Spacer(minLength: 0)

                Text(model.workbenchBackgroundFeature.displayName ?? "No background image selected")
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: 112, alignment: .trailing)
            }

            if settings.hasConfiguredWorkbenchBackground {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Workbench background opacity")
                            .font(.system(size: 11.5, weight: .medium))
                        Spacer()
                        Text("\(Int((settings.workbenchBackgroundOpacity * 100).rounded()))%")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                    Slider(value: $settings.workbenchBackgroundOpacity, in: 0.05...1.0, step: 0.01)
                }
            }
        }
        .padding(14)
        .frame(width: 356)
        .background(LitheTheme.popupBackground)
    }

    private func presetButton(_ preset: WorkbenchBackgroundPreset) -> some View {
        let isSelected = settings.workbenchBackgroundPreset == preset
        return Button {
            model.workbenchBackgroundFeature.selectPreset(preset)
        } label: {
            VStack(spacing: 5) {
                WorkbenchBackgroundPresetArtwork(
                    imageData: model.workbenchBackgroundFeature.previewData(for: preset)
                )
                    .frame(height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                isSelected ? LitheTheme.accent : LitheTheme.panelBorder,
                                lineWidth: isSelected ? 2 : 1
                            )
                    }
                Text(LocalizedStringKey(preset.title))
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? LitheTheme.primaryText : LitheTheme.secondaryText)
            }
            .frame(width: 100)
        }
        .buttonStyle(.plain)
        .lithePointer()
        .accessibilityLabel(Text(LocalizedStringKey(preset.title)))
    }
}

struct WorkbenchBackgroundPresetArtwork: View {
    let imageData: Data?

    var body: some View {
        if let imageData, let image = NSImage(data: imageData) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        }
    }
}
