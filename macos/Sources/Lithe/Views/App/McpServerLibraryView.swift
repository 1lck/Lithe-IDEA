import SwiftUI

/// Settings › AI › MCP: the discovered server library plus the project grant.
///
/// The list is deliberately independent of the workspace so a user can manage
/// Codex and Claude Code servers before opening a project. Project-scoped rows
/// are shown for transparency but are owned by the grant section below.
struct McpServerLibraryView: View {
    @ObservedObject var feature: McpServerLibraryFeatureModel
    @ObservedObject var access: IdeCapabilitiesFeatureModel
    let workspaceURL: URL?

    @State private var editing: McpServerDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if editing != nil {
                McpServerEditorView(feature: feature, draft: editorBinding) {
                    editing = nil
                }
            } else {
                header
                if let error = feature.error {
                    LitheBanner(status: .warning) {
                        Text(error)
                            .font(LitheTheme.smallFont)
                            .textSelection(.enabled)
                    }
                }
                if !feature.loadErrors.isEmpty {
                    LitheBanner(status: .warning) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(feature.loadErrors, id: \.self) { message in
                                Text(message).font(LitheTheme.smallFont)
                            }
                        }
                    }
                }
                librarySection
                if let backup = feature.lastBackupURL {
                    backupLine(backup)
                }
                McpSettingsView(
                    feature: access,
                    library: feature,
                    workspaceURL: workspaceURL
                )
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .onAppear { feature.refreshIfNeeded() }
        .onChange(of: workspaceURL) { _ in feature.refresh() }
    }

    private var editorBinding: Binding<McpServerDraft> {
        Binding(
            get: { editing ?? McpServerDraft() },
            set: { editing = $0 }
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LitheTheme.accent.opacity(0.12))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "server.rack")
                        .font(LitheTheme.uiFont(size: 14, weight: .semibold))
                        .foregroundStyle(LitheTheme.accent)
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("MCP servers")
                        .font(LitheTheme.uiFont(size: 15, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                    LitheInfoTip("Lithe reads the servers registered in your Codex and Claude Code configuration. Saving writes only the changed entry, keeps backups in Application Support, and never overwrites an entry created outside Lithe. Agents read MCP configuration when a session starts, so restart a session to apply changes.")
                }
                Text("Manage the servers Codex and Claude Code can start.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            Spacer(minLength: 12)

            Button("Refresh") { feature.refresh() }
                .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 12, height: 26, fontSize: 11.5))
        }
    }

    private var librarySection: some View {
        LitheSettingsSection("Server library") {
            VStack(alignment: .leading, spacing: 8) {
                if !feature.isAvailable {
                    Text("MCP configuration management is unavailable.")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                } else if feature.rows.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 6) {
                        ForEach(feature.rows) { row in
                            McpServerRowView(feature: feature, row: row) {
                                editing = feature.draft(for: row)
                            }
                        }
                    }
                }

                if feature.isAvailable {
                    Button {
                        editing = feature.makeDraft()
                    } label: {
                        Label("Add server", systemImage: "plus")
                            .font(LitheTheme.uiFont(size: 12, weight: .medium))
                    }
                    .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 12, height: 28, fontSize: 12))
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "tray")
                .font(LitheTheme.uiFont(size: 15))
                .foregroundStyle(LitheTheme.tertiaryText)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("No MCP servers registered")
                    .font(LitheTheme.uiFont(size: 12.5, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                Text("Add one here, or register a server with Codex or Claude Code and refresh.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.settingsControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func backupLine(_ url: URL) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(LitheTheme.uiFont(size: 10))
            Text("Previous configuration backed up to")
            Text(url.path)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(LitheTheme.smallFont)
        .foregroundStyle(LitheTheme.secondaryText)
    }
}

/// One library row: identity, a one-line command summary and per-Agent chips.
private struct McpServerRowView: View {
    @ObservedObject var feature: McpServerLibraryFeatureModel
    let row: McpServerRow
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: edit) {
                HStack(spacing: 10) {
                    icon
                    identity
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(row.isProjectOnly)
            .lithePointer()

            ForEach(McpAgent.allCases) { agent in
                McpAgentChip(
                    agent: agent,
                    isOn: row.enabledGlobalAgents.contains(agent),
                    isDisabled: row.isProjectOnly
                ) {
                    _ = feature.setAgent(agent, enabled: !row.enabledGlobalAgents.contains(agent), for: row)
                }
            }

            if !row.isProjectOnly {
                Image(systemName: "chevron.right")
                    .font(LitheTheme.uiFont(size: 9, weight: .semibold))
                    .foregroundStyle(LitheTheme.tertiaryText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.settingsControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(LitheTheme.settingsControlBorder.opacity(0.8), lineWidth: 1)
        }
    }

    private var icon: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LitheTheme.accent.opacity(0.10))
            .frame(width: 26, height: 26)
            .overlay {
                Image(systemName: row.definition.transport == .stdio ? "terminal" : "network")
                    .font(LitheTheme.uiFont(size: 11, weight: .medium))
                    .foregroundStyle(LitheTheme.accent)
            }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(row.name)
                    .font(LitheTheme.uiFont(size: 12.5, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                if row.isLitheRegistration {
                    badge("Lithe", color: LitheTheme.accent)
                } else if row.isProjectOnly {
                    badge("Project", color: LitheTheme.secondaryText)
                }
                if row.hasDefinitionConflict {
                    badge("Conflict", color: LitheTheme.warning)
                        .help("Another global entry uses this name with a different definition.")
                }
            }
            Text(row.summary.isEmpty ? String(localized: "No command") : row.summary)
                .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func badge(_ title: LocalizedStringKey, color: Color) -> some View {
        Text(title)
            .font(LitheTheme.uiFont(size: 9.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.10))
            .clipShape(Capsule())
    }
}

/// Compact per-Agent switch rendered as a checkable capsule.
private struct McpAgentChip: View {
    let agent: McpAgent
    let isOn: Bool
    let isDisabled: Bool
    let action: () -> Void

    private var helpText: LocalizedStringKey {
        if isDisabled {
            return "This entry belongs to the open project and is managed by Lithe IDE access."
        }
        return isOn ? "Registered with \(agent.displayName)" : "Add to \(agent.displayName)"
    }

    private var accessibilityText: LocalizedStringKey {
        isOn ? "\(agent.displayName) enabled" : "\(agent.displayName) disabled"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: isOn ? "checkmark" : "plus")
                    .font(LitheTheme.uiFont(size: 8.5, weight: .bold))
                Text(agent.displayName)
                    .font(LitheTheme.uiFont(size: 10.5, weight: .medium))
            }
            .foregroundStyle(isOn ? LitheTheme.accent : LitheTheme.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(isOn ? LitheTheme.accent.opacity(0.12) : Color.clear)
            .clipShape(Capsule())
            .overlay {
                Capsule().strokeBorder(
                    isOn ? LitheTheme.accent.opacity(0.35) : LitheTheme.settingsControlBorder,
                    lineWidth: 1
                )
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        .lithePointer()
        .help(Text(helpText))
        .accessibilityLabel(Text(accessibilityText))
    }
}

/// Detail editor for one server definition.
private struct McpServerEditorView: View {
    @ObservedObject var feature: McpServerLibraryFeatureModel
    @Binding var draft: McpServerDraft
    let onClose: () -> Void

    @State private var didAttemptSave = false

    private var original: McpServerRow? {
        guard let id = draft.originalRowID else { return nil }
        return feature.rows.first { $0.id == id }
    }

    private var validationMessage: String? {
        feature.validationMessage(for: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            backBar
            serverSection
            if draft.transport == .stdio {
                environmentSection
            } else {
                headersSection
            }
            agentsSection
            destinationSection

            if didAttemptSave, let message = validationMessage {
                LitheBanner(status: .warning) {
                    Text(message).font(LitheTheme.smallFont)
                }
            }
            if let error = feature.error {
                LitheBanner(status: .warning) {
                    Text(error)
                        .font(LitheTheme.smallFont)
                        .textSelection(.enabled)
                }
            }

            footer
        }
    }

    private var backBar: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(LitheTheme.uiFont(size: 9, weight: .semibold))
                    Text("All servers")
                        .font(LitheTheme.uiFont(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(LitheTheme.accent)
            .lithePointer()

            Spacer(minLength: 8)

            if original != nil {
                Button(role: .destructive) {
                    guard let original, feature.delete(original) else { return }
                    onClose()
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(LitheTheme.uiFont(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LitheTheme.error)
                .lithePointer()
            }
        }
    }

    private var serverSection: some View {
        LitheSettingsSection("Server") {
            VStack(alignment: .leading, spacing: 9) {
                McpSettingsRow("Name") {
                    TextField("Name", text: $draft.name)
                        .litheSettingsTextField()
                        .frame(width: 240)
                }
                McpSettingsRow("Transport") {
                    LitheSettingsSegmentedControl(
                        selection: $draft.transport,
                        options: McpTransport.allCases,
                        width: 210,
                        title: { $0.title }
                    )
                }
                if draft.transport == .stdio {
                    McpSettingsRow("Command") {
                        TextField("Command", text: $draft.command)
                            .litheSettingsTextField()
                    }
                    McpSettingsRow("Arguments", info: "One argument per line. Arguments keep spaces without quoting.") {
                        TextEditor(text: $draft.argumentsText)
                            .font(LitheTheme.uiFont(size: 11.5, design: .monospaced))
                            .litheSettingsTextEditor(height: 64)
                    }
                } else {
                    McpSettingsRow("URL") {
                        TextField("https://example.com/mcp", text: $draft.url)
                            .litheSettingsTextField()
                    }
                }
            }
        }
    }

    private var environmentSection: some View {
        LitheSettingsSection("Environment variables") {
            McpKeyValueEditor(
                entries: $draft.env,
                keyPlaceholder: "Name",
                valuePlaceholder: "Value",
                addTitle: "Add variable"
            )
        }
    }

    private var headersSection: some View {
        LitheSettingsSection("Headers") {
            McpKeyValueEditor(
                entries: $draft.headers,
                keyPlaceholder: "Header",
                valuePlaceholder: "Value",
                addTitle: "Add header"
            )
        }
    }

    private var agentsSection: some View {
        LitheSettingsSection(
            title: "Available to Agents",
            accessory: {
                LitheInfoTip("Each Agent keeps its own configuration file. Turning an Agent off removes only the entry Lithe wrote; an entry created outside Lithe is never removed without taking ownership first.")
            },
            content: {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(McpAgent.allCases) { agent in
                        agentRow(agent)
                    }
                }
            }
        )
    }

    private func agentRow(_ agent: McpAgent) -> some View {
        let isOn = binding(for: agent)
        let owned = original?.ownedGlobalAgents.contains(agent) == true
        return VStack(alignment: .leading, spacing: 2) {
            LitheSettingsCheckbox(isOn: isOn, title: LocalizedStringKey(agent.displayName))
            if isOn.wrappedValue, original != nil, !owned {
                HStack(spacing: 4) {
                    Text("Created outside Lithe.")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                    Button("Take ownership") {
                        if let original {
                            feature.takeOwnership(of: original, agent: agent)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.accent)
                    .lithePointer()
                }
                .padding(.leading, 20)
            }
        }
    }

    private func binding(for agent: McpAgent) -> Binding<Bool> {
        Binding(
            get: { draft.enabledAgents.contains(agent) },
            set: { isOn in
                if isOn {
                    draft.enabledAgents.insert(agent)
                } else {
                    draft.enabledAgents.remove(agent)
                }
            }
        )
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Saving writes to")
                .font(LitheTheme.uiFont(size: 11, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
            let urls = feature.destinationURLs(for: draft)
            if urls.isEmpty {
                Text("No Agent is selected.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            } else {
                ForEach(urls, id: \.self) { url in
                    Text(url.path)
                        .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 12)
            Button("Cancel", action: onClose)
                .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 12, height: 28, fontSize: 12))
            Button("Save") {
                didAttemptSave = true
                guard feature.save(draft) else { return }
                onClose()
            }
            .buttonStyle(LithePrimaryButtonStyle(horizontalPadding: 14, height: 28))
            .disabled(validationMessage != nil)
        }
        .padding(.top, 2)
    }
}

/// Key/value rows for environment variables and HTTP headers. Values stay
/// masked because Agent configuration files commonly store API keys here.
private struct McpKeyValueEditor: View {
    @Binding var entries: [McpKeyValue]
    let keyPlaceholder: LocalizedStringKey
    let valuePlaceholder: LocalizedStringKey
    let addTitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entries.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField(keyPlaceholder, text: $entries[index].key)
                        .litheSettingsTextField()
                        .frame(maxWidth: .infinity)
                    SecureField(valuePlaceholder, text: $entries[index].value)
                        .litheSettingsTextField()
                        .frame(maxWidth: .infinity)
                    Button {
                        entries.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(LitheTheme.uiFont(size: 12))
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .lithePointer()
                    .help("Remove")
                }
            }

            Button {
                entries.append(McpKeyValue(key: "", value: ""))
            } label: {
                Label(addTitle, systemImage: "plus")
                    .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(LitheTheme.accent)
            .lithePointer()

            Text("Values are masked here but stored as plain text in the Agent's configuration file.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
    }
}

/// Label plus control row matching the shared settings pages.
private struct McpSettingsRow<Content: View>: View {
    let title: LocalizedStringKey
    let info: LocalizedStringKey?
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, info: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.info = info
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            LitheSettingsLabel(title, info: info)
                .frame(width: 110, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 30)
    }
}
