import SwiftUI
import AppKit
import LitheCoreContracts
import LitheDebugModule

struct GenericDebugView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: GenericDebugFeatureModel
    @State private var performanceExpanded = false
    @State private var performanceWidth: CGFloat = 360
    @State private var inspectorWidth: CGFloat?
    @State private var watchesHeight: CGFloat?
    @State private var stackListActive = false
    @State private var showsStackSourceName = true
    @State private var debugToolActive = false
    @State private var evaluateExpression = ""
    @State private var showsVariableJSON = true
    @State private var editingVariable: DebugVariable?
    @State private var watchEditor: WatchEditorContext?
    @State private var smartStepTargets: [DebugStepInTarget] = []
    @State private var isSmartStepPickerPresented = false
    @State private var isJavaAttachPresented = false
    @State private var isJavaSteppingSettingsPresented = false
    @State private var selectedContent: DebugContent = .console
    @State private var consoleWrapsLines = false
    @State private var consolePresentation = ConsoleFoldPresentation()

    var body: some View {
        VStack(spacing: 0) {
            header
            if feature.showsEmptyState {
                emptyState
            } else {
                debugToolbar
                activeContent
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .background(LitheToolWindowActivityTracker(isActive: $debugToolActive))
        .sheet(item: $editingVariable) { variable in
            VariableValueEditorView(variable: variable) {
                feature.setVariable(variable, value: $0)
            }
        }
        .sheet(isPresented: $isJavaAttachPresented) {
            JavaAttachView { host, port in
                model.attachJavaDebugger(host: host, port: port)
            }
        }
        .sheet(isPresented: $isJavaSteppingSettingsPresented) {
            if let filters = feature.javaSteppingFilters {
                JavaSteppingFiltersView(
                    filters: filters,
                    onSave: feature.updateJavaSteppingFilters,
                    onReset: feature.resetJavaSteppingFilters
                )
            }
        }
        .onAppear { synchronizePerformanceSession() }
        .onChange(of: feature.activeSessionID) { _ in synchronizePerformanceSession() }
        .onDisappear { model.debugPerformanceFeature.setVisible(false) }
        .onChange(of: feature.state) { state in
            synchronizePerformanceSession()
            switch state {
            case .paused:
                selectedContent = .debugger
            case .initializing, .launching, .failed:
                selectedContent = .console
            default:
                break
            }
        }

    }

    private func synchronizePerformanceSession() {
        model.debugPerformanceFeature.select(sessionID: feature.activeSessionID?.rawValue,
            isActive: feature.isSessionActive)
    }

    @ViewBuilder
    private var activeContent: some View {
        switch selectedContent {
        case .debugger:
            inspector
        case .console:
            debugConsole
        }
    }

    private var contentTabs: some View {
        HStack(spacing: 0) {
            ForEach(DebugContent.allCases) { content in
                Button {
                    selectedContent = content
                } label: {
                    Text(content.title)
                        .font(LitheTheme.uiFont(size: 13))
                        .foregroundStyle(LitheTheme.primaryText)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .modifier(LitheToolWindowTabStyle(
                    isSelected: selectedContent == content, isActive: debugToolActive
                ))
                .padding(.horizontal, 4)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Debug")
                .font(LitheTheme.uiFont(size: 13, weight: .bold))
                .foregroundStyle(LitheTheme.primaryText)
                .padding(.trailing, 16)
            if !feature.showsEmptyState {
                if let sessionTitle = debugSessionTitle {
                    debugSessionTab(sessionTitle).padding(.horizontal, 4)
                }
                if feature.sessionSummaries.count > 1 { sessionPicker }
            }
            Spacer(minLength: 12)
            debugOptionsMenu.padding(.horizontal, 2)
            LitheSidebarHideButton(title: "Debug") {
                model.workbenchFeature.setVisibility(.debug, isVisible: false)
            }
            .padding(.horizontal, 2)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 41)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
        .overlay(alignment: .bottom) { LitheToolWindowHeaderDivider() }
    }

    private var debugSessionTitle: String? {
        if let targetTitle = feature.targetTitle, !targetTitle.isEmpty {
            return targetTitle
        }
        if let providerID = feature.providerID, !providerID.isEmpty {
            return providerID.uppercased()
        }
        if let selectedConfiguration = model.runFeatureIfActive?.selectedConfiguration,
           !selectedConfiguration.name.isEmpty {
            return selectedConfiguration.name
        }
        return nil
    }

    private func debugSessionTab(_ title: String) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                LitheIDEAIcon(
                    resourcePath: "debugger/debug.svg", size: 16,
                    fallbackSystemImage: "ladybug", preservesOriginalColors: true
                )
                Text(title)
                    .font(LitheTheme.uiFont(size: 13))
                    .lineLimit(1)
            }
            .padding(.leading, 8)
            .padding(.trailing, feature.isSessionActive ? 3 : 8)
            if feature.isSessionActive {
                LitheToolWindowTabCloseButton(action: stopActiveDebugSession)
                    .help("Stop debug session")
                    .accessibilityLabel("Stop debug session")
            }
        }
        .foregroundStyle(LitheTheme.primaryText)
        .modifier(LitheToolWindowTabStyle(isSelected: true, isActive: debugToolActive))
    }

    private var sessionPicker: some View {
        LitheMenu {
            LitheContextMenuItem.heading("Sessions")

            for summary in feature.sessionSummaries {
                LitheContextMenuItem.action(
                    sessionLabel(summary) + " · " + summary.state.title,
                    systemImage: summary.id == feature.activeSessionID
                        ? "checkmark.circle.fill" : "circle"
                ) {
                    _ = feature.selectSession(summary.id)
                }
            }

            if feature.sessionSummaries.count > 1 {
                LitheContextMenuItem.separator
                LitheContextMenuItem.heading("Close other sessions")

                for summary in (feature.sessionSummaries.filter { $0.id != feature.activeSessionID }) {
                    LitheContextMenuItem.action("Stop \(sessionLabel(summary))", role: .destructive) {
                        feature.stopSession(summary.id)
                    }
                }

            }
        } label: {
            LitheIDEAIcon(
                resourcePath: "debugger/threads.svg",
                size: 14,
                fallbackSystemImage: "square.stack.3d.up",
                preservesOriginalColors: true
            )
        }
        .litheIconButton()
        .help("Debug sessions")
        .accessibilityLabel("Debug sessions")
    }

    private func sessionLabel(_ summary: DebugSessionSummary) -> String {
        let rootName = summary.rootURL.lastPathComponent.isEmpty
            ? summary.rootURL.path
            : summary.rootURL.lastPathComponent
        if let targetTitle = summary.targetTitle, !targetTitle.isEmpty {
            return "\(targetTitle) · \(rootName)"
        }
        return "\(summary.providerDisplayName) · \(rootName)"
    }

    private var debugToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(DebugToolbarPresentation.primaryActions) { action in
                    debugToolbarActionButton(action)
                    if DebugToolbarPresentation.separatorsAfter.contains(action) {
                        toolbarDivider
                    }
                }
                if feature.canUpdateJavaService {
                    Button { model.applyDebugServiceUpdate() } label: {
                        Image(systemName: "bolt.fill")
                    }
                    .litheToolbarIconButton()
                    .padding(.horizontal, 2)
                    .disabled(feature.updatingServiceSessionID != nil)
                    .help("Apply code changes to this service")
                    .accessibilityLabel("Apply code changes")
                }
                if feature.serviceUpdateFailed && feature.canUpdateJavaService {
                    Button("Restart service") { model.restartUpdatedDebugService() }
                        .disabled(feature.updatingServiceSessionID != nil)
                }
                if let message = feature.serviceUpdateMessage {
                    Text(message).font(.caption).lineLimit(1).help(message)
                }
                debugOptionsMenu.padding(.horizontal, 2)
                contentTabs
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .frame(height: DebugToolbarPresentation.toolbarHeight)
        }
        .litheWorkbenchSurface(LitheTheme.toolHeader)
        .overlay(alignment: .bottom) { LitheToolWindowHeaderDivider() }
        .litheDropdown(isPresented: $isSmartStepPickerPresented) {
            smartStepPicker
        }
    }

    private func debugToolbarActionButton(_ action: DebugToolbarActionID) -> some View {
        let isDisabled = isDebugToolbarActionDisabled(action)
        return Button {
            performDebugToolbarAction(action)
        } label: {
            LitheIDEAIcon(
                resourcePath: DebugToolbarPresentation.ideaAssetPath(
                    for: action,
                    isSessionActive: feature.isSessionActive
                ),
                size: DebugToolbarPresentation.iconSize,
                fallbackSystemImage: DebugToolbarPresentation.fallbackSystemImage(for: action),
                preservesOriginalColors: true,
                usesIDEADisabledAppearance: true
            )
            .frame(width: DebugToolbarPresentation.iconSize, height: DebugToolbarPresentation.iconSize)
        }
        .buttonStyle(LitheIconButtonStyle(size: LitheTheme.Metrics.toolbarIconButtonSize, disabledOpacity: 1, cornerRadius: 4, hoverBackground: LitheTheme.toolbarHoverBackground, pressedBackground: LitheTheme.toolbarPressedBackground))
        .padding(.horizontal, 2)
        .disabled(isDisabled)
        .help(debugToolbarActionHelp(action))
        .accessibilityLabel(debugToolbarActionHelp(action))
        .accessibilityIdentifier("debug-toolbar-\(action.rawValue)")
    }

    private func performDebugToolbarAction(_ action: DebugToolbarActionID) {
        switch action {
        case .restartOrStart:
            if feature.isSessionActive {
                feature.execute(.restart)
            } else if feature.canRetry {
                _ = feature.retry()
            } else {
                model.startDebugging()
            }
        case .stop:
            stopActiveDebugSession()
        case .resume:
            feature.execute(.continueExecution)
        case .pause:
            feature.execute(.pause)
        case .stepOver:
            feature.execute(.next)
        case .stepInto:
            feature.execute(.stepIn)
        case .stepOut:
            feature.execute(.stepOut)
        case .viewBreakpoints:
            model.showDebugBreakpointManager()
        case .muteBreakpoints:
            feature.toggleBreakpointMute()
        }
    }

    private func isDebugToolbarActionDisabled(_ action: DebugToolbarActionID) -> Bool {
        switch action {
        case .restartOrStart:
            feature.isSessionActive && !feature.canRestart
        case .stop:
            !feature.isSessionActive
        case .resume:
            feature.state != .paused || feature.isExecutionRequestPending
        case .pause:
            feature.state != .running || feature.isExecutionRequestPending
        case .stepOver, .stepInto, .stepOut:
            // DAP step requests require a concrete stopped thread. Keep the
            // toolbar disabled during the short inspection window after a
            // stop event instead of sending a no-op request with no thread.
            feature.state != .paused || feature.selectedThreadID == nil
                || feature.isExecutionRequestPending
        case .viewBreakpoints:
            model.workspaceURL == nil
        case .muteBreakpoints:
            feature.breakpoints.isEmpty
        }
    }

    private func debugToolbarActionHelp(_ action: DebugToolbarActionID) -> String {
        let title: String
        switch action {
        case .restartOrStart:
            title = feature.isSessionActive ? "Rerun" : feature.canRetry ? "Retry debugging" : "Start debugging"
        case .stop: title = "Stop debugging"
        case .resume: title = "Resume"
        case .pause: title = "Pause"
        case .stepOver: title = "Step over"
        case .stepInto: title = "Step into"
        case .stepOut: title = "Step out"
        case .viewBreakpoints: title = "View breakpoints"
        case .muteBreakpoints:
            title = feature.areBreakpointsMuted ? "Enable breakpoints" : "Mute breakpoints"
        }
        guard let commandID = debugToolbarCommandID(for: action),
              let shortcut = model.keyboardShortcutFeature.displayText(for: commandID),
              !shortcut.isEmpty else {
            return title
        }
            return "\(title) (\(shortcut))"
    }

    private func debugToolbarCommandID(for action: DebugToolbarActionID) -> String? {
        switch action {
        case .restartOrStart: "debug"
        case .stop: "stop-debug"
        case .resume: "debug-resume"
        case .pause: nil
        case .stepOver: "debug-step-over"
        case .stepInto: "debug-step-into"
        case .stepOut: "debug-step-out"
        case .viewBreakpoints: "view-breakpoints"
        case .muteBreakpoints: nil
        }
    }

    private func stopActiveDebugSession() {
        if feature.canTerminate {
            feature.execute(.terminate)
        } else {
            model.stopDebugging()
        }
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(LitheTheme.ActionToolbar.separator)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 3)
    }

    private var debugOptionsMenu: some View {
        LitheMenu {
            if feature.capabilities.supportsStepInTargetsRequest {
                LitheContextMenuItem.action("Smart Step Into") { requestSmartStepInto() }
                    .disabled(feature.state != .paused || feature.selectedFrameID == nil)
            }
            if feature.capabilities.supportsStepBack {
                LitheContextMenuItem.action("Step Back") { feature.execute(.stepBack) }
                    .disabled(!feature.canStepBack)
            }
            if feature.javaSteppingFilters != nil {
                LitheContextMenuItem.action("Java Stepping Filters…") {
                    isJavaSteppingSettingsPresented = true
                }
                .disabled(feature.isSessionActive)
            }
            LitheContextMenuItem.separator
            LitheContextMenuItem.action("Connect to Running JVM…") { isJavaAttachPresented = true }
                .disabled(feature.isSessionActive)
            LitheContextMenuItem.action("Clear Console") { feature.clearOutput() }
                .disabled(!feature.hasOutput)
        } label: {
            LitheIDEAIcon(
                resourcePath: "expui/general/moreVertical.svg",
                size: 16,
                fallbackSystemImage: "ellipsis",
                preservesOriginalColors: true
            )
        }
        .litheToolbarIconButton()
        .help("More Debug actions")
        .accessibilityLabel("More Debug actions")
    }

    private func requestSmartStepInto() {
        feature.requestSmartStepInto { result in
            guard case .success(let targets) = result else { return }
            if targets.count == 1, let target = targets.first {
                feature.smartStepInto(target)
            } else {
                smartStepTargets = targets
                isSmartStepPickerPresented = true
            }
        }
    }

    private var smartStepPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Choose Step Target")
                .font(LitheTheme.uiFont(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.top, 6)
            if smartStepTargets.isEmpty {
                Text("No callable target at this location")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .padding(8)
            } else {
                ForEach(smartStepTargets) { target in
                    Button(target.label) {
                        feature.smartStepInto(target)
                        isSmartStepPickerPresented = false
                    }
                    .buttonStyle(.litheNoPress)
                    .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 230)
        .padding(.vertical, 4)
    }

    private var inspector: some View {
        GeometryReader { geometry in
            LitheSplitPaneView(axis: .horizontal, placement: .leading,
                defaultSize: inspectorWidth ?? geometry.size.width / 3,
                minimum: 240, maximum: max(240, geometry.size.width - 300), flexibleMinimum: 300,
                dividerColor: LitheTheme.toolWindowBorder(for: colorScheme),
                onCommit: { inspectorWidth = $0 }) {
                executionInspector
                    .background(LitheToolWindowActivityTracker(isActive: $stackListActive))
            } flexible: {
                dataInspector
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    private var executionInspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                threadPicker
                Spacer(minLength: 0)
                stackPresentationMenu
                    .padding(.trailing, LitheTheme.Tree.horizontalInset)
            }
            divider
            if feature.stackFrames.isEmpty {
                LitheToolWindowStatusText("Frames are not available")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if feature.areFilteredStackFramesExpanded,
                           feature.hiddenStackFrameCount > 0 {
                            Button {
                                feature.collapseFilteredStackFrames()
                            } label: {
                                HStack(spacing: 6) {
                                    LitheIDEAIcon(resourcePath: "expui/general/collapseAll.svg", size: 16, preservesOriginalColors: true)
                                    Text("Collapse filtered frames")
                                }
                                    .font(LitheTheme.uiFont(size: 13))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: 27)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.litheNoPress)
                        }
                        ForEach(feature.visibleStackFrameRows) { row in
                            if let frame = row.frame {
                                rowButton(selected: feature.selectedFrameID == frame.id) {
                                    feature.selectFrame(frame)
                                    if let sourceURL = frame.sourceURL {
                                        model.revealDebugLocation(
                                            url: sourceURL,
                                            line: frame.line,
                                            column: frame.column
                                        )
                                    }
                                } label: {
                                    if frame.isFiltered {
                                        LitheIDEAIcon(resourcePath: "expui/general/moreHorizontal.svg", size: 16,
                                                          preservesOriginalColors: true)
                                    }
                                    Text(DebugToolbarPresentation.stackFrameText(frame,
                                        showsSourceName: showsStackSourceName, isDark: colorScheme == .dark))
                                        .font(LitheTheme.uiFont(size: 13, weight: .regular))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: LitheTheme.Tree.horizontalInset)
                                    if showsStackSourceName, let sourceURL = frame.sourceURL {
                                        Text(sourceURL.lastPathComponent)
                                            .font(LitheTheme.uiFont(size: 13, weight: .regular))
                                            .foregroundStyle(LitheTheme.Tree.secondaryText)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                .opacity(frame.isFiltered ? 0.58 : 1)
                                .litheContextMenu {
                                    var items: [LitheContextMenuItem] = []
                                    items.append(.action("Copy Method Name", action: {
                                        copyToPasteboard(frame.name)
                                    }))
                                    if let sourceURL = frame.sourceURL {
                                        items.append(.separator)
                                        items.append(.action("Copy Source Location", action: {
                                            copyToPasteboard(
                                                "\(sourceURL.path):\(frame.line):\(frame.column)"
                                            )
                                        }))
                                        items.append(.action("Copy Relative Location", action: {
                                            copyToPasteboard(
                                                "\(sourceURL.lastPathComponent):\(frame.line):\(frame.column)"
                                            )
                                        }))
                                    }
                                    return items
                                }
                            } else {
                                Button {
                                    feature.expandFilteredStackFrames()
                                } label: {
                                    HStack(spacing: 6) {
                                        LitheIDEAIcon(resourcePath: "expui/general/moreHorizontal.svg", size: 16, preservesOriginalColors: true)
                                        Text("\(row.hiddenFrameCount) hidden frames")
                                    }
                                    .font(LitheTheme.uiFont(size: 13))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: 27)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.litheNoPress)
                                .help("Show JDK, proxy, and framework frames")
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    private var stackPresentationMenu: some View {
        LitheMenu {
            LitheContextMenuItem.action("Show source file name", checked: showsStackSourceName) {
                showsStackSourceName.toggle()
            }
        } label: {
            LitheIDEAIcon(resourcePath: "expui/general/settings.svg",
                          size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
        }
        .litheToolbarIconButton()
        .help("Stack frame display options")
        .accessibilityLabel("Stack frame display options")
        .accessibilityIdentifier("debug-stack-display-options")
    }

    private var threadPicker: some View {
        LitheMenu {
            if feature.threads.isEmpty {
                LitheContextMenuItem.action("Load threads") { feature.inspectThreads() }
            } else {
                for thread in feature.threads {
                    LitheContextMenuItem.action(
                        thread.name,
                        icon: AnyView(
                            LitheIDEAIcon(
                                resourcePath: threadIconResourcePath(thread),
                                size: 16,
                                fallbackSystemImage: threadIcon(thread),
                                preservesOriginalColors: true
                            ))
                    ) {
                        feature.selectThread(thread)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                if let thread = selectedThread {
                    Text(thread.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(feature.state == .paused ? "Paused" : feature.state.title)
                        .font(LitheTheme.uiFont(size: 13))
                        .foregroundStyle(LitheTheme.secondaryText)
                } else {
                    Text(feature.threads.isEmpty ? "Load threads" : "Select thread")
                }
                LitheIDEAIcon(resourcePath: "expui/general/chevronDown.svg", size: 16,
                              preservesOriginalColors: true)
            }
            .font(LitheTheme.uiFont(size: 13, weight: .regular))
            .fontWeight(.regular)
            .foregroundStyle(LitheTheme.Tree.text)
            .padding(.horizontal, LitheTheme.Tree.horizontalInset)
            .frame(height: LitheTheme.Debugger.inspectorHeaderHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)

        .litheRowHover()
        .accessibilityLabel("Debugger thread")
        .litheContextMenu {
            var items: [LitheContextMenuItem] = []
            if let thread = selectedThread {
                items.append(.action("Copy Thread Name", action: { copyToPasteboard(thread.name) }))
                if feature.capabilities.supportsSingleThreadExecutionRequests {
                    items.append(.action(feature.state == .paused ? "Resume Thread" : "Pause Thread", isEnabled: !(feature.state != .paused && feature.state != .running), action: {
                        feature.executeThread(
                            feature.state == .paused ? .continueExecution : .pause,
                            thread: thread
                        )
                    }))
                }
            }
            return items
        }
    }

    private var selectedThread: DebugThread? {
        feature.threads.first { $0.id == feature.selectedThreadID }
    }

    private var dataInspector: some View {
        VStack(spacing: 0) {
            evaluateRow
            divider
            GeometryReader { geometry in
                LitheSplitPaneView(axis: .vertical, placement: .trailing,
                    defaultSize: watchesHeight ?? max(80, geometry.size.height * 0.28), minimum: 80,
                    maximum: max(80, geometry.size.height - 120), flexibleMinimum: 120,
                    dividerColor: LitheTheme.toolWindowBorder(for: colorScheme),
                    onCommit: { watchesHeight = $0 }) {
                    watchesInspector
                } flexible: {
                    variablesInspector
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .litheWorkbenchSurface(LitheTheme.sidebar)
        .background(LitheCenteredPopup(isPresented: Binding(
            get: { watchEditor != nil },
            set: { if !$0 { watchEditor = nil } }
        )) {
            if let context = watchEditor {
                WatchEditorView(watch: context.watch, onCancel: { watchEditor = nil }) { expression in
                    if let watch = context.watch {
                        feature.updateWatch(watch, expression: expression)
                    } else {
                        feature.addWatch(expression)
                    }
                    watchEditor = nil
                }
                .litheContextMenuSurface()
                .id(context.id)
            }
        }.frame(width: 0, height: 0).allowsHitTesting(false))
    }

    private var variablesInspector: some View {
        VStack(spacing: 0) {
            variablesHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let exceptionInfo = feature.exceptionInfo {
                        exceptionInspector(exceptionInfo)
                        divider
                    }
                    if showsVariableJSON && !feature.presentedVariables.isEmpty {
                        DebugVariableJSONView(feature: feature)
                    } else if !feature.visibleVariableRows.isEmpty {
                        ForEach(feature.visibleVariableRows) { row in
                            switch row.content {
                            case .variable(let variable):
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Group {
                                        if feature.isVariableLoading(variable) {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            LitheIDEAIcon(resourcePath: feature.isVariableExpanded(variable)
                                                ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg",
                                                size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
                                        }
                                    }
                                        .frame(width: LitheTheme.Tree.disclosureSlot)
                                        .opacity(variable.isExpandable ? 1 : 0)
                                    LitheIDEAIcon(
                                        resourcePath: variableIconResourcePath(variable),
                                        size: LitheTheme.Tree.iconSize,
                                        preservesOriginalColors: true
                                    )
                                    Text(variable.name)
                                        .font(LitheTheme.uiFont(size: 13, design: .monospaced))
                                        .foregroundStyle(LitheTheme.Tree.text)
                                    Text("=")
                                        .foregroundStyle(LitheTheme.secondaryText)
                                    Text(variable.value)
                                        .font(LitheTheme.uiFont(size: 13, design: .monospaced))
                                        .foregroundStyle(LitheTheme.Debugger.value)
                                        .lineLimit(2)
                                    if let type = variable.type, !type.isEmpty {
                                        Text(": \(type)")
                                            .font(LitheTheme.uiFont(size: 13, design: .monospaced))
                                            .foregroundStyle(LitheTheme.Debugger.type)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    feature.toggleVariableExpansion(variable)
                                }
                                .padding(.leading, LitheTheme.Tree.horizontalInset + CGFloat(row.depth) * LitheTheme.Tree.indent)
                                .padding(.trailing, 10)
                                .padding(.vertical, LitheTheme.Tree.verticalInset)
                                .frame(minHeight: LitheTheme.Tree.rowHeight)
                                .litheRowHover()
                                .litheContextMenu {
                                    var items: [LitheContextMenuItem] = []
                                    if feature.capabilities.supportsSetVariable,
                                       variable.containerReference != nil {
                                        items.append(.action("Set Value…", action: { editingVariable = variable }))
                                    }
                                    if feature.capabilities.supportsDataBreakpoints,
                                       variable.containerReference != nil {
                                        items.append(.action("Break on Field Access…", action: {
                                            feature.requestDataBreakpoint(for: variable)
                                        }))
                                    }
                                    items.append(.separator)
                                    items.append(.action("Copy Value", action: { copyToPasteboard(variable.value) }))
                                    items.append(.action("Copy Expression", action: {
                                        copyToPasteboard(variable.evaluateName ?? variable.name)
                                    }))
                                    items.append(.action("Copy Name", action: { copyToPasteboard(variable.name) }))
                                    if let expression = variable.evaluateName,
                                       !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        items.append(.separator)
                                        items.append(.action("Add to Watches", action: {
                                            feature.addWatch(expression)
                                        }))
                                    }
                                    return items
                                }
                            case .loadMore(let parentVariableID, let nextCount, let remainingCount):
                                variableLoadMoreRow(
                                    parentVariableID: parentVariableID,
                                    nextCount: nextCount,
                                    remainingCount: remainingCount,
                                    depth: row.depth
                                )
                            }
                        }
                    }

                }
            }
            .overlay {
                if feature.visibleVariableRows.isEmpty && feature.exceptionInfo == nil {
                    LitheToolWindowStatusText(feature.state == .paused
                        ? "Select a stack frame to inspect variables" : "Pause the process to inspect variables")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var watchesInspector: some View {
        VStack(spacing: 0) {
            watchSectionHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !feature.watches.isEmpty {
                        ForEach(feature.watches) { watch in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                LitheIDEAIcon(
                                    resourcePath: "expui/debugger/watch.svg",
                                    size: LitheTheme.Tree.iconSize,
                                    preservesOriginalColors: true
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(watch.expression)
                                        .font(LitheTheme.uiFont(size: 13, design: .monospaced))
                                        .foregroundStyle(LitheTheme.Tree.text)
                                        .lineLimit(1)
                                    if let error = watch.error {
                                        Text(error)
                                            .font(LitheTheme.uiFont(size: 13))
                                            .foregroundStyle(LitheTheme.error)
                                            .lineLimit(2)
                                    } else if let value = watch.value {
                                        HStack(spacing: 4) {
                                            Text(value)
                                                .foregroundStyle(LitheTheme.Debugger.value)
                                            if let type = watch.type {
                                                Text(type).foregroundStyle(LitheTheme.Debugger.type)
                                            }
                                        }
                                        .font(LitheTheme.uiFont(size: 13, design: .monospaced))
                                        .lineLimit(2)
                                    } else {
                                        Text(feature.state == .paused ? "Evaluating…" : "Not available")
                                            .font(LitheTheme.uiFont(size: 13))
                                            .foregroundStyle(LitheTheme.secondaryText)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .litheContextMenu {
                                var items: [LitheContextMenuItem] = []
                                items.append(.action("Refresh", isEnabled: !(feature.state != .paused), action: { feature.refreshWatches() }))
                                items.append(.action("Edit…", action: {
                                    watchEditor = WatchEditorContext(watch: watch)
                                }))
                                items.append(.separator)
                                items.append(.action("Remove", role: .destructive, action: {
                                    feature.removeWatch(watch)
                                }))
                                return items
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var variablesHeader: some View {
        HStack(spacing: 7) {
            Text("Variables")
                .font(LitheTheme.uiFont(size: 13, weight: .regular))
                .foregroundStyle(LitheTheme.Tree.text)
            Spacer(minLength: 0)
            if !feature.scopes.isEmpty {
                LitheMenu {
                    for scope in feature.scopes {
                        LitheContextMenuItem.action(
                            scope.name,
                            checked: feature.selectedScopeID == scope.id
                        ) {
                            feature.selectScope(scope)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedScopeName)
                            .lineLimit(1)
                        LitheIDEAIcon(resourcePath: "expui/general/chevronDown.svg", size: 16,
                                      preservesOriginalColors: true)
                    }
                    .font(LitheTheme.uiFont(size: 13))
                    .foregroundStyle(LitheTheme.secondaryText)
                }
                .buttonStyle(.litheNoPress)

                .accessibilityLabel("Variable scope")
            }
            Button { showsVariableJSON.toggle() } label: {
                LitheIDEAIcon(resourcePath: showsVariableJSON ? "expui/toolwindows/structure.svg" : "fileTypes/json.svg",
                              size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .help(showsVariableJSON ? "Show as tree" : "Show as JSON")
            .accessibilityLabel(showsVariableJSON ? "Show as tree" : "Show as JSON")
            .accessibilityIdentifier("debug-variable-view-toggle")
        }
        .padding(.horizontal, 10)
        .frame(height: LitheTheme.Debugger.inspectorHeaderHeight)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private var selectedScopeName: String {
        feature.scopes.first { $0.id == feature.selectedScopeID }?.name
            ?? feature.scopes.first?.name
            ?? "Scope"
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func exceptionInspector(_ info: DebugExceptionInfo) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Label("Exception", systemImage: "exclamationmark.octagon.fill")
                    .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                    .foregroundStyle(LitheTheme.error)
                Spacer(minLength: 8)
                Text(exceptionBreakModeTitle(info.breakMode))
                    .font(LitheTheme.uiFont(size: 13, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Text(info.exceptionID)
                .font(LitheTheme.uiFont(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(LitheTheme.primaryText)
                .textSelection(.enabled)
            if let description = info.description,
               !description.isEmpty,
               description != info.exceptionID {
                Text(description)
                    .font(LitheTheme.uiFont(size: 13, design: .monospaced))
                    .foregroundStyle(LitheTheme.warning)
                    .textSelection(.enabled)
            }
            if let details = info.details {
                if let message = details.message,
                   !message.isEmpty,
                   message != info.description {
                    Text(message)
                        .font(LitheTheme.uiFont(size: 13))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .textSelection(.enabled)
                }
                ForEach(Array(nestedExceptionDetails(details).enumerated()), id: \.offset) { _, cause in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(LitheTheme.uiFont(size: 8))
                            .foregroundStyle(LitheTheme.secondaryText)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(cause.fullTypeName ?? cause.typeName ?? "Nested exception")
                                .font(LitheTheme.uiFont(size: 13, weight: .medium, design: .monospaced))
                            if let message = cause.message, !message.isEmpty {
                                Text(message)
                                    .font(LitheTheme.uiFont(size: 13))
                                    .foregroundStyle(LitheTheme.secondaryText)
                            }
                        }
                    }
                }
                if let stackTrace = details.stackTrace, !stackTrace.isEmpty {
                    Text(stackTrace)
                        .font(LitheTheme.uiFont(size: 13, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(12)
                        .textSelection(.enabled)
                }
            }
        }
        .litheBannerSurface(.error, layout: .editor)
        .accessibilityElement(children: .contain)
    }

    private func nestedExceptionDetails(
        _ details: DebugExceptionDetails
    ) -> [DebugExceptionDetails] {
        details.innerExceptions.flatMap { [$0] + nestedExceptionDetails($0) }
    }

    private func exceptionBreakModeTitle(_ breakMode: String) -> String {
        switch breakMode {
        case "always": "Always break"
        case "unhandled": "Unhandled"
        case "userUnhandled": "User-unhandled"
        case "never": "Never break"
        default: breakMode
        }
    }

    private var evaluateRow: some View {
        HStack(spacing: 6) {
            LitheSearchTextField("Evaluate expression", text: $evaluateExpression)
                .font(LitheTheme.uiFont(size: 13, design: .monospaced))
                .onSubmit { evaluateInspectorExpression() }

            Button { addWatchExpression() } label: {
                LitheIDEAIcon(
                    resourcePath: "expui/debugger/addToWatch.svg",
                    size: 16,
                    fallbackSystemImage: "plus.circle",
                    preservesOriginalColors: true,
                    usesIDEADisabledAppearance: true
                )
            }
            .buttonStyle(LitheIconButtonStyle(size: LitheTheme.Metrics.toolbarIconButtonSize, disabledOpacity: 1, cornerRadius: 4))
            .disabled(evaluateExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Add watch")
            .accessibilityLabel("Add watch")
            .litheContextMenu {
                [
                    .action("Previous console expression", isEnabled: !feature.consoleHistory.isEmpty) {
                        if let expression = feature.previousConsoleExpression(current: evaluateExpression) {
                            evaluateExpression = expression
                        }
                    },
                    .action("Next console expression", isEnabled: !feature.consoleHistory.isEmpty) {
                        if let expression = feature.nextConsoleExpression() { evaluateExpression = expression }
                    }
                ]
            }
        }
        .padding(.horizontal, 10)
        .frame(height: LitheTheme.Debugger.inspectorHeaderHeight)
    }

    private func evaluateInspectorExpression() {
        guard feature.state == .paused,
              !evaluateExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        feature.evaluate(evaluateExpression)
        evaluateExpression = ""
        selectedContent = .console
    }

    private var watchSectionHeader: some View {
        HStack {
            Text("Watches")
                .font(LitheTheme.uiFont(size: 13, weight: .regular))
                .foregroundStyle(LitheTheme.Tree.text)
            Spacer()
            if !feature.watches.isEmpty {
                Button { feature.refreshWatches() } label: {
                    LitheIDEAIcon(
                        resourcePath: "expui/general/refresh.svg",
                        size: 16,
                        fallbackSystemImage: "arrow.clockwise",
                        preservesOriginalColors: true, usesIDEADisabledAppearance: true
                    )
                }
                .buttonStyle(LitheIconButtonStyle(size: LitheTheme.Metrics.toolbarIconButtonSize, disabledOpacity: 1, cornerRadius: 4))
                .disabled(feature.state != .paused || feature.watches.isEmpty)
                .help("Refresh watches")
            }
            Button { watchEditor = WatchEditorContext(watch: nil) } label: {
                LitheIDEAIcon(resourcePath: "expui/general/add.svg", size: 16,
                              fallbackSystemImage: "plus", preservesOriginalColors: true)
            }
            .buttonStyle(LitheIconButtonStyle(size: LitheTheme.Metrics.toolbarIconButtonSize, disabledOpacity: 1, cornerRadius: 4))
            .help("Add watch")

        }
        .padding(.horizontal, 10)
        .frame(height: LitheTheme.Debugger.inspectorHeaderHeight)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private func addWatchExpression() {
        feature.addWatch(evaluateExpression)
        evaluateExpression = ""
    }

    private var debugConsole: some View {
        VStack(spacing: 0) {
            if feature.stoppedReason != nil || feature.errorMessage != nil {
                debugConsoleStatus
                divider
            }
            DebugConsoleWithPerformance(feature: model.debugPerformanceFeature,
                isExpanded: $performanceExpanded, width: $performanceWidth) {
            DebugConsoleOutputView(
                presentation: feature.outputPresentation,
                consolePresentation: consolePresentation,
                wrapsLines: $consoleWrapsLines,
                onClearOutput: feature.clearOutput,
                standardInputSessionID: feature.activeSessionID?.rawValue,
                onSubmitStandardInput: feature.isSessionActive && model.isDebugStandardInputAvailable
                    ? { model.sendDebugStandardInput($0) } : nil,
                searchRoots: model.runFeatureIfActive?.sourceSearchRoots
                    ?? model.workspaceURL.map { [$0] }
                    ?? [],
                fileExists: { model.fileExists(at: $0) },
                onOpenLocation: { url, line, column in
                    model.openSourceLocation(url: url, line: line, column: column)
                }
            )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .litheWorkbenchSurface(LitheTheme.editor)
    }

    private var debugConsoleStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let stoppedReason = feature.stoppedReason {
                Label(stoppedReason, systemImage: "pause.circle.fill")
                    .font(LitheTheme.uiFont(size: 13, weight: .medium))
                    .foregroundStyle(LitheTheme.warning)
            }
            if let errorMessage = feature.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(LitheTheme.uiFont(size: 13))
                    .foregroundStyle(LitheTheme.error)

                HStack(spacing: 8) {
                    if feature.canRetry {
                        Button {
                            _ = feature.retry()
                        } label: {
                            Label("Retry Debug", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("debug-error-retry")
                    }

                    if !model.workbenchFeature.isVisible(.run) {
                        Button {
                            model.toggleRun()
                        } label: {
                            Label("Open Run Configuration", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("debug-error-open-run-configuration")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .litheWorkbenchSurface(LitheTheme.editor)
    }

    private var emptyState: some View {
        // ActivateDebugToolWindowAction + StatusText: left-aligned lines, above center.
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: LitheTheme.ToolWindowEmptyState.lineSpacing) {
                Text("To debug your code, do one of the following:")
                    .frame(height: LitheTheme.ToolWindowEmptyState.rowHeight)
                Text("— Click the Run icon in the editor gutter")
                    .frame(height: LitheTheme.ToolWindowEmptyState.rowHeight)
                Text("— Select \"Debug...\" in the editor context menu")
                    .frame(height: LitheTheme.ToolWindowEmptyState.rowHeight)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("— Launch a")
                    Button("run configuration") {
                        if !model.workbenchFeature.isVisible(.run) { model.toggleRun() }
                    }
                }
                .frame(height: LitheTheme.ToolWindowEmptyState.rowHeight)
                Color.clear.frame(width: 0, height: LitheTheme.ToolWindowEmptyState.rowHeight)
                    .accessibilityHidden(true)
                Link(destination: URL(string: "https://www.jetbrains.com/help/idea/debugging-code.html")!) {
                    HStack(spacing: 2) {
                        LitheIDEAIcon(resourcePath: "general/contextHelp.svg", size: 16, preservesOriginalColors: true)
                            .accessibilityHidden(true)
                        Text("Debugging code")
                    }
                }
                .frame(height: LitheTheme.ToolWindowEmptyState.rowHeight)
            }
            .font(LitheTheme.uiFont(size: LitheTheme.ToolWindowEmptyState.fontSize, weight: .regular))
            .foregroundStyle(LitheTheme.ToolWindowEmptyState.text)
            .buttonStyle(LitheToolWindowEmptyLinkStyle())
            .tint(LitheTheme.ToolWindowEmptyState.link)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(LitheTheme.uiFont(size: 10.5, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
            Text(String(count))
                .font(LitheTheme.uiFont(size: 9.5, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .padding(.horizontal, 10)
        .frame(height: 27)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private func variableIconResourcePath(_ variable: DebugVariable) -> String {
        feature.automaticVariables.contains(where: { $0.id == variable.id })
            ? "expui/debugger/watch.svg"
            : variable.name == "this" ? "expui/nodes/variable.svg" : "expui/nodes/field.svg"
    }

    private func threadIcon(_ thread: DebugThread) -> String {
        if feature.stoppedThreadIDs.contains(thread.id) {
            return feature.selectedThreadID == thread.id
                ? "pause.circle.fill"
                : "pause.circle"
        }
        return "play.circle"
    }

    private func threadIconResourcePath(_ thread: DebugThread) -> String {
        if feature.selectedThreadID == thread.id,
           feature.stoppedThreadIDs.contains(thread.id) {
            return "expui/debugger/threadCurrent.svg"
        }
        return feature.stoppedThreadIDs.contains(thread.id)
            ? "expui/debugger/threads.svg"
            : "expui/debugger/threadRunning.svg"
    }

    private func threadColor(_ thread: DebugThread) -> Color {
        feature.stoppedThreadIDs.contains(thread.id)
            ? LitheTheme.warning
            : LitheTheme.secondaryText
    }

    private func variableLoadMoreRow(
        parentVariableID: String?,
        nextCount: Int,
        remainingCount: Int?,
        depth: Int
    ) -> some View {
        let isLoading = feature.isVariablePageLoading(parentVariableID: parentVariableID)
        return Button {
            feature.loadMoreVariables(parentVariableID: parentVariableID)
        } label: {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    LitheIDEAIcon(
                        resourcePath: "actions/more.svg",
                        size: 12,
                        fallbackSystemImage: "ellipsis.circle",
                        preservesOriginalColors: true
                    )
                }
                Text(isLoading ? "Loading…" : "Load \(nextCount) more")
                    .font(LitheTheme.smallFont)
                if let remainingCount, !isLoading {
                    Text("\(remainingCount) remaining")
                        .font(LitheTheme.uiFont(size: 9.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(.leading, 10 + CGFloat(depth * 14))
            .padding(.trailing, 10)
            .frame(minHeight: 27)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .disabled(isLoading)
        .accessibilityLabel(isLoading ? "Loading debugger variables" : "Load more debugger variables")
    }

    private var divider: some View {
        LitheToolWindowHeaderDivider()
    }

    private func rowButton<Label: View>(
        selected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                label()
            }
            .font(LitheTheme.uiFont(size: 13, weight: .regular))
            .fontWeight(.regular)
            .foregroundStyle(LitheTheme.Tree.text)
            .padding(.horizontal, LitheTheme.Tree.horizontalInset)
            .frame(minHeight: LitheTheme.Tree.rowHeight)
            .litheSelectionRow(isSelected: selected, isFocused: stackListActive)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
    }
}

struct DebugBreakpointManagerDialog: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var feature: GenericDebugFeatureModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                LitheIDEAIcon(
                    resourcePath: "toolwindows/toolWindowDebugger.svg",
                    size: 18,
                    fallbackSystemImage: "circle.fill"
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text("Breakpoints")
                        .font(LitheTheme.uiFont(size: 14, weight: .semibold))
                    Text("Manage project breakpoints without starting a debug session")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer(minLength: 16)
                Button(
                    feature.areBreakpointsMuted
                        ? "Unmute Line Breakpoints"
                        : "Mute Line Breakpoints"
                ) {
                    feature.toggleBreakpointMute()
                }
                .disabled(feature.breakpoints.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .litheWorkbenchSurface(LitheTheme.toolHeader)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            DebugBreakpointManagerView(feature: feature, onNavigate: { dismiss() })
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 500, idealHeight: 580)
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }
}

struct DebugBreakpointManagerView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: GenericDebugFeatureModel
    let onNavigate: (() -> Void)?

    @State private var editingBreakpoint: GenericDebugBreakpoint?
    @State private var editingExceptionBreakpoint: GenericDebugExceptionBreakpoint?
    @State private var functionBreakpointEditor: FunctionBreakpointEditorContext?
    @State private var editingDataBreakpoint: GenericDebugDataBreakpoint?

    init(
        feature: GenericDebugFeatureModel,
        onNavigate: (() -> Void)? = nil
    ) {
        self.feature = feature
        self.onNavigate = onNavigate
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sourceBreakpointHeader
                if feature.breakpoints.isEmpty {
                    placeholder("Click the editor gutter to add a breakpoint")
                } else {
                    ForEach(feature.breakpoints) { breakpoint in
                        sourceBreakpointRow(breakpoint)
                    }
                }

                if !feature.exceptionBreakpoints.isEmpty {
                    divider
                    sectionHeader("Exception Breakpoints", count: feature.exceptionBreakpoints.count)
                    ForEach(feature.exceptionBreakpoints) { breakpoint in
                        exceptionBreakpointRow(breakpoint)
                    }
                }

                if feature.capabilities.supportsFunctionBreakpoints
                    || !feature.functionBreakpoints.isEmpty {
                    divider
                    functionBreakpointHeader
                    if feature.functionBreakpoints.isEmpty {
                        placeholder("Add a class or method name")
                    } else {
                        ForEach(feature.functionBreakpoints) { breakpoint in
                            functionBreakpointRow(breakpoint)
                        }
                    }
                }

                if feature.capabilities.supportsDataBreakpoints
                    || !feature.dataBreakpoints.isEmpty {
                    divider
                    sectionHeader("Field Breakpoints", count: feature.dataBreakpoints.count)
                    if feature.dataBreakpoints.isEmpty {
                        placeholder("Right-click a field while paused to add a breakpoint")
                    } else {
                        ForEach(feature.dataBreakpoints) { breakpoint in
                            dataBreakpointRow(breakpoint)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .litheWorkbenchSurface(LitheTheme.sidebar)
        .sheet(item: $editingBreakpoint) { breakpoint in
            BreakpointEditorView(
                breakpoint: breakpoint,
                supportsCondition: !feature.capabilities.negotiated
                    || feature.capabilities.supportsConditionalBreakpoints,
                supportsHitCondition: !feature.capabilities.negotiated
                    || feature.capabilities.supportsHitConditionalBreakpoints,
                supportsLogMessage: !feature.capabilities.negotiated
                    || feature.capabilities.supportsLogPoints
            ) {
                feature.updateBreakpoint(
                    fileURL: breakpoint.fileURL,
                    line: breakpoint.line,
                    enabled: $0.enabled,
                    condition: $0.condition,
                    hitCondition: $0.hitCondition,
                    logMessage: $0.logMessage
                )
            }
        }
        .sheet(item: $editingExceptionBreakpoint) { breakpoint in
            ExceptionBreakpointEditorView(breakpoint: breakpoint) {
                feature.updateExceptionBreakpoint(
                    breakpoint,
                    enabled: $0.enabled,
                    condition: $0.condition
                )
            }
        }
        .sheet(item: $functionBreakpointEditor) { context in
            FunctionBreakpointEditorView(breakpoint: context.breakpoint) { value in
                if let breakpoint = context.breakpoint {
                    feature.updateFunctionBreakpoint(
                        breakpoint,
                        name: value.name,
                        enabled: value.enabled,
                        condition: value.condition,
                        hitCondition: value.hitCondition
                    )
                } else {
                    feature.addFunctionBreakpoint(
                        name: value.name,
                        condition: value.condition,
                        hitCondition: value.hitCondition
                    )
                }
            }
        }
        .sheet(item: $editingDataBreakpoint) { breakpoint in
            DataBreakpointEditorView(breakpoint: breakpoint) { value in
                feature.updateDataBreakpoint(
                    breakpoint,
                    enabled: value.enabled,
                    accessType: value.accessType,
                    condition: value.condition,
                    hitCondition: value.hitCondition
                )
            }
        }
    }

    private var sourceBreakpointHeader: some View {
        HStack {
            Text("Line Breakpoints")
                .font(LitheTheme.uiFont(size: 10.5, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
            Text(String(feature.breakpoints.count))
                .font(LitheTheme.uiFont(size: 9.5, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
            LitheMenu {
                LitheContextMenuItem.action(
                    feature.areBreakpointsMuted
                        ? "Unmute Line Breakpoints"
                        : "Mute Line Breakpoints"
                ) {
                    feature.toggleBreakpointMute()
                }
                LitheContextMenuItem.action("Remove All", role: .destructive) {
                    feature.removeAllBreakpoints()
                }
                .disabled(feature.breakpoints.isEmpty)
            } label: {
                LitheIDEAIcon(
                    resourcePath: feature.areBreakpointsMuted
                        ? "debugger/muteBreakpoints.svg"
                        : "actions/moreVertical.svg",
                    size: 14,
                    fallbackSystemImage: feature.areBreakpointsMuted
                        ? "speaker.slash.fill" : "ellipsis",
                    preservesOriginalColors: true
                )
            }
            .buttonStyle(.litheNoPress)
            .fixedSize()
            .help("Breakpoint actions")
            .accessibilityLabel("Line breakpoint actions")
        }
        .padding(.horizontal, 10)
        .frame(height: 29)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private var functionBreakpointHeader: some View {
        HStack {
            Text("Method Breakpoints")
                .font(LitheTheme.uiFont(size: 10.5, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
            Text(String(feature.functionBreakpoints.count))
                .font(LitheTheme.uiFont(size: 9.5, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
            Button {
                functionBreakpointEditor = FunctionBreakpointEditorContext(breakpoint: nil)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.litheNoPress)
            .help("Add method breakpoint")
            .accessibilityLabel("Add method breakpoint")
        }
        .padding(.horizontal, 10)
        .frame(height: 29)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private func sourceBreakpointRow(_ breakpoint: GenericDebugBreakpoint) -> some View {
        HStack(spacing: 7) {
            Button {
                feature.setBreakpointEnabled(breakpoint, enabled: !breakpoint.enabled)
            } label: {
                if breakpoint.isLogpoint {
                    Image(systemName: breakpointSymbol(breakpoint))
                        .font(LitheTheme.uiFont(size: 9))
                        .foregroundStyle(breakpointColor(breakpoint))
                } else {
                    let asset = LitheIcons.debuggerBreakpointAssetPath(
                        enabled: breakpoint.enabled,
                        verified: breakpoint.verified,
                        muted: feature.areBreakpointsMuted
                    )
                    LitheIDEAIcon(
                        resourcePath: asset,
                        size: 13,
                        fallbackSystemImage: breakpointSymbol(breakpoint),
                        preservesOriginalColors: true
                    )
                }
            }
            .buttonStyle(.litheNoPress)
            .help(breakpoint.enabled ? "Disable breakpoint" : "Enable breakpoint")
            .accessibilityLabel(breakpoint.enabled ? "Disable breakpoint" : "Enable breakpoint")
            Button {
                model.openSourceLocation(
                    url: breakpoint.fileURL,
                    line: breakpoint.resolvedLine ?? breakpoint.line,
                    column: breakpoint.column ?? 1
                )
                onNavigate?()
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(breakpoint.title)
                        .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                        .lineLimit(1)
                    if let detail = breakpointDetail(breakpoint) {
                        Text(detail)
                            .font(LitheTheme.uiFont(size: 9.5, design: .monospaced))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.litheNoPress)
            .accessibilityLabel("Open \(breakpoint.title)")
            LitheMenu {
                LitheContextMenuItem.action("Edit…") { editingBreakpoint = breakpoint }
                LitheContextMenuItem.action(breakpoint.enabled ? "Disable" : "Enable") {
                    feature.setBreakpointEnabled(breakpoint, enabled: !breakpoint.enabled)
                }
                LitheContextMenuItem.separator
                LitheContextMenuItem.action("Remove", role: .destructive) {
                    feature.removeBreakpoint(breakpoint)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(.litheNoPress)
            .fixedSize()
            .accessibilityLabel("Actions for \(breakpoint.title)")
        }
        .help(breakpoint.message ?? breakpoint.title)
        .padding(.horizontal, 10)
        .frame(minHeight: 33)
        .opacity(breakpoint.enabled && !feature.areBreakpointsMuted ? 1 : 0.55)
        .litheContextMenu {
            var items: [LitheContextMenuItem] = []
            items.append(.action("Edit…", action: { editingBreakpoint = breakpoint }))
            items.append(.action(breakpoint.enabled ? "Disable" : "Enable", action: {
                feature.setBreakpointEnabled(breakpoint, enabled: !breakpoint.enabled)
            }))
            items.append(.separator)
            items.append(.action("Remove", role: .destructive, action: { feature.removeBreakpoint(breakpoint) }))
            return items
        }
    }

    private func exceptionBreakpointRow(
        _ breakpoint: GenericDebugExceptionBreakpoint
    ) -> some View {
        HStack(spacing: 7) {
            Button {
                feature.updateExceptionBreakpoint(
                    breakpoint,
                    enabled: !breakpoint.enabled,
                    condition: breakpoint.condition
                )
            } label: {
                Image(systemName: breakpoint.enabled ? "bolt.circle.fill" : "bolt.circle")
                    .font(LitheTheme.uiFont(size: 10))
                    .foregroundStyle(breakpoint.enabled ? LitheTheme.error : LitheTheme.secondaryText)
            }
            .buttonStyle(.litheNoPress)
            .accessibilityLabel(
                breakpoint.enabled
                    ? "Disable \(breakpoint.label) exception breakpoint"
                    : "Enable \(breakpoint.label) exception breakpoint"
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(breakpoint.label).font(LitheTheme.uiFont(size: 11)).lineLimit(1)
                if let condition = breakpoint.condition {
                    Text("If: \(condition)")
                        .font(LitheTheme.uiFont(size: 9.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if breakpoint.supportsCondition {
                Button { editingExceptionBreakpoint = breakpoint } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(.litheNoPress)
                .help("Edit exception breakpoint")
                .accessibilityLabel("Edit \(breakpoint.label) exception breakpoint")
            }
        }
        .help(breakpoint.description ?? breakpoint.label)
        .padding(.horizontal, 10)
        .frame(minHeight: 33)
        .opacity(breakpoint.enabled ? 1 : 0.55)
    }

    private func functionBreakpointRow(
        _ breakpoint: GenericDebugFunctionBreakpoint
    ) -> some View {
        HStack(spacing: 7) {
            Button {
                feature.setFunctionBreakpointEnabled(breakpoint, enabled: !breakpoint.enabled)
            } label: {
                Image(systemName: "function")
                    .font(LitheTheme.uiFont(size: 10, weight: .semibold))
                    .foregroundStyle(
                        breakpoint.enabled
                            ? (breakpoint.verified ? LitheTheme.error : LitheTheme.warning)
                            : LitheTheme.secondaryText
                    )
            }
            .buttonStyle(.litheNoPress)
            .accessibilityLabel(
                breakpoint.enabled
                    ? "Disable \(breakpoint.name) method breakpoint"
                    : "Enable \(breakpoint.name) method breakpoint"
            )
            Button {
                functionBreakpointEditor = FunctionBreakpointEditorContext(breakpoint: breakpoint)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(breakpoint.name)
                        .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                        .lineLimit(1)
                    if let detail = functionBreakpointDetail(breakpoint) {
                        Text(detail)
                            .font(LitheTheme.uiFont(size: 9.5, design: .monospaced))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.litheNoPress)
            .accessibilityLabel("Edit \(breakpoint.name) method breakpoint")
            LitheMenu {
                LitheContextMenuItem.action("Edit…") {
                    functionBreakpointEditor = FunctionBreakpointEditorContext(breakpoint: breakpoint)
                }
                LitheContextMenuItem.action(breakpoint.enabled ? "Disable" : "Enable") {
                    feature.setFunctionBreakpointEnabled(breakpoint, enabled: !breakpoint.enabled)
                }
                LitheContextMenuItem.separator
                LitheContextMenuItem.action("Remove", role: .destructive) {
                    feature.removeFunctionBreakpoint(breakpoint)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(.litheNoPress)
            .fixedSize()
            .accessibilityLabel("Actions for \(breakpoint.name) method breakpoint")
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 33)
        .opacity(breakpoint.enabled ? 1 : 0.55)
    }

    private func dataBreakpointRow(_ breakpoint: GenericDebugDataBreakpoint) -> some View {
        HStack(spacing: 7) {
            Button {
                feature.setDataBreakpointEnabled(breakpoint, enabled: !breakpoint.enabled)
            } label: {
                LitheIDEAIcon(
                    resourcePath: "nodes/field.svg",
                    size: 13,
                    fallbackSystemImage: "eye.circle.fill",
                    preservesOriginalColors: true
                )
            }
            .buttonStyle(.litheNoPress)
            .accessibilityLabel(
                breakpoint.enabled
                    ? "Disable \(breakpoint.label) field breakpoint"
                    : "Enable \(breakpoint.label) field breakpoint"
            )
            Button { editingDataBreakpoint = breakpoint } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(breakpoint.label)
                        .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                        .lineLimit(1)
                    Text(dataBreakpointDetail(breakpoint))
                        .font(LitheTheme.uiFont(size: 9.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.litheNoPress)
            .accessibilityLabel("Edit \(breakpoint.label) field breakpoint")
            LitheMenu {
                LitheContextMenuItem.action("Edit…") { editingDataBreakpoint = breakpoint }
                LitheContextMenuItem.action(breakpoint.enabled ? "Disable" : "Enable") {
                    feature.setDataBreakpointEnabled(breakpoint, enabled: !breakpoint.enabled)
                }
                LitheContextMenuItem.separator
                LitheContextMenuItem.action("Remove", role: .destructive) {
                    feature.removeDataBreakpoint(breakpoint)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(.litheNoPress)
            .fixedSize()
            .accessibilityLabel("Actions for \(breakpoint.label) field breakpoint")
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 33)
        .opacity(breakpoint.enabled ? 1 : 0.55)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(LitheTheme.uiFont(size: 10.5, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
            Text(String(count))
                .font(LitheTheme.uiFont(size: 9.5, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .padding(.horizontal, 10)
        .frame(height: 29)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private func breakpointSymbol(_ breakpoint: GenericDebugBreakpoint) -> String {
        if breakpoint.isLogpoint { return breakpoint.enabled ? "diamond.fill" : "diamond" }
        return breakpoint.enabled ? "circle.fill" : "circle"
    }

    private func breakpointColor(_ breakpoint: GenericDebugBreakpoint) -> Color {
        guard breakpoint.enabled, !feature.areBreakpointsMuted else {
            return LitheTheme.secondaryText
        }
        if breakpoint.isLogpoint { return LitheTheme.accent }
        return breakpoint.verified ? LitheTheme.error : LitheTheme.warning
    }

    private func breakpointDetail(_ breakpoint: GenericDebugBreakpoint) -> String? {
        if let logMessage = breakpoint.logMessage {
            return String(format: String(localized: "Log: %@"), logMessage)
        }
        if let condition = breakpoint.condition {
            return String(format: String(localized: "If: %@"), condition)
        }
        if let hitCondition = breakpoint.hitCondition {
            return String(format: String(localized: "Hit: %@"), hitCondition)
        }
        return breakpoint.message
            ?? String(localized: breakpoint.verified ? "Verified" : "Pending verification")
    }

    private func functionBreakpointDetail(
        _ breakpoint: GenericDebugFunctionBreakpoint
    ) -> String? {
        if let condition = breakpoint.condition {
            return String(format: String(localized: "If: %@"), condition)
        }
        if let hitCondition = breakpoint.hitCondition {
            return String(format: String(localized: "Hit: %@"), hitCondition)
        }
        return breakpoint.message
            ?? String(localized: breakpoint.verified ? "Verified" : "Pending verification")
    }

    private func dataBreakpointDetail(_ breakpoint: GenericDebugDataBreakpoint) -> String {
        var parts = [breakpoint.accessType ?? "access"]
        if let condition = breakpoint.condition { parts.append("if \(condition)") }
        if let hitCondition = breakpoint.hitCondition { parts.append("hit \(hitCondition)") }
        if let message = breakpoint.message { parts.append(message) }
        if breakpoint.message == nil {
            parts.append(breakpoint.verified ? "verified" : "pending verification")
        }
        return parts.joined(separator: " · ")
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(LitheTheme.smallFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(10)
    }

    private var divider: some View {
        Rectangle().fill(LitheTheme.divider).frame(height: 1)
    }
}

private enum DebugContent: CaseIterable, Identifiable {
    case debugger
    case console

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .debugger: "Threads & Variables"
        case .console: "Console"
        }
    }
}

private struct JavaAttachView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host = "localhost"
    @State private var port = "5005"
    let onAttach: (String, Int) -> Void

    private var parsedPort: Int? {
        guard let value = Int(port), (1...65_535).contains(value) else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to Running JVM")
                .font(LitheTheme.uiFont(size: 14, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Host")
                    TextField("localhost", text: $host)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Port")
                    TextField("5005", text: $port)
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    guard let parsedPort else { return }
                    onAttach(host.trimmingCharacters(in: .whitespacesAndNewlines), parsedPort)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || parsedPort == nil
                )
            }
        }
        .padding(18)
        .frame(width: 360)
    }
}

private struct JavaSteppingFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (DebugSteppingFilters) -> Void
    let onReset: () -> Void
    @State private var skipJDK: Bool
    @State private var skipLibraries: Bool
    @State private var skipSynthetics: Bool
    @State private var skipStaticInitializers: Bool
    @State private var skipConstructors: Bool
    @State private var hideFilteredStackFrames: Bool
    @State private var classPatterns: String

    init(
        filters: DebugSteppingFilters,
        onSave: @escaping (DebugSteppingFilters) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onReset = onReset
        _skipJDK = State(initialValue: filters.classNameFilters.contains("$JDK"))
        _skipLibraries = State(initialValue: filters.classNameFilters.contains("$Libraries"))
        _skipSynthetics = State(initialValue: filters.skipSynthetics)
        _skipStaticInitializers = State(initialValue: filters.skipStaticInitializers)
        _skipConstructors = State(initialValue: filters.skipConstructors)
        _hideFilteredStackFrames = State(initialValue: filters.hideFilteredStackFrames)
        _classPatterns = State(initialValue: filters.classNameFilters
            .filter { $0 != "$JDK" && $0 != "$Libraries" }
            .joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Java Stepping Filters")
                    .font(LitheTheme.uiFont(size: 15, weight: .semibold))
                Text("Controls where Step Into stops. Changes apply to the next Java debug session.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Toggle("Skip JDK and reflection code", isOn: $skipJDK)
                    Toggle("Skip third-party libraries", isOn: $skipLibraries)
                }
                GridRow {
                    Toggle("Skip synthetic methods", isOn: $skipSynthetics)
                    Toggle("Skip static initializers", isOn: $skipStaticInitializers)
                }
                GridRow {
                    Toggle("Skip constructors", isOn: $skipConstructors)
                    Toggle("Collapse matching stack frames", isOn: $hideFilteredStackFrames)
                }
            }
            .toggleStyle(.checkbox)
            .font(LitheTheme.uiFont(size: 11))

            VStack(alignment: .leading, spacing: 6) {
                Text("Additional class patterns")
                    .font(LitheTheme.uiFont(size: 11, weight: .semibold))
                Text("One pattern per line, for example org.mockito.* or com.example.generated.*")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                TextEditor(text: $classPatterns)
                    .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(LitheTheme.sidebar)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(LitheTheme.divider, lineWidth: 1)
                    }
                    .frame(minHeight: 185)
            }

            HStack {
                Button("Reset Defaults") {
                    onReset()
                    dismiss()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var patterns = classPatterns
                        .split(whereSeparator: \Character.isNewline)
                        .map(String.init)
                    if skipJDK { patterns.append("$JDK") }
                    if skipLibraries { patterns.append("$Libraries") }
                    onSave(DebugSteppingFilters(
                        classNameFilters: patterns,
                        skipSynthetics: skipSynthetics,
                        skipStaticInitializers: skipStaticInitializers,
                        skipConstructors: skipConstructors,
                        hideFilteredStackFrames: hideFilteredStackFrames
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560, height: 470)
        .litheWorkbenchSurface(LitheTheme.editor)
    }
}

struct BreakpointEditorValue {
    let enabled: Bool
    let condition: String?
    let hitCondition: String?
    let logMessage: String?
}

private struct ExceptionBreakpointEditorValue {
    let enabled: Bool
    let condition: String?
}

private struct FunctionBreakpointEditorContext: Identifiable {
    let id = UUID()
    let breakpoint: GenericDebugFunctionBreakpoint?
}

private struct FunctionBreakpointEditorValue {
    let name: String
    let enabled: Bool
    let condition: String?
    let hitCondition: String?
}

private struct FunctionBreakpointEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let breakpoint: GenericDebugFunctionBreakpoint?
    let onSave: (FunctionBreakpointEditorValue) -> Void
    @State private var name: String
    @State private var enabled: Bool
    @State private var condition: String
    @State private var hitCondition: String

    init(
        breakpoint: GenericDebugFunctionBreakpoint?,
        onSave: @escaping (FunctionBreakpointEditorValue) -> Void
    ) {
        self.breakpoint = breakpoint
        self.onSave = onSave
        _name = State(initialValue: breakpoint?.name ?? "")
        _enabled = State(initialValue: breakpoint?.enabled ?? true)
        _condition = State(initialValue: breakpoint?.condition ?? "")
        _hitCondition = State(initialValue: breakpoint?.hitCondition ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(breakpoint == nil ? "Add Method Breakpoint" : "Edit Method Breakpoint")
                    .font(LitheTheme.uiFont(size: 14, weight: .semibold))
                Spacer()
                Toggle("Enabled", isOn: $enabled)
                    .toggleStyle(.checkbox)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                functionEditorRow("Class or method", text: $name)
                functionEditorRow("Condition", text: $condition)
                functionEditorRow("Hit count", text: $hitCondition)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(FunctionBreakpointEditorValue(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        enabled: enabled,
                        condition: optionalFunctionText(condition),
                        hitCondition: optionalFunctionText(hitCondition)
                    ))
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440, height: 245)
        .litheWorkbenchSurface(LitheTheme.editor)
    }

    private func functionEditorRow(_ title: String, text: Binding<String>) -> some View {
        GridRow {
            Text(title)
                .font(LitheTheme.uiFont(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                .frame(minWidth: 300)
        }
    }

    private func optionalFunctionText(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

private struct ExceptionBreakpointEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let breakpoint: GenericDebugExceptionBreakpoint
    let onSave: (ExceptionBreakpointEditorValue) -> Void
    @State private var enabled: Bool
    @State private var condition: String

    init(
        breakpoint: GenericDebugExceptionBreakpoint,
        onSave: @escaping (ExceptionBreakpointEditorValue) -> Void
    ) {
        self.breakpoint = breakpoint
        self.onSave = onSave
        _enabled = State(initialValue: breakpoint.enabled)
        _condition = State(initialValue: breakpoint.condition ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(breakpoint.label)
                        .font(LitheTheme.uiFont(size: 14, weight: .semibold))
                    if let description = breakpoint.description {
                        Text(description)
                            .font(LitheTheme.uiFont(size: 10.5))
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                }
                Spacer()
                Toggle("Enabled", isOn: $enabled)
                    .toggleStyle(.checkbox)
            }
            TextField(
                breakpoint.conditionDescription ?? "Exception condition",
                text: $condition
            )
            .textFieldStyle(.roundedBorder)
            .font(LitheTheme.uiFont(size: 11, design: .monospaced))
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let normalized = condition.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(ExceptionBreakpointEditorValue(
                        enabled: enabled,
                        condition: normalized.isEmpty ? nil : normalized
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440, height: 190)
        .litheWorkbenchSurface(LitheTheme.editor)
    }
}

struct BreakpointEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let breakpoint: GenericDebugBreakpoint
    let supportsCondition: Bool
    let supportsHitCondition: Bool
    let supportsLogMessage: Bool
    let onSave: (BreakpointEditorValue) -> Void
    @State private var enabled: Bool
    @State private var condition: String
    @State private var hitCondition: String
    @State private var logMessage: String

    init(
        breakpoint: GenericDebugBreakpoint,
        supportsCondition: Bool = true,
        supportsHitCondition: Bool = true,
        supportsLogMessage: Bool = true,
        onSave: @escaping (BreakpointEditorValue) -> Void
    ) {
        self.breakpoint = breakpoint
        self.supportsCondition = supportsCondition
        self.supportsHitCondition = supportsHitCondition
        self.supportsLogMessage = supportsLogMessage
        self.onSave = onSave
        _enabled = State(initialValue: breakpoint.enabled)
        _condition = State(initialValue: breakpoint.condition ?? "")
        _hitCondition = State(initialValue: breakpoint.hitCondition ?? "")
        _logMessage = State(initialValue: breakpoint.logMessage ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Breakpoint")
                        .font(LitheTheme.uiFont(size: 14, weight: .semibold))
                    Text(breakpoint.title)
                        .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer()
                Toggle("Enabled", isOn: $enabled)
                    .toggleStyle(.checkbox)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                editorRow(
                    "Condition",
                    text: $condition,
                    isSupported: supportsCondition,
                    help: "The active debug adapter does not support conditional breakpoints."
                )
                editorRow(
                    "Hit count",
                    text: $hitCondition,
                    isSupported: supportsHitCondition,
                    help: "The active debug adapter does not support hit-count breakpoints."
                )
                editorRow(
                    "Log message",
                    text: $logMessage,
                    isSupported: supportsLogMessage,
                    help: "The active debug adapter does not support logpoints."
                )
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(BreakpointEditorValue(
                        enabled: enabled,
                        condition: supportsCondition ? optional(condition) : nil,
                        hitCondition: supportsHitCondition ? optional(hitCondition) : nil,
                        logMessage: supportsLogMessage ? optional(logMessage) : nil
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440, height: 245)
        .litheWorkbenchSurface(LitheTheme.editor)
    }

    private func editorRow(
        _ title: String,
        text: Binding<String>,
        isSupported: Bool,
        help: String
    ) -> some View {
        GridRow {
            Text(title)
                .font(LitheTheme.uiFont(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                .frame(minWidth: 300)
                .disabled(!isSupported)
                .help(isSupported ? title : help)
        }
        .opacity(isSupported ? 1 : 0.55)
    }

    private func optional(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

private struct DataBreakpointEditorValue {
    let enabled: Bool
    let accessType: String?
    let condition: String?
    let hitCondition: String?
}

private struct DataBreakpointEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let breakpoint: GenericDebugDataBreakpoint
    let onSave: (DataBreakpointEditorValue) -> Void
    @State private var enabled: Bool
    @State private var accessType: String
    @State private var condition: String
    @State private var hitCondition: String

    init(
        breakpoint: GenericDebugDataBreakpoint,
        onSave: @escaping (DataBreakpointEditorValue) -> Void
    ) {
        self.breakpoint = breakpoint
        self.onSave = onSave
        _enabled = State(initialValue: breakpoint.enabled)
        _accessType = State(initialValue: breakpoint.accessType ?? breakpoint.accessTypes.first ?? "")
        _condition = State(initialValue: breakpoint.condition ?? "")
        _hitCondition = State(initialValue: breakpoint.hitCondition ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Field Breakpoint")
                        .font(LitheTheme.uiFont(size: 14, weight: .semibold))
                    Text(breakpoint.label)
                        .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer()
                Toggle("Enabled", isOn: $enabled).toggleStyle(.checkbox)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                if !breakpoint.accessTypes.isEmpty {
                    GridRow {
                        Text("Access")
                            .font(LitheTheme.uiFont(size: 11))
                            .foregroundStyle(LitheTheme.secondaryText)
                        LitheSettingsSelect(selection: $accessType, options: breakpoint.accessTypes, width: 180, accessibilityLabel: "Access", title: { $0 })
                        .labelsHidden()
                    }
                }
                dataEditorRow("Condition", text: $condition)
                dataEditorRow("Hit count", text: $hitCondition)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(DataBreakpointEditorValue(
                        enabled: enabled,
                        accessType: optionalDataText(accessType),
                        condition: optionalDataText(condition),
                        hitCondition: optionalDataText(hitCondition)
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440, height: 245)
        .litheWorkbenchSurface(LitheTheme.editor)
    }

    private func dataEditorRow(_ title: String, text: Binding<String>) -> some View {
        GridRow {
            Text(title)
                .font(LitheTheme.uiFont(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                .frame(minWidth: 300)
        }
    }

    private func optionalDataText(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

private struct DebugConsoleOutputView: View {
    @ObservedObject var presentation: GenericDebugOutputPresentation
    let consolePresentation: ConsoleFoldPresentation
    @Binding var wrapsLines: Bool
    let onClearOutput: () -> Void
    let standardInputSessionID: UUID?
    let onSubmitStandardInput: ((String) -> Bool)?
    let searchRoots: [URL]
    let fileExists: (URL) -> Bool
    let onOpenLocation: (URL, Int, Int?) -> Void

    var body: some View {
        OutputTextView(
            output: presentation.text,
            searchRoots: searchRoots,
            fileExists: fileExists,
            emptyMessage: onSubmitStandardInput == nil ? "Waiting for Debug Adapter output…" : "",
            wrapsLines: wrapsLines,
            showsConsoleToolbar: true,
            onClearOutput: onClearOutput,
            consolePresentation: consolePresentation,
            standardInputSessionID: standardInputSessionID,
            onSubmitStandardInput: onSubmitStandardInput,
            onToggleWrapsLines: { wrapsLines.toggle() },
            onOpenLocation: onOpenLocation
        )
    }
}

private struct WatchEditorContext: Identifiable {
    let id = UUID()
    let watch: GenericDebugWatch?
}

private struct WatchEditorView: View {
    let watch: GenericDebugWatch?
    let onCancel: () -> Void
    let onSave: (String) -> Void
    @State private var expression: String
    @FocusState private var expressionFocused: Bool

    init(watch: GenericDebugWatch?, onCancel: @escaping () -> Void, onSave: @escaping (String) -> Void) {
        self.watch = watch
        self.onCancel = onCancel
        self.onSave = onSave
        _expression = State(initialValue: watch?.expression ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(watch == nil ? "Add Watch" : "Edit Watch")
                .font(LitheTheme.uiFont(size: 14, weight: .semibold))
            LitheSearchTextField("Expression", text: $expression)
                .focused($expressionFocused)
                .litheSearchField(isFocused: expressionFocused)
                .onSubmit { save() }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(LitheSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                .buttonStyle(LithePrimaryButtonStyle())
                .disabled(expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 440)
        .onAppear { expressionFocused = true }
    }

    private func save() {
        guard !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSave(expression)
    }
}

private struct VariableValueEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let variable: DebugVariable
    let onSave: (String) -> Void
    @State private var value: String

    init(variable: DebugVariable, onSave: @escaping (String) -> Void) {
        self.variable = variable
        self.onSave = onSave
        _value = State(initialValue: variable.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Set Variable Value")
                    .font(LitheTheme.uiFont(size: 14, weight: .semibold))
                Text(variable.name)
                    .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            TextField("Value", text: $value)
                .textFieldStyle(.roundedBorder)
                .font(LitheTheme.uiFont(size: 11, design: .monospaced))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set") {
                    onSave(value)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440, height: 170)
        .litheWorkbenchSurface(LitheTheme.editor)
    }
}

private extension DebugAdapterState {
    var title: String {
        switch self {
        case .idle: "Ready"
        case .initializing: "Initializing Adapter"
        case .ready: "Adapter Ready"
        case .launching: "Launching"
        case .running: "Running"
        case .paused: "Paused"
        case .terminated: "Finished"
        case .failed: "Failed"
        }
    }
}
