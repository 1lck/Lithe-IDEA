import SwiftUI

struct JavaDebugView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var service: JavaDebugFeatureModel
    @ObservedObject var runService: JavaRunFeatureModel
    @State private var evaluateExpression = ""

    init(feature: JavaDebugFeatureModel, runFeature: JavaRunFeatureModel) {
        service = feature
        runService = runFeature
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            targetBar
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            if service.isSessionActive || !service.output.isEmpty {
                HStack(spacing: 0) {
                    inspector
                        .frame(width: 280)
                    Rectangle().fill(LitheTheme.divider).frame(width: 1)
                    outputView
                }
            } else {
                emptyState
            }
        }
        .background(LitheTheme.editor)
    }

    private var targetBar: some View {
        VStack(spacing: 7) {
            Picker("Debug target", selection: $service.targetKind) {
                ForEach(JavaDebugTargetKind.allCases) { target in
                    Label(LocalizedStringKey(target.title), systemImage: target.systemImage)
                        .tag(target)
                }
            }
            .pickerStyle(.segmented)
            .lithePointer()
            .labelsHidden()
            .disabled(service.isSessionActive)

            switch service.targetKind {
            case .currentFile:
                HStack(spacing: 7) {
                    LitheSystemIcon(systemImage: "doc.text")
                        .foregroundStyle(LitheTheme.secondaryText)
                    Text(model.activeDocument?.url.lastPathComponent ?? "Open a Java file")
                        .font(.system(size: 11.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            case .runConfiguration:
                HStack(spacing: 7) {
                    if let selectedDebugConfiguration {
                        RunConfigurationIcon(kind: selectedDebugConfiguration.kind, size: 16)
                    } else {
                        LitheSystemIcon(systemImage: "shippingbox")
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                    Menu {
                        if debugConfigurations.isEmpty {
                            Text("No Spring Boot or Maven Module configurations")
                        } else {
                            ForEach(debugConfigurations) { configuration in
                                Button {
                                    model.selectRunConfiguration(configuration)
                                } label: {
                                    HStack {
                                        RunConfigurationIcon(kind: configuration.kind, size: 16)
                                        Text(configuration.name)
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedDebugConfiguration?.name ?? "Select a Spring Boot or Maven Module configuration")
                                .font(.system(size: 11.5))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .lithePointer()
                    .menuIndicator(.hidden)
                    Spacer(minLength: 0)
                }
            case .remote:
                remoteFields
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(LitheTheme.toolHeader)
    }

    private var remoteFields: some View {
        HStack(spacing: 8) {
            TextField("Host", text: $service.remoteHost)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
            TextField("JDWP port", text: $service.remotePort)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
            TextField("Local JDK Home (optional)", text: $service.remoteJavaHomePath)
                .textFieldStyle(.roundedBorder)
            Image(systemName: "lock.shield")
                .foregroundStyle(LitheTheme.warning)
                .help("JDWP is not encrypted; prefer localhost or an SSH tunnel")
        }
        .font(.system(size: 11.5))
        .disabled(service.isSessionActive)
    }

    private var header: some View {
        LitheToolWindowHeader(
            title: "Debug",
            systemImage: "ladybug",
            ideaAssetPath: "toolwindows/toolWindowDebugger.svg",
            subtitle: service.state.title,
            onMinimize: { model.isDebugVisible = false }
        ) {
            if let runningTargetTitle = service.runningTargetTitle {
                Text(runningTargetTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            }

            if let port = service.port {
                Text("JDWP \(port)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            Spacer()

            Group {
                Button {
                    model.toggleDebugBreakpointAtCaret()
                } label: {
                    Image(systemName: "smallcircle.filled.circle")
                }
                .litheIconButton()
                .help("Toggle breakpoint at caret")

                Button {
                    if canStop {
                        model.stopDebugging()
                    } else {
                        model.startDebugging()
                    }
                } label: {
                    Image(systemName: canStop ? "stop.fill" : "play.fill")
                }
                .litheIconButton()
                .foregroundStyle(canStop ? LitheTheme.warning : LitheTheme.success)
                .help(canStop ? "Stop debugging" : "Start debugging")

                Button {
                    service.pause()
                } label: {
                    Image(systemName: "pause.fill")
                }
                .litheIconButton()
                .disabled(!service.canControl || service.state != .running)
                .help("Pause")
            }

            Button {
                service.continueExecution()
            } label: {
                LitheSystemIcon(systemImage: "play.fill")
            }
            .litheIconButton()
            .disabled(!service.canControl || service.state != .paused)
            .help("Continue")

            Button {
                service.stepOver()
            } label: {
                Image(systemName: "arrow.right.to.line")
            }
            .litheIconButton()
            .disabled(!service.canControl || service.state != .paused)
            .help("Step over")

            Button {
                service.stepInto()
            } label: {
                Image(systemName: "arrow.down.to.line")
            }
            .litheIconButton()
            .disabled(!service.canControl || service.state != .paused)
            .help("Step into")

            Button {
                service.stepOut()
            } label: {
                Image(systemName: "arrow.up.to.line")
            }
            .litheIconButton()
            .disabled(!service.canControl || service.state != .paused)
            .help("Step out")

            Button {
                service.clearOutput()
            } label: {
                Image(systemName: "trash")
            }
            .litheIconButton()
            .help("Clear debug output")

        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Breakpoints", count: service.breakpoints.count)
            if service.breakpoints.isEmpty {
                Text("No breakpoints")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(service.breakpoints) { breakpoint in
                            HStack(spacing: 7) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(LitheTheme.error)
                                Text(breakpoint.title)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(LitheTheme.primaryText)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            Group {
                sectionHeader("Inspect", count: nil)
                inspectButton("Threads", icon: "person.3", action: service.inspectThreads)
                inspectButton("Call Stack", icon: "list.number", action: service.inspectStack)
                inspectButton("Local Variables", icon: "list.bullet.rectangle", action: service.inspectVariables)
                evaluateRow
            }

            if let exceptionMessage = service.exceptionMessage {
                exceptionBanner(exceptionMessage)
            }

            if let title = service.inspectionTitle {
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                Text(LocalizedStringKey(title))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 30, alignment: .leading)
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        structuredInspection
                        if !service.inspectionOutput.isEmpty {
                            DisclosureGroup("Raw jdb output") {
                                Text(service.inspectionOutput)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .padding(.top, 7)
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .lithePointer()
                            .padding(10)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }

            Spacer(minLength: 0)
        }
        .background(LitheTheme.sidebar)
    }

    private var evaluateRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "function")
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 16)
            TextField("Evaluate expression", text: $evaluateExpression)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .onSubmit {
                    service.evaluate(evaluateExpression)
                }
            Button {
                service.evaluate(evaluateExpression)
            } label: {
                Image(systemName: "arrow.right.circle")
            }
            .litheIconButton()
            .disabled(evaluateExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Evaluate expression")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(LitheTheme.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var structuredInspection: some View {
        switch service.inspectionTitle {
        case "Threads":
            if service.threads.isEmpty {
                Text("Waiting for thread data…")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .padding(10)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(service.threads) { thread in
                        HStack(spacing: 7) {
                            Image(systemName: thread.isCurrent ? "play.circle.fill" : "circle")
                                .foregroundStyle(thread.isCurrent ? LitheTheme.accent : LitheTheme.secondaryText)
                            Text(thread.name)
                                .font(.system(size: 11.5, weight: thread.isCurrent ? .medium : .regular))
                                .foregroundStyle(LitheTheme.primaryText)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(thread.status.isEmpty ? thread.id : thread.status)
                                .font(.system(size: 10.5))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 28)
                    }
                }
            }
        case "Call Stack":
            if service.callStack.isEmpty {
                Text("Waiting for stack data…")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .padding(10)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(service.callStack) { frame in
                        HStack(alignment: .top, spacing: 8) {
                            Text("#\(frame.level)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .frame(width: 24, alignment: .trailing)
                            Text(frame.description)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(LitheTheme.primaryText)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                }
            }
        case "Local Variables":
            if service.variables.isEmpty {
                Text("No local variables in the current frame")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .padding(10)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(service.variables) { variable in
                        variableRow(variable, depth: 0)
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    private func variableRow(_ variable: JavaDebugVariable, depth: Int) -> JavaDebugVariableRow {
        JavaDebugVariableRow(service: service, variable: variable, depth: depth)
    }

    private func exceptionBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LitheTheme.error)
            VStack(alignment: .leading, spacing: 2) {
                Text("Exception")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                Text(message)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(LitheTheme.error.opacity(0.10))
    }

    private var outputView: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(service.output.isEmpty ? "Waiting for debugger output…" : service.output)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(LitheTheme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            LitheSystemIcon(systemImage: "ladybug")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(emptyStateTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            Button(emptyStateActionTitle) {
                model.startDebugging()
            }
            .buttonStyle(.borderedProminent)
            .lithePointer()
            .tint(LitheTheme.accent)
            .controlSize(.small)
            .disabled(
                runService.isLoadingProject ||
                    (service.targetKind == .runConfiguration &&
                        runService.configurationStatus == .ready &&
                        selectedDebugConfiguration == nil)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var debugConfigurations: [JavaRunConfiguration] {
        runService.configurations.filter {
            $0.kind.isMavenBacked
        }
    }

    private var selectedDebugConfiguration: JavaRunConfiguration? {
        guard let configuration = runService.selectedConfiguration,
              configuration.kind.isMavenBacked else {
            return nil
        }
        return configuration
    }

    private var emptyStateTitle: String {
        switch service.targetKind {
        case .currentFile:
            "Start debugging the current Java file"
        case .runConfiguration:
            selectedDebugConfiguration.map { "Start debugging \($0.name)" }
                ?? "Select a Spring Boot or Maven Module configuration"
        case .remote:
            "Attach to a remote JVM or Tomcat"
        }
    }

    private var emptyStateActionTitle: String {
        service.targetKind == .remote ? "Attach" : "Start Debugging"
    }

    private func sectionHeader(_ title: String, count: Int?) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Spacer()
            if let count {
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(LitheTheme.sidebar)
    }

    private func inspectButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(LocalizedStringKey(title), systemImage: icon)
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
    }

    private var canStop: Bool {
        service.isSessionActive
    }

    private var stateColor: Color {
        switch service.state {
        case .running: LitheTheme.success
        case .paused: LitheTheme.accent
        case .failed: LitheTheme.error
        case .launching: LitheTheme.warning
        default: LitheTheme.secondaryText
        }
    }
}

private struct JavaDebugVariableRow: View {
    @ObservedObject var service: JavaDebugFeatureModel
    let variable: JavaDebugVariable
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                service.toggleVariable(variable)
            } label: {
                HStack(spacing: 6) {
                    if variable.canExpand {
                        Image(systemName: service.expandingVariableID == variable.id ? "hourglass" : (variable.isExpanded ? "chevron.down" : "chevron.right"))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .frame(width: 10)
                    } else {
                        Color.clear.frame(width: 10, height: 1)
                    }
                    Text(variable.name)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(LitheTheme.primaryText)
                    Text(variable.value)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth * 14) + 10)
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()

            if variable.isExpanded {
                ForEach(variable.children) { child in
                    JavaDebugVariableRow(service: service, variable: child, depth: depth + 1)
                }
            }
        }
    }
}
