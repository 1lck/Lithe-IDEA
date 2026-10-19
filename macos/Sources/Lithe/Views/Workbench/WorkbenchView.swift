import AppKit
import SwiftUI
import LitheGitModule
import LitheModuleAPI

enum WorkbenchLayoutMetrics {
    static let rightActivityBarWidth: CGFloat = 40
    static let workspaceTrailingInset = rightActivityBarWidth
    static let projectTabGap: CGFloat = 4

    @MainActor
    static func projectTabWidth(name: String, documentName: String?, needsAttention: Bool) -> CGFloat {
        let nameWidth = (name as NSString).size(withAttributes: [.font: LitheTheme.uiNSFont(size: 13)]).width
        let documentWidth = documentName.map {
            ("· \($0)" as NSString).size(withAttributes: [.font: LitheTheme.uiNSFont(size: 11.5)]).width + 7
        } ?? 0
        // Reserve the folder, label gaps, close target and content insets; long labels truncate.
        return min(360, max(120, ceil(nameWidth + documentWidth + 65 + (needsAttention ? 13 : 0))))
    }
}

enum ActivityBarMetrics {
    static let width: CGFloat = 40
    static let rightWidth = WorkbenchLayoutMetrics.rightActivityBarWidth
    static let buttonWidth: CGFloat = 30
    static let buttonHeight: CGFloat = 30
    static let iconSize: CGFloat = 20
    static let slotWidth: CGFloat = 37
    static let slotHeight: CGFloat = 40
    static let toolViewportHeight: CGFloat = 280
}

/// Shared 30pt paint area centered in the activity rail's 37×40pt slot.
struct LitheActivityBarButtonStyle: ButtonStyle {
    var isSelected = false
    var isDragging = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: ActivityBarMetrics.buttonWidth, height: ActivityBarMetrics.buttonHeight)
            .litheRowHover(isActive: isSelected, cornerRadius: 6, activeBackground: LitheTheme.selection)
            .frame(width: ActivityBarMetrics.slotWidth, height: isDragging ? 0 : ActivityBarMetrics.slotHeight)
            .clipped()
            .opacity(isDragging ? 0 : 1)
            .contentShape(Rectangle())
            .foregroundStyle(isSelected ? LitheTheme.toolWindowSelectedText : LitheTheme.toolWindowButtonText)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private enum WorkbenchWorkspaceMetrics {
    static let paneInset: CGFloat = 0
    static let paneSpacing: CGFloat = SplitHandleView.thickness
    static let paneCornerRadius: CGFloat = 10
    static let minimumPaneHeight = CGFloat(WorkbenchLayout.minimumPaneSize)
}

private enum WorkbenchTopBarMetrics {
    // IDEA reserves 78pt for macOS window controls, then leaves a small widget gap.
    static let leadingInset: CGFloat = 83
    // ponytail: Reserve the reference's extra right-hand actions without adding them;
    // replace this space with their actual widths if those actions join the toolbar.
    static let executionTrailingSpace = 4 * LitheTheme.Metrics.toolbarHeight
    static let projectAvatarSize: CGFloat = 20
    static let projectAvatarLeadingInset: CGFloat = 6
    static let projectAvatarCenterX = leadingInset + projectAvatarLeadingInset + projectAvatarSize / 2
}

enum WorkbenchFrameGradient {
    static let coordinateSpace = "workbenchFrame"
    static let width: CGFloat = 600
    static let height: CGFloat = 300

    static func color(glow: Color, background: Color, at point: CGPoint) -> Color {
        let center = WorkbenchTopBarMetrics.projectAvatarCenterX
        let horizontal = point.x <= center
            ? max(0, point.x / center)
            : max(0, 1 - (point.x - center) / width)
        let vertical = max(0, 1 - point.y / height)
        return ProjectIdentityAppearance.blend(background, with: glow, fraction: horizontal * vertical)
    }
}

private struct WorkbenchToolbarGlowKey: EnvironmentKey {
    static let defaultValue = LitheTheme.titlebar
}

extension EnvironmentValues {
    var workbenchToolbarGlow: Color {
        get { self[WorkbenchToolbarGlowKey.self] }
        set { self[WorkbenchToolbarGlowKey.self] = newValue }
    }
}

/// Owns observation of replacement visibility so the overlay can dismiss
/// without reconstructing the complete workbench.
private struct ProjectReplaceOverlay: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: SearchSessionFeatureModel

    var body: some View {
        if session.isProjectReplaceVisible {
            ZStack {
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        session.isProjectReplaceVisible = false
                    }

                ProjectReplaceFloatingPanel {
                    if let feature = model.searchFeatureIfActive {
                        ProjectReplaceView(
                            feature: feature,
                            session: session,
                            previewReplacement: { await model.previewProjectReplacement(query: $0, replacement: $1, options: $2) },
                            loadPreviewDocument: { await model.documentFeature.previewDocument(at: $0) },
                            close: { session.isProjectReplaceVisible = false },
                            openFile: { model.openFile($0, displayPath: $1) },
                            revealInFinder: { model.revealProjectItemInFinder($0) },
                            copyPath: { model.copyProjectItemPath($0, relative: $1) }
                        )
                    } else {
                        WorkbenchModuleUIRegistry.moduleLoadingView
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .task {
                                if await model.activateSearchModule() == nil {
                                    session.isProjectReplaceVisible = false
                                }
                            }
                    }
                }
            }
            .background(ProjectReplaceKeyMonitor(session: session))
            .onDisappear { model.documentFeature.discardPreviewDocuments() }
        }
    }

}

private struct ProjectReplaceKeyMonitor: NSViewRepresentable {
    let session: SearchSessionFeatureModel

    func makeNSView(context: Context) -> ProjectReplaceKeyMonitorView {
        ProjectReplaceKeyMonitorView(session: session)
    }

    func updateNSView(_ view: ProjectReplaceKeyMonitorView, context: Context) {
        view.session = session
    }

    static func dismantleNSView(_ view: ProjectReplaceKeyMonitorView, coordinator: ()) {
        view.removeKeyMonitor()
    }
}

/// Scopes replacement shortcuts to the native window hosting this overlay.
final class ProjectReplaceKeyMonitorView: NSView {
    var session: SearchSessionFeatureModel
    private var keyMonitor: Any?

    init(session: SearchSessionFeatureModel) {
        self.session = session
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeKeyMonitor()
        guard window != nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event)
        }
    }

    func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window,
              session.isProjectReplaceVisible else { return event }
        let textInput = window.firstResponder as? NSTextInputClient
        if event.keyCode == 53 {
            // Let the input method cancel marked text before treating Escape as dismissal.
            if textInput?.hasMarkedText() == true { return event }
            session.isProjectReplaceVisible = false
            return nil
        }

        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.contains(.command) else { return event }
        let character = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers == .command && ["a", "c", "v", "x", "z"].contains(character) { return event }
        if modifiers == [.command, .shift] && ["z", "v"].contains(character) { return event }
        guard textInput != nil else { return nil }
        if modifiers == [.command, .option, .shift] && character == "v" { return event }
        // Native movement/selection and deletion use key codes, independent of keyboard layout.
        if modifiers == .command || modifiers == [.command, .shift] {
            switch event.keyCode {
            case 123...126, 51, 117: return event
            default: break
            }
        }
        return nil
    }

    func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

struct WorkbenchView: View {
    private var moduleUIRegistry: WorkbenchModuleUIRegistry { model.workbenchUIRegistry }
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var projectSessions: ProjectSessionManager
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.projectWindowScope) private var projectWindowScope
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var toolWindowDrag = ToolWindowDragState()
    @StateObject private var toolContentStore = WorkbenchToolContentStore()
    @State private var sidebarWidth: CGFloat = 320
    @State private var rightSidebarWidth: CGFloat = 380
    @State private var mavenPaneWidth = CGFloat(WorkbenchLayout.defaultMavenPaneWidth)
    @State private var branchPopupHeight: CGFloat?
    @State private var branchPopupWidth = LitheDropdownMetrics.branchMinimumWidth
    @State private var topPaneHeight: CGFloat?
    @State private var isBranchSwitcherPresented = false
    @State private var newBranchReference: GitReference?
    @State private var isCheckoutRevisionPresented = false
    @State private var pendingTopBarPushReference: GitReference?
    @State private var pendingTopBarDeleteReference: GitReference?
    @State private var isProjectSwitcherPresented = false
    @State private var isNotificationCenterPresented = false
    @State private var didRestoreLayout = false
    @State private var hoveredProjectTabID: UUID?
    @State private var workbenchBackgroundImage: NSImage?
    @State private var isBackgroundPickerPresented = false
    @State private var isRunConfigurationPickerPresented = false
    @State private var isSettingsMenuPresented = false

    var body: some View {
        let encodingRequest = model.pendingEncodingReopen
        let _ = LitheSignpost.bodyEvaluated("WorkbenchView")
        VStack(spacing: 0) {
            topBar

            HStack(spacing: 0) {
                activityBar
                VStack(spacing: 0) {
                    if scopedOpenProjects.count > 1 {
                        projectTabBar
                    }
                    workspaceArea
                        .workbenchToolContentLayers(store: toolContentStore) { toolWindowDropOverlay }
                }
                .padding(.horizontal, scopedOpenProjects.count > 1 ? WorkbenchLayoutMetrics.projectTabGap : 0)
                .padding(.trailing, WorkbenchLayoutMetrics.workspaceTrailingInset)
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .trailing) {
                pluginActivityBar
            }

            statusBar
        }
        .environment(\.workbenchHasBackgroundImage, model.workbenchBackgroundFeature.hasImage)
        .coordinateSpace(name: WorkbenchFrameGradient.coordinateSpace)
        .background {
            if let feature = model.gitFeatureIfActive { GitAuthenticationHost(feature: feature) }
        }
        .background {
            WorkbenchBackgroundImageView(
                image: workbenchBackgroundImage,
                opacity: settings.workbenchBackgroundOpacity,
                showsIDEAFrameGradient: usesIDEAFrameExperiment
            )
        }
        .environment(
            \.workbenchToolbarGlow,
            ProjectIdentityAppearance(colorIndex: currentProjectColorIndex, isDark: colorScheme == .dark)
                .toolbarGlow(over: Color(nsColor: LitheTheme.nsColor(.titlebar, isDark: colorScheme == .dark)))
        )
        .sheet(item: $newBranchReference) { reference in
            TopBarNewBranchDialog(reference: reference) { name, checkout in
                Task {
                    await model.createBranch(named: name, from: reference, checkout: checkout)
                }
            }
        }
        .sheet(item: $model.debugBreakpointPresentation.pendingEditor) { breakpoint in
            BreakpointEditorView(breakpoint: breakpoint) { value in
                model.updateDebugBreakpoint(
                    breakpoint,
                    enabled: value.enabled,
                    condition: value.condition,
                    hitCondition: value.hitCondition,
                    logMessage: value.logMessage
                )
            }
        }
        .sheet(isPresented: $model.debugBreakpointPresentation.isManagerPresented) {
            if let feature = model.genericDebugFeatureIfActive {
                DebugBreakpointManagerDialog(feature: feature)
            } else {
                ProgressView("Loading breakpoints…")
                    .frame(minWidth: 640, minHeight: 420)
            }
        }
        .sheet(item: Binding(
            get: { model.pendingJavaLaunchDecision },
            set: { _ in }
        )) { request in
            JavaLaunchDecisionDialog(request: request)
        }
        .onAppear {
            updateWorkbenchBackgroundImage(model.workbenchBackgroundFeature.imageData)
            model.setNotificationsApplicationActive(NSApplication.shared.isActive)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.setNotificationsApplicationActive(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.setNotificationsApplicationActive(false)
            toolWindowDrag.finish()
        }
        .onChange(of: isNotificationCenterPresented) { isPresented in
            if isPresented {
                model.dismissNotificationBalloons()
                model.markAllNotificationsRead()
            }
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
                changes: model.gitChanges,
                onShowDiff: { model.showGitConflictDiff(path: $0) },
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
                changes: model.gitChanges,
                onShowDiff: { model.showGitConflictDiff(path: $0) },
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
            isPresented: pendingCloseConfirmationBinding,
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
            "Save changes before reopening with \(encodingRequest?.encoding.displayName ?? "this encoding")?",
            isPresented: pendingEncodingReopenBinding,
            titleVisibility: .visible
        ) {
            Button("Save") { model.resolvePendingEncodingReopen(saveChanges: true) }
                .lithePointer()
            Button("Discard Changes", role: .destructive) {
                model.resolvePendingEncodingReopen(saveChanges: false)
            }
            .lithePointer()
            Button("Cancel", role: .cancel) { model.cancelEncodingChange() }
                .lithePointer()
        } message: {
            Text(encodingRequest?.document.url.lastPathComponent ?? "")
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
                guard let change = model.pendingDiscardChange else { return }
                Task { await model.confirmDiscardChange(change) }
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
                guard let request = model.pendingDiscardHunk else { return }
                Task { await model.confirmDiscardHunk(request) }
            }
            .lithePointer()
            Button("Cancel", role: .cancel) { model.cancelDiscardHunk() }
                .lithePointer()
        } message: {
            Text(model.pendingDiscardHunk?.change.path ?? "This action cannot be undone by Lithe.")
        }
        .sheet(item: $pendingTopBarPushReference) { reference in
            GitPushDialog(
                projectName: model.projectName,
                reference: reference,
                onPush: {
                    Task { await model.pushBranch(reference) }
                }
            )
        }
        .confirmationDialog(
            "Delete branch?",
            isPresented: Binding(
                get: { pendingTopBarDeleteReference != nil },
                set: { if !$0 { pendingTopBarDeleteReference = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let reference = pendingTopBarDeleteReference else { return }
                pendingTopBarDeleteReference = nil
                Task { await model.deleteBranch(reference) }
            }
            .disabled(model.isPerformingBranchOperation)
            .lithePointer()
            Button("Cancel", role: .cancel) {
                pendingTopBarDeleteReference = nil
            }
            .lithePointer()
        } message: {
            Text(
                "Delete the local branch \(pendingTopBarDeleteReference?.shortName ?? "")? "
                    + "Git will refuse if it contains unmerged work."
            )
        }
        .overlay(alignment: .bottomTrailing) {
            if !model.activeNotifications.isEmpty {
                VStack(alignment: .trailing, spacing: 2 * LitheTheme.Notification.shadowInset) {
                    // IDEA keeps the oldest balloon at the bottom; new messages grow upward.
                    ForEach(model.activeNotifications.reversed()) { notification in
                        WorkbenchNotificationBanner(message: notification.message,
                            messageArguments: notification.arguments,
                            collapsedCount: notification.collapsedCount,
                            occurrenceCount: notification.occurrenceCount,
                            showHistory: { isNotificationCenterPresented = true }) {
                            model.dismissNotification(notification.id)
                        }
                        .onHover { model.setNotificationHovered(notification.id, isHovered: $0) }
                    }
                }
                .padding(.trailing, WorkbenchLayoutMetrics.rightActivityBarWidth + LitheTheme.Notification.edgeInset)
                .padding(.bottom, LitheTheme.Metrics.statusBarHeight + LitheTheme.Notification.edgeInset)
            }
        }
        .overlay {
            if model.isSearchEverywhereVisible, let feature = model.searchFeatureIfActive {
                SearchEverywhereView(
                    feature: feature,
                    session: model.searchSessionFeature,
                    actionMatches: { model.searchEverywhereActionMatches(query: $0) },
                    search: { await model.searchEverywhere(query: $0, options: $1) },
                    dismiss: { model.dismissSearchEverywhere() },
                    openResult: { model.openSearchEverywhereResult($0) },
                    performAction: { model.performSearchEverywhereAction($0) },
                    revealInFinder: { model.revealProjectItemInFinder($0) },
                    copyPath: { model.copyProjectItemPath($0, relative: $1) },
                    relativePath: { model.relativePath(for: $0) },
                    moduleLabel: { url in
                        let path = url.standardizedFileURL.path
                        if let project = model.mavenFeatureIfActive?.project {
                            let owning = project.allModules
                                .filter { path.hasPrefix($0.url.standardizedFileURL.path + "/") }
                                .max { $0.url.standardizedFileURL.path.count < $1.url.standardizedFileURL.path.count }
                            if let owning { return owning.displayName }
                            if path.hasPrefix(project.rootURL.standardizedFileURL.path + "/") {
                                return project.displayName
                            }
                        }
                        return model.relativePath(for: url).components(separatedBy: "/").first ?? ""
                    },
                    actionIcon: { action in
                        guard let id = action.contributionID,
                              let contribution = model.workbenchContributions.first(where: { $0.id == id }) else { return nil }
                        return moduleUIRegistry.icon(for: contribution, role: .action)
                    }
                )
                    .transition(.opacity)
            }
        }
        .workbenchHoverTooltipScope()
        .animation(.easeOut(duration: 0.12), value: model.isSearchEverywhereVisible)
        // Replace in Files 是工作台上的自绘模态层，避免系统 sheet 的大圆角和标题栏。
        .overlay {
            ProjectReplaceOverlay(model: model, session: model.searchSessionFeature)
        }
        .onAppear {
            restoreLayout()
        }
        .onChange(of: model.workbenchFeature.toolWindowStates) { _ in
            saveLayout(sidebarWidth: sidebarWidth, topPaneHeight: topPaneHeight)
        }
        .onChange(of: model.workbenchFeature.groupFractions) { _ in
            saveLayout(sidebarWidth: sidebarWidth, topPaneHeight: topPaneHeight)
        }
        .onDisappear { toolWindowDrag.finish() }
        .onChange(of: model.workspaceURL?.standardizedFileURL.path) { _ in
            didRestoreLayout = false
            restoreLayout()
        }
    }

    private var usesIDEAFrameExperiment: Bool {
        settings.colorTheme == .lithe && colorScheme == .dark && !model.workbenchBackgroundFeature.hasImage
    }

    private var currentProjectColorIndex: Int {
        ProjectIdentityAppearance.colorIndex(for: model.workspaceURL)
    }

    private var frameChromeBackground: Color {
        model.workbenchBackgroundFeature.hasImage || usesIDEAFrameExperiment ? .clear : LitheTheme.titlebar
    }

    private var scopedOpenProjects: [AppModel] {
        projectSessions.openProjects(in: projectWindowScope)
    }

    private var projectTabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(scopedOpenProjects) { projectModel in
                        projectTab(projectModel)
                            .id(projectModel.id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .onAppear {
                proxy.scrollTo(projectSessions.activeSessionID(in: projectWindowScope), anchor: .center)
            }
            .onChange(of: projectSessions.activeSessionIDs) { _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(
                        projectSessions.activeSessionID(in: projectWindowScope),
                        anchor: .center
                    )
                }
            }
        }
        .frame(height: 36)
        .workbenchPaneChrome(
            background: model.workbenchBackgroundFeature.hasImage ? Color.clear : LitheTheme.toolHeader,
            surrounding: frameChromeBackground,
            roundsCorners: !model.workbenchBackgroundFeature.hasImage,
            showsFrameGradient: usesIDEAFrameExperiment
        )
        .padding(.bottom, WorkbenchLayoutMetrics.projectTabGap)
    }

    private func projectTab(_ projectModel: AppModel) -> some View {
        let isActive = projectModel.id == projectSessions.activeSessionID(in: projectWindowScope)
        let isHovered = projectModel.id == hoveredProjectTabID
        let width = WorkbenchLayoutMetrics.projectTabWidth(
            name: projectModel.projectName,
            documentName: projectModel.activeDocument?.displayName,
            needsAttention: projectModel.agentConversationNeedsAttention
        )

        return ZStack(alignment: .trailing) {
            Button {
                projectSessions.activateSession(projectModel.id)
            } label: {
                HStack(spacing: 7) {
                    LitheIDEAIcon(resourcePath: "expui/nodes/folder.svg", size: 16, preservesOriginalColors: true)

                    Text(projectModel.projectName)
                        .font(LitheTheme.uiFont(size: 13, weight: .regular))
                        .foregroundStyle(isActive ? LitheTheme.primaryText : LitheTheme.secondaryText)

                    AgentAttentionIndicator(model: projectModel)

                    if let documentName = projectModel.activeDocument?.displayName {
                        Text("· \(documentName)")
                            .font(LitheTheme.uiFont(size: 11.5))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                }
                .lineLimit(1)
                .padding(.leading, 12)
                .padding(.trailing, 30)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .accessibilityIdentifier("project-tab-\(projectModel.id.uuidString)")

            Button {
                projectSessions.closeProject(projectModel.id)
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/close.svg", size: 16, preservesOriginalColors: true)
            }
            .buttonStyle(LitheIconButtonStyle())
            .help("Close Project")
            .opacity(isActive || isHovered ? 1 : 0)
            .allowsHitTesting(isActive || isHovered)
            .padding(.trailing, 3)
        }
        .frame(width: width, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    isActive
                        ? LitheTheme.subtleSelection
                        : (isHovered ? LitheTheme.hoverBackground : LitheTheme.inactiveTabBackground)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onHover { hovering in
            hoveredProjectTabID = hovering ? projectModel.id : nil
        }
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private var topBar: some View {
        HStack(spacing: 9) {
            Button {
                updateSwitcherPresentation(
                    project: !isProjectSwitcherPresented,
                    branch: false
                )
            } label: {
                HStack(spacing: 6) {
                    ProjectAvatarBadge(
                        name: model.projectName,
                        colorIndex: currentProjectColorIndex,
                        size: WorkbenchTopBarMetrics.projectAvatarSize
                    )

                    Text(model.projectName)
                        .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(LitheTheme.uiFont(size: 9, weight: .semibold))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .padding(.leading, WorkbenchTopBarMetrics.projectAvatarLeadingInset)
                .padding(.trailing, 10)
                .frame(height: 30)
                .litheRowHover(isActive: isProjectSwitcherPresented, cornerRadius: 6,
                               activeBackground: LitheTheme.hoverBackground)
            }
            .buttonStyle(.litheNoPress)
            .accessibilityIdentifier("project-switcher-\(model.id.uuidString)")
            // Anchor at the full toolbar slot, leaving its margin below the painted button.
            .frame(height: LitheTheme.Metrics.toolbarHeight)
            .litheDropdown(isPresented: instantProjectSwitcherPresentation) { projectSwitcherContent }

            Button {
                updateSwitcherPresentation(
                    project: false,
                    branch: !isBranchSwitcherPresented
                )
            } label: {
                HStack(spacing: 7) {
                    LitheIDEAIcon(
                        resourcePath: "toolwindows/toolWindowVcs.svg",
                        size: 14,
                        fallbackSystemImage: "point.3.connected.trianglepath.dotted"
                    )
                        .foregroundStyle(LitheTheme.secondaryText)
                    Text(model.currentBranch)
                        .font(LitheTheme.uiFont(size: 12.5, weight: .medium))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(LitheTheme.uiFont(size: 8, weight: .bold))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .padding(.horizontal, 9)
                .frame(height: 32)
                .litheRowHover(isActive: isBranchSwitcherPresented, cornerRadius: 6,
                               activeBackground: LitheTheme.hoverBackground)
            }
            .buttonStyle(.litheNoPress)
            .frame(height: LitheTheme.Metrics.toolbarHeight)
            .litheDropdown(isPresented: instantBranchSwitcherPresentation, searchOnTyping: true,
                           resizableWidth: Binding(get: { branchPopupWidth }, set: { width in
                               branchPopupWidth = width
                               saveLayout(sidebarWidth: sidebarWidth, topPaneHeight: topPaneHeight)
                           }), minimumWidth: LitheDropdownMetrics.branchMinimumWidth,
                           resizableHeight: $branchPopupHeight, minimumHeight: BranchSwitcherPopover.Metrics.minimumHeight) { branchSwitcherContent }

            Spacer(minLength: 22)

            HStack(spacing: 0) {
                runConfigurationPicker
                ForEach(model.registeredContributions(at: .toolbar)) { contribution in
                    registeredToolbarButton(contribution)
                }
            }
            Spacer(minLength: 0)
                .frame(maxWidth: WorkbenchTopBarMetrics.executionTrailingSpace)
            settingsMenuButton
        }
        .padding(.leading, WorkbenchTopBarMetrics.leadingInset)
        .frame(height: LitheTheme.Metrics.toolbarHeight)
        .background {
            frameChromeBackground
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    (NSApplication.shared.keyWindow?.delegate as? LitheWindowCoordinator)?
                        .toggleWorkspaceZoom()
                }
        }
    }

    private func registeredToolbarButton(_ contribution: ModuleContribution) -> some View {
        let state = moduleUIRegistry.state(for: contribution, model: model)
        return Group {
            switch contribution.actionID {
            case "workbench.run-start-or-restart": runLaunchButton
            case "workbench.debug-start-or-restart": debugLaunchButton
            case "workbench.stop-execution": stopExecutionButton
            default:
                Button { moduleUIRegistry.perform(contribution, model: model) } label: {
                    HStack(spacing: 6) {
                        moduleUIRegistry.icon(for: contribution, role: .action)
                        Text(verbatim: contribution.title)
                    }
                }
                .buttonStyle(LitheMainToolbarButtonStyle(isActive: state.isChecked))
                .foregroundStyle(LitheTheme.primaryText)
                .accessibilityIdentifier("workbench-action-" + contribution.id)
            }
        }
        .disabled(!state.isEnabled)
        .litheContextMenu { contributionCustomizationItems(contribution) }
    }

    private var projectSwitcherContent: some View {
                ProjectSwitcherPopover(
                    isPresented: instantProjectSwitcherPresentation,
                    onNewProject: {
                        updateSwitcherPresentation(project: false)
                        model.chooseProject(title: "New Project", prompt: "Choose Folder")
                    },
                    onOpenProject: {
                        updateSwitcherPresentation(project: false)
                        model.chooseProject()
                    },
                    onCloneRepository: {
                        updateSwitcherPresentation(project: false)
                        model.showCloneRepository()
                    },
                    onOpenRecentProject: { project in
                        updateSwitcherPresentation(project: false)
                        model.openProject(project.url)
                    }
                )
        .environmentObject(model)
        .environmentObject(projectSessions)
        .environment(\.projectWindowScope, projectWindowScope)
    }

    private var branchSwitcherContent: some View {
        Group {
                if let feature = model.gitFeatureIfActive {
                    BranchSwitcherPopover(
                        feature: feature,
                        isPresented: instantBranchSwitcherPresentation,
                        onCommit: {
                            updateSwitcherPresentation(branch: false)
                            model.workbenchFeature.selectedSidebar = .changes
                        },
                        onPush: { reference in
                            updateSwitcherPresentation(branch: false)
                            pendingTopBarPushReference = reference
                        },
                        onDelete: { reference in
                            updateSwitcherPresentation(branch: false)
                            pendingTopBarDeleteReference = reference
                        },
                        onNewBranch: { reference in
                            updateSwitcherPresentation(branch: false)
                            newBranchReference = reference
                        },
                        onCheckoutRevision: {
                            updateSwitcherPresentation(branch: false)
                            isCheckoutRevisionPresented = true
                        },
                        onManageBranches: {
                            updateSwitcherPresentation(branch: false)
                            if !model.workbenchFeature.isVisible(.gitLog) {
                                model.workbenchFeature.selectedSidebar = .changes
                                Task { await model.toggleGitLog() }
                            }
                        },
                        onCompareWithWorkingTree: { [weak model] in
                            await model?.showComparisonWithWorkingTree(for: $0)
                        },
                        onCompareReferences: { [weak model] in
                            await model?.showComparison(from: $0, to: $1)
                        }
                    )

                } else {
                    ProgressView()
                        .frame(width: BranchSwitcherPopover.Metrics.popupWidth, height: BranchSwitcherPopover.Metrics.branchListHeight)

                }
        }
        .task {
            let feature = await model.activateGitModule()
            guard !Task.isCancelled else { return }
            guard let feature else {
                updateSwitcherPresentation(branch: false)
                return
            }
            await feature.refreshGitHistory()
        }
    }

    private var instantProjectSwitcherPresentation: Binding<Bool> {
        Binding(
            get: { isProjectSwitcherPresented },
            set: { updateSwitcherPresentation(project: $0) }
        )
    }

    private var pendingCloseConfirmationBinding: Binding<Bool> {
        let confirmationID = model.pendingCloseConfirmationID
        return Binding(
            get: { model.pendingCloseDocument != nil },
            set: { isPresented in
                guard !isPresented else { return }
                model.dismissPendingCloseConfirmation(confirmationID)
            }
        )
    }

    private var pendingEncodingReopenBinding: Binding<Bool> {
        let requestID = model.pendingEncodingReopen?.id
        return Binding(
            get: { model.pendingEncodingReopen != nil },
            set: { isPresented in
                guard !isPresented else { return }
                model.dismissPendingEncodingReopen(requestID)
            }
        )
    }

    private var instantBranchSwitcherPresentation: Binding<Bool> {
        Binding(
            get: { isBranchSwitcherPresented },
            set: { updateSwitcherPresentation(branch: $0) }
        )
    }

    private func updateSwitcherPresentation(
        project: Bool? = nil,
        branch: Bool? = nil
    ) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let project {
                isProjectSwitcherPresented = project
            }
            if let branch {
                isBranchSwitcherPresented = branch
            }
        }
    }

    private var runLaunchButton: some View {
        let control = WorkbenchModuleUIComposition.mainToolbarDebugControl(for: model)
        let isRunningConfiguration = model.activeTestTarget == nil && model.runFeatureIfActive?.isSelectedConfigurationRunning == true
        return Button {
            moduleUIRegistry.performAction(id: "workbench.run-start-or-restart", model: model)
        } label: {
            LitheIDEAIcon(
                resourcePath: control.map { DebugToolbarPresentation.ideaAssetPath(for: $0) }
                    ?? (isRunningConfiguration
                    ? "expui/run/rerun_stroke.svg"
                    : "expui/run/run_stroke.svg"),
                size: 16,
                fallbackSystemImage: isRunningConfiguration
                    ? "arrow.clockwise"
                    : "play.fill",
                preservesOriginalColors: control != nil
            )
                .foregroundStyle(isRunningConfiguration
                                 ? LitheTheme.MainToolbar.runningIcon : LitheTheme.MainToolbar.runIcon)
        }
        .buttonStyle(LitheMainToolbarButtonStyle(
            insets: LitheTheme.MainToolbar.runInsets,
            executionBackground: control == nil && isRunningConfiguration
                ? LitheTheme.MainToolbar.runningBackground : nil
        ))
        .help(control == .resume ? "Resume" : control == .pause ? "Pause" : isRunningConfiguration ? "Rerun selected configuration" : "Run selected configuration")
        .accessibilityLabel(control == .resume ? "Resume" : control == .pause ? "Pause" : isRunningConfiguration ? "Rerun selected configuration" : "Run selected configuration")
        .accessibilityIdentifier("run-selected-run-configuration")
    }

    private var debugLaunchButton: some View {
        Button {
            moduleUIRegistry.performAction(id: "workbench.debug-start-or-restart", model: model)
        } label: {
            LitheIDEAIcon(
                resourcePath: isDebugSessionActive
                    ? "expui/run/restartDebug_stroke.svg"
                    : "expui/run/debug_stroke.svg",
                size: 16,
                fallbackSystemImage: "ladybug.fill"
            )
            .foregroundStyle(isDebugSessionActive ? LitheTheme.MainToolbar.runningIcon : LitheTheme.MainToolbar.runIcon)
        }
        .buttonStyle(LitheMainToolbarButtonStyle(
            insets: LitheTheme.MainToolbar.runInsets,
            executionBackground: isDebugSessionActive ? LitheTheme.MainToolbar.runningBackground : nil
        ))
        .help(isDebugSessionActive ? "Rerun or show Debug session" : "Debug selected run configuration")
        .accessibilityLabel(isDebugSessionActive ? "Rerun or show Debug session" : "Debug selected run configuration")
        .accessibilityIdentifier("debug-selected-run-configuration")
    }

    private var stopExecutionButton: some View {
        Button {
            moduleUIRegistry.performAction(id: "workbench.stop-execution", model: model)
        } label: {
            LitheIDEAIcon(
                resourcePath: "expui/run/stop_stroke.svg",
                size: 16,
                fallbackSystemImage: "stop"
            )
            .foregroundStyle(LitheTheme.MainToolbar.runningIcon)
        }
        .buttonStyle(LitheMainToolbarButtonStyle(
            insets: LitheTheme.MainToolbar.runInsets,
            executionBackground: LitheTheme.MainToolbar.stopBackground
        ))
        .help("Stop active execution")
        .accessibilityLabel("Stop active execution")
        .accessibilityIdentifier("stop-active-execution")
    }

    private var isDebugSessionActive: Bool {
        model.genericDebugFeatureIfActive?.isSessionActive == true
    }

    private var runConfigurationPicker: some View {
        Button {
            isRunConfigurationPickerPresented.toggle()
        } label: {
            HStack(spacing: 2) {
                HStack(spacing: 6) {
                    if let target = model.activeTestTarget {
                        LitheIDEAIcon(
                            resourcePath: "expui/runConfigurations/junit.svg",
                            size: LitheTheme.MainToolbar.iconSize,
                            preservesOriginalColors: true
                        )
                        Text(target.name)
                            .font(LitheTheme.MainToolbar.font)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        RunConfigurationIcon(
                            kind: model.runFeatureIfActive?.selectedConfiguration?.kind ?? .currentFile,
                            size: LitheTheme.MainToolbar.iconSize
                        )
                        Text(model.runFeatureIfActive?.selectedConfiguration?.name ?? "Current File")
                            .font(LitheTheme.MainToolbar.font)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                LitheIDEAIcon(resourcePath: "expui/general/chevronDown.svg", size: 16)
                    .foregroundStyle(LitheTheme.MainToolbar.icon)
            }
            .foregroundStyle(LitheTheme.MainToolbar.foreground)
            .padding(.leading, 10)
            .padding(.trailing, 6)
        }
        .buttonStyle(LitheMainToolbarButtonStyle(insets: LitheTheme.MainToolbar.runInsets))
        .help("Select run configuration for Run or Debug")
        .accessibilityLabel("Select run configuration for Run or Debug")
        .accessibilityIdentifier("run-configuration-picker")
        .litheDropdown(isPresented: $isRunConfigurationPickerPresented) {
            runConfigurationSelectionPanel
        }
    }

    private var runConfigurationSelectionPanel: some View {
        let configurations = model.runFeatureIfActive?.configurations ?? [.currentFile]
        let services = configurations.filter { $0.execution == .service }
        let visibleConfigurations = [RunConfiguration.currentFile] + services
        return VStack(alignment: .leading, spacing: 6) {
            Text("Run configurations")
                .font(LitheTheme.uiFont(size: 11, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            ScrollView {
                VStack(spacing: 3) {
                    if let activeTarget = model.activeTestTarget {
                        Button {
                            isRunConfigurationPickerPresented = false
                        } label: {
                            HStack(spacing: 10) {
                                LitheIDEAIcon(
                                    resourcePath: "expui/runConfigurations/junit.svg",
                                    size: 16,
                                    preservesOriginalColors: true
                                )
                                Text(activeTarget.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 12)
                                Image(systemName: "checkmark")
                                    .font(LitheTheme.uiFont(size: 11, weight: .semibold))
                                    .opacity(1)
                            }
                            .foregroundStyle(LitheTheme.primaryText)
                            .frame(minHeight: LitheDropdownMetrics.rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(LitheDropdownRowStyle(isSelected: true))
                        .help(activeTarget.name)
                        .accessibilityAddTraits(.isSelected)

                        Divider().padding(.vertical, 3)
                    }

                    ForEach(visibleConfigurations) { configuration in
                        if configuration.id == services.first?.id {
                            Divider().padding(.vertical, 3)
                            Text("Services")
                                .font(LitheTheme.uiFont(size: 11, weight: .semibold))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                        }
                        let isSelected = configuration.id == model.runFeatureIfActive?.selectedConfiguration?.id
                        Button {
                            model.selectRunConfiguration(configuration)
                            isRunConfigurationPickerPresented = false
                        } label: {
                            HStack(spacing: 10) {
                                RunConfigurationIcon(kind: configuration.kind, size: 16)
                                Text(configuration.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 12)
                                Image(systemName: "checkmark")
                                    .font(LitheTheme.uiFont(size: 11, weight: .semibold))
                                    .opacity(isSelected ? 1 : 0)
                            }
                            .foregroundStyle(LitheTheme.primaryText)
                            .frame(minHeight: LitheDropdownMetrics.rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(LitheDropdownRowStyle(isSelected: isSelected))
                        .help(configuration.name)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .frame(height: min(CGFloat(visibleConfigurations.count) * (LitheDropdownMetrics.rowHeight + 3) + (services.isEmpty ? 0 : 28), 296))
        }
        .padding(LitheDropdownMetrics.popupPadding)
        .frame(width: 280)
    }

    private var backgroundPickerButton: some View {
        activityToolButton(
            ideaAssetPath: "expui/actions/viewAsImage.svg",
            help: "Change workbench background",
            tooltipPlacement: .leading,
            isSelected: isBackgroundPickerPresented
        ) {
            isBackgroundPickerPresented.toggle()
        }
        .accessibilityIdentifier("workbench-background-picker")
        .litheDropdown(isPresented: $isBackgroundPickerPresented, opensUpward: true) {
            WorkbenchBackgroundPicker {
                isBackgroundPickerPresented = false
            }
            .environmentObject(model)
            .environmentObject(settings)
        }
    }

    private var settingsMenuButton: some View {
        Button { isSettingsMenuPresented.toggle() } label: {
            LitheIDEAIcon(resourcePath: "expui/general/settings@20x20.svg", size: ActivityBarMetrics.iconSize)
                .foregroundStyle(LitheTheme.toolWindowButtonText)
                .frame(width: 30, height: 30)
                .litheRowHover(isActive: isSettingsMenuPresented, cornerRadius: 6,
                               activeBackground: LitheTheme.hoverBackground)
        }
        .buttonStyle(.litheNoPress)
        .frame(width: ActivityBarMetrics.rightWidth, height: LitheTheme.Metrics.toolbarHeight)
        .workbenchHoverHelp(Text(LocalizedStringKey("Settings")), placement: .below)
        .accessibilityLabel(Text(LocalizedStringKey("Settings")))
        .accessibilityIdentifier("workbench-settings-menu")
        .overlay {
            LitheDropdownPopover(isPresented: $isSettingsMenuPresented, items: [
                .action("Settings…", icon: AnyView(LitheIDEAIcon(resourcePath: "expui/general/settings.svg", size: 16)),
                        initiallySelected: true, shortcut: model.keyboardShortcutFeature.displayText(for: "settings")) {
                    model.showSettings()
                },
                .action("Plugins…") { model.showSettings(category: .plugins) },
                .separator,
                .action("Theme…") { model.showSettings(category: .general) },
                .action("Keymap…") { model.showSettings(category: .keymap) }
            ]) { EmptyView() }
        }
    }

    private var activityBar: some View {
        VStack(spacing: 0) {
            dockStripe(DockPosition(anchor: .left, group: .primary))
            Spacer(minLength: 0)
            dockStripe(DockPosition(anchor: .left, group: .secondary))
            dockStripe(DockPosition(anchor: .bottom, group: .primary))
        }
        .frame(width: ActivityBarMetrics.width)
        .background(frameChromeBackground)
    }

    private var pluginActivityBar: some View {
        VStack(spacing: 0) {
            Button {
                isNotificationCenterPresented.toggle()
            } label: {
                ZStack(alignment: .topTrailing) {
                    LitheIDEAIcon(
                        resourcePath: "expui/toolwindows/notifications@20x20.svg",
                        size: ActivityBarMetrics.iconSize
                    )
                        .frame(width: ActivityBarMetrics.buttonWidth, height: ActivityBarMetrics.buttonHeight)
                        .litheRowHover(
                            isActive: isNotificationCenterPresented,
                            cornerRadius: 6,
                            activeBackground: LitheTheme.selection
                        )

                    if unreadNotificationCount > 0 {
                        Circle()
                            .fill(LitheTheme.error)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(LitheTheme.titlebar, lineWidth: 1))
                            .offset(x: -2, y: 3)
                    }
                }
                .frame(width: ActivityBarMetrics.slotWidth, height: ActivityBarMetrics.slotHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .foregroundStyle(
                isNotificationCenterPresented ? LitheTheme.toolWindowSelectedText
                    : unreadNotificationCount > 0 ? LitheTheme.primaryText
                    : LitheTheme.toolWindowButtonText
            )
            .workbenchHoverHelp(Text("Notifications"), placement: .leading)
            .accessibilityLabel("Notifications")
            .litheDropdown(isPresented: $isNotificationCenterPresented) {
                WorkbenchNotificationCenterView()
                    .environmentObject(model)
            }

            dockStripe(DockPosition(anchor: .right, group: .primary))
            Spacer(minLength: 0)
            dockStripe(DockPosition(anchor: .right, group: .secondary))
            dockStripe(DockPosition(anchor: .bottom, group: .secondary))
            UpdateControl(compact: true)
            backgroundPickerButton
        }
        .frame(width: ActivityBarMetrics.rightWidth)
        .background(frameChromeBackground)
    }

    private func contributionCustomizationItems(_ contribution: ModuleContribution) -> [LitheContextMenuItem] {
        let workbench = model.workbenchFeature
        let state = moduleUIRegistry.state(for: contribution, model: model)
        let hidden = workbench.contributionPreferences[contribution.id]?.isHidden == true
        var items: [LitheContextMenuItem] = [
            .action(String(localized: contribution.kind == .toolWindow ? "Show" : "Show Entry"),
                    isEnabled: contribution.kind != .toolWindow || (state.isVisible && state.isEnabled && !state.isPending)) {
                model.showContributionEntry(contribution)
            },
            .action(String(localized: "Hide Entry"), isEnabled: !hidden) {
                workbench.customizeContribution(contribution.id, isHidden: true)
            }
        ]
        if contribution.kind == .toolWindow {
            items += [
                .action(String(localized: "Move to Left")) { workbench.customizeContribution(contribution.id, placement: .leftSidebar) },
                .action(String(localized: "Move to Bottom")) { workbench.customizeContribution(contribution.id, placement: .activityBar) },
                .action(String(localized: "Move to Right")) { workbench.customizeContribution(contribution.id, placement: .rightSidebar) }
            ]
        }
        items += [
            .action(String(localized: "Move Earlier")) { workbench.moveContribution(contribution.id, earlier: true) },
            .action(String(localized: "Move Later")) { workbench.moveContribution(contribution.id, earlier: false) }
        ]
        return items
    }

    private var unreadNotificationCount: Int {
        model.notifications.lazy.filter { !$0.isRead }.count
    }

    private func contribution(for tool: WorkbenchFeatureModel.ToolWindow) -> ModuleContribution? {
        model.workbenchContributions.first { $0.id == tool.rawValue && $0.kind == .toolWindow }
    }

    private func isToolAvailable(_ tool: WorkbenchFeatureModel.ToolWindow) -> Bool {
        if let entry = contribution(for: tool) {
            let state = moduleUIRegistry.state(for: entry, model: model)
            return state.isVisible && state.isEnabled
        }
        return (tool == .references || tool == .spring) && model.workbenchFeature.isVisible(tool)
    }

    private func isToolEntryVisible(_ tool: WorkbenchFeatureModel.ToolWindow) -> Bool {
        guard model.workbenchFeature.contributionPreferences[tool.rawValue]?.isHidden != true else { return false }
        if let entry = contribution(for: tool), let renderer = moduleUIRegistry.renderer(for: entry) {
            return renderer.isVisible(model) && moduleUIRegistry.state(for: entry, model: model).isVisible
        }
        return isToolAvailable(tool)
    }

    private func openTool(_ tool: WorkbenchFeatureModel.ToolWindow) {
        if let entry = contribution(for: tool) {
            if !entry.hasDeclarativeContent && model.workbenchFeature.isVisible(tool) {
                model.workbenchFeature.setVisibility(tool, isVisible: false)
            } else { moduleUIRegistry.perform(entry, model: model) }
        }
        else if isToolAvailable(tool) { model.workbenchFeature.toggleVisibility(tool) }
    }

    private func moveTool(_ tool: WorkbenchFeatureModel.ToolWindow, target: ToolWindowDragState.Target) {
        guard isToolAvailable(tool) else { return }
        model.workbenchFeature.move(tool, to: target.position, before: target.before)
    }

    private func dockStripe(_ position: DockPosition) -> some View {
        let tools = model.workbenchFeature.tools(in: position).filter(isToolEntryVisible)
        let hidesSource = toolWindowDrag.source.map { tools.contains($0) } ?? false
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(tools, id: \.self) { tool in
                    let entry = contribution(for: tool)
                    let renderer = entry.flatMap { moduleUIRegistry.renderer(for: $0) }
                    let title = entry?.title ?? tool.rawValue
                    let target = ToolWindowDragState.Target(position: position, before: tool)
                    if toolWindowDrag.source != nil && toolWindowDrag.target == target { toolWindowDropSlot }
                    activityToolButton(
                        ideaAssetPath: renderer?.ideaAssetPath ?? "expui/toolwindows/toolWindowComponents@20x20.svg",
                        icon: entry.flatMap { moduleUIRegistry.icon(for: $0, role: .toolWindow) },
                        help: renderer?.help ?? title, tooltipPlacement: position.anchor == .right ? .leading : .trailing,
                        isSelected: model.workbenchFeature.isVisible(tool), isDragging: toolWindowDrag.source == tool, action: { openTool(tool) }
                    )
                    .disabled(!isToolAvailable(tool))
                    .overlay(ToolWindowDragSource(tool: tool, position: position, drag: toolWindowDrag, image: {
                        ImageRenderer(content: Group {
                            if let entry, let icon = moduleUIRegistry.icon(for: entry, role: .toolWindow) { icon }
                            else { LitheIDEAIcon(resourcePath: renderer?.ideaAssetPath ?? "expui/toolwindows/toolWindowComponents@20x20.svg", size: ActivityBarMetrics.iconSize) }
                        }
                            .foregroundStyle(LitheTheme.toolWindowButtonText)
                            .modifier(LitheToolWindowDragButtonStyle())
                            .environment(\.colorScheme, colorScheme)).nsImage
                    }, click: { openTool(tool) }, commit: { moveTool($0, target: $1) }, isEnabled: isToolAvailable(tool),
                       openInEditor: renderer?.openInEditor.map { open in { open(model) } }))
                    .accessibilityHidden(toolWindowDrag.source == tool)
                    .litheContextMenu {
                        guard isToolAvailable(tool) else { return [] }
                        let editorItems: [LitheContextMenuItem] = renderer?.openInEditor.map { open in
                            [.action(String(localized: "Open in Editor")) { open(model) }, .separator]
                        } ?? []
                        return editorItems + (entry.map { contributionCustomizationItems($0) } ?? []) + DockAnchor.allCases.flatMap { anchor in
                            DockGroup.allCases.map { group in
                                let destination = DockPosition(anchor: anchor, group: group)
                                return LitheContextMenuItem.action(dockMoveTitle(destination), action: {
                                    model.workbenchFeature.move(tool, to: destination)
                                })
                            }
                        }
                    }
                    .accessibilityIdentifier("tool-window-" + tool.rawValue)
                }
                if toolWindowDrag.source != nil && toolWindowDrag.target == .init(position: position, before: nil) {
                    toolWindowDropSlot
                }
            }
            .frame(width: ActivityBarMetrics.width)
        }
        .frame(height: max(1, min(CGFloat(tools.count - (hidesSource ? 1 : 0)
            + (toolWindowDrag.source != nil && toolWindowDrag.target?.position == position ? 1 : 0)) * ActivityBarMetrics.slotHeight,
                                ActivityBarMetrics.toolViewportHeight)))
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var toolWindowDropSlot: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(LitheTheme.toolWindowDropButton)
            .frame(width: ActivityBarMetrics.buttonWidth, height: ActivityBarMetrics.buttonHeight)
            .frame(width: ActivityBarMetrics.slotWidth, height: ActivityBarMetrics.slotHeight)
            .accessibilityHidden(true)
            .background(ToolWindowWorkspaceAnchor(drag: toolWindowDrag, region: .insertion))
    }

    private func dockMoveTitle(_ position: DockPosition) -> String {
        switch (position.anchor, position.group) {
        case (.left, .primary): "Move to Left Top"
        case (.left, .secondary): "Move to Left Bottom"
        case (.right, .primary): "Move to Right Top"
        case (.right, .secondary): "Move to Right Bottom"
        case (.bottom, .primary): "Move to Bottom Left"
        case (.bottom, .secondary): "Move to Bottom Right"
        }
    }

    private func hasVisibleTool(on anchor: DockAnchor, group: DockGroup) -> Bool {
        guard let tool = model.workbenchFeature.activeTool(in: .init(anchor: anchor, group: group)) else { return false }
        if let entry = contribution(for: tool) { return moduleUIRegistry.isContentVisible(for: entry, model: model) }
        return isToolAvailable(tool)
    }

    private func hasVisibleTool(on anchor: DockAnchor) -> Bool {
        DockGroup.allCases.contains { hasVisibleTool(on: anchor, group: $0) }
    }

    private func dockContent(on anchor: DockAnchor) -> some View {
        WorkbenchDockGroups(
            anchor: anchor, primaryVisible: hasVisibleTool(on: anchor, group: .primary),
            secondaryVisible: hasVisibleTool(on: anchor, group: .secondary),
            fraction: model.workbenchFeature.groupFractions[anchor.rawValue] ?? 0.5,
            hasWorkbenchBackground: model.workbenchBackgroundFeature.hasImage,
            showsFrameGradient: usesIDEAFrameExperiment,
            drag: toolWindowDrag,
            commitFraction: { model.workbenchFeature.setGroupFraction($0, for: anchor) },
            content: { group in
                toolContent(model.workbenchFeature.activeTool(in: .init(anchor: anchor, group: group)))
            }
        )
    }

    @ViewBuilder
    private func toolContent(_ tool: WorkbenchFeatureModel.ToolWindow?) -> some View {
        if tool == .references { LanguageReferencesView() }
        else if tool == .spring { SpringEndpointsView() }
        else if let tool, let entry = contribution(for: tool), let renderer = moduleUIRegistry.renderer(for: entry) {
            let content = ModuleToolContent(rendererID: renderer.id,
                contentIdentity: renderer.contentIdentity(model), content: renderer.content(model)).equatable()
            if tool == .gitLog || tool == .terminal {
                RetainedWorkbenchToolPane(store: toolContentStore, tool: tool, content: content
                    .environmentObject(model).environmentObject(settings).environmentObject(projectSessions)
                    .environment(\.projectWindowScope, projectWindowScope),
                    contentIdentity: renderer.contentIdentity(model),
                    onActivate: tool == .terminal ? { model.activeToolTerminalSession?.focus() } : nil,
                    showsFrameGradient: usesIDEAFrameExperiment)
            } else {
                content
            }
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
            // Through the app model so JDT is asked which classes can be launched.
            await model.generateRunConfigurations()
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
        ideaAssetPath: String,
        icon: AnyView? = nil,
        help: String,
        tooltipPlacement: WorkbenchHoverTooltipPlacement = .trailing,
        isSelected: Bool,
        isDragging: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if let icon { icon } else {
                LitheIDEAIcon(resourcePath: ideaAssetPath, size: ActivityBarMetrics.iconSize)
            }
        }
        .buttonStyle(LitheActivityBarButtonStyle(isSelected: isSelected, isDragging: isDragging))
        .workbenchHoverHelp(Text(LocalizedStringKey(help)), placement: tooltipPlacement)
        .accessibilityLabel(Text(LocalizedStringKey(help)))
    }

    @ViewBuilder
    private var workspaceArea: some View {
        workspaceContent
            .task(id: didRestoreLayout ? model.workspaceURL?.standardizedFileURL.path : nil) {
                guard didRestoreLayout else { return }
                await model.restoreVisibleToolModules()
            }
    }

    private var workspaceContent: some View {
        WorkbenchWorkspaceSplitView(
            sidebarWidth: sidebarWidth,
            isSidebarVisible: hasVisibleTool(on: .left),
            rightToolWidth: mavenPaneWidth,
            isRightToolVisible: hasVisibleTool(on: .right),
            topPaneHeight: topPaneHeight,
            isBottomToolVisible: isBottomToolVisible,
            actions: WorkbenchWorkspaceSplitActions(
                onSidebarWidthCommitted: { width in
                    sidebarWidth = width
                    saveLayout(sidebarWidth: width, topPaneHeight: topPaneHeight)
                },
                onTopPaneHeightCommitted: { height in
                    topPaneHeight = height
                    saveLayout(sidebarWidth: sidebarWidth, topPaneHeight: height)
                },
                onBottomToolMinimize: {
                    model.closeGitLog()
                },
                onRightToolWidthCommitted: { width in
                    mavenPaneWidth = width
                    saveLayout(sidebarWidth: sidebarWidth, topPaneHeight: topPaneHeight)
                }
            ),
            showsBottomToolMinimize: model.workbenchFeature.isVisible(.gitLog) && model.workbenchFeature.state(for: .gitLog).position.anchor == .bottom,
            hasWorkbenchBackground: model.workbenchBackgroundFeature.hasImage,
            showsFrameGradient: usesIDEAFrameExperiment,
            sidebar: {
                dockContent(on: .left)
            },
            editor: {
                Group {
                    if model.workbenchFeature.isVisible(.pullRequests) {
                        if LitheFeatureAvailability.githubPullRequests {
                            GitHubPullRequestDetailView()
                        } else {
                            GitHubFeatureUnavailableView()
                        }
                    } else {
                        EditorAreaView()
                    }
                }
                .background(ToolWindowWorkspaceAnchor(drag: toolWindowDrag, region: .editor))
            },
            bottomTool: { dockContent(on: .bottom) },
            rightTool: { dockContent(on: .right) }
        )
        .background(ToolWindowWorkspaceAnchor(drag: toolWindowDrag, sideWidths: [.left: sidebarWidth, .right: mavenPaneWidth]))
    }

    @ViewBuilder
    private var toolWindowDropOverlay: some View {
        if toolWindowDrag.source != nil, toolWindowDrag.targetsEditor {
            GeometryReader { geometry in
                let leading = hasVisibleTool(on: .left) ? min(sidebarWidth, geometry.size.width) : 0
                let trailing = hasVisibleTool(on: .right) ? min(mavenPaneWidth, geometry.size.width - leading) : 0
                let height = isBottomToolVisible ? min(topPaneHeight ?? geometry.size.height * 2 / 3, geometry.size.height)
                    : geometry.size.height
                Rectangle().fill(LitheTheme.toolWindowDropArea)
                    .overlay {
                        Text("Open in Editor")
                            .font(LitheTheme.uiFont(size: 12))
                            .padding(8).background(LitheTheme.raised).cornerRadius(6)
                    }
                    .frame(width: max(0, geometry.size.width - leading - trailing), height: height)
                    .position(x: leading + (geometry.size.width - leading - trailing) / 2, y: height / 2)
            }
        } else if toolWindowDrag.source != nil, let target = toolWindowDrag.target {
            GeometryReader { _ in
                let frame = toolWindowDrag.previewFrame(for: target)
                let workspace = toolWindowDrag.workspaceFrame

                Rectangle().fill(LitheTheme.toolWindowDropArea)
                    .overlay {
                        Text(LocalizedStringKey(dockMoveTitle(target.position)))
                            .font(LitheTheme.uiFont(size: 12))
                            .padding(8).background(LitheTheme.raised).cornerRadius(6)
                    }
                    .frame(width: max(0, frame.width), height: max(0, frame.height))
                    .position(x: frame.midX - workspace.minX, y: workspace.maxY - frame.midY)
            }
        }
    }

    private var isBottomToolVisible: Bool {
        hasVisibleTool(on: .bottom)
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
        .background(frameChromeBackground)
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
        .buttonStyle(.litheNoPress)
        .lithePointer()
        .help(LocalizedStringKey(title))
    }

    private var breadcrumbSeparator: some View {
        Image(systemName: "chevron.right")
            .font(LitheTheme.uiFont(size: 7, weight: .semibold))
            .foregroundStyle(LitheTheme.secondaryText.opacity(0.72))
    }

    private var detailedStatusItems: some View {
        HStack(spacing: 14) {
            EditorCaretPositionLabel(chrome: model.editorChrome) { model.showGoToLine() }
            if let document = model.activeDocument, document.url.isFileURL {
                LitheMenu {
                    LitheContextMenuItem.heading("Reopen with Encoding")

                    for descriptor in DocumentEncoding.catalog.filter(\.supportsRead) {
                        let encoding = descriptor.id
                        LitheContextMenuItem.action(
                            descriptor.displayName, checked: document.readEncoding == encoding
                        ) {
                            model.reopenDocument(document, with: encoding)
                        }
                    }

                    LitheContextMenuItem.separator

                    LitheContextMenuItem.heading("Save with Encoding")

                    for descriptor in DocumentEncoding.catalog.filter(\.supportsWrite) {
                        let encoding = descriptor.id
                        LitheContextMenuItem.action(
                            descriptor.displayName, checked: document.saveEncoding == encoding
                        ) {
                            model.saveDocument(document, encoding: encoding)
                        }
                        .disabled(document.isReadOnly)
                    }

                } label: {
                    Text(document.readEncoding.displayName)
                }
                .buttonStyle(.litheNoPress)
                .fixedSize()
                .help("File encoding")
            }
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
            ProjectPreparationStatusView(compact: true)
            MemoryUsageStatusView()
            FrameRateStatusView()
            gitStatus
        }
    }

    private var compactStatusItems: some View {
        HStack(spacing: 10) {
            EditorCaretPositionLabel(chrome: model.editorChrome) { model.showGoToLine() }
            ProjectPreparationStatusView(compact: true)
            MemoryUsageStatusView()
            FrameRateStatusView()
            gitStatus
        }
    }

    private var gitStatus: some View {
        HStack(spacing: 7) {
            if model.workbenchFeature.isVisible(.references) {
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
        mavenPaneWidth = CGFloat(layout.mavenPaneWidth ?? WorkbenchLayout.defaultMavenPaneWidth)
        branchPopupHeight = layout.branchPopupHeight.map { CGFloat($0) }
        branchPopupWidth = layout.branchPopupWidth.map { CGFloat($0) } ?? LitheDropdownMetrics.branchMinimumWidth
        didRestoreLayout = true
        let sidebarIDs = layout.isSidebarVisible == true ? [layout.sidebarToolWindowID].compactMap { $0 } : []
        let dockIDs = layout.toolWindows?.filter(\.isVisible).map { WorkbenchFeatureModel.ToolWindow.restoredID($0.id) }
        model.restoreRegisteredToolWindows(dockIDs ?? ((layout.visibleToolWindowIDs ?? []) + sidebarIDs))
    }

    private func saveLayout(sidebarWidth: CGFloat, topPaneHeight: CGFloat?) {
        guard didRestoreLayout, let workspaceURL = model.workspaceURL else { return }
        model.saveWorkbenchLayout(
            WorkbenchLayout(
                sidebarWidth: Double(sidebarWidth),
                topPaneHeight: topPaneHeight.map(Double.init),
                mavenPaneWidth: Double(mavenPaneWidth),
                branchPopupWidth: Double(branchPopupWidth),
                branchPopupHeight: branchPopupHeight.map { Double($0) }
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
    @Environment(\.locale) private var locale

    /// Repeats of one message stay a single row whose text carries the count.
    private func message(for notification: WorkbenchNotification) -> String {
        WorkbenchNotificationPresentation.message(
            notification.message,
            arguments: notification.arguments,
            occurrenceCount: notification.occurrenceCount,
            locale: locale
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notifications")
                    .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)

                Spacer()

                Button("Clear All") {
                    model.clearNotifications()
                }
                .buttonStyle(.litheNoPress)
                .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
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
                        .font(LitheTheme.uiFont(size: 22, weight: .regular))
                        .foregroundStyle(LitheTheme.tertiaryText)
                    Text("No notifications")
                        .font(LitheTheme.uiFont(size: 12))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.notifications) { notification in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "info.circle.fill")
                                    .font(LitheTheme.uiFont(size: 13))
                                    .foregroundStyle(LitheTheme.accent)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(message(for: notification))
                                        .font(LitheTheme.uiFont(size: 12))
                                        .foregroundStyle(LitheTheme.primaryText)
                                        .fixedSize(horizontal: false, vertical: true)

                                    Text(notification.updatedAt.formatted(date: .omitted, time: .shortened))
                                        .font(LitheTheme.uiFont(size: 10.5))
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
        .onAppear {
            model.markAllNotificationsRead()
        }
        .onChange(of: model.notifications.count) { _ in
            model.markAllNotificationsRead()
        }
    }
}

/// The callbacks the workspace split view hands back to the workbench.
///
/// Grouped into one value, following `GitGraphRowActions`, so the split view
/// carries a single stored property instead of three freshly allocated escaping
/// closures per parent body pass.
private struct WorkbenchWorkspaceSplitActions {
    let onSidebarWidthCommitted: (CGFloat) -> Void
    let onTopPaneHeightCommitted: (CGFloat) -> Void
    let onBottomToolMinimize: () -> Void
    let onRightToolWidthCommitted: (CGFloat) -> Void
}

private struct WorkbenchWorkspaceSplitView<Sidebar: View, Editor: View, BottomTool: View, RightTool: View>: View {
    let sidebarWidth: CGFloat
    let isSidebarVisible: Bool
    let rightToolWidth: CGFloat
    let isRightToolVisible: Bool
    let topPaneHeight: CGFloat?
    let isBottomToolVisible: Bool
    let actions: WorkbenchWorkspaceSplitActions
    let showsBottomToolMinimize: Bool
    let hasWorkbenchBackground: Bool
    let showsFrameGradient: Bool
    let sidebar: Sidebar
    let editor: Editor
    let bottomTool: BottomTool
    let rightTool: RightTool

    @State private var liveSidebarWidth: CGFloat
    @State private var liveTopPaneHeight: CGFloat?

    init(
        sidebarWidth: CGFloat,
        isSidebarVisible: Bool,
        rightToolWidth: CGFloat,
        isRightToolVisible: Bool,
        topPaneHeight: CGFloat?,
        isBottomToolVisible: Bool,
        actions: WorkbenchWorkspaceSplitActions,
        showsBottomToolMinimize: Bool,
        hasWorkbenchBackground: Bool,
        showsFrameGradient: Bool,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder editor: () -> Editor,
        @ViewBuilder bottomTool: () -> BottomTool,
        @ViewBuilder rightTool: () -> RightTool
    ) {
        self.sidebarWidth = sidebarWidth
        self.isSidebarVisible = isSidebarVisible
        self.rightToolWidth = rightToolWidth
        self.isRightToolVisible = isRightToolVisible
        self.topPaneHeight = topPaneHeight
        self.isBottomToolVisible = isBottomToolVisible
        self.actions = actions
        self.showsBottomToolMinimize = showsBottomToolMinimize
        self.hasWorkbenchBackground = hasWorkbenchBackground
        self.showsFrameGradient = showsFrameGradient
        self.sidebar = sidebar()
        self.editor = editor()
        self.bottomTool = bottomTool()
        self.rightTool = rightTool()
        _liveSidebarWidth = State(initialValue: sidebarWidth)
        _liveTopPaneHeight = State(initialValue: topPaneHeight)
    }

    var body: some View {
        let _ = LitheSignpost.bodyEvaluated("WorkbenchWorkspaceSplitView")
        GeometryReader { geometry in
            let contentWidth = max(0, geometry.size.width - WorkbenchWorkspaceMetrics.paneInset * 2)
            let resolvedRightToolWidth = isRightToolVisible ? WorkbenchRightToolGeometry.resolvedWidth(
                rightToolWidth, in: contentWidth, sidebarWidth: sidebarWidth, isSidebarVisible: isSidebarVisible
            ) : 0
            let availableTopWidth = max(
                0,
                contentWidth - WorkbenchWorkspaceMetrics.paneSpacing
                    - (isRightToolVisible ? resolvedRightToolWidth + WorkbenchWorkspaceMetrics.paneSpacing : 0)
            )
            let minimumEditorWidth = CGFloat(WorkbenchLayout.minimumPaneSize)
            let maximumSidebarWidth = max(0, availableTopWidth - minimumEditorWidth)
            let minimumSidebarWidth = min(CGFloat(WorkbenchLayout.minimumPaneSize), maximumSidebarWidth)
            let resolvedSidebarWidth = constrained(
                liveSidebarWidth,
                minimum: minimumSidebarWidth,
                maximum: maximumSidebarWidth
            )

            let availablePaneHeight = max(0, geometry.size.height - WorkbenchWorkspaceMetrics.paneSpacing)
            let minimumTopPaneHeight = min(
                WorkbenchWorkspaceMetrics.minimumPaneHeight,
                availablePaneHeight / 2
            )
            let maximumTopPaneHeight = availablePaneHeight - minimumTopPaneHeight
            let resolvedTopPaneHeight = constrained(
                liveTopPaneHeight ?? max(255, geometry.size.height * 0.40),
                minimum: minimumTopPaneHeight,
                maximum: maximumTopPaneHeight
            )

            let editorPane = editor
                .workbenchResizablePaneChrome(
                    background: hasWorkbenchBackground ? Color.clear : LitheTheme.editor,
                    surrounding: hasWorkbenchBackground ? Color.clear : LitheTheme.titlebar,
                    roundsCorners: !hasWorkbenchBackground,
                    showsFrameGradient: showsFrameGradient
                )
            let mainContent: AnyView = isSidebarVisible ? AnyView(
                LitheSplitPaneView(
                    axis: .horizontal,
                    placement: .leading,
                    defaultSize: resolvedSidebarWidth,
                    minimum: minimumSidebarWidth,
                    maximum: maximumSidebarWidth,
                    clipsSizedPane: true,
                    trackBackground: hasWorkbenchBackground ? LitheTheme.titlebar.opacity(0.7) : .clear,
                    showsIdleDivider: false,
                    onCommit: { width in
                        guard liveSidebarWidth <= maximumSidebarWidth || width < maximumSidebarWidth else { return }
                        actions.onSidebarWidthCommitted(width)
                    },
                    sized: {
                        sidebar
                    },
                    flexible: {
                        editorPane
                    }
                )
            ) : AnyView(editorPane)
            let topContent: AnyView = isRightToolVisible ? AnyView(
                WorkbenchRightToolSplitView(
                    width: rightToolWidth,
                    sidebarWidth: sidebarWidth,
                    isSidebarVisible: isSidebarVisible,
                    hasWorkbenchBackground: hasWorkbenchBackground,
                    showsFrameGradient: showsFrameGradient,
                    onCommit: actions.onRightToolWidthCommitted,
                    workspace: { mainContent },
                    tool: { rightTool }
                )
            ) : mainContent

            Group {
                if isBottomToolVisible {
                    LitheSplitPaneView(
                        axis: .vertical,
                        placement: .leading,
                        defaultSize: resolvedTopPaneHeight,
                        minimum: minimumTopPaneHeight,
                        maximum: maximumTopPaneHeight,
                        flexibleMinimum: 0,
                        clipsSizedPane: true,
                        trackBackground: hasWorkbenchBackground ? LitheTheme.titlebar.opacity(0.7) : .clear,
                        showsIdleDivider: false,
                        onCommit: { height in
                            guard (liveTopPaneHeight ?? 0) <= maximumTopPaneHeight
                                    || height < maximumTopPaneHeight else { return }
                            actions.onTopPaneHeightCommitted(height)
                        },
                        sized: {
                            topContent
                                .padding(.horizontal, WorkbenchWorkspaceMetrics.paneInset)
                                .padding(.top, WorkbenchWorkspaceMetrics.paneInset)
                        },
                        flexible: {
                            bottomTool
                                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                                .clipped()
                                .padding(.horizontal, WorkbenchWorkspaceMetrics.paneInset)
                                .padding(.bottom, WorkbenchWorkspaceMetrics.paneInset)
                        }
                    )
                } else {
                    topContent
                        .padding(.horizontal, WorkbenchWorkspaceMetrics.paneInset)
                        .padding(.vertical, WorkbenchWorkspaceMetrics.paneInset)
                }
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .topLeading
            )
            .background(hasWorkbenchBackground || showsFrameGradient ? Color.clear : LitheTheme.titlebar)
            // Keep the workspace as a live view hierarchy. `drawingGroup()`
            // cannot composite AppKit-backed editors, fields, checkboxes, or
            // terminals and replaces them with unavailable placeholders. It
            // also rasterizes vector activity-bar icons at inconsistent sizes.
        }
        // Committing a drag round-trips through the workbench and back down as a
        // prop. Without these guards that echo writes the value this view just
        // set, invalidating it a second time for no change.
        .onChange(of: sidebarWidth) { newWidth in
            guard newWidth != liveSidebarWidth else { return }
            liveSidebarWidth = newWidth
        }
        .onChange(of: topPaneHeight) { newHeight in
            guard newHeight != liveTopPaneHeight else { return }
            liveTopPaneHeight = newHeight
        }
    }

    private func constrained(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}

extension View {
    /// Position pane notches at the visible drag width, not the content's intrinsic width.
    func workbenchResizablePaneChrome(
        background: Color,
        surrounding: Color,
        alignment: Alignment = .topLeading,
        roundsCorners: Bool = true,
        showsFrameGradient: Bool = false
    ) -> some View {
        GeometryReader { proxy in
            self
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: alignment)
                .workbenchPaneChrome(
                    background: background,
                    surrounding: surrounding,
                    roundsCorners: roundsCorners,
                    showsFrameGradient: showsFrameGradient
                )
        }
    }

    /// Draws pane rounding without masking AppKit-backed editor and tool views.
    func workbenchPaneChrome(
        background: Color,
        surrounding: Color,
        roundsCorners: Bool = true,
        showsFrameGradient: Bool = false,
        frameInWorkbench: CGRect? = nil
    ) -> some View {
        modifier(
            WorkbenchPaneChromeModifier(
                background: background,
                surrounding: surrounding,
                roundsCorners: roundsCorners,
                showsFrameGradient: showsFrameGradient,
                frameInWorkbench: frameInWorkbench
            )
        )
    }
}

private struct WorkbenchPaneChromeModifier: ViewModifier {
    let background: Color
    let surrounding: Color
    let roundsCorners: Bool
    let showsFrameGradient: Bool
    let frameInWorkbench: CGRect?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workbenchToolbarGlow) private var toolbarGlow

    @ViewBuilder
    func body(content: Content) -> some View {
        if roundsCorners {
            // Four fixed-size corner notches instead of one pane-sized even-odd
            // fill. The notch geometry only depends on the corner radius, so it
            // is built once and merely repositioned while a pane resizes, rather
            // than re-tessellating a full-pane vector path every frame. Absolute
            // positioning (not leading/trailing alignment) keeps the notches on
            // the same physical corners the previous fill used.
            content
                .background(background)
                .overlay {
                    GeometryReader { proxy in
                        let radius = WorkbenchWorkspaceMetrics.paneCornerRadius
                        let half = radius / 2
                        let paneFrame = frameInWorkbench ?? proxy.frame(in: .named(WorkbenchFrameGradient.coordinateSpace))
                        ZStack {
                            notch(.topLeading, offset: paneFrame.origin).position(x: half, y: half)
                            notch(.topTrailing, offset: CGPoint(x: paneFrame.maxX - radius, y: paneFrame.minY))
                                .position(x: proxy.size.width - half, y: half)
                            notch(.bottomLeading, offset: CGPoint(x: paneFrame.minX, y: paneFrame.maxY - radius))
                                .position(x: half, y: proxy.size.height - half)
                            notch(.bottomTrailing, offset: CGPoint(x: paneFrame.maxX - radius, y: paneFrame.maxY - radius))
                                .position(x: proxy.size.width - half, y: proxy.size.height - half)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        } else {
            content.background(background)
        }
    }

    @ViewBuilder
    private func notch(_ corner: WorkbenchPaneCornerGeometry.Corner, offset: CGPoint) -> some View {
        let shape = WorkbenchPaneCornerNotch(corner: corner)
        if showsFrameGradient {
            shape.fill(WorkbenchFrameGradient.color(
                glow: toolbarGlow,
                background: Color(nsColor: LitheTheme.nsColor(.titlebar, isDark: colorScheme == .dark)),
                at: CGPoint(
                    x: offset.x + WorkbenchWorkspaceMetrics.paneCornerRadius / 2,
                    y: offset.y + WorkbenchWorkspaceMetrics.paneCornerRadius / 2
                )
            ))
                .frame(width: WorkbenchWorkspaceMetrics.paneCornerRadius, height: WorkbenchWorkspaceMetrics.paneCornerRadius)
        } else {
            shape.fill(surrounding)
                .frame(width: WorkbenchWorkspaceMetrics.paneCornerRadius, height: WorkbenchWorkspaceMetrics.paneCornerRadius)
        }
    }
}

/// One corner of the gap between a pane's square bounds and its rounded
/// silhouette, painted in the surrounding color so the pane reads as rounded
/// without clipping the AppKit-backed content inside it.
///
/// The path is a compile-time constant: the radius is fixed, so every instance
/// reuses the same geometry and resizing a pane only moves it.
private struct WorkbenchPaneCornerNotch: Shape {
    let corner: WorkbenchPaneCornerGeometry.Corner

    /// Ignores `rect` because the caller always frames this at exactly
    /// `paneCornerRadius` square; honoring an arbitrary rect would mean
    /// rebuilding the path on every layout, which is the cost being removed.
    func path(in rect: CGRect) -> Path {
        WorkbenchPaneCornerGeometry.path(for: corner)
    }
}

/// Pure geometry for the four pane corner notches, separated from the `Shape`
/// so the arc direction can be verified without rendering.
enum WorkbenchPaneCornerGeometry {
    enum Corner: CaseIterable {
        case topLeading
        case topTrailing
        case bottomLeading
        case bottomTrailing
    }

    /// The notch path in a `radius`-square box, cached per corner.
    static func path(for corner: Corner) -> Path {
        paths[corner] ?? Path()
    }

    private static let radius = WorkbenchWorkspaceMetrics.paneCornerRadius

    private static let paths: [Corner: Path] = Dictionary(
        uniqueKeysWithValues: Corner.allCases.map { ($0, makePath(for: $0, radius: radius)) }
    )

    static func makePath(for corner: Corner, radius: CGFloat) -> Path {
        // The arc is centered on the box corner diagonally opposite the pane
        // corner being rounded, so it stays tangent to both pane edges.
        let center: CGPoint
        let start: CGPoint
        let end: CGPoint
        switch corner {
        case .topLeading:
            center = CGPoint(x: radius, y: radius)
            start = CGPoint(x: radius, y: 0)
            end = CGPoint(x: 0, y: radius)
        case .topTrailing:
            center = CGPoint(x: 0, y: radius)
            start = CGPoint(x: 0, y: 0)
            end = CGPoint(x: radius, y: radius)
        case .bottomLeading:
            center = CGPoint(x: radius, y: 0)
            start = CGPoint(x: radius, y: radius)
            end = CGPoint(x: 0, y: 0)
        case .bottomTrailing:
            center = CGPoint(x: 0, y: 0)
            start = CGPoint(x: 0, y: radius)
            end = CGPoint(x: radius, y: 0)
        }

        // Quarter arc as a cubic Bézier. Building it from the two tangent points
        // rather than sweep angles keeps the direction unambiguous in SwiftUI's
        // y-down space, where `clockwise:` reads inverted.
        let handle = radius * 0.5522847498307936
        let startTangent = unitTangent(from: center, through: start, toward: end)
        let endTangent = unitTangent(from: center, through: end, toward: start)

        var path = Path()
        path.move(to: paneCorner(for: corner, radius: radius))
        path.addLine(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(
                x: start.x + startTangent.dx * handle,
                y: start.y + startTangent.dy * handle
            ),
            control2: CGPoint(
                x: end.x + endTangent.dx * handle,
                y: end.y + endTangent.dy * handle
            )
        )
        path.closeSubpath()
        return path
    }

    /// The square corner the notch fills in, in box-local coordinates.
    private static func paneCorner(for corner: Corner, radius: CGFloat) -> CGPoint {
        switch corner {
        case .topLeading: CGPoint(x: 0, y: 0)
        case .topTrailing: CGPoint(x: radius, y: 0)
        case .bottomLeading: CGPoint(x: 0, y: radius)
        case .bottomTrailing: CGPoint(x: radius, y: radius)
        }
    }

    /// Unit tangent to the circle at `point`, oriented so the arc sweeps toward
    /// `destination` along the 90-degree side.
    private static func unitTangent(
        from center: CGPoint,
        through point: CGPoint,
        toward destination: CGPoint
    ) -> CGVector {
        let radial = CGVector(dx: point.x - center.x, dy: point.y - center.y)
        // Rotating the radius by 90 degrees gives the tangent; the sign that
        // points at the other endpoint is the one that sweeps the minor arc.
        let candidate = CGVector(dx: -radial.dy, dy: radial.dx)
        let towardDestination = CGVector(
            dx: destination.x - point.x,
            dy: destination.y - point.y
        )
        let alignment = candidate.dx * towardDestination.dx + candidate.dy * towardDestination.dy
        let length = max(hypot(radial.dx, radial.dy), 0.0001)
        let sign: CGFloat = alignment >= 0 ? 1 : -1
        return CGVector(dx: sign * candidate.dx / length, dy: sign * candidate.dy / length)
    }
}

private struct WorkbenchBackgroundImageView: View {
    let image: NSImage?
    let opacity: Double
    let showsIDEAFrameGradient: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workbenchToolbarGlow) private var toolbarGlow

    var body: some View {
        ZStack {
            LitheTheme.window

            if showsIDEAFrameGradient {
                LitheTheme.titlebar
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 0) {
                            LinearGradient(
                                colors: [LitheTheme.titlebar, toolbarGlow],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: WorkbenchTopBarMetrics.projectAvatarCenterX)
                            LinearGradient(
                                colors: [toolbarGlow, LitheTheme.titlebar],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: WorkbenchFrameGradient.width)
                        }
                        .frame(height: WorkbenchFrameGradient.height)
                        .overlay {
                            LinearGradient(
                                colors: [.clear, LitheTheme.titlebar],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                    }
            }

            if let image {
                // Fill and clip at the container instead of measuring with a
                // GeometryReader, so a window resize no longer re-evaluates a
                // geometry closure just to restate the size the layout offers.
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .opacity(opacity)
            }

            // Preserve the source image's colour while keeping text legible.
            // Soft-light compositing against the dark theme muted bright images
            // twice, so a single contrast veil produces the intended wallpaper
            // effect at the full 100% setting.
            if !showsIDEAFrameGradient {
                (colorScheme == .dark ? Color.black.opacity(0.46) : Color.white.opacity(0.25))
            }
        }
        .clipped()
        // Deliberately not a compositing group: no group-wide opacity or blend
        // mode is applied here, so flattening these layers offscreen changed
        // nothing visually while forcing the whole window to recomposite on
        // every resize.
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
                    .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .litheIconButton()
                .help("Close")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Built-in backgrounds")
                    .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
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
                    .buttonStyle(.litheNoPress)
                    .foregroundStyle(LitheTheme.accent)
                    .lithePointer()
                }

                Spacer(minLength: 0)

                Text(model.workbenchBackgroundFeature.displayName ?? "No background image selected")
                    .font(LitheTheme.uiFont(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: 112, alignment: .trailing)
            }

            if settings.hasConfiguredWorkbenchBackground {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Workbench background opacity")
                            .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
                        Spacer()
                        Text("\(Int((settings.workbenchBackgroundOpacity * 100).rounded()))%")
                            .font(LitheTheme.uiFont(size: 11.5, design: .monospaced))
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                    Slider(value: $settings.workbenchBackgroundOpacity, in: 0.05...1.0, step: 0.01)
                }
            }
        }
        .padding(14)
        .frame(width: 356)
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
                    .font(LitheTheme.uiFont(size: 10.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? LitheTheme.primaryText : LitheTheme.secondaryText)
            }
            .frame(width: 100)
        }
        .buttonStyle(.litheNoPress)
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

/// Marks a project tab whose Agent conversation waits for a permission decision.
private struct AgentAttentionIndicator: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.agentConversationNeedsAttention {
            Circle()
                .fill(LitheTheme.accent)
                .frame(width: 6, height: 6)
                .help("The Agent is waiting for your permission")
                .accessibilityLabel("The Agent is waiting for your permission")
        }
    }
}
