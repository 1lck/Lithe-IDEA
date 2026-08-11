import SwiftUI

struct LSPControlCenterView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedProviderID: String?
    @State private var isToolSetupExpanded = false

    private let metricColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]
    private let serverListHeight: CGFloat = 176

    private var copy: LSPControlCenterCopy {
        LSPControlCenterCopy(language: settings.language)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    globalControls
                    if isToolSetupExpanded {
                        languageServerSetupPanel
                    } else {
                        serverList
                        if let selected = selectedDescriptor {
                            serverDetail(selected)
                        } else {
                            emptyDetail
                        }
                        eventLog
                        diagnosticLog
                    }
                }
                .padding(8)
            }
            .background(LitheTheme.editor)
        }
        .background(LitheTheme.editor)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(copy.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Spacer(minLength: 0)
            Button {
                isToolSetupExpanded.toggle()
            } label: {
                LitheIDEAIcon(
                    resourcePath: "general/gear.svg",
                    size: 15,
                    fallbackSystemImage: "gearshape"
                )
            }
            .litheIconButton()
            .help(copy.configureLanguageServers)
            Button {
                model.isLSPControlCenterVisible = false
            } label: {
                Image(systemName: "xmark")
            }
            .litheIconButton()
            .help(copy.hideControlCenter)
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: 34)
        .background(LitheTheme.toolHeader)
    }

    private var languageServerSetupPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                sectionTitle(copy.configureLanguageServers)
                Spacer(minLength: 0)
                Button {
                    isToolSetupExpanded = false
                } label: {
                    Label(copy.backToOverview, systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(LitheSecondaryButtonStyle())
            }

            LanguageServerSetupView(
                tools: model.languageServerTools,
                providers: configurableLanguageServerDescriptors,
                initialProviderID: selectedDescriptor?.id,
                language: settings.language,
                chooseExecutable: { descriptor in
                    model.chooseLanguageServerExecutable(providerName: descriptor.displayName)
                },
                openOfficialDownload: { url in
                    model.openLanguageServerDownload(url)
                },
                configurationChanged: { providerID in
                    model.languageServerToolConfigurationDidChange(providerID: providerID)
                },
                isEmbedded: true
            )
        }
        .padding(10)
        .panelChrome()
    }

    private var globalControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(copy.currentProject)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                Text(model.projectName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                statusPill(
                    title: activeServerCount > 0 ? copy.lspActive : copy.noRunningSession,
                    color: activeServerCount > 0 ? LitheTheme.success : LitheTheme.secondaryText
                )
            }

            HStack(spacing: 8) {
                Button {
                    model.restartLanguageServers()
                } label: {
                    Label(copy.restartAll, systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LithePrimaryButtonStyle())

                Button {
                    model.clearLanguageServerDiagnostics()
                } label: {
                    Label(copy.clearDiagnostics, systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LitheSecondaryButtonStyle())
            }
        }
        .padding(10)
        .panelChrome()
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle(copy.languageServers)

            ScrollView(.vertical) {
                if languageServerDescriptors.isEmpty {
                    Text(copy.noProjectLanguageServers)
                        .font(.system(size: 11.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: serverListHeight, alignment: .leading)
                } else {
                    VStack(spacing: 1) {
                        ForEach(languageServerDescriptors) { descriptor in
                            serverRow(descriptor)
                        }
                    }
                }
            }
            .frame(height: serverListHeight)
            .litheScrollViewChrome(hideHorizontal: true, alwaysShowVertical: true)
        }
        .padding(10)
        .panelChrome()
    }

    private func serverRow(_ descriptor: LanguageProviderDescriptor) -> some View {
        let metrics = providerMetrics(for: descriptor)
        let isSelected = descriptor.id == selectedDescriptor?.id

        return HStack(spacing: 8) {
            Circle()
                .fill(statusColor(metrics.status))
                .frame(width: 8, height: 8)
            providerIcon(for: descriptor)
            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                Text(metrics.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(copy.title(for: metrics.status))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(statusColor(metrics.status))
            if metrics.status == .active || metrics.status == .error {
                Button {
                    model.disableLanguageServerForCurrentWorkspace(providerID: descriptor.id)
                } label: {
                    Image(systemName: "stop")
                }
                .litheIconButton()
                .help(copy.disableProvider(descriptor.displayName))
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 38)
        .contentShape(Rectangle())
        .litheRowHover(isActive: isSelected, cornerRadius: 6, activeBackground: LitheTheme.subtleSelection)
        .onTapGesture {
            selectedProviderID = descriptor.id
        }
    }

    private func serverDetail(_ descriptor: LanguageProviderDescriptor) -> some View {
        let metrics = providerMetrics(for: descriptor)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                providerIcon(for: descriptor)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(descriptor.displayName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(LitheTheme.primaryText)
                        statusPill(title: copy.title(for: metrics.status), color: statusColor(metrics.status))
                    }
                    Text(metrics.workspacePath)
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(metrics.version)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            HStack(spacing: 0) {
                summaryButton(copy.rootFiles, value: "\(metrics.fileCount)") {
                    openFirstProjectFile(for: descriptor)
                }
                summaryButton(copy.openFiles, value: "\(metrics.openFileCount)") {
                    openFirstOpenDocument(for: descriptor)
                }
                summaryButton(copy.diagnostics, value: "\(metrics.diagnosticCount)") {
                    openFirstDiagnostic(for: descriptor)
                }
            }

            capabilityGrid(descriptor)
            configurationSection(descriptor)
        }
        .padding(10)
        .panelChrome()
    }

    private var emptyDetail: some View {
        VStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(copy.openSupportedFile)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text(copy.matchingServerWillAppear)
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .panelChrome()
    }

    private var diagnosticLog: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionTitle(copy.diagnostics)
                Spacer(minLength: 0)
                Text("\(allDiagnostics.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            if allDiagnostics.isEmpty {
                Text(copy.noLanguageServerDiagnostics)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(allDiagnostics.prefix(5).enumerated()), id: \.offset) { _, diagnostic in
                        Button {
                            model.openDiagnostic(diagnostic)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: diagnostic.severity.systemImage)
                                    .foregroundStyle(color(for: diagnostic.severity))
                                    .frame(width: 14)
                                Text(diagnostic.locationTitle)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(LitheTheme.primaryText)
                                    .lineLimit(1)
                                Text(diagnostic.message)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .frame(height: 25)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .lithePointer()
                    }
                }
            }
        }
        .padding(10)
        .panelChrome()
    }

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionTitle(copy.eventLog)
                Spacer(minLength: 0)
                Button {
                    model.languageToolingSessions.clearLanguageServerLogs()
                } label: {
                    Image(systemName: "trash")
                }
                .litheIconButton()
                .help(copy.clearEventLog)
            }

            if model.languageToolingSessions.languageServerLogs.isEmpty {
                Text(copy.noLanguageServerEvents)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            } else {
                VStack(spacing: 1) {
                    ForEach(model.languageToolingSessions.languageServerLogs.prefix(6)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 7) {
                                Image(systemName: logIcon(for: entry.level))
                                    .foregroundStyle(logColor(for: entry.level))
                                    .frame(width: 14)
                                Text(providerName(for: entry.providerID))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(LitheTheme.primaryText)
                                    .lineLimit(1)
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                Spacer(minLength: 0)
                            }
                            Text(entry.message)
                                .font(.system(size: 11))
                                .foregroundStyle(LitheTheme.primaryText)
                                .lineLimit(1)
                            if let detail = entry.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(LitheTheme.raised.opacity(0.38))
                        )
                    }
                }
            }
        }
        .padding(10)
        .panelChrome()
    }

    private func capabilityGrid(_ descriptor: LanguageProviderDescriptor) -> some View {
        let features = model.languageToolingSessions.languageServerFeatures[descriptor.id] ?? []
        let rows: [LSPCapabilityRow] = [
            LSPCapabilityRow(
                title: copy.languageServerCapability,
                icon: "chevron.left.forwardslash.chevron.right",
                declared: descriptor.capabilities.contains(.languageServer),
                active: !features.isEmpty || model.languageToolingSessions.activeLanguageServerIDs.contains(descriptor.id)
            ),
            LSPCapabilityRow(
                title: copy.formatting,
                icon: "text.alignleft",
                declared: descriptor.capabilities.contains(.formatting),
                active: features.contains(.formatting)
            ),
            LSPCapabilityRow(
                title: copy.testing,
                icon: "checkmark.seal",
                declared: descriptor.capabilities.contains(.testing),
                active: false
            ),
            LSPCapabilityRow(
                title: copy.debug,
                icon: "ladybug",
                declared: descriptor.capabilities.contains(.debugAdapter),
                active: model.languageToolingSessions.activeDebugAdapterIDs.contains(descriptor.id)
            ),
            LSPCapabilityRow(
                title: copy.run,
                icon: "play",
                declared: descriptor.capabilities.contains(.run),
                active: false
            )
        ]

        return VStack(alignment: .leading, spacing: 7) {
            sectionTitle(copy.capabilities)
            LazyVGrid(columns: metricColumns, spacing: 6) {
                ForEach(rows) { row in
                    Button {
                        model.showNotification(copy.capabilityState(row.title, declared: row.declared, active: row.active))
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: row.icon)
                                .frame(width: 15)
                            Text(row.title)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: row.active ? "bolt.fill" : row.declared ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(row.active ? LitheTheme.success : row.declared ? LitheTheme.accent : LitheTheme.secondaryText)
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(row.declared ? LitheTheme.primaryText : LitheTheme.secondaryText)
                        .padding(.horizontal, 7)
                        .frame(height: 30)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(LitheTheme.raised.opacity(0.55))
                        )
                    }
                    .buttonStyle(.plain)
                    .lithePointer()
                }
            }
        }
    }

    private func configurationSection(_ descriptor: LanguageProviderDescriptor) -> some View {
        return VStack(alignment: .leading, spacing: 7) {
            sectionTitle(copy.providerConfiguration)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "curlybraces.square")
                        .foregroundStyle(LitheTheme.accent)
                    Text(copy.rustOwnedConfiguration)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                configActionRow(title: copy.providerID, value: descriptor.id, systemImage: "doc.on.doc") {
                    model.showNotification(copy.providerIDCopied(descriptor.id))
                }
                configActionRow(title: copy.activation, value: copy.activationPolicy(descriptor.activationPolicy), systemImage: "bolt.badge.clock") {
                    model.showNotification(copy.activationPolicy(descriptor.activationPolicy))
                }
                configActionRow(title: copy.builtinCatalog, value: builtinCatalogPath, systemImage: "curlybraces") {
                    openFileIfPresent(URL(fileURLWithPath: builtinCatalogPath), missingMessage: copy.builtinCatalogUnavailable)
                }
                configActionRow(title: copy.projectOverride, value: projectLSPConfigPath, systemImage: "folder.badge.gearshape") {
                    openFileIfPresent(URL(fileURLWithPath: projectLSPConfigPath), missingMessage: copy.projectOverrideMissing)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(LitheTheme.raised.opacity(0.55))
            )

            Button {
                selectedProviderID = descriptor.id
                isToolSetupExpanded = true
            } label: {
                Label(copy.editToolPath, systemImage: "wrench.and.screwdriver")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(LithePrimaryButtonStyle())

            Text(copy.configurationHint)
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(2)
        }
    }

    private func configActionRow(
        title: String,
        value: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 82, alignment: .leading)
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 14)
                Text(value)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
    }

    private func summaryButton(_ title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LitheTheme.primaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(LitheTheme.divider)
                    .frame(width: 1)
            }
        }
        .buttonStyle(.plain)
        .lithePointer()
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(LitheTheme.secondaryText)
    }

    private func statusPill(title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            Capsule()
                .fill(color.opacity(0.16))
        )
    }

    private func providerIcon(for _: LanguageProviderDescriptor) -> some View {
        LitheIcon(kind: .generic, size: 17)
    }

    private func color(for severity: DiagnosticSeverity) -> Color {
        switch severity {
        case .unknown: LitheTheme.secondaryText
        case .error: LitheTheme.error
        case .warning: LitheTheme.warning
        case .information: LitheTheme.accent
        case .hint: LitheTheme.secondaryText
        }
    }

    private func logColor(for level: LanguageServerLogLevel) -> Color {
        switch level {
        case .info: LitheTheme.accent
        case .warning: LitheTheme.warning
        case .error: LitheTheme.error
        }
    }

    private func logIcon(for level: LanguageServerLogLevel) -> String {
        switch level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private func providerName(for providerID: String) -> String {
        model.languageProviderCatalog.descriptors.first { $0.id == providerID }?.displayName
            ?? providerID
    }

    private func statusColor(_ status: LSPServerStatus) -> Color {
        switch status {
        case .active: LitheTheme.success
        case .stopped: LitheTheme.secondaryText
        case .disabled: LitheTheme.warning
        case .error: LitheTheme.error
        }
    }

    private var languageServerDescriptors: [LanguageProviderDescriptor] {
        model.languageProviderCatalog.descriptors
            .filter { $0.capabilities.contains(.languageServer) }
            .filter { descriptor in
                model.projectFiles.contains { descriptor.handles(fileURL: $0) }
            }
    }

    private var configurableLanguageServerDescriptors: [LanguageProviderDescriptor] {
        model.languageProviderCatalog.descriptors
            .filter { $0.capabilities.contains(.languageServer) }
            .filter { $0.languageServerLaunch != nil }
    }

    private var selectedDescriptor: LanguageProviderDescriptor? {
        if let selectedProviderID,
           let selected = languageServerDescriptors.first(where: { $0.id == selectedProviderID }) {
            return selected
        }
        if let document = model.activeDocument,
           let descriptor = languageServerDescriptors.first(where: { $0.handles(fileURL: document.url) }) {
            return descriptor
        }
        return languageServerDescriptors.first
    }

    private var activeServerCount: Int {
        languageServerDescriptors.filter { providerMetrics(for: $0).status == .active }.count
    }

    private var builtinCatalogPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rust")
            .appendingPathComponent("lithe-core")
            .appendingPathComponent("resources")
            .appendingPathComponent("lsp")
            .appendingPathComponent("language-providers.json")
            .path
    }

    private var projectLSPConfigPath: String {
        guard let workspaceURL = model.workspaceURL else {
            return ".lithe/lsp/language-providers.json"
        }
        return workspaceURL
            .appendingPathComponent(".lithe")
            .appendingPathComponent("lsp")
            .appendingPathComponent("language-providers.json")
            .path
    }

    private func matchingProjectFiles(for descriptor: LanguageProviderDescriptor) -> [URL] {
        model.projectFiles.filter { descriptor.handles(fileURL: $0) }
    }

    private func matchingOpenDocuments(for descriptor: LanguageProviderDescriptor) -> [EditorDocument] {
        model.openDocuments.filter { descriptor.handles(fileURL: $0.url) }
    }

    private func matchingDiagnostics(for descriptor: LanguageProviderDescriptor) -> [EditorDiagnostic] {
        model.languageToolingSessions.diagnostics(for: descriptor.id)
            .flatMap { fileURL, diagnostics in
                diagnostics.map {
                    EditorDiagnostic(languageServerDiagnostic: $0, fileURL: fileURL)
                }
            }
            .sorted {
                if $0.severity != $1.severity { return $0.severity.sortOrder < $1.severity.sortOrder }
                if $0.line != $1.line { return $0.line < $1.line }
                return $0.message < $1.message
            }
    }

    private var allDiagnostics: [EditorDiagnostic] {
        model.languageToolingSessions.diagnostics
            .flatMap { fileURL, diagnostics in
                diagnostics.map {
                    EditorDiagnostic(languageServerDiagnostic: $0, fileURL: fileURL)
                }
            }
            .sorted {
                if $0.severity != $1.severity { return $0.severity.sortOrder < $1.severity.sortOrder }
                if $0.line != $1.line { return $0.line < $1.line }
                return $0.message < $1.message
            }
    }

    private func openFirstProjectFile(for descriptor: LanguageProviderDescriptor) {
        guard let fileURL = matchingProjectFiles(for: descriptor).first else {
            model.showNotification(copy.noMatchingFiles)
            return
        }
        model.openFile(fileURL)
    }

    private func openFirstOpenDocument(for descriptor: LanguageProviderDescriptor) {
        guard let document = matchingOpenDocuments(for: descriptor).first else {
            model.showNotification(copy.noOpenFilesForProvider)
            return
        }
        model.openFile(document.url)
    }

    private func openFirstDiagnostic(for descriptor: LanguageProviderDescriptor) {
        guard let diagnostic = matchingDiagnostics(for: descriptor).first else {
            model.showNotification(copy.noLanguageServerDiagnostics)
            return
        }
        model.openDiagnostic(diagnostic)
    }

    private func openFileIfPresent(_ url: URL, missingMessage: String) {
        if model.workspaceFileOperations.fileExists(at: url) {
            model.openFile(url)
        } else {
            model.showNotification(missingMessage)
        }
    }

    private func providerMetrics(for descriptor: LanguageProviderDescriptor) -> LSPProviderMetrics {
        let files = matchingProjectFiles(for: descriptor)
        let openFiles = matchingOpenDocuments(for: descriptor)
        let diagnostics = matchingDiagnostics(for: descriptor)
        let features = model.languageToolingSessions.languageServerFeatures[descriptor.id] ?? []
        let status: LSPServerStatus
        let hasServerState = model.languageToolingSessions.activeLanguageServerIDs.contains(descriptor.id)
            || !features.isEmpty
            || !diagnostics.isEmpty

        if model.isLanguageServerDisabledInCurrentWorkspace(providerID: descriptor.id) {
            status = .disabled
        } else if let state = model.languageToolingSessions.languageServerStates[descriptor.id],
                  case .failed = state {
            status = .error
        } else if diagnostics.contains(where: { $0.severity == .error }) {
            status = .error
        } else if model.languageToolingSessions.activeLanguageServerIDs.contains(descriptor.id) || !features.isEmpty {
            status = .active
        } else if hasServerState {
            status = .active
        } else {
            status = .stopped
        }

        return LSPProviderMetrics(
            status: status,
            subtitle: files.isEmpty ? copy.noMatchingFiles : copy.matchingFiles(files.count),
            workspacePath: model.workspaceURL?.path ?? copy.noWorkspace,
            version: copy.title(for: status),
            fileCount: files.count,
            openFileCount: openFiles.count,
            diagnosticCount: diagnostics.count
        )
    }

}

private enum LSPServerStatus {
    case active
    case stopped
    case disabled
    case error
}

private struct LSPCapabilityRow: Identifiable {
    let title: String
    let icon: String
    let declared: Bool
    let active: Bool

    var id: String { title }
}

private struct LSPControlCenterCopy {
    let language: AppLanguage

    private var usesChinese: Bool {
        language == .simplifiedChinese
    }

    var title: String { usesChinese ? "LSP 控制中心" : "LSP Control Center" }
    var hideControlCenter: String { usesChinese ? "隐藏 LSP 控制中心" : "Hide LSP Control Center" }
    var configureLanguageServers: String { usesChinese ? "配置语言服务器" : "Configure language servers" }
    var backToOverview: String { usesChinese ? "返回概览" : "Back to overview" }
    var currentProject: String { usesChinese ? "当前项目：" : "Current project:" }
    var lspActive: String { usesChinese ? "LSP 运行中" : "LSP active" }
    var noRunningSession: String { usesChinese ? "无运行会话" : "No running session" }
    var restartAll: String { usesChinese ? "全部重启" : "Restart all" }
    var clearDiagnostics: String { usesChinese ? "清空诊断" : "Clear diagnostics" }
    var languageServers: String { usesChinese ? "语言服务器" : "Language Servers" }
    var noProjectLanguageServers: String {
        usesChinese ? "当前项目没有匹配的语言服务器。" : "No matching language servers in this project."
    }
    var rootFiles: String { usesChinese ? "项目文件" : "Root files" }
    var openFiles: String { usesChinese ? "打开文件" : "Open files" }
    var diagnostics: String { usesChinese ? "诊断" : "Diagnostics" }
    var openSupportedFile: String { usesChinese ? "打开一个受支持的源码文件" : "Open a supported source file" }
    var matchingServerWillAppear: String {
        usesChinese ? "匹配的语言服务器会显示在这里。" : "The matching language server will appear here."
    }
    var noLanguageServerDiagnostics: String {
        usesChinese ? "暂无语言服务器诊断。" : "No language server diagnostics."
    }
    var eventLog: String { usesChinese ? "事件日志" : "Event Log" }
    var clearEventLog: String { usesChinese ? "清空事件日志" : "Clear event log" }
    var noLanguageServerEvents: String {
        usesChinese ? "暂无 LSP 事件。" : "No LSP events."
    }
    var capabilities: String { usesChinese ? "能力" : "Capabilities" }
    var languageServerCapability: String { usesChinese ? "语言服务器" : "Language Server" }
    var definition: String { usesChinese ? "定义" : "Definition" }
    var completion: String { usesChinese ? "补全" : "Completion" }
    var formatting: String { usesChinese ? "格式化" : "Formatting" }
    var testing: String { usesChinese ? "测试" : "Testing" }
    var debug: String { usesChinese ? "调试" : "Debug" }
    var run: String { usesChinese ? "运行" : "Run" }
    var noMatchingFiles: String { usesChinese ? "没有匹配文件" : "No matching files" }
    var noWorkspace: String { usesChinese ? "未打开工作区" : "No workspace" }
    var notRunning: String { usesChinese ? "未运行" : "Not running" }
    var providerConfiguration: String { usesChinese ? "Provider 配置" : "Provider Configuration" }
    var rustOwnedConfiguration: String {
        usesChinese ? "由 Rust LSP 配置加载" : "Loaded by Rust LSP configuration"
    }
    var providerID: String { usesChinese ? "Provider ID" : "Provider ID" }
    var activation: String { usesChinese ? "启动策略" : "Activation" }
    var builtinCatalog: String { usesChinese ? "内置 JSON" : "Built-in JSON" }
    var projectOverride: String { usesChinese ? "项目覆盖" : "Project override" }
    var editToolPath: String { usesChinese ? "编辑 LSP 工具路径" : "Edit LSP tool path" }
    var noOpenFilesForProvider: String {
        usesChinese ? "这个语言服务器当前没有打开的文件。" : "No open files for this language server."
    }
    var builtinCatalogUnavailable: String {
        usesChinese ? "内置 LSP catalog 文件不可用。" : "The built-in LSP catalog file is unavailable."
    }
    var projectOverrideMissing: String {
        usesChinese ? "当前项目还没有 LSP 覆盖配置。" : "This project has no LSP override configuration yet."
    }
    var configurationHint: String {
        usesChinese
            ? "语言、扩展名、能力、命令和平台覆盖只允许写入独立 LSP JSON，由 Rust 兼容层注册。"
            : "Languages, extensions, capabilities, commands, and platform overrides belong in standalone LSP JSON registered by Rust."
    }

    func matchingFiles(_ count: Int) -> String {
        if usesChinese { return "\(count) 个匹配文件" }
        return "\(count) matching file\(count == 1 ? "" : "s")"
    }

    func activationPolicy(_ policy: ToolingActivationPolicy) -> String {
        switch policy {
        case .always:
            usesChinese ? "始终启动" : "Always"
        case .onDemand:
            usesChinese ? "按需激活" : "On demand"
        }
    }

    func disableProvider(_ name: String) -> String {
        usesChinese
            ? "在当前工作区禁用 \(name) LSP"
            : "Disable \(name) LSP in this workspace"
    }

    func providerIDCopied(_ id: String) -> String {
        usesChinese ? "Provider ID：\(id)" : "Provider ID: \(id)"
    }

    func capabilityState(_ name: String, declared: Bool, active: Bool) -> String {
        if usesChinese {
            if active { return "\(name) 当前会话已启用。" }
            if declared { return "\(name) 只是由 catalog 声明；当前没有运行中的 LSP 会话。" }
            return "\(name) 未由 catalog 声明。"
        }
        if active { return "\(name) is enabled in the current session." }
        if declared { return "\(name) is only declared by the catalog; no LSP session is running." }
        return "\(name) is not declared by the catalog."
    }

    func title(for status: LSPServerStatus) -> String {
        if usesChinese {
            switch status {
            case .active: "运行中"
            case .stopped: "未运行"
            case .disabled: "已禁用"
            case .error: "错误"
            }
        } else {
            switch status {
            case .active: "Running"
            case .stopped: "Not running"
            case .disabled: "Disabled"
            case .error: "Error"
            }
        }
    }
}

private struct LSPProviderMetrics {
    let status: LSPServerStatus
    let subtitle: String
    let workspacePath: String
    let version: String
    let fileCount: Int
    let openFileCount: Int
    let diagnosticCount: Int
}

private extension DiagnosticSeverity {
    var sortOrder: Int {
        switch self {
        case .error: 0
        case .warning: 1
        case .information: 2
        case .hint: 3
        case .unknown: 4
        }
    }
}

private extension LanguageServerFeatureSet {
    var enabledFeatureCount: Int {
        [
            .definition,
            .references,
            .implementation,
            .hover,
            .completion,
            .rename,
            .formatting,
            .codeActions,
            .completionResolve,
            .codeActionResolve,
            .executeCommand
        ].filter { contains($0) }.count
    }
}

private extension View {
    func panelChrome() -> some View {
        background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LitheTheme.sidebar)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(LitheTheme.panelBorder, lineWidth: 1)
        }
    }
}
