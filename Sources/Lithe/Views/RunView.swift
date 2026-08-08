import SwiftUI

struct RunView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: JavaRunFeatureModel
    @State private var selectedSessionID: String?
    /// The configuration whose editor popover is open. Held separately from the list
    /// selection so opening an editor does not switch which log is shown.
    @State private var editingConfigurationID: String?

    var body: some View {
        VStack(spacing: 0) {
            toolWindowHeader

            if !feature.portConflicts.isEmpty {
                portConflictBanner
                Rectangle().fill(LitheTheme.warning.opacity(0.35)).frame(height: 1)
            }

            if let notice = configurationNotice {
                configurationNoticeBanner(notice)
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }

            if feature.configurationStatus != .ready {
                configurationSetupView
            } else if !hasRunnableConfigurations {
                OutputTextView(
                    output: feature.output,
                    searchRoots: feature.sourceSearchRoots,
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
                        searchRoots: feature.sourceSearchRoots,
                        emptyMessage: "Select a run configuration to see its output."
                    ) { url, line, column in
                        model.openSourceLocation(url: url, line: line, column: column)
                    }
                }
            }
        }
        .background(LitheTheme.editor)
        .onChange(of: feature.configurations) {
            if let selectedSessionID,
               !feature.configurations.contains(where: { $0.id == selectedSessionID }) {
                self.selectedSessionID = nil
            }
        }
    }

    private var configurationSetupView: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.slash")
                .font(.system(size: 28))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(configurationSetupTitle)
                .font(.system(size: 14, weight: .semibold))
            Text(configurationSetupMessage)
                .font(.system(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if feature.isLoadingProject {
                ProgressView("Identifying project…")
                    .controlSize(.small)
            } else if feature.recoveryAction == .editConfiguration {
                HStack(spacing: 8) {
                    Button("Open Configuration") {
                        model.openRunConfiguration(relativePath: feature.recoveryPath)
                    }
                    if canRegenerateBrokenFile {
                        Button("Regenerate") {
                            feature.requestRunConfigurationGeneration()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else if feature.recoveryAction == .upgradeApplication {
                Label("Update Lithe to use this configuration version.", systemImage: "arrow.down.app")
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.warning)
            } else if feature.recoveryAction != .none {
                Button {
                    feature.requestRunConfigurationGeneration()
                } label: {
                    Label(
                        feature.recoveryAction == .fixPermissions
                            ? String(localized: "Retry Identification")
                            : String(localized: "Identify and Generate"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var canRegenerateBrokenFile: Bool {
        feature.recoveryPath == ".lithe/run/generated.json"
            || feature.recoveryPath == ".lithe/toolchains/requirements.json"
    }

    private var configurationNotice: (title: String, message: String, systemImage: String)? {
        if let diagnostic = feature.configurationDiagnostics.first(where: { $0.code == "staleFingerprint" }) {
            return (
                String(localized: "Run configurations may be out of date"),
                diagnostic.message,
                "exclamationmark.triangle.fill"
            )
        }
        if let diagnostic = feature.blockingToolchainDiagnostic {
            return (
                String(localized: "Project toolchain needs attention"),
                diagnostic.message,
                "wrench.and.screwdriver.fill"
            )
        }
        if let diagnostic = feature.configurationDiagnostics.first(where: { $0.code == "toolchainVendorMismatch" }) {
            return (
                String(localized: "Different JDK vendor selected"),
                diagnostic.message,
                "info.circle.fill"
            )
        }
        switch feature.generationState {
        case .succeeded(let entryCount):
            return (
                String(localized: "Project identification complete"),
                entryCount == 1
                    ? String(localized: "Generated 1 runnable project entry.")
                    : String(
                        format: String(localized: "Generated %lld runnable project entries."),
                        Int64(entryCount)
                    ),
                "checkmark.circle.fill"
            )
        case .noEntries:
            return (
                String(localized: "No project entry point detected"),
                String(localized: "Current File remains available. Add a supported Java or Maven entry point, then identify the project again."),
                "info.circle.fill"
            )
        case .failed(let message):
            return (String(localized: "Project identification failed"), message, "xmark.octagon.fill")
        case .idle:
            return nil
        }
    }

    private func configurationNoticeBanner(
        _ notice: (title: String, message: String, systemImage: String)
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: notice.systemImage)
                .foregroundStyle(LitheTheme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(notice.message)
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if feature.configurationDiagnostics.contains(where: { $0.code == "staleFingerprint" }) {
                Button("Identify Again") {
                    feature.requestRunConfigurationGeneration()
                }
                .controlSize(.small)
            } else if feature.blockingToolchainDiagnostic != nil {
                Button("Open Settings") {
                    model.showSettings()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(LitheTheme.warning.opacity(0.08))
    }

    private var configurationSetupTitle: String {
        switch feature.configurationStatus {
        case .missing: String(localized: "Project run configuration not found")
        case .invalid: String(localized: "Project run configuration is invalid")
        case .ready: String(localized: "Run configuration ready")
        }
    }

    private var configurationSetupMessage: String {
        switch feature.configurationStatus {
        case .missing:
            String(localized: "Generate .lithe/run/generated.json to enable Run and Debug. Existing project and local overrides will be preserved.")
        case .invalid(let message):
            message
        case .ready:
            ""
        }
    }

    private var toolWindowHeader: some View {
        LitheToolWindowHeader(
            title: "Run",
            systemImage: "play.rectangle",
            ideaAssetPath: "toolwindows/toolWindowRun.svg",
            subtitle: selectedModuleSession?.title ?? feature.runningTitle,
            onMinimize: { model.isRunVisible = false }
        ) {
            if let session = selectedModuleSession {
                sessionStatus(isRunning: session.isRunning, exitCode: session.exitCode)
            } else if feature.isLoadingProject {
                ProgressView()
                    .controlSize(.mini)
            } else if feature.isRunning {
                Label("Running", systemImage: "circle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.success)
            } else if let exitCode = feature.lastExitCode {
                sessionStatus(isRunning: false, exitCode: exitCode)
            }

            if hasServiceConfigurations {
                Button {
                    feature.runAllServices()
                    selectedSessionID = feature.moduleSessions.first?.id
                } label: {
                    Image(systemName: "square.stack.3d.up.fill")
                }
                .litheIconButton()
                .help("Run all services")
                .disabled(feature.configurationStatus != .ready || feature.isLoadingProject)

                if feature.moduleSessions.contains(where: \.isRunning) {
                    Button(action: feature.stopAllServices) {
                        Image(systemName: "stop.circle")
                    }
                    .litheIconButton()
                    .foregroundStyle(LitheTheme.warning)
                    .help("Stop all services")
                }
            }

            Button {
                if let session = selectedModuleSession, session.isRunning {
                    feature.stopModule(session)
                } else if let configuration = selectedRunnableConfiguration {
                    feature.startConfiguration(configuration)
                } else if feature.isRunning {
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
            .disabled(feature.isLoadingProject)

            Button {
                if let configuration = selectedRunnableConfiguration {
                    feature.startConfiguration(configuration)
                } else {
                    model.restartSelectedRun()
                }
            } label: {
                LitheSystemIcon(systemImage: "arrow.clockwise")
            }
            .litheIconButton()
            .disabled(selectedModuleSession == nil && feature.runningTitle == nil && feature.lastExitCode == nil)
            .help("Restart run")

            Button {
                feature.requestRunConfigurationGeneration()
            } label: {
                Image(systemName: "sparkle.magnifyingglass")
            }
            .litheIconButton()
            .disabled(feature.isLoadingProject)
            .help("Rescan services")

            Button {
                if let session = selectedModuleSession {
                    feature.clearModuleOutput(session)
                } else {
                    feature.clearOutput()
                }
            } label: {
                Image(systemName: "trash")
            }
            .litheIconButton()
            .help("Clear run output")

        }
    }

    private var runnableConfigurations: [JavaRunConfiguration] {
        feature.configurations.filter { $0.kind != .currentFile }
    }

    private var serviceConfigurations: [JavaRunConfiguration] {
        runnableConfigurations.filter { $0.execution == .service }
    }

    private var hasServiceConfigurations: Bool {
        !serviceConfigurations.isEmpty
    }

    private var hasRunnableConfigurations: Bool {
        !runnableConfigurations.isEmpty
    }

    private var portConflictBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(feature.portConflicts) { conflict in
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
        return feature.moduleSessions.first(where: { $0.id == selectedSessionID })
    }

    /// The list shows every service, running or not, so a selection can name a
    /// configuration that has no session yet.
    private var selectedRunnableConfiguration: JavaRunConfiguration? {
        guard let selectedSessionID else { return nil }
        return runnableConfigurations.first(where: { $0.id == selectedSessionID })
    }

    private var selectedSessionIsRunning: Bool {
        guard selectedSessionID != nil else { return feature.isRunning }
        return selectedModuleSession?.isRunning ?? false
    }

    private var selectedOutput: String {
        guard selectedSessionID != nil else { return feature.output }
        return selectedModuleSession?.output ?? ""
    }

    private var moduleSessionList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                sessionRow(
                    title: String(localized: "Current run"),
                    subtitle: feature.runningTitle ?? String(localized: "Primary configuration"),
                    isRunning: feature.isRunning,
                    exitCode: feature.lastExitCode,
                    isSelected: selectedSessionID == nil,
                    onToggle: nil
                ) {
                    selectedSessionID = nil
                }

                ForEach(RunConfigurationExecution.displayOrder, id: \.self) { execution in
                    let configurations = runnableConfigurations.filter { $0.execution == execution }
                    if !configurations.isEmpty {
                        Text(String(localized: String.LocalizationValue(execution.sectionTitle)))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.top, 8)

                        ForEach(configurations) { configuration in
                            let session = feature.moduleSessions.first { $0.id == configuration.id }
                            sessionRow(
                                title: configuration.name,
                                subtitle: String(localized: String.LocalizationValue(configuration.kind.title)),
                                isRunning: session?.isRunning ?? false,
                                exitCode: session?.exitCode,
                                isSelected: selectedSessionID == configuration.id,
                                onEdit: {
                                    editingConfigurationID = configuration.id
                                },
                                isEditing: Binding(
                                    get: { editingConfigurationID == configuration.id },
                                    set: { isPresented in
                                        if !isPresented, editingConfigurationID == configuration.id {
                                            editingConfigurationID = nil
                                        }
                                    }
                                ),
                                editorConfiguration: configuration,
                                onToggle: {
                                    if let session, session.isRunning {
                                        feature.stopModule(session)
                                    } else {
                                        feature.startConfiguration(configuration)
                                        selectedSessionID = configuration.id
                                    }
                                }
                            ) {
                                selectedSessionID = configuration.id
                            }
                        }
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
        onEdit: (() -> Void)? = nil,
        isEditing: Binding<Bool> = .constant(false),
        editorConfiguration: JavaRunConfiguration? = nil,
        onToggle: (() -> Void)?,
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
                if let onEdit, let editorConfiguration {
                    Button(action: onEdit) {
                        Image(systemName: "gearshape")
                    }
                    .litheIconButton()
                    .foregroundStyle(LitheTheme.secondaryText)
                    .help("Edit run configuration")
                    .disabled(feature.configurationStatus != .ready || feature.isLoadingProject)
                    .popover(isPresented: isEditing, arrowEdge: .trailing) {
                        JavaRunConfigurationEditorView(
                            feature: feature,
                            configuration: editorConfiguration
                        )
                    }
                }
                if let onToggle {
                    Button(action: onToggle) {
                        Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    }
                    .litheIconButton()
                    .foregroundStyle(isRunning ? LitheTheme.warning : LitheTheme.success)
                    .help(isRunning ? "Stop" : "Run")
                    .disabled(feature.configurationStatus != .ready || feature.isLoadingProject)
                }
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
