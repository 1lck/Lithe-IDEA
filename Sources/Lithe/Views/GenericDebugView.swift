import SwiftUI

struct GenericDebugView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: GenericDebugFeatureModel
    @State private var evaluateExpression = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            if feature.isSessionActive || !feature.output.isEmpty || feature.errorMessage != nil {
                HStack(spacing: 0) {
                    inspector
                        .frame(width: 300)
                    Rectangle().fill(LitheTheme.divider).frame(width: 1)
                    output
                }
            } else {
                emptyState
            }
        }
        .background(LitheTheme.editor)
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
            controlButton("arrow.up.to.line", help: "Step out", disabled: feature.state != .paused) {
                feature.execute(.stepOut)
            }
            Button {
                if feature.isSessionActive {
                    model.stopDebugging()
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Group {
                    sectionHeader("Breakpoints", count: feature.breakpoints.count)
                    if feature.breakpoints.isEmpty {
                        placeholder("Click the editor gutter to add a breakpoint")
                    } else {
                        ForEach(feature.breakpoints) { breakpoint in
                            HStack(spacing: 7) {
                                Image(systemName: breakpoint.verified ? "circle.fill" : "circle")
                                    .font(.system(size: 8))
                                    .foregroundStyle(breakpoint.verified ? LitheTheme.error : LitheTheme.warning)
                                Text(breakpoint.title)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .help(breakpoint.message ?? breakpoint.title)
                            .padding(.horizontal, 10)
                            .frame(height: 27)
                        }
                    }
                }

                Group {
                    divider
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
                        }
                    }
                }

                Group {
                    divider
                    sectionHeader("Call Stack", count: feature.stackFrames.count)
                    if feature.stackFrames.isEmpty {
                        placeholder("Pause the process to inspect frames")
                    } else {
                        ForEach(feature.stackFrames) { frame in
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
                                Image(systemName: "chevron.right")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(frame.name).lineLimit(1)
                                    if let sourceURL = frame.sourceURL {
                                        Text("\(sourceURL.lastPathComponent):\(frame.line)")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(LitheTheme.secondaryText)
                                    }
                                }
                            }
                        }
                    }
                }

                Group {
                    divider
                    sectionHeader("Variables", count: feature.variables.count)
                    if feature.variables.isEmpty {
                        placeholder("Select a stack frame to inspect variables")
                    } else {
                        ForEach(feature.variables) { variable in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: variable.isExpandable ? "chevron.right" : "circle.fill")
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
                                if variable.isExpandable {
                                    feature.loadVariables(reference: variable.variablesReference)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                        }
                    }
                }

                divider
                evaluateRow
            }
        }
        .background(LitheTheme.sidebar)
    }

    private var evaluateRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "function")
                .foregroundStyle(LitheTheme.secondaryText)
            TextField("Evaluate expression", text: $evaluateExpression)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit { feature.evaluate(evaluateExpression) }
            Button { feature.evaluate(evaluateExpression) } label: {
                Image(systemName: "arrow.right.circle")
            }
            .litheIconButton()
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private var output: some View {
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(12)
        }
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
        .background(LitheTheme.toolHeader)
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
