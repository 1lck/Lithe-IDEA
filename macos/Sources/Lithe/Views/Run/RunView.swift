import SwiftUI

struct RunView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @ObservedObject var feature: RunFeatureModel
    @State private var selectedSessionID: String?
    @AppStorage("lithe.run.collapsedExecutions") private var collapsedExecutionIDs = ""
    @AppStorage("lithe.run.pinnedConfigurationIDs") private var pinnedConfigurationTokens = ""
    @AppStorage("lithe.run.configurationListWidth") private var configurationListWidth = 230.0
    @AppStorage("lithe.run.configurationListCollapsed") private var isConfigurationListCollapsed = false
    /// Separate caches: the two raw strings change independently, and one box
    /// memoizes a single raw value.
    @State private var collapsedExecutionCache = RunConfigurationTokenCache()
    @State private var pinnedConfigurationCache = RunConfigurationTokenCache()
    /// The configuration whose editor popover is open. Held separately from the list
    /// selection so opening an editor does not switch which log is shown.
    @State private var editingConfigurationID: String?

    var body: some View {
        let _ = LitheSignpost.bodyEvaluated("RunView")
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
                    fileExists: { model.fileExists(at: $0) },
                    emptyMessage: String(localized: "Run a configuration to see process output.")
                ) { url, line, column in
                    model.openSourceLocation(url: url, line: line, column: column)
                }
            } else {
                GeometryReader { geometry in
                    let minimumListWidth: CGFloat = 180
                    let minimumContentWidth: CGFloat = 320
                    let maximumListWidth = max(
                        minimumListWidth,
                        min(420, geometry.size.width - SplitHandleView.thickness - minimumContentWidth)
                    )
                    if isConfigurationListCollapsed {
                        HStack(spacing: 0) {
                            collapsedConfigurationListBar
                                .frame(width: 32)
                            Rectangle()
                                .fill(LitheTheme.divider)
                                .frame(width: 1)
                            selectedConfigurationContent
                        }
                    } else {
                        LitheSplitPaneView(
                            axis: .horizontal,
                            placement: .leading,
                            defaultSize: CGFloat(configurationListWidth),
                            minimum: minimumListWidth,
                            maximum: maximumListWidth,
                            onCommit: { configurationListWidth = Double($0) },
                            sized: { moduleSessionList },
                            flexible: { selectedConfigurationContent }
                        )
                    }
                }
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .onChange(of: feature.configurations) { _ in
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
        case .projectNotReady:
            return (
                String(localized: "Project is still loading"),
                String(localized: "Wait for the project to finish loading, then identify it again."),
                "clock.fill"
            )
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
                String(localized: "Current File remains available. Add a supported project entry point, then identify the project again."),
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
                Button("Edit Service") {
                    openJavaServiceEditor()
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
            onMinimize: { model.workbenchFeature.setVisibility(.run, isVisible: false) }
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
                    model.runAllServiceConfigurations()
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
                    model.startRunConfiguration(configuration)
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
                    model.startRunConfiguration(configuration)
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

    private var runnableConfigurations: [RunConfiguration] {
        feature.configurations.filter { $0.kind != .currentFile }
    }

    private var serviceConfigurations: [RunConfiguration] {
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

    private var selectedModuleSession: RunSession? {
        guard let selectedSessionID else { return nil }
        return feature.moduleSessions.first(where: { $0.id == selectedSessionID })
    }

    /// The list shows every service, running or not, so a selection can name a
    /// configuration that has no session yet.
    private var selectedRunnableConfiguration: RunConfiguration? {
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

    @ViewBuilder
    private var selectedConfigurationContent: some View {
        if let configuration = selectedRunnableConfiguration {
            configurationContent(configuration)
        } else {
            OutputTextView(
                output: selectedOutput,
                searchRoots: feature.sourceSearchRoots,
                fileExists: { model.fileExists(at: $0) },
                emptyMessage: String(localized: "Select a run configuration to see its output.")
            ) { url, line, column in
                model.openSourceLocation(url: url, line: line, column: column)
            }
        }
    }

    private var collapsedExecutions: Set<String> {
        collapsedExecutionCache.tokens(from: collapsedExecutionIDs, separator: ",")
    }

    private var pinnedConfigurationTokenSet: Set<String> {
        pinnedConfigurationCache.tokens(from: pinnedConfigurationTokens, separator: "\n")
    }

    private func pinToken(for configuration: RunConfiguration) -> String {
        let project = model.workspaceURL?.standardizedFileURL.path ?? ""
        return project + "::" + configuration.id
    }

    private func isPinned(_ configuration: RunConfiguration) -> Bool {
        pinnedConfigurationTokenSet.contains(pinToken(for: configuration))
    }

    private func toggleCollapsed(_ execution: RunConfigurationExecution) {
        var values = collapsedExecutions
        if values.contains(execution.rawValue) {
            values.remove(execution.rawValue)
        } else {
            values.insert(execution.rawValue)
        }
        collapsedExecutionIDs = values.sorted().joined(separator: ",")
    }

    private func togglePinned(_ configuration: RunConfiguration) {
        var values = pinnedConfigurationTokenSet
        let token = pinToken(for: configuration)
        if values.contains(token) {
            values.remove(token)
        } else {
            values.insert(token)
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            pinnedConfigurationTokens = values.sorted().joined(separator: "\n")
        }
    }

    private var pinnedRunnableConfigurations: [RunConfiguration] {
        runnableConfigurations
            .filter(isPinned)
            .sorted(by: configurationNamePrecedes)
    }

    private func unpinnedConfigurations(
        for execution: RunConfigurationExecution
    ) -> [RunConfiguration] {
        runnableConfigurations
            .filter { $0.execution == execution && !isPinned($0) }
            .sorted(by: configurationNamePrecedes)
    }

    private func configurationNamePrecedes(
        _ left: RunConfiguration,
        _ right: RunConfiguration
    ) -> Bool {
        left.name.localizedStandardCompare(right.name) == .orderedAscending
    }

    private var moduleSessionList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Run configurations")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
                Spacer(minLength: 0)
                Button {
                    isConfigurationListCollapsed = true
                } label: {
                    Image(systemName: "chevron.left")
                }
                .litheIconButton()
                .help("Hide configuration list")
                .accessibilityLabel("Hide configuration list")
            }
            .padding(.leading, 12)
            .padding(.trailing, 5)
            .frame(height: 30)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    let pinnedConfigurations = pinnedRunnableConfigurations
                    if !pinnedConfigurations.isEmpty {
                        pinnedSectionHeader(count: pinnedConfigurations.count)

                        ForEach(pinnedConfigurations) { configuration in
                            configurationRow(configuration)
                        }
                    }

                    sessionRow(
                        title: String(localized: "Current run"),
                        subtitle: feature.runningTitle ?? String(localized: "Primary configuration"),
                        isRunning: feature.isRunning,
                        exitCode: feature.lastExitCode,
                        isSelected: selectedSessionID == nil,
                        onToggle: nil
                    ) {
                        selectedSessionID = nil
                        feature.select(.currentFile)
                    }

                    ForEach(RunConfigurationExecution.displayOrder, id: \.self) { execution in
                        let configurations = unpinnedConfigurations(for: execution)
                        if !configurations.isEmpty {
                            sectionHeader(execution, count: configurations.count)

                            if !collapsedExecutions.contains(execution.rawValue) {
                                ForEach(configurations) { configuration in
                                    configurationRow(configuration)
                                }
                            }
                        }
                    }
                }
            }
                .padding(7)
        }
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    private func pinnedSectionHeader(count: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "pin.fill")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 10)
            Text("Pinned")
            Spacer(minLength: 0)
            Text(String(count))
                .font(.system(size: 10))
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(LitheTheme.accent)
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    private func configurationRow(_ configuration: RunConfiguration) -> some View {
        let session = feature.moduleSessions.first { $0.id == configuration.id }
        let serviceURL = session?.isRunning == true ? feature.serviceURL(for: configuration) : nil

        return sessionRow(
            title: configuration.name,
            subtitle: String(localized: String.LocalizationValue(configuration.kind.title)),
            serviceURL: serviceURL,
            configurationKind: configuration.kind,
            isRunning: session?.isRunning ?? false,
            exitCode: session?.exitCode,
            isSelected: selectedSessionID == configuration.id,
            isPinned: isPinned(configuration),
            onPin: { togglePinned(configuration) },
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
                    feature.select(configuration)
                    model.startRunConfiguration(configuration)
                    selectedSessionID = configuration.id
                }
            }
        ) {
            selectedSessionID = configuration.id
            feature.select(configuration)
        }
    }

    private var collapsedConfigurationListBar: some View {
        VStack(spacing: 0) {
            Button {
                isConfigurationListCollapsed = false
            } label: {
                Image(systemName: "chevron.right")
            }
            .litheIconButton()
            .help("Show configuration list")
            .accessibilityLabel("Show configuration list")
            .frame(height: 30)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    private func configurationContent(_ configuration: RunConfiguration) -> some View {
        let session = feature.moduleSessions.first { $0.id == configuration.id }

        return VStack(spacing: 0) {
            configurationDetail(configuration, session: session)
                .frame(maxHeight: session == nil ? .infinity : 220, alignment: .top)

            if let session {
                Rectangle()
                    .fill(LitheTheme.divider)
                    .frame(height: 1)

                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                    Text("Process output")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(LitheTheme.sidebar.opacity(0.45))

                OutputTextView(
                    output: session.output,
                    searchRoots: feature.sourceSearchRoots,
                    fileExists: { model.fileExists(at: $0) },
                    emptyMessage: String(localized: "Process output will appear here.")
                ) { url, line, column in
                    model.openSourceLocation(url: url, line: line, column: column)
                }
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
    }

    private func configurationDetail(
        _ configuration: RunConfiguration,
        session: RunSession?
    ) -> some View {
        let options = feature.options(for: configuration)
        let capabilities = configuration.effectiveCapabilities(
            for: model.activeDocument?.url,
            catalog: model.languageProviderCatalog
        )
        let workingDirectory = options.workingDirectoryPath.isEmpty
            ? (model.workspaceURL?.standardizedFileURL.path ?? String(localized: "Project root"))
            : options.workingDirectoryPath

        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 11) {
                    RunConfigurationIcon(kind: configuration.kind, size: 22)
                        .frame(width: 34, height: 34)
                        .background(LitheTheme.accent.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 7))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(configuration.name)
                            .font(.system(size: 14, weight: .semibold))
                            .textSelection(.enabled)
                        Text(String(localized: String.LocalizationValue(configuration.kind.title)))
                            .font(.system(size: 11))
                            .foregroundStyle(LitheTheme.secondaryText)
                    }

                    Spacer(minLength: 10)
                    statusLabel(for: session)
                }

                Rectangle()
                    .fill(LitheTheme.divider)
                    .frame(height: 1)

                HStack(alignment: .firstTextBaseline) {
                    Text("Configuration details")
                        .font(.system(size: 11.5, weight: .semibold))
                    Spacer(minLength: 8)
                    Button {
                        editingConfigurationID = configuration.id
                    } label: {
                        Label("Edit Service", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .lithePointer()
                }

                VStack(spacing: 8) {
                    Group {
                        configurationDetailRow(
                            "Type",
                            value: String(localized: String.LocalizationValue(configuration.kind.title))
                        )
                        configurationDetailRow("Category", value: localizedExecution(configuration.execution))
                        configurationDetailRow("Provider", value: configuration.kind.id, monospaced: true)
                        configurationDetailRow("Working directory", value: workingDirectory, monospaced: true)
                    }

                    Group {
                        if session?.isRunning == true,
                           let serviceURL = feature.serviceURL(for: configuration) {
                            configurationLinkRow("Address", url: serviceURL)
                        }

                        if let modulePath = nonEmpty(configuration.modulePath) {
                            configurationDetailRow("Module", value: modulePath, monospaced: true)
                        }
                        if let mainClass = nonEmpty(configuration.mainClass) {
                            configurationDetailRow("Main class", value: mainClass, monospaced: true)
                        }
                        if capabilities.contains(.javaRuntime),
                           let javaHome = nonEmpty(options.javaHomePath) {
                            configurationDetailRow("JDK home", value: javaHome, monospaced: true)
                        }
                        if configuration.kind.isMavenBacked,
                           let mavenExecutable = nonEmpty(options.mavenExecutablePath) {
                            configurationDetailRow("Maven", value: mavenExecutable, monospaced: true)
                        }
                        if configuration.kind.isMavenBacked,
                           let mavenJavaHome = nonEmpty(options.mavenJavaHomePath) {
                            configurationDetailRow("Maven JDK", value: mavenJavaHome, monospaced: true)
                        }
                        if capabilities.contains(.javaVMArguments),
                           let vmArguments = nonEmpty(options.vmArguments) {
                            configurationDetailRow("VM arguments", value: vmArguments, monospaced: true)
                        }
                        if let programArguments = nonEmpty(options.programArguments) {
                            configurationDetailRow("Program arguments", value: programArguments, monospaced: true)
                        }
                        if capabilities.contains(.mavenProfiles), !options.activeProfiles.isEmpty {
                            configurationDetailRow(
                                "Active profiles",
                                value: options.activeProfiles.sorted().joined(separator: ", "),
                                monospaced: true
                            )
                        }
                    }

                    Group {
                        if (!capabilities.contains(.javaRuntime) || options.javaHomePath.isEmpty),
                           (!capabilities.contains(.javaVMArguments) || options.vmArguments.isEmpty),
                           options.programArguments.isEmpty,
                           (!capabilities.contains(.mavenProfiles) || options.activeProfiles.isEmpty) {
                            configurationDetailRow("Options", value: String(localized: "Default options"))
                        }

                        configurationDetailRow("Source", value: localizedSource(feature.source(for: configuration)))
                        configurationDetailRow("Configuration ID", value: configuration.id, monospaced: true)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func openJavaServiceEditor() {
        let selected = feature.configurations.first { configuration in
            configuration.id == selectedSessionID
                && configuration.kind.capabilities.contains(.javaRuntime)
        }
        let javaService = selected ?? feature.configurations.first { configuration in
            configuration.kind.capabilities.contains(.javaRuntime)
                && configuration.execution == .service
        } ?? feature.configurations.first { configuration in
            configuration.kind.capabilities.contains(.javaRuntime)
        }
        if let javaService {
            selectedSessionID = javaService.id
            editingConfigurationID = javaService.id
        }
    }

    private func configurationDetailRow(
        _ label: LocalizedStringKey,
        value: String,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 118, alignment: .trailing)

            Text(value)
                .font(.system(size: 11.5, design: monospaced ? .monospaced : .default))
                .foregroundStyle(LitheTheme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func configurationLinkRow(_ label: LocalizedStringKey, url: URL) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 118, alignment: .trailing)

            Link(destination: url) {
                Label(url.absoluteString, systemImage: "arrow.up.right.square")
                    .font(.system(size: 11.5, design: .monospaced))
            }
            .foregroundStyle(LitheTheme.accent)
            .help("Open service in browser")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusLabel(for session: RunSession?) -> some View {
        let title: LocalizedStringKey
        let color: Color
        if let session, session.isRunning {
            title = "Running"
            color = LitheTheme.success
        } else if let exitCode = session?.exitCode {
            title = exitCode == 0 ? "Finished" : "Failed"
            color = exitCode == 0 ? LitheTheme.success : LitheTheme.error
        } else {
            title = "Not run"
            color = LitheTheme.secondaryText
        }

        return Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(color.opacity(0.10))
            .clipShape(Capsule())
    }

    private func localizedExecution(_ execution: RunConfigurationExecution) -> String {
        String(localized: String.LocalizationValue(execution.sectionTitle))
    }

    private func localizedSource(_ source: RunConfigurationSource) -> String {
        switch source {
        case .generated: String(localized: "Automatically identified")
        case .project: String(localized: "Shared with project")
        case .local: String(localized: "This Mac only")
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sectionHeader(_ execution: RunConfigurationExecution, count: Int) -> some View {
        Button {
            toggleCollapsed(execution)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: collapsedExecutions.contains(execution.rawValue) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 10)
                Text(String(localized: String.LocalizationValue(execution.sectionTitle)))
                Spacer(minLength: 0)
                Text(String(count))
                    .font(.system(size: 10))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
        .help(collapsedExecutions.contains(execution.rawValue) ? "Expand" : "Collapse")
        .accessibilityLabel(String(localized: String.LocalizationValue(execution.sectionTitle)))
        .accessibilityValue(collapsedExecutions.contains(execution.rawValue) ? "Collapsed" : "Expanded")
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
        serviceURL: URL? = nil,
        configurationKind: RunConfigurationKind? = nil,
        isRunning: Bool,
        exitCode: Int32?,
        isSelected: Bool,
        isPinned: Bool = false,
        onPin: (() -> Void)? = nil,
        onEdit: (() -> Void)? = nil,
        isEditing: Binding<Bool> = .constant(false),
        editorConfiguration: RunConfiguration? = nil,
        onToggle: (() -> Void)?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    if let configurationKind {
                        RunConfigurationIcon(kind: configurationKind, size: 16)
                    } else {
                        Image(systemName: isRunning ? "circle.fill" : (exitCode == 0 ? "checkmark.circle.fill" : "play.rectangle"))
                            .foregroundStyle(
                                isRunning
                                    ? LitheTheme.success
                                    : (exitCode == 0 ? LitheTheme.success : LitheTheme.secondaryText)
                            )
                            .frame(width: 16, height: 16)
                    }

                    if configurationKind != nil, isRunning || exitCode != nil {
                        Circle()
                            .fill(isRunning || exitCode == 0 ? LitheTheme.success : LitheTheme.error)
                            .frame(width: 6, height: 6)
                            .overlay {
                                Circle().stroke(LitheTheme.sidebar, lineWidth: 1)
                            }
                            .offset(x: 1, y: 1)
                    }
                }
                .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(subtitle)
                            .lineLimit(1)
                        if let serviceURL, let port = serviceURL.port {
                            let portText = String(port)
                            Button {
                                openURL(serviceURL)
                            } label: {
                                Text("localhost:" + portText)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(LitheTheme.accent)
                            .help("Open \(serviceURL.absoluteString) in browser")
                            .accessibilityLabel("Open service on port " + portText)
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let onPin {
                    Button(action: onPin) {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.plain)
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
                    .lithePointer()
                    .foregroundStyle(isPinned ? LitheTheme.accent : LitheTheme.secondaryText)
                    .help(isPinned ? "Unpin configuration" : "Pin configuration")
                    .accessibilityLabel(isPinned ? "Unpin configuration" : "Pin configuration")
                }
                if let onEdit, let editorConfiguration {
                    Button(action: onEdit) {
                        Image(systemName: "gearshape")
                    }
                    .litheIconButton()
                    .foregroundStyle(LitheTheme.secondaryText)
                    .help("Edit run configuration")
                    .disabled(feature.configurationStatus != .ready || feature.isLoadingProject)
                    .popover(isPresented: isEditing, arrowEdge: .trailing) {
                        RunConfigurationEditorView(
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
        .onTapGesture(perform: action)
        .lithePointer()
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Select configuration", action)
    }
}
