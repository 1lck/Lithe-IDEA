import SwiftUI

struct RunView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var service: JavaRunService
    @State private var selectedSessionID: String?

    var body: some View {
        VStack(spacing: 0) {
            toolWindowHeader

            if !service.portConflicts.isEmpty {
                portConflictBanner
                Rectangle().fill(LitheTheme.warning.opacity(0.35)).frame(height: 1)
            }

            if service.moduleSessions.isEmpty {
                OutputTextView(
                    output: service.output,
                    searchRoots: service.sourceSearchRoots,
                    emptyMessage: "Run a configuration to see process output."
                ) { url, line, column in
                    model.openSourceLocation(url: url, line: line, column: column)
                }
            } else {
                HStack(spacing: 0) {
                    moduleSessionList
                        .frame(width: 230)
                    Rectangle().fill(LitheTheme.divider).frame(width: 1)
                    OutputTextView(
                        output: selectedOutput,
                        searchRoots: service.sourceSearchRoots,
                        emptyMessage: "Select a run session to see process output."
                    ) { url, line, column in
                        model.openSourceLocation(url: url, line: line, column: column)
                    }
                }
            }
        }
        .background(LitheTheme.editor)
        .onChange(of: service.moduleSessions) {
            if let selectedSessionID,
               !service.moduleSessions.contains(where: { $0.id == selectedSessionID }) {
                self.selectedSessionID = nil
            }
        }
    }

    private var toolWindowHeader: some View {
        LitheToolWindowHeader(
            title: "Run",
            systemImage: "play.rectangle",
            ideaAssetPath: "toolwindows/toolWindowRun.svg",
            subtitle: selectedModuleSession?.title ?? service.runningTitle,
            onMinimize: { model.isRunVisible = false }
        ) {
            if let session = selectedModuleSession {
                sessionStatus(isRunning: session.isRunning, exitCode: session.exitCode)
            } else if service.isLoadingProject {
                ProgressView()
                    .controlSize(.mini)
            } else if service.isRunning {
                Label("Running", systemImage: "circle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.success)
            } else if let exitCode = service.lastExitCode {
                sessionStatus(isRunning: false, exitCode: exitCode)
            }

            if hasModuleConfigurations {
                Button {
                    service.runAllModules()
                    selectedSessionID = service.moduleSessions.first?.id
                } label: {
                    Image(systemName: "square.stack.3d.up.fill")
                }
                .litheIconButton()
                .help("Run all Maven modules")

                if service.moduleSessions.contains(where: \.isRunning) {
                    Button(action: service.stopAllModules) {
                        Image(systemName: "stop.circle")
                    }
                    .litheIconButton()
                    .foregroundStyle(LitheTheme.warning)
                    .help("Stop all Maven modules")
                }
            }

            Button {
                if let session = selectedModuleSession {
                    if session.isRunning {
                        service.stopModule(session)
                    } else {
                        service.restartModule(session)
                    }
                } else if service.isRunning {
                    model.stopSelectedRun()
                } else {
                    model.runSelectedConfiguration()
                }
            } label: {
                Image(systemName: selectedSessionIsRunning ? "stop.fill" : "play.fill")
            }
            .litheIconButton()
            .foregroundStyle(selectedSessionIsRunning ? LitheTheme.warning : LitheTheme.success)
            .help(selectedSessionIsRunning ? "Stop run" : "Run configuration")

            Button {
                if let session = selectedModuleSession {
                    service.restartModule(session)
                } else {
                    model.restartSelectedRun()
                }
            } label: {
                LitheSystemIcon(systemImage: "arrow.clockwise")
            }
            .litheIconButton()
            .disabled(selectedModuleSession == nil && service.runningTitle == nil && service.lastExitCode == nil)
            .help("Restart run")

            Button {
                if let session = selectedModuleSession {
                    service.clearModuleOutput(session)
                } else {
                    service.clearOutput()
                }
            } label: {
                Image(systemName: "trash")
            }
            .litheIconButton()
            .help("Clear run output")

        }
    }

    private var hasModuleConfigurations: Bool {
        service.configurations.contains(where: { $0.kind == .mavenModule })
    }

    private var portConflictBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(service.portConflicts) { conflict in
                Label(conflict.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.warning)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.10))
    }

    private var selectedModuleSession: JavaRunSession? {
        guard let selectedSessionID else { return nil }
        return service.moduleSessions.first(where: { $0.id == selectedSessionID })
    }

    private var selectedSessionIsRunning: Bool {
        selectedModuleSession?.isRunning ?? service.isRunning
    }

    private var selectedOutput: String {
        selectedModuleSession?.output ?? service.output
    }

    private var moduleSessionList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                sessionRow(
                    title: "Current run",
                    subtitle: service.runningTitle ?? "Primary configuration",
                    isRunning: service.isRunning,
                    exitCode: service.lastExitCode,
                    isSelected: selectedSessionID == nil
                ) {
                    selectedSessionID = nil
                }

                ForEach(service.moduleSessions) { session in
                    sessionRow(
                        title: session.title,
                        subtitle: "Maven Module",
                        isRunning: session.isRunning,
                        exitCode: session.exitCode,
                        isSelected: selectedSessionID == session.id
                    ) {
                        selectedSessionID = session.id
                    }
                }
            }
            .padding(7)
        }
        .background(LitheTheme.sidebar)
    }

    private func sessionStatus(isRunning: Bool, exitCode: Int32?) -> some View {
        Group {
            if isRunning {
                Label("Running", systemImage: "circle.fill")
            } else if let exitCode {
                Label(
                    exitCode == 0 ? "Finished" : "Failed",
                    systemImage: exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(isRunning || exitCode == 0 ? LitheTheme.success : LitheTheme.error)
    }

    private func sessionRow(
        title: String,
        subtitle: String,
        isRunning: Bool,
        exitCode: Int32?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isRunning ? "circle.fill" : (exitCode == 0 ? "checkmark.circle.fill" : "play.rectangle"))
                    .foregroundStyle(isRunning ? LitheTheme.success : (exitCode == 0 ? LitheTheme.success : LitheTheme.secondaryText))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 34)
            .background(isSelected ? LitheTheme.subtleSelection : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
    }
}
