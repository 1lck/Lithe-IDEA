import SwiftUI

struct RunView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @ObservedObject var feature: RunFeatureModel
    private var selectedSessionID: String? {
        get { feature.selectedProjectSessionID }
        nonmutating set { feature.selectedConfigurationID = newValue ?? RunConfiguration.currentFileID }
    }
    @State private var browser = RunBrowserState()
    @State private var contentTab: ContentTab = .console
    @State private var selectionWorkspacePath: String?
    @AppStorage("lithe.run.selectedServiceIDs") private var selectedConfigurationTokens = ""

    private enum ContentTab { case console, details }
    @AppStorage("lithe.run.pinnedConfigurationIDs") private var pinnedConfigurationTokens = ""
    @AppStorage("lithe.run.configurationListCollapsed") private var isConfigurationListCollapsed = false
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
                RunServicesSplitView(
                    isScopeCollapsed: isConfigurationListCollapsed,
                    scopes: scopeList,
                    configurations: applicationTypeList,
                    content: selectedConfigurationContent
                )
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
        .onAppear { synchronizeCheckedConfigurations() }
        .onChange(of: feature.configurations) { _ in synchronizeCheckedConfigurations() }
        .onChange(of: feature.projectLoadState) { _ in synchronizeCheckedConfigurations() }
        .onChange(of: browser.checkedIDs) { _ in persistCheckedConfigurations() }
        .onChange(of: feature.selectedConfigurationID) { _ in contentTab = .console }
        .onChange(of: selectedModuleSession?.isRunning) { isRunning in
            if isRunning == true { contentTab = .console }
        }
        .onChange(of: model.workspaceFeature.workspaceGeneration) { _ in
            selectionWorkspacePath = nil
            browser = RunBrowserState()
            editingConfigurationID = nil
            contentTab = .console
        }
        .popover(isPresented: Binding(
            get: { editingConfigurationID != nil },
            set: { if !$0 { editingConfigurationID = nil } }
        )) {
            if let configuration = feature.configurations.first(where: { $0.id == editingConfigurationID }) {
                RunConfigurationEditorView(feature: feature, configuration: configuration)
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
            subtitle: selectedRunnableConfiguration?.name ?? feature.runningTitle,
            onMinimize: { model.workbenchFeature.setVisibility(.run, isVisible: false) }
        ) {
            if let session = selectedModuleSession {
                sessionStatus(isRunning: session.isRunning, exitCode: session.exitCode)
            } else if feature.isLoadingProject {
                ProgressView()
                    .controlSize(.mini)
            } else if selectedSessionID == nil, feature.isRunning {
                Label("Running", systemImage: "circle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.success)
            } else if selectedSessionID == nil, let exitCode = feature.lastExitCode {
                sessionStatus(isRunning: false, exitCode: exitCode)
            }

            if !browser.checkedIDs.isEmpty {
                Text(String(format: String(localized: "%lld selected"), Int64(browser.checkedIDs.count)))
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                Button(action: runCheckedConfigurations) {
                    Label("Run selected", systemImage: "play.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(LitheTheme.success)
                .help("Run checked configurations without restarting running services")
                .disabled(feature.configurationStatus != .ready || feature.isLoadingProject)

                Button {
                    for session in feature.moduleSessions where browser.checkedIDs.contains(session.configurationID) && session.isRunning {
                        feature.stopModule(session)
                    }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .litheIconButton()
                .help("Stop selected")
                .disabled(!feature.moduleSessions.contains { browser.checkedIDs.contains($0.configurationID) && $0.isRunning })

                Button { browser.clearSelection() } label: {
                    Image(systemName: "xmark")
                }
                .litheIconButton()
                .help("Clear selection")
            }

            Button {
                if let session = selectedModuleSession, session.isRunning {
                    feature.stopModule(session)
                } else if let configuration = selectedRunnableConfiguration {
                    contentTab = .console
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
                    contentTab = .console
                    model.startRunConfiguration(configuration)
                } else {
                    model.restartSelectedRun()
                }
            } label: {
                LitheSystemIcon(systemImage: "arrow.clockwise")
            }
            .litheIconButton()
            .disabled(selectedSessionID != nil
                ? selectedModuleSession == nil
                : feature.runningTitle == nil && feature.lastExitCode == nil)
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
                } else if selectedSessionID == nil {
                    feature.clearOutput()
                }
            } label: {
                Image(systemName: "trash")
            }
            .litheIconButton()
            .help("Clear run output")
            .disabled(selectedSessionID != nil && selectedModuleSession == nil)

        }
    }

    private var runnableConfigurations: [RunConfiguration] {
        feature.configurations.filter { $0.kind != .currentFile }
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

    private var pinnedIDs: Set<String> {
        Set(runnableConfigurations.filter(isPinned).map(\.id))
    }

    private func configurations(in scope: RunBrowserState.Scope) -> [RunConfiguration] {
        browser.configurations(in: scope, from: runnableConfigurations, pinnedIDs: pinnedIDs)
    }

    @ViewBuilder
    private var scopeList: some View {
        if isConfigurationListCollapsed {
            collapsedConfigurationListBar
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("Services").font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                    Button { isConfigurationListCollapsed = true } label: {
                        Image(systemName: "chevron.left")
                    }
                    .litheIconButton()
                    .help("Hide configuration list")
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                ScrollView(.vertical) {
                    VStack(spacing: 3) {
                        scopeRow(.all, title: "All configurations", systemImage: "square.stack.3d.up")
                        scopeRow(.pinned, title: "Pinned", systemImage: "pin")
                        ForEach(RunConfigurationExecution.displayOrder, id: \.self) { execution in
                            if !configurations(in: .execution(execution)).isEmpty {
                                scopeRow(
                                    .execution(execution),
                                    title: String(localized: String.LocalizationValue(execution.sectionTitle)),
                                    systemImage: execution == .service ? "server.rack" : "play.rectangle"
                                )
                            }
                        }
                        Rectangle().fill(LitheTheme.divider).frame(height: 1).padding(.vertical, 5)
                        sessionRow(
                            title: String(localized: "Current run"),
                            subtitle: feature.runningTitle ?? String(localized: "Current File"),
                            isRunning: feature.isRunning,
                            exitCode: feature.lastExitCode,
                            isSelected: selectedSessionID == nil,
                            onToggle: nil
                        ) {
                            selectedSessionID = nil
                            contentTab = .console
                            feature.select(.currentFile)
                        }
                    }
                    .padding(6)
                }
            }
            .litheWorkbenchSurface(LitheTheme.sidebar)
        }
    }

    private func scopeRow(_ scope: RunBrowserState.Scope, title: String, systemImage: String) -> some View {
        let entries = configurations(in: scope)
        return HStack(spacing: 6) {
            selectionCheckbox(entries, title: String(localized: String.LocalizationValue(title)))
            Button {
                browser.scope = scope
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: systemImage).frame(width: 16)
                    Text(String(localized: String.LocalizationValue(title))).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(String(entries.count)).foregroundStyle(LitheTheme.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 6)
        .frame(height: 30)
        .background(browser.scope == scope ? LitheTheme.subtleSelection : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var applicationTypeList: some View {
        let entries = configurations(in: browser.scope)
        let groups = RunBrowserState.groups(for: entries)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                selectionCheckbox(entries, title: String(localized: "Application types"))
                Text("Application types")
                Spacer(minLength: 0)
                Text(String(entries.count)).foregroundStyle(LitheTheme.secondaryText)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 30)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            if entries.isEmpty {
                Text("No configurations in this scope")
                    .font(.system(size: 11))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups) { group in
                            applicationGroupHeader(group)
                            if !browser.collapsedGroupIDs.contains(group.id) {
                                ForEach(group.configurations) { configuration in
                                    configurationRow(configuration)
                                }
                            }
                        }
                    }
                    .padding(6)
                }
            }
        }
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    private func applicationGroupHeader(_ group: RunBrowserState.ApplicationGroup) -> some View {
        let isCollapsed = browser.collapsedGroupIDs.contains(group.id)
        return HStack(spacing: 6) {
            selectionCheckbox(group.configurations, title: group.title)
            Button {
                if isCollapsed {
                    browser.collapsedGroupIDs.remove(group.id)
                } else {
                    browser.collapsedGroupIDs.insert(group.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                    RunConfigurationIcon(kind: group.iconKind, size: 14)
                    Text(String(localized: String.LocalizationValue(group.title)))
                    Spacer(minLength: 0)
                    Text(String(group.configurations.count)).foregroundStyle(LitheTheme.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lithePointer()
            .help(isCollapsed ? "Expand" : "Collapse")
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 6)
        .frame(height: 28)
    }

    private func selectionCheckbox(_ entries: [RunConfiguration], title: String) -> some View {
        let state = browser.checkState(for: entries)
        return Button { browser.toggle(entries) } label: {
            Image(systemName: state == .checked ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(state == .unchecked ? LitheTheme.secondaryText : LitheTheme.accent)
                .frame(width: 18, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
        .disabled(entries.isEmpty || feature.isLoadingProject)
        .help("Select configurations for batch actions")
        .accessibilityLabel(String(format: String(localized: "Select %@"), title))
        .accessibilityValue(state == .checked ? "Selected" : state == .mixed ? "Partially selected" : "Not selected")
    }

    private func synchronizeCheckedConfigurations() {
        guard let workspace = model.workspaceURL?.standardizedFileURL,
              feature.hasReadyInventory(for: workspace) else { return }
        if selectionWorkspacePath != workspace.path {
            browser.restoreSelection(
                persistedConfigurationSelections()[workspace.path] ?? [],
                configurations: runnableConfigurations
            )
            selectionWorkspacePath = workspace.path
        } else {
            browser.retainConfigurations(runnableConfigurations)
        }
    }

    private func persistCheckedConfigurations() {
        guard let path = model.workspaceURL?.standardizedFileURL.path,
              selectionWorkspacePath == path else { return }
        var selections = persistedConfigurationSelections()
        selections[path] = browser.checkedIDs.sorted()
        do {
            let data = try JSONSerialization.data(withJSONObject: selections, options: [.sortedKeys])
            selectedConfigurationTokens = String(decoding: data, as: UTF8.self)
        } catch {
            model.showNotification("Could not save service selection")
        }
    }

    private func persistedConfigurationSelections() -> [String: [String]] {
        if let data = selectedConfigurationTokens.data(using: .utf8),
           let selections = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
            return selections
        }
        // Keep the legacy workspace-prefixed format readable during migration.
        let path = model.workspaceURL?.standardizedFileURL.path ?? ""
        let prefix = path + "::"
        let ids = selectedConfigurationTokens.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        return ids.isEmpty ? [:] : [path: ids]
    }

    private func runCheckedConfigurations() {
        let checked = runnableConfigurations.filter { browser.checkedIDs.contains($0.id) }
        guard !checked.isEmpty else { return }
        if let configuration = checked.first(where: { candidate in
            !feature.moduleSessions.contains { $0.id == candidate.id && $0.isRunning }
        }) ?? checked.first {
            selectedSessionID = configuration.id
            feature.select(configuration)
        }
        contentTab = .console
        model.startRunConfigurations(checked.map(\.id))
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
            onEdit: { editingConfigurationID = configuration.id },
            checkedConfiguration: configuration,
            onToggle: {
                if let session, session.isRunning {
                    feature.stopModule(session)
                } else {
                    feature.select(configuration)
                    contentTab = .console
                    model.startRunConfiguration(configuration)
                    selectedSessionID = configuration.id
                }
            }
        ) {
            selectedSessionID = configuration.id
            contentTab = .console
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
            HStack(spacing: 8) {
                RunConfigurationIcon(kind: configuration.kind, size: 16)
                Text(configuration.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .help(configuration.name)
                Spacer(minLength: 8)
                statusLabel(for: session)
                Button { editingConfigurationID = configuration.id } label: {
                    Image(systemName: "gearshape")
                }
                .litheIconButton()
                .help("Edit run configuration")
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            HStack(spacing: 12) {
                contentTabButton("Console", tab: .console, systemImage: "terminal")
                contentTabButton("Configuration details", tab: .details, systemImage: "slider.horizontal.3")
                Spacer(minLength: 0)
                if session?.isRunning == true, let url = feature.serviceURL(for: configuration) {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                        .help(url.absoluteString)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            if contentTab == .details {
                configurationDetail(configuration, session: session)
            } else {
                OutputTextView(
                    output: session?.output ?? "",
                    searchRoots: feature.sourceSearchRoots,
                    fileExists: { model.fileExists(at: $0) },
                    emptyMessage: String(localized: "Start this configuration to see its output here.")
                ) { url, line, column in
                    model.openSourceLocation(url: url, line: line, column: column)
                }
                .id(configuration.id)
            }
        }
        .litheWorkbenchSurface(LitheTheme.editor)
    }

    private func contentTabButton(_ title: LocalizedStringKey, tab: ContentTab, systemImage: String) -> some View {
        Button { contentTab = tab } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: contentTab == tab ? .semibold : .regular))
                .foregroundStyle(contentTab == tab ? LitheTheme.accent : LitheTheme.secondaryText)
                .frame(height: 30)
                .overlay(alignment: .bottom) {
                    if contentTab == tab { Rectangle().fill(LitheTheme.accent).frame(height: 2) }
                }
        }
        .buttonStyle(.plain)
        .lithePointer()
        .accessibilityAddTraits(contentTab == tab ? .isSelected : [])
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
        checkedConfiguration: RunConfiguration? = nil,
        onToggle: (() -> Void)?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
                if let checkedConfiguration {
                    selectionCheckbox([checkedConfiguration], title: checkedConfiguration.name)
                }
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
                if let onEdit {
                    Button(action: onEdit) {
                        Image(systemName: "gearshape")
                    }
                    .litheIconButton()
                    .foregroundStyle(LitheTheme.secondaryText)
                    .help("Edit run configuration")
                    .disabled(feature.configurationStatus != .ready || feature.isLoadingProject)

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
