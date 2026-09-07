import SwiftUI
import AppKit
import LitheCoreContracts
import LitheDebugModule

struct GenericDebugView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: GenericDebugFeatureModel
    @State private var evaluateExpression = ""
    @State private var editingVariable: DebugVariable?
    @State private var watchEditor: WatchEditorContext?
    @State private var smartStepTargets: [DebugStepInTarget] = []
    @State private var isSmartStepPickerPresented = false
    @State private var isJavaAttachPresented = false
    @State private var isJavaSteppingSettingsPresented = false
    @State private var selectedContent: DebugContent = .debugger
    @State private var consoleExpression = ""
    @State private var programInput = ""
    @FocusState private var isConsoleInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            debugToolbar
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            if feature.isSessionActive || !feature.output.isEmpty || feature.errorMessage != nil {
                VStack(spacing: 0) {
                    contentTabs
                    Rectangle().fill(LitheTheme.divider).frame(height: 1)
                    activeContent
                }
            } else {
                emptyState
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .sheet(item: $editingVariable) { variable in
            VariableValueEditorView(variable: variable) {
                feature.setVariable(variable, value: $0)
            }
        }
        .sheet(item: $watchEditor) { context in
            WatchEditorView(watch: context.watch) { expression in
                if let watch = context.watch {
                    feature.updateWatch(watch, expression: expression)
                } else {
                    feature.addWatch(expression)
                }
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
        .onChange(of: feature.state) { state in
            switch state {
            case .paused:
                selectedContent = .debugger
                if isConsoleInputFocused {
                    isConsoleInputFocused = false
                }
            case .failed:
                selectedContent = .console
            default:
                break
            }
        }
        .onChange(of: selectedContent) { content in
            if content == .console && feature.state == .paused {
                isConsoleInputFocused = true
            }
        }
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
                        .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(
                        selectedContent == content
                            ? LitheTheme.primaryText
                            : LitheTheme.secondaryText
                    )
                    .padding(.horizontal, 11)
                    .frame(height: 25)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(selectedContent == content
                                ? LitheTheme.selection
                                : Color.clear)
                    )
                    .overlay {
                        if selectedContent == content {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(LitheTheme.accent.opacity(0.65), lineWidth: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .lithePointer()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Debug")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LitheTheme.toolWindowText)
            if let sessionTitle = debugSessionTitle {
                debugSessionTab(sessionTitle)
            }
            if feature.sessionSummaries.count > 1 {
                sessionPicker
            }
            if !feature.isSessionActive {
                debugConfigurationPicker
            }
            Spacer(minLength: 8)
            debugOptionsMenu
            Button { model.workbenchFeature.setVisibility(.debug, isVisible: false) } label: {
                Image(systemName: "minus")
            }
            .litheIconButton()
            .help("Hide Debug tool window")
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: DebugToolbarPresentation.sessionHeaderHeight)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
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
        HStack(spacing: 6) {
            LitheIDEAIcon(
                resourcePath: "debugger/debug.svg",
                size: 14,
                fallbackSystemImage: "ladybug.fill",
                preservesOriginalColors: true
            )
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            if feature.isSessionActive {
                Button(action: stopActiveDebugSession) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .lithePointer()
                .help("Stop debug session")
            }
        }
        .foregroundStyle(LitheTheme.primaryText)
        .padding(.leading, 8)
        .padding(.trailing, feature.isSessionActive ? 4 : 8)
        .frame(height: 25)
        .background(RoundedRectangle(cornerRadius: 5).fill(LitheTheme.selection))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(LitheTheme.accent.opacity(0.7), lineWidth: 1)
        }
    }

    private var sessionPicker: some View {
        Menu {
            Section("Sessions") {
                ForEach(feature.sessionSummaries) { summary in
                    Button {
                        _ = feature.selectSession(summary.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: summary.id == feature.activeSessionID
                                ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(sessionLabel(summary))
                                Text(summary.state.title)
                                    .font(.system(size: 9))
                                    .foregroundStyle(LitheTheme.secondaryText)
                            }
                        }
                    }
                }
            }
            if feature.sessionSummaries.count > 1 {
                Divider()
                Section("Close other sessions") {
                    ForEach(feature.sessionSummaries.filter { $0.id != feature.activeSessionID }) { summary in
                        Button("Stop \(sessionLabel(summary))", role: .destructive) {
                            feature.stopSession(summary.id)
                        }
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

    /// Keeps the Debug entry point visibly tied to the same Run configuration
    /// used by the Run tool window. IDEA exposes this choice next to the
    /// debugger session rather than hiding it behind a second, unrelated
    /// launch flow.
    private var debugConfigurationPicker: some View {
        Menu {
            if let runFeature = model.runFeatureIfActive,
               !runFeature.configurations.isEmpty {
                ForEach(runFeature.configurations) { configuration in
                    Button {
                        model.selectRunConfiguration(configuration)
                    } label: {
                        HStack(spacing: 7) {
                            RunConfigurationIcon(kind: configuration.kind, size: 14)
                            Text(configuration.name)
                            if configuration.id == runFeature.selectedConfiguration?.id {
                                Spacer(minLength: 8)
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } else {
                Button("Current File") {
                    model.selectRunConfiguration(.currentFile)
                }
            }
        } label: {
            HStack(spacing: 5) {
                RunConfigurationIcon(
                    kind: model.runFeatureIfActive?.selectedConfiguration?.kind ?? .currentFile,
                    size: 13
                )
                Text(model.runFeatureIfActive?.selectedConfiguration?.name ?? "Current File")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 8)
            .frame(maxWidth: 210, minHeight: 25)
            .background(RoundedRectangle(cornerRadius: 5).fill(LitheTheme.selection.opacity(0.72)))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .help("Select the Run configuration used by Debug")
        .accessibilityLabel("Debug run configuration")
        .accessibilityIdentifier("debug-run-configuration-picker")
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
                debugOptionsMenu
                debugExecutionStatus
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .frame(height: DebugToolbarPresentation.toolbarHeight)
        }
        .litheWorkbenchSurface(LitheTheme.toolHeader)
        .popover(isPresented: $isSmartStepPickerPresented, arrowEdge: .bottom) {
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
                preservesOriginalColors: true
            )
            .frame(width: DebugToolbarPresentation.iconSize, height: DebugToolbarPresentation.iconSize)
        }
        .litheIconButton()
        .frame(width: 32, height: 30)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.36 : 1)
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
            .fill(LitheTheme.divider)
            .frame(width: 1, height: 18)
            .padding(.horizontal, 3)
    }

    private var debugExecutionStatus: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(debugStatusColor)
                .frame(width: 6, height: 6)
            Text(debugStatusText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
            if let frame = feature.selectedFrame,
               let sourceURL = frame.sourceURL {
                Button {
                    model.revealDebugLocation(
                        url: sourceURL,
                        line: frame.line,
                        column: frame.column
                    )
                } label: {
                    Text("· \(sourceURL.lastPathComponent):\(frame.line)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText.opacity(0.82))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Reveal stopped location in editor")
                .accessibilityLabel("Reveal stopped location in editor")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            Capsule()
                .fill(LitheTheme.selection.opacity(0.58))
        )
        .help(debugStatusText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(debugStatusText)
    }

    private var debugStatusText: String {
        DebugToolbarPresentation.statusText(
            for: feature.state,
            stoppedReason: feature.stoppedReason
        )
    }

    private var debugStatusColor: Color {
        switch feature.state {
        case .paused: return LitheTheme.warning
        case .failed: return LitheTheme.error
        case .terminated, .idle: return LitheTheme.secondaryText
        default: return LitheTheme.success
        }
    }

    private var debugOptionsMenu: some View {
        Menu {
            if feature.capabilities.supportsStepInTargetsRequest {
                Button("Smart Step Into") { requestSmartStepInto() }
                    .disabled(feature.state != .paused || feature.selectedFrameID == nil)
            }
            if feature.capabilities.supportsStepBack {
                Button("Step Back") { feature.execute(.stepBack) }
                    .disabled(!feature.canStepBack)
            }
            if feature.javaSteppingFilters != nil {
                Button("Java Stepping Filters…") {
                    isJavaSteppingSettingsPresented = true
                }
                .disabled(feature.isSessionActive)
            }
            Divider()
            Button("Connect to Running JVM…") { isJavaAttachPresented = true }
                .disabled(feature.isSessionActive)
            Button("Clear Console") { feature.clearOutput() }
                .disabled(feature.output.isEmpty)
        } label: {
            LitheIDEAIcon(
                resourcePath: "actions/moreVertical.svg",
                size: 15,
                fallbackSystemImage: "ellipsis"
            )
        }
        .litheIconButton()
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
                .font(.system(size: 11, weight: .semibold))
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
                    .buttonStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 230)
        .padding(.vertical, 4)
    }

    private var inspector: some View {
        HSplitView {
            executionInspector
                .frame(minWidth: 240, idealWidth: 320, maxWidth: .infinity)
            dataInspector
                .frame(minWidth: 300, idealWidth: 480, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    private var executionInspector: some View {
        VStack(spacing: 0) {
            threadPicker
            divider
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if feature.stackFrames.isEmpty {
                        placeholder("Pause the process to inspect frames")
                    } else {
                        if feature.areFilteredStackFramesExpanded,
                           feature.hiddenStackFrameCount > 0 {
                            Button {
                                feature.collapseFilteredStackFrames()
                            } label: {
                                Label("Collapse filtered frames", systemImage: "rectangle.compress.vertical")
                                    .font(LitheTheme.smallFont)
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: 27)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
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
                                        Image(systemName: "ellipsis")
                                            .foregroundStyle(LitheTheme.secondaryText)
                                    } else if feature.selectedFrameID == frame.id {
                                        LitheIDEAIcon(
                                            resourcePath: "debugger/frame.svg",
                                            size: 14,
                                            fallbackSystemImage: "pause.fill",
                                            preservesOriginalColors: true
                                        )
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(LitheTheme.secondaryText)
                                    }
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(frame.name).lineLimit(1)
                                        if let sourceURL = frame.sourceURL {
                                            Text("\(sourceURL.lastPathComponent):\(frame.line)")
                                                .font(.system(size: 9.5, design: .monospaced))
                                                .foregroundStyle(LitheTheme.secondaryText)
                                        }
                                    }
                                }
                                .opacity(frame.isFiltered ? 0.58 : 1)
                                .contextMenu {
                                    Button("Copy Method Name") {
                                        copyToPasteboard(frame.name)
                                    }
                                    if let sourceURL = frame.sourceURL {
                                        Divider()
                                        Button("Copy Source Location") {
                                            copyToPasteboard(
                                                "\(sourceURL.path):\(frame.line):\(frame.column)"
                                            )
                                        }
                                        Button("Copy Relative Location") {
                                            copyToPasteboard(
                                                "\(sourceURL.lastPathComponent):\(frame.line):\(frame.column)"
                                            )
                                        }
                                    }
                                }
                            } else {
                                Button {
                                    feature.expandFilteredStackFrames()
                                } label: {
                                    Label(
                                        "\(row.hiddenFrameCount) hidden frames",
                                        systemImage: "ellipsis.circle"
                                    )
                                    .font(LitheTheme.smallFont)
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: 27)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
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

    private var threadPicker: some View {
        Menu {
            if feature.threads.isEmpty {
                Button("Load threads") { feature.inspectThreads() }
            } else {
                ForEach(feature.threads) { thread in
                    Button {
                        feature.selectThread(thread)
                    } label: {
                        HStack(spacing: 7) {
                            LitheIDEAIcon(
                                resourcePath: threadIconResourcePath(thread),
                                size: 14,
                                fallbackSystemImage: threadIcon(thread),
                                preservesOriginalColors: true
                            )
                            Text(thread.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                if let thread = selectedThread {
                    LitheIDEAIcon(
                        resourcePath: threadIconResourcePath(thread),
                        size: 14,
                        fallbackSystemImage: threadIcon(thread),
                        preservesOriginalColors: true
                    )
                    Text(thread.name)
                        .lineLimit(1)
                    Text(feature.state == .paused ? "Paused" : feature.state.title)
                        .font(.system(size: 9.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                } else {
                    LitheIDEAIcon(
                        resourcePath: "debugger/threadSuspended.svg",
                        size: 14,
                        fallbackSystemImage: "circle.dotted",
                        preservesOriginalColors: true
                    )
                    Text(feature.threads.isEmpty ? "Load threads" : "Select thread")
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Debugger thread")
        .contextMenu {
            if let thread = selectedThread {
                Button("Copy Thread Name") { copyToPasteboard(thread.name) }
                if feature.capabilities.supportsSingleThreadExecutionRequests {
                    Button(feature.state == .paused ? "Resume Thread" : "Pause Thread") {
                        feature.executeThread(
                            feature.state == .paused ? .continueExecution : .pause,
                            thread: thread
                        )
                    }
                    .disabled(feature.state != .paused && feature.state != .running)
                }
            }
        }
    }

    private var selectedThread: DebugThread? {
        feature.threads.first { $0.id == feature.selectedThreadID }
    }

    private var dataInspector: some View {
        VStack(spacing: 0) {
            evaluateRow
            divider
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let exceptionInfo = feature.exceptionInfo {
                        exceptionInspector(exceptionInfo)
                        divider
                    }
                    variablesHeader
                    if feature.visibleVariableRows.isEmpty {
                        placeholder("Select a stack frame to inspect variables")
                    } else {
                        ForEach(feature.visibleVariableRows) { row in
                            switch row.content {
                            case .variable(let variable):
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: variableDisclosureSymbol(variable))
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(LitheTheme.secondaryText)
                                        .frame(width: 9)
                                        .opacity(variable.isExpandable ? 1 : 0)
                                    LitheIDEAIcon(
                                        resourcePath: variableIconResourcePath(variable),
                                        size: 13,
                                        fallbackSystemImage: "circle.fill"
                                    )
                                    Text(variable.name)
                                        .font(.system(size: 10.5, design: .monospaced))
                                    Text("=")
                                        .foregroundStyle(LitheTheme.secondaryText)
                                    Text(variable.value)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(LitheTheme.accent)
                                        .lineLimit(2)
                                    if let type = variable.type, !type.isEmpty {
                                        Text(": \(type)")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(LitheTheme.secondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    feature.toggleVariableExpansion(variable)
                                }
                                .padding(.leading, 10 + CGFloat(row.depth * 14))
                                .padding(.trailing, 10)
                                .padding(.vertical, 5)
                                .contextMenu {
                                    if feature.capabilities.supportsSetVariable,
                                       variable.containerReference != nil {
                                        Button("Set Value…") { editingVariable = variable }
                                    }
                                    if feature.capabilities.supportsDataBreakpoints,
                                       variable.containerReference != nil {
                                        Button("Break on Field Access…") {
                                            feature.requestDataBreakpoint(for: variable)
                                        }
                                    }
                                    Divider()
                                    Button("Copy Value") { copyToPasteboard(variable.value) }
                                    Button("Copy Expression") {
                                        copyToPasteboard(variable.evaluateName ?? variable.name)
                                    }
                                    Button("Copy Name") { copyToPasteboard(variable.name) }
                                    if let expression = variable.evaluateName,
                                       !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Divider()
                                        Button("Add to Watches") {
                                            feature.addWatch(expression)
                                        }
                                    }
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

                    divider
                    watchSectionHeader
                    if feature.watches.isEmpty {
                        placeholder("Add an expression to watch while paused")
                    } else {
                        ForEach(feature.watches) { watch in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                LitheIDEAIcon(
                                    resourcePath: "debugger/watch.svg",
                                    size: 13,
                                    fallbackSystemImage: "eye"
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(watch.expression)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .lineLimit(1)
                                    if let error = watch.error {
                                        Text(error)
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(LitheTheme.error)
                                            .lineLimit(2)
                                    } else if let value = watch.value {
                                        HStack(spacing: 4) {
                                            Text(value)
                                                .foregroundStyle(LitheTheme.accent)
                                            if let type = watch.type {
                                                Text(type).foregroundStyle(LitheTheme.secondaryText)
                                            }
                                        }
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .lineLimit(2)
                                    } else {
                                        Text(feature.state == .paused ? "Evaluating…" : "Not available")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(LitheTheme.secondaryText)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contextMenu {
                                Button("Refresh") { feature.refreshWatches() }
                                    .disabled(feature.state != .paused)
                                Button("Edit…") {
                                    watchEditor = WatchEditorContext(watch: watch)
                                }
                                Divider()
                                Button("Remove", role: .destructive) {
                                    feature.removeWatch(watch)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    private var variablesHeader: some View {
        HStack(spacing: 7) {
            Text("Variables")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(String(feature.presentedVariables.count))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer(minLength: 0)
            if !feature.scopes.isEmpty {
                Menu {
                    ForEach(feature.scopes) { scope in
                        Button {
                            feature.selectScope(scope)
                        } label: {
                            Label(
                                scope.name,
                                systemImage: feature.selectedScopeID == scope.id
                                    ? "checkmark"
                                    : "circle"
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedScopeName)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Variable scope")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 27)
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
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.error)
                Spacer(minLength: 8)
                Text(exceptionBreakModeTitle(info.breakMode))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Text(info.exceptionID)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(LitheTheme.primaryText)
                .textSelection(.enabled)
            if let description = info.description,
               !description.isEmpty,
               description != info.exceptionID {
                Text(description)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.warning)
                    .textSelection(.enabled)
            }
            if let details = info.details {
                if let message = details.message,
                   !message.isEmpty,
                   message != info.description {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .textSelection(.enabled)
                }
                ForEach(Array(nestedExceptionDetails(details).enumerated()), id: \.offset) { _, cause in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 8))
                            .foregroundStyle(LitheTheme.secondaryText)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(cause.fullTypeName ?? cause.typeName ?? "Nested exception")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                            if let message = cause.message, !message.isEmpty {
                                Text(message)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(LitheTheme.secondaryText)
                            }
                        }
                    }
                }
                if let stackTrace = details.stackTrace, !stackTrace.isEmpty {
                    Text(stackTrace)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(12)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.error.opacity(0.06))
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
            LitheIDEAIcon(
                resourcePath: "debugger/evaluateExpression.svg",
                size: 16,
                fallbackSystemImage: "function",
                preservesOriginalColors: true
            )
            TextField("Evaluate expression", text: $evaluateExpression)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit { addWatchExpression() }
            Button { addWatchExpression() } label: {
                LitheIDEAIcon(
                    resourcePath: "actions/add.svg",
                    size: 14,
                    fallbackSystemImage: "plus.circle",
                    preservesOriginalColors: true
                )
            }
            .litheIconButton()
            .help("Add watch")
            Button { feature.evaluate(evaluateExpression) } label: {
                LitheIDEAIcon(
                    resourcePath: "actions/execute.svg",
                    size: 14,
                    fallbackSystemImage: "arrow.right.circle",
                    preservesOriginalColors: true
                )
            }
            .litheIconButton()
            .disabled(feature.state != .paused || evaluateExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Evaluate expression")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private var watchSectionHeader: some View {
        HStack {
            Text("Watches")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
            Text(String(feature.watches.count))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
            Button { feature.refreshWatches() } label: {
                LitheIDEAIcon(
                    resourcePath: "actions/refresh.svg",
                    size: 13,
                    fallbackSystemImage: "arrow.clockwise",
                    preservesOriginalColors: true
                )
            }
            .buttonStyle(.plain)
            .disabled(feature.state != .paused || feature.watches.isEmpty)
            .help("Refresh watches")
            Button { watchEditor = WatchEditorContext(watch: nil) } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("Add watch")
        }
        .padding(.horizontal, 10)
        .frame(height: 27)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private func addWatchExpression() {
        feature.addWatch(evaluateExpression)
        evaluateExpression = ""
    }

    private var debugConsole: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let stoppedReason = feature.stoppedReason {
                            Label(stoppedReason, systemImage: "pause.circle.fill")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(LitheTheme.warning)
                        }
                        if let errorMessage = feature.errorMessage {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11.5))
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
                        Text(feature.output.isEmpty ? "Waiting for Debug Adapter output…" : feature.output)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(LitheTheme.primaryText)
                            .textSelection(.enabled)
                    }
                    .frame(
                        minWidth: max(0, geometry.size.width - 24),
                        minHeight: max(0, geometry.size.height - 97),
                        alignment: .topLeading
                    )
                    .padding(12)
                }
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                consoleInputRow
                programInputRow
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .litheWorkbenchSurface(LitheTheme.editor)
    }

    private var consoleInputRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LitheTheme.accent)
            Button {
                if let expression = feature.previousConsoleExpression(current: consoleExpression) {
                    consoleExpression = expression
                }
            } label: {
                Image(systemName: "chevron.up")
            }
            .litheIconButton()
            .disabled(feature.consoleHistory.isEmpty || feature.state != .paused)
            .help("Previous console expression")
            TextField("Evaluate expression while paused", text: $consoleExpression)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .focused($isConsoleInputFocused)
                .disabled(feature.state != .paused)
                .onSubmit { evaluateConsoleExpression() }
            Button { evaluateConsoleExpression() } label: {
                LitheIDEAIcon(
                    resourcePath: "debugger/evaluateExpression.svg",
                    size: 15,
                    fallbackSystemImage: "arrow.right.circle.fill",
                    preservesOriginalColors: true
                )
            }
            .litheIconButton()
            .disabled(feature.state != .paused || consoleExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Evaluate expression")
            Button {
                if let expression = feature.nextConsoleExpression() {
                    consoleExpression = expression
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .litheIconButton()
            .disabled(feature.consoleHistory.isEmpty || feature.state != .paused)
            .help("Next console expression")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private func evaluateConsoleExpression() {
        guard feature.state == .paused else { return }
        let expression = consoleExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { return }
        feature.evaluate(expression)
        consoleExpression = ""
    }

    private var programInputRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LitheTheme.warning)
            TextField("Send input to debuggee", text: $programInput)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .disabled(!model.isDebugStandardInputAvailable)
                .onSubmit { sendProgramInput() }
            Button { sendProgramInput() } label: {
                LitheIDEAIcon(
                    resourcePath: "debugger/run.svg",
                    size: 15,
                    fallbackSystemImage: "paperplane.fill",
                    preservesOriginalColors: true
                )
            }
            .litheIconButton()
            .disabled(!model.isDebugStandardInputAvailable || programInput.isEmpty)
            .help("Send program input")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private func sendProgramInput() {
        guard !programInput.isEmpty,
              model.sendDebugStandardInput(programInput) else { return }
        programInput = ""
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            LitheIDEAIcon(
                resourcePath: "debugger/debug.svg",
                size: 32,
                fallbackSystemImage: "ladybug",
                preservesOriginalColors: true
            )
            .frame(width: 36, height: 36)
            Text(emptyStateTitle)
                .font(.system(size: 13, weight: .medium))
            Text(emptyStateSubtitle)
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
            Button("Start Debugging") { model.startDebugging() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(LitheTheme.accent)
            Button("Connect to Running JVM") { isJavaAttachPresented = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("View Breakpoints") { model.showDebugBreakpointManager() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.workspaceURL == nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var currentLanguageName: String {
        guard let document = model.activeDocument,
              let descriptor = model.languageProviderCatalog.provider(for: document.url)
        else { return "source" }
        return descriptor.displayName
    }

    private var emptyStateTitle: String {
        if let configuration = model.runFeatureIfActive?.selectedConfiguration,
           !configuration.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Debug \(configuration.name)"
        }
        return "Debug the current \(currentLanguageName) file"
    }

    private var emptyStateSubtitle: String {
        if model.runFeatureIfActive?.selectedConfiguration != nil {
            return "Uses the selected Run configuration and its project toolchain."
        }
        return "The Debug Adapter starts only when this action is used."
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
            Text(String(count))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .padding(.horizontal, 10)
        .frame(height: 27)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private func variableDisclosureSymbol(_ variable: DebugVariable) -> String {
        if feature.isVariableLoading(variable) { return "hourglass" }
        return feature.isVariableExpanded(variable) ? "chevron.down" : "chevron.right"
    }

    private func variableIconResourcePath(_ variable: DebugVariable) -> String {
        feature.automaticVariables.contains(where: { $0.id == variable.id })
            ? "debugger/watch.svg"
            : variable.name == "this" ? "nodes/variable.svg" : "nodes/field.svg"
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
            return "debugger/threadCurrent.svg"
        }
        return feature.stoppedThreadIDs.contains(thread.id)
            ? "debugger/threadSuspended.svg"
            : "debugger/threadRunning.svg"
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
                        .font(.system(size: 9.5, design: .monospaced))
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
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel(isLoading ? "Loading debugger variables" : "Load more debugger variables")
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(LitheTheme.smallFont)
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(10)
    }

    private var divider: some View {
        Rectangle().fill(LitheTheme.divider).frame(height: 1)
    }

    private func rowButton<Label: View>(
        selected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                label()
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(selected ? LitheTheme.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                        .font(.system(size: 14, weight: .semibold))
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
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
            Text(String(feature.breakpoints.count))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
            Menu {
                Button(
                    feature.areBreakpointsMuted
                        ? "Unmute Line Breakpoints"
                        : "Mute Line Breakpoints"
                ) {
                    feature.toggleBreakpointMute()
                }
                Button("Remove All", role: .destructive) {
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
            .menuStyle(.borderlessButton)
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
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
            Text(String(feature.functionBreakpoints.count))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
            Button {
                functionBreakpointEditor = FunctionBreakpointEditorContext(breakpoint: nil)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
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
                        .font(.system(size: 9))
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
            .buttonStyle(.plain)
            .help(breakpoint.enabled ? "Disable breakpoint" : "Enable breakpoint")
            .accessibilityLabel(breakpoint.enabled ? "Disable breakpoint" : "Enable breakpoint")
            Button {
                model.openSourceLocation(
                    url: breakpoint.fileURL,
                    line: breakpoint.line,
                    column: breakpoint.column ?? 1
                )
                onNavigate?()
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(breakpoint.title)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                    if let detail = breakpointDetail(breakpoint) {
                        Text(detail)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(breakpoint.title)")
            Menu {
                Button("Edit…") { editingBreakpoint = breakpoint }
                Button(breakpoint.enabled ? "Disable" : "Enable") {
                    feature.setBreakpointEnabled(breakpoint, enabled: !breakpoint.enabled)
                }
                Divider()
                Button("Remove", role: .destructive) {
                    feature.removeBreakpoint(breakpoint)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Actions for \(breakpoint.title)")
        }
        .help(breakpoint.message ?? breakpoint.title)
        .padding(.horizontal, 10)
        .frame(minHeight: 33)
        .opacity(breakpoint.enabled && !feature.areBreakpointsMuted ? 1 : 0.55)
        .contextMenu {
            Button("Edit…") { editingBreakpoint = breakpoint }
            Button(breakpoint.enabled ? "Disable" : "Enable") {
                feature.setBreakpointEnabled(breakpoint, enabled: !breakpoint.enabled)
            }
            Divider()
            Button("Remove", role: .destructive) { feature.removeBreakpoint(breakpoint) }
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
                    .font(.system(size: 10))
                    .foregroundStyle(breakpoint.enabled ? LitheTheme.error : LitheTheme.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                breakpoint.enabled
                    ? "Disable \(breakpoint.label) exception breakpoint"
                    : "Enable \(breakpoint.label) exception breakpoint"
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(breakpoint.label).font(.system(size: 11)).lineLimit(1)
                if let condition = breakpoint.condition {
                    Text("If: \(condition)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if breakpoint.supportsCondition {
                Button { editingExceptionBreakpoint = breakpoint } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(.plain)
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
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(
                        breakpoint.enabled
                            ? (breakpoint.verified ? LitheTheme.error : LitheTheme.warning)
                            : LitheTheme.secondaryText
                    )
            }
            .buttonStyle(.plain)
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
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                    if let detail = functionBreakpointDetail(breakpoint) {
                        Text(detail)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(breakpoint.name) method breakpoint")
            Menu {
                Button("Edit…") {
                    functionBreakpointEditor = FunctionBreakpointEditorContext(breakpoint: breakpoint)
                }
                Button(breakpoint.enabled ? "Disable" : "Enable") {
                    feature.setFunctionBreakpointEnabled(breakpoint, enabled: !breakpoint.enabled)
                }
                Divider()
                Button("Remove", role: .destructive) {
                    feature.removeFunctionBreakpoint(breakpoint)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
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
            .buttonStyle(.plain)
            .accessibilityLabel(
                breakpoint.enabled
                    ? "Disable \(breakpoint.label) field breakpoint"
                    : "Enable \(breakpoint.label) field breakpoint"
            )
            Button { editingDataBreakpoint = breakpoint } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(breakpoint.label)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                    Text(dataBreakpointDetail(breakpoint))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(breakpoint.label) field breakpoint")
            Menu {
                Button("Edit…") { editingDataBreakpoint = breakpoint }
                Button(breakpoint.enabled ? "Disable" : "Enable") {
                    feature.setDataBreakpointEnabled(breakpoint, enabled: !breakpoint.enabled)
                }
                Divider()
                Button("Remove", role: .destructive) { feature.removeDataBreakpoint(breakpoint) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
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
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
            Text(String(count))
                .font(.system(size: 9.5, design: .monospaced))
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
                .font(.system(size: 14, weight: .semibold))
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
                    .font(.system(size: 15, weight: .semibold))
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
            .font(.system(size: 11))

            VStack(alignment: .leading, spacing: 6) {
                Text("Additional class patterns")
                    .font(.system(size: 11, weight: .semibold))
                Text("One pattern per line, for example org.mockito.* or com.example.generated.*")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                TextEditor(text: $classPatterns)
                    .font(.system(size: 11, design: .monospaced))
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
                    .font(.system(size: 14, weight: .semibold))
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
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
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
                        .font(.system(size: 14, weight: .semibold))
                    if let description = breakpoint.description {
                        Text(description)
                            .font(.system(size: 10.5))
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
            .font(.system(size: 11, design: .monospaced))
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
                        .font(.system(size: 14, weight: .semibold))
                    Text(breakpoint.title)
                        .font(.system(size: 10.5, design: .monospaced))
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
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
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
                        .font(.system(size: 14, weight: .semibold))
                    Text(breakpoint.label)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer()
                Toggle("Enabled", isOn: $enabled).toggleStyle(.checkbox)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                if !breakpoint.accessTypes.isEmpty {
                    GridRow {
                        Text("Access")
                            .font(.system(size: 11))
                            .foregroundStyle(LitheTheme.secondaryText)
                        Picker("", selection: $accessType) {
                            ForEach(breakpoint.accessTypes, id: \.self) { Text($0).tag($0) }
                        }
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
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(minWidth: 300)
        }
    }

    private func optionalDataText(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

private struct WatchEditorContext: Identifiable {
    let id = UUID()
    let watch: GenericDebugWatch?
}

private struct WatchEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let watch: GenericDebugWatch?
    let onSave: (String) -> Void
    @State private var expression: String

    init(watch: GenericDebugWatch?, onSave: @escaping (String) -> Void) {
        self.watch = watch
        self.onSave = onSave
        _expression = State(initialValue: watch?.expression ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(watch == nil ? "Add Watch" : "Edit Watch")
                .font(.system(size: 14, weight: .semibold))
            TextField("Expression", text: $expression)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(expression)
                    dismiss()
                }
                .disabled(expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440, height: 150)
        .litheWorkbenchSurface(LitheTheme.editor)
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
                    .font(.system(size: 14, weight: .semibold))
                Text(variable.name)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            TextField("Value", text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
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
