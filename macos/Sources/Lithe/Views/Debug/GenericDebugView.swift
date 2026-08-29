import SwiftUI
import LitheCoreContracts
import LitheDebugModule

struct GenericDebugView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: GenericDebugFeatureModel
    @State private var evaluateExpression = ""
    @State private var editingBreakpoint: GenericDebugBreakpoint?
    @State private var editingExceptionBreakpoint: GenericDebugExceptionBreakpoint?
    @State private var functionBreakpointEditor: FunctionBreakpointEditorContext?
    @State private var editingDataBreakpoint: GenericDebugDataBreakpoint?
    @State private var editingVariable: DebugVariable?
    @State private var watchEditor: WatchEditorContext?
    @State private var smartStepTargets: [DebugStepInTarget] = []
    @State private var isSmartStepPickerPresented = false
    @State private var isJavaAttachPresented = false
    @State private var isJavaSteppingSettingsPresented = false
    @State private var selectedContent: DebugContent = .debugger

    var body: some View {
        VStack(spacing: 0) {
            header
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
        .sheet(item: $editingBreakpoint) { breakpoint in
            BreakpointEditorView(breakpoint: breakpoint) {
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
            case .failed:
                selectedContent = .console
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var activeContent: some View {
        switch selectedContent {
        case .debugger:
            inspector
        case .breakpoints:
            breakpointInspector
        case .console:
            output
        }
    }

    private var contentTabs: some View {
        HStack(spacing: 0) {
            ForEach(DebugContent.allCases) { content in
                Button {
                    selectedContent = content
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: content.systemImage)
                            .font(.system(size: 10, weight: .medium))
                        Text(content.title)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(
                        selectedContent == content
                            ? LitheTheme.primaryText
                            : LitheTheme.secondaryText
                    )
                    .padding(.horizontal, 12)
                    .frame(height: 29)
                    .overlay(alignment: .bottom) {
                        if selectedContent == content {
                            Rectangle()
                                .fill(LitheTheme.accent)
                                .frame(height: 2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if feature.state == .paused {
                Label(feature.stoppedReason ?? "Paused", systemImage: "pause.circle.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LitheTheme.warning)
                    .lineLimit(1)
                    .padding(.trailing, 10)
            }
        }
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private var header: some View {
        LitheToolWindowHeader(
            title: "Debug",
            systemImage: "ladybug",
            ideaAssetPath: "toolwindows/toolWindowDebugger.svg",
            subtitle: feature.state.title,
            onMinimize: { model.isDebugVisible = false }
        ) {
            if let providerID = feature.providerID {
                Text(providerID.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            if let targetTitle = feature.targetTitle {
                Text(targetTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            if feature.javaSteppingFilters != nil {
                Button { isJavaSteppingSettingsPresented = true } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .litheIconButton()
                .disabled(feature.isSessionActive)
                .help("Java stepping filters")
            }
            Button { isJavaAttachPresented = true } label: {
                Image(systemName: "link")
            }
            .litheIconButton()
            .disabled(feature.isSessionActive)
            .help("Connect to running JVM")
            controlButton(
                feature.state == .running ? "pause.fill" : "play.fill",
                help: feature.state == .running ? "Pause" : "Continue",
                disabled: !feature.canControl
            ) {
                feature.execute(feature.state == .running ? .pause : .continueExecution)
            }
            controlButton("arrow.right.to.line", help: "Step over", disabled: feature.state != .paused) {
                feature.execute(.next)
            }
            controlButton("arrow.down.to.line", help: "Step into", disabled: feature.state != .paused) {
                feature.execute(.stepIn)
            }
            if feature.capabilities.supportsStepInTargetsRequest {
                Button {
                    feature.requestSmartStepInto { result in
                        guard case .success(let targets) = result else { return }
                        if targets.count == 1, let target = targets.first {
                            feature.smartStepInto(target)
                        } else {
                            smartStepTargets = targets
                            isSmartStepPickerPresented = true
                        }
                    }
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .litheIconButton()
                .disabled(feature.state != .paused || feature.selectedFrameID == nil)
                .help("Smart step into")
                .popover(isPresented: $isSmartStepPickerPresented, arrowEdge: .bottom) {
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
            }
            controlButton("arrow.up.to.line", help: "Step out", disabled: feature.state != .paused) {
                feature.execute(.stepOut)
            }
            if feature.capabilities.supportsStepBack {
                controlButton("arrow.uturn.backward", help: "Step back", disabled: !feature.canStepBack) {
                    feature.execute(.stepBack)
                }
            }
            if feature.capabilities.supportsRestartRequest {
                controlButton("arrow.clockwise", help: "Restart", disabled: !feature.canRestart) {
                    feature.execute(.restart)
                }
            }
            Button {
                if feature.isSessionActive {
                    if feature.canTerminate {
                        feature.execute(.terminate)
                    } else {
                        model.stopDebugging()
                    }
                } else {
                    model.startDebugging()
                }
            } label: {
                Image(systemName: feature.isSessionActive ? "stop.fill" : "play.fill")
            }
            .litheIconButton()
            .foregroundStyle(feature.isSessionActive ? LitheTheme.warning : LitheTheme.success)
            .help(feature.isSessionActive ? "Stop debugging" : "Start debugging")
            controlButton("trash", help: "Clear output", disabled: false) {
                feature.clearOutput()
            }
        }
    }

    private func controlButton(
        _ image: String,
        help: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Image(systemName: image) }
            .litheIconButton()
            .disabled(disabled)
            .help(help)
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                sectionHeader("Threads", count: feature.threads.count)
                if feature.threads.isEmpty {
                    Button("Load threads") { feature.inspectThreads() }
                        .buttonStyle(.plain)
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.accent)
                        .padding(10)
                } else {
                    ForEach(feature.threads) { thread in
                        rowButton(selected: feature.selectedThreadID == thread.id) {
                            feature.selectThread(thread)
                        } label: {
                            Image(systemName: "circle")
                            Text(thread.name).lineLimit(1)
                        }
                        .contextMenu {
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

                divider
                sectionHeader("Call Stack", count: feature.stackFrames.count)
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
                                    model.openSourceLocation(
                                        url: sourceURL,
                                        line: frame.line,
                                        column: frame.column
                                    )
                                }
                            } label: {
                                Image(systemName: frame.isFiltered ? "ellipsis" : "chevron.right")
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
                        } else {
                            Button {
                                feature.expandFilteredStackFrames()
                            } label: {
                                Label(
                                    "\(row.hiddenFrameCount) filtered frames",
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    private var dataInspector: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let exceptionInfo = feature.exceptionInfo {
                        exceptionInspector(exceptionInfo)
                        divider
                    }
                    sectionHeader("Variables", count: feature.variables.count)
                    if feature.variables.isEmpty {
                        placeholder("Select a stack frame to inspect variables")
                    } else {
                        ForEach(feature.visibleVariableRows) { row in
                            let variable = row.variable
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: variableSymbol(variable))
                                    .font(.system(size: variable.isExpandable ? 8 : 4))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                Text(variable.name)
                                    .font(.system(size: 10.5, design: .monospaced))
                                Text("=")
                                    .foregroundStyle(LitheTheme.secondaryText)
                                Text(variable.value)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(LitheTheme.accent)
                                    .lineLimit(2)
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
                                Image(systemName: "eye")
                                    .font(.system(size: 9))
                                    .foregroundStyle(LitheTheme.secondaryText)
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
            divider
            evaluateRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    private var breakpointInspector: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Group {
                    breakpointSectionHeader
                    if feature.breakpoints.isEmpty {
                        placeholder("Click the editor gutter to add a breakpoint")
                    } else {
                        ForEach(feature.breakpoints) { breakpoint in
                            HStack(spacing: 7) {
                                Button {
                                    feature.setBreakpointEnabled(
                                        breakpoint,
                                        enabled: !breakpoint.enabled
                                    )
                                } label: {
                                    Image(systemName: breakpointSymbol(breakpoint))
                                        .font(.system(size: 9))
                                        .foregroundStyle(breakpointColor(breakpoint))
                                }
                                .buttonStyle(.plain)
                                .help(breakpoint.enabled ? "Disable breakpoint" : "Enable breakpoint")
                                Button {
                                    model.openSourceLocation(
                                        url: breakpoint.fileURL,
                                        line: breakpoint.line,
                                        column: breakpoint.column ?? 1
                                    )
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
                                Menu {
                                    Button("Edit…") { editingBreakpoint = breakpoint }
                                    Button(breakpoint.enabled ? "Disable" : "Enable") {
                                        feature.setBreakpointEnabled(
                                            breakpoint,
                                            enabled: !breakpoint.enabled
                                        )
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
                            }
                            .help(breakpoint.message ?? breakpoint.title)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 31)
                            .opacity(breakpoint.enabled && !feature.areBreakpointsMuted ? 1 : 0.55)
                            .contextMenu {
                                Button("Edit…") { editingBreakpoint = breakpoint }
                                Button(breakpoint.enabled ? "Disable" : "Enable") {
                                    feature.setBreakpointEnabled(
                                        breakpoint,
                                        enabled: !breakpoint.enabled
                                    )
                                }
                                Divider()
                                Button("Remove", role: .destructive) {
                                    feature.removeBreakpoint(breakpoint)
                                }
                            }
                        }
                    }
                    if !feature.exceptionBreakpoints.isEmpty {
                        divider
                        sectionHeader("Exception Breakpoints", count: feature.exceptionBreakpoints.count)
                        ForEach(feature.exceptionBreakpoints) { breakpoint in
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
                                        .foregroundStyle(
                                            breakpoint.enabled ? LitheTheme.error : LitheTheme.secondaryText
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(breakpoint.enabled ? "Disable exception breakpoint" : "Enable exception breakpoint")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(breakpoint.label)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                    if let condition = breakpoint.condition {
                                        Text("If: \(condition)")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(LitheTheme.secondaryText)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if breakpoint.supportsCondition {
                                    Button {
                                        editingExceptionBreakpoint = breakpoint
                                    } label: {
                                        Image(systemName: "ellipsis")
                                    }
                                    .buttonStyle(.plain)
                                    .help("Edit exception breakpoint")
                                }
                            }
                            .help(breakpoint.description ?? breakpoint.label)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 31)
                            .opacity(breakpoint.enabled ? 1 : 0.55)
                            .contextMenu {
                                Button(breakpoint.enabled ? "Disable" : "Enable") {
                                    feature.updateExceptionBreakpoint(
                                        breakpoint,
                                        enabled: !breakpoint.enabled,
                                        condition: breakpoint.condition
                                    )
                                }
                                if breakpoint.supportsCondition {
                                    Button("Edit Condition…") {
                                        editingExceptionBreakpoint = breakpoint
                                    }
                                }
                            }
                        }
                    }
                    if feature.capabilities.supportsFunctionBreakpoints
                        || !feature.functionBreakpoints.isEmpty {
                        divider
                        functionBreakpointSectionHeader
                        if feature.functionBreakpoints.isEmpty {
                            placeholder("Add a class or method name")
                        } else {
                            ForEach(feature.functionBreakpoints) { breakpoint in
                                HStack(spacing: 7) {
                                    Button {
                                        feature.setFunctionBreakpointEnabled(
                                            breakpoint,
                                            enabled: !breakpoint.enabled
                                        )
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
                                    .help(breakpoint.enabled ? "Disable method breakpoint" : "Enable method breakpoint")
                                    Button {
                                        functionBreakpointEditor = FunctionBreakpointEditorContext(
                                            breakpoint: breakpoint
                                        )
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
                                    Menu {
                                        Button("Edit…") {
                                            functionBreakpointEditor = FunctionBreakpointEditorContext(
                                                breakpoint: breakpoint
                                            )
                                        }
                                        Button(breakpoint.enabled ? "Disable" : "Enable") {
                                            feature.setFunctionBreakpointEnabled(
                                                breakpoint,
                                                enabled: !breakpoint.enabled
                                            )
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
                                }
                                .padding(.horizontal, 10)
                                .frame(minHeight: 31)
                                .opacity(breakpoint.enabled ? 1 : 0.55)
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
                                HStack(spacing: 7) {
                                    Button {
                                        feature.setDataBreakpointEnabled(
                                            breakpoint,
                                            enabled: !breakpoint.enabled
                                        )
                                    } label: {
                                        Image(systemName: "eye.circle.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(
                                                breakpoint.enabled
                                                    ? (breakpoint.verified ? LitheTheme.error : LitheTheme.warning)
                                                    : LitheTheme.secondaryText
                                            )
                                    }
                                    .buttonStyle(.plain)
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
                                    Menu {
                                        Button("Edit…") { editingDataBreakpoint = breakpoint }
                                        Button(breakpoint.enabled ? "Disable" : "Enable") {
                                            feature.setDataBreakpointEnabled(
                                                breakpoint,
                                                enabled: !breakpoint.enabled
                                            )
                                        }
                                        Divider()
                                        Button("Remove", role: .destructive) {
                                            feature.removeDataBreakpoint(breakpoint)
                                        }
                                    } label: { Image(systemName: "ellipsis") }
                                        .menuStyle(.borderlessButton)
                                        .fixedSize()
                                }
                                .padding(.horizontal, 10)
                                .frame(minHeight: 31)
                                .opacity(breakpoint.enabled ? 1 : 0.55)
                            }
                        }
                    }
                }

            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .litheWorkbenchSurface(LitheTheme.sidebar)
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
            Image(systemName: "function")
                .foregroundStyle(LitheTheme.secondaryText)
            TextField("Evaluate expression", text: $evaluateExpression)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit { addWatchExpression() }
            Button { addWatchExpression() } label: {
                Image(systemName: "plus.circle")
            }
            .litheIconButton()
            .help("Add watch")
            Button { feature.evaluate(evaluateExpression) } label: {
                Image(systemName: "arrow.right.circle")
            }
            .litheIconButton()
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
                Image(systemName: "arrow.clockwise")
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

    private var output: some View {
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 8) {
                    if let stoppedReason = feature.stoppedReason {
                        Label(stoppedReason, systemImage: "pause.circle.fill")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(LitheTheme.warning)
                    }
                    if let errorMessage = feature.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(LitheTheme.error)
                    }
                    Text(feature.output.isEmpty ? "Waiting for Debug Adapter output…" : feature.output)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(LitheTheme.primaryText)
                        .textSelection(.enabled)
                }
                .frame(
                    minWidth: max(0, geometry.size.width - 24),
                    minHeight: max(0, geometry.size.height - 24),
                    alignment: .topLeading
                )
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .litheWorkbenchSurface(LitheTheme.editor)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            LitheSystemIcon(systemImage: "ladybug")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(LitheTheme.secondaryText)
            Text("Debug the current \(currentLanguageName) file")
                .font(.system(size: 13, weight: .medium))
            Text("The Debug Adapter starts only when this action is used.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
            Button("Start Debugging") { model.startDebugging() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(LitheTheme.accent)
            Button("Connect to Running JVM") { isJavaAttachPresented = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var currentLanguageName: String {
        guard let document = model.activeDocument,
              let descriptor = model.languageProviderCatalog.provider(for: document.url)
        else { return "source" }
        return descriptor.displayName
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

    private var breakpointSectionHeader: some View {
        HStack {
            Text("Breakpoints")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
            Text(String(feature.breakpoints.count))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
            Menu {
                Button(feature.areBreakpointsMuted ? "Unmute All" : "Mute All") {
                    feature.toggleBreakpointMute()
                }
                Button("Remove All", role: .destructive) {
                    feature.removeAllBreakpoints()
                }
                .disabled(feature.breakpoints.isEmpty)
            } label: {
                Image(systemName: feature.areBreakpointsMuted ? "speaker.slash.fill" : "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Breakpoint actions")
        }
        .padding(.horizontal, 10)
        .frame(height: 27)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private var functionBreakpointSectionHeader: some View {
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
        }
        .padding(.horizontal, 10)
        .frame(height: 27)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private func breakpointSymbol(_ breakpoint: GenericDebugBreakpoint) -> String {
        if breakpoint.isLogpoint { return breakpoint.enabled ? "diamond.fill" : "diamond" }
        return breakpoint.enabled ? "circle.fill" : "circle"
    }

    private func variableSymbol(_ variable: DebugVariable) -> String {
        guard variable.isExpandable else { return "circle.fill" }
        if feature.isVariableLoading(variable) { return "hourglass" }
        return feature.isVariableExpanded(variable) ? "chevron.down" : "chevron.right"
    }

    private func breakpointColor(_ breakpoint: GenericDebugBreakpoint) -> Color {
        guard breakpoint.enabled, !feature.areBreakpointsMuted else {
            return LitheTheme.secondaryText
        }
        if breakpoint.isLogpoint { return LitheTheme.accent }
        return breakpoint.verified ? LitheTheme.error : LitheTheme.warning
    }

    private func breakpointDetail(_ breakpoint: GenericDebugBreakpoint) -> String? {
        if let logMessage = breakpoint.logMessage { return "Log: \(logMessage)" }
        if let condition = breakpoint.condition { return "If: \(condition)" }
        if let hitCondition = breakpoint.hitCondition { return "Hit: \(hitCondition)" }
        return breakpoint.message
    }

    private func functionBreakpointDetail(
        _ breakpoint: GenericDebugFunctionBreakpoint
    ) -> String? {
        if let condition = breakpoint.condition { return "If: \(condition)" }
        if let hitCondition = breakpoint.hitCondition { return "Hit: \(hitCondition)" }
        return breakpoint.message
    }

    private func dataBreakpointDetail(_ breakpoint: GenericDebugDataBreakpoint) -> String {
        var parts = [breakpoint.accessType ?? "access"]
        if let condition = breakpoint.condition { parts.append("if \(condition)") }
        if let hitCondition = breakpoint.hitCondition { parts.append("hit \(hitCondition)") }
        if let message = breakpoint.message { parts.append(message) }
        return parts.joined(separator: " · ")
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

private enum DebugContent: CaseIterable, Identifiable {
    case debugger
    case breakpoints
    case console

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .debugger: "Debugger"
        case .breakpoints: "Breakpoints"
        case .console: "Console"
        }
    }

    var systemImage: String {
        switch self {
        case .debugger: "ladybug"
        case .breakpoints: "circle.fill"
        case .console: "terminal"
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
    let onSave: (BreakpointEditorValue) -> Void
    @State private var enabled: Bool
    @State private var condition: String
    @State private var hitCondition: String
    @State private var logMessage: String

    init(
        breakpoint: GenericDebugBreakpoint,
        onSave: @escaping (BreakpointEditorValue) -> Void
    ) {
        self.breakpoint = breakpoint
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
                editorRow("Condition", text: $condition)
                editorRow("Hit count", text: $hitCondition)
                editorRow("Log message", text: $logMessage)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(BreakpointEditorValue(
                        enabled: enabled,
                        condition: optional(condition),
                        hitCondition: optional(hitCondition),
                        logMessage: optional(logMessage)
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

    private func editorRow(_ title: String, text: Binding<String>) -> some View {
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
