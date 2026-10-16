import SwiftUI

struct TestJVMPerformanceView: View {
    @ObservedObject var feature: TestJVMPerformanceFeatureModel
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            if feature.usesJVM {
                HStack(spacing: 4) {
                    Button(action: feature.isRecording ? feature.stopRecording : feature.startRecording) {
                        LitheIDEAIcon(resourcePath: feature.isRecording ? "expui/run/stop.svg" : "expui/profiler/rec.svg",
                            size: 16, preservesOriginalColors: true, usesIDEADisabledAppearance: true)
                    }
                    .buttonStyle(LitheIconButtonStyle(size: LitheTheme.Metrics.toolbarIconButtonSize, disabledOpacity: 1))
                    .disabled(feature.isBusy || (!feature.isRecording && !feature.canStartRecording))
                    .help(feature.isRecording ? "Stop Recording" : "Start Recording")
                    .accessibilityLabel(feature.isRecording ? "Stop Recording" : "Start Recording")
                    Button("Show Results", action: feature.showResults)
                        .buttonStyle(LitheActionButtonStyle())
                        .disabled(feature.recording == nil || feature.isRecording || feature.isBusy)
                    if feature.isBusy { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                    if let recording = feature.recording {
                        TimelineView(.periodic(from: recording.startedAt, by: 1)) { context in
                            Text(Duration.seconds(feature.isRecording
                                ? min(120, max(0, context.date.timeIntervalSince(recording.startedAt)))
                                : feature.recordingDuration).formatted(.time(pattern: .minuteSecond)))
                                .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                    } else {
                        Text("00:00").font(LitheTheme.uiFont(size: 11, design: .monospaced))
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                if !feature.processes.isEmpty {
                    LitheMenu {
                        feature.processes.map { process in
                            LitheContextMenuItem.action("JVM · PID \(process.processID)",
                                checked: feature.selectedProcess == process,
                                isEnabled: !feature.isRecording && !feature.isBusy) { feature.select(process) }
                        }
                    } label: {
                        Text(feature.selectedProcess.map { "JVM · PID \($0.processID)" } ?? "Select test JVM")
                            .font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.secondaryText)
                    }
                    .buttonStyle(.litheNoPress)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                } else if feature.recording == nil {
                    Text("Waiting for a local test JVM…")
                        .font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            }
            if let error = feature.errorMessage {
                Text(error).font(LitheTheme.uiFont(size: 12)).foregroundStyle(LitheTheme.error)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if feature.usesJVM, feature.selectedProcess != nil, !feature.isProcessRunning {
                Text("Process Terminated").font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText).padding(12)
            }
            TestJVMLiveCharts(feature: feature.metrics, residentMemory: !feature.usesJVM)
        }
        .background(LitheCenteredPopup(isPresented: Binding(
            get: { feature.report != nil }, set: { if !$0 { feature.report = nil } }
        ), dialogTitle: String(localized: "Performance Results", locale: locale)) {
            VStack(spacing: 10) {
                OutputTextView(output: feature.report ?? "", searchRoots: [], fileExists: { _ in false },
                    emptyMessage: "No profiling events were recorded.", wrapsLines: false) { _, _, _ in }
                HStack {
                    Spacer()
                    Button("Close") { feature.report = nil }
                        .buttonStyle(LitheCommitDialogButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(width: 760, height: 500)
            .foregroundStyle(LitheTheme.primaryText)
            .background(LitheCommitDialogStyle.background)
            .environment(\.lithePointingHandCursorEnabled, false)
            .onExitCommand { feature.report = nil }
        }.frame(width: 0, height: 0).allowsHitTesting(false))
    }
}

private struct TestJVMLiveCharts: View {
    @ObservedObject var feature: DebugPerformanceFeatureModel
    let residentMemory: Bool
    @State private var hoveredTime: TimeInterval?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let error = feature.errorMessage {
                    Text(LocalizedStringKey(error)).font(LitheTheme.uiFont(size: 12))
                        .foregroundStyle(LitheTheme.secondaryText).padding(12)
                }
                DebugPerformanceChart(samples: feature.samples, cpu: true,
                    residentMemory: residentMemory, hoveredTime: $hoveredTime).frame(height: 160)
                DebugPerformanceChart(samples: feature.samples, cpu: false,
                    residentMemory: residentMemory, hoveredTime: $hoveredTime).frame(height: 160)
            }
        }.litheScrollViewChrome()
    }
}
