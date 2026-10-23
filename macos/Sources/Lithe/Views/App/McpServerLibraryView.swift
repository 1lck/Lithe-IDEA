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
    @State private var showsImporter = false
    @State private var query = ""
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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
            McpDiscoveryView(feature: feature.discovery) { editing = $0 }
            Divider()
            McpSettingsView(feature: access, library: feature, workspaceURL: workspaceURL)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: Binding(get: { editing != nil || showsImporter }, set: {
            if !$0 { editing = nil; showsImporter = false; feature.error = nil }
        })) {
            Group {
                if showsImporter {
                    McpJsonImportView(feature: feature, cancel: closeEditor) { draft in
                        showsImporter = false
                        editing = draft
                    }
                } else {
                    McpServerEditorView(feature: feature, draft: editorBinding, onClose: closeEditor)
                }
            }
            .padding(20)
            .frame(width: 640, height: showsImporter ? 580 : 500)
            .background(LitheTheme.settingsSurface)
            .environment(\.locale, locale)
        }
        .onAppear { feature.refreshIfNeeded() }
        .onChange(of: workspaceURL) { _ in feature.refresh() }
        .onDisappear { feature.tools.leavePage() }
    }

    private func closeEditor() {
        editing = nil
        showsImporter = false
        feature.error = nil
    }

    private var editorBinding: Binding<McpServerDraft> {
        Binding(
            get: { editing ?? McpServerDraft() },
            set: { editing = $0 }
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("MCP servers")
                    .font(LitheTheme.uiFont(size: 17, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)
                LitheInfoTip("Lithe reads the servers registered in your Codex and Claude Code configuration. Saving writes only the changed entry, keeps backups in Application Support, and never overwrites an entry created outside Lithe. Agents read MCP configuration when a session starts, so restart a session to apply changes.")
            }
            Spacer(minLength: 12)
            HStack(spacing: LitheTheme.ActionButton.spacing) {
                Button("Import JSON") { showsImporter = true }
                    .buttonStyle(LitheActionButtonStyle())
                Button("Add server") { editing = feature.makeDraft() }
                    .buttonStyle(LitheActionButtonStyle(isPrimary: true))
            }
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Server library").font(LitheTheme.settingsFont).foregroundStyle(LitheTheme.secondaryText)
                Text(verbatim: "\(feature.rows.count)").font(LitheTheme.smallFont).foregroundStyle(LitheTheme.tertiaryText)
                Spacer()
                Button("Refresh") { feature.refresh() }
                    .buttonStyle(.plain)
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lithePointer()
            }
            if feature.rows.count > 5 || !query.isEmpty {
                LitheSettingsSearchField("Search MCP servers", text: $query)
            }
            VStack(alignment: .leading, spacing: 8) {
                if !feature.isAvailable {
                    Text("MCP configuration management is unavailable.")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                } else if feature.rows.isEmpty {
                    emptyState
                } else if filteredRows.isEmpty {
                    Text("No matching MCP servers")
                        .font(LitheTheme.settingsFont).foregroundStyle(LitheTheme.secondaryText)
                        .padding(16)
                } else {
                    VStack(spacing: 6) {
                        ForEach(filteredRows) { row in
                            McpServerRowView(feature: feature, row: row) {
                                editing = feature.draft(for: row)
                            }
                        }
                    }
                }

            }
        }
    }

    private var filteredRows: [McpServerRow] {
        feature.rows.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.summary.localizedCaseInsensitiveContains(query)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No MCP servers registered")
                .font(LitheTheme.uiFont(size: 12.5, weight: .medium))
                .foregroundStyle(LitheTheme.primaryText)
            Text("Add one here, or register a server with Codex or Claude Code and refresh.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(LitheTheme.settingsControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LitheTheme.settingsControlBorder, style: StrokeStyle(lineWidth: 1, dash: [4])))
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
struct McpServerRowView: View {
    @ObservedObject var feature: McpServerLibraryFeatureModel
    let row: McpServerRow
    let edit: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(LitheTheme.uiFont(size: 10, weight: .semibold))
                }.buttonStyle(.plain).foregroundStyle(LitheTheme.secondaryText)
                    .accessibilityLabel(Text("Server tools"))
            }
          }
          if expanded { McpToolsPanel(feature: feature.tools, row: row) }
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
        McpBrandIcon(entry: feature.catalogEntry(for: row.definition) ?? McpRegistryEntry(
            id: row.id, title: row.name, summary: "", version: "", website: nil, draft: row.definition))
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(row.name)
                    .font(LitheTheme.uiFont(size: 12.5, weight: .medium))
                    .foregroundStyle(LitheTheme.primaryText)
                McpToolStatusBadge(feature: feature.tools, row: row)
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
                AgentBrandIcon(name: agent.displayName, size: 13, style: .brand)
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
struct McpServerEditorView: View {
    @ObservedObject var feature: McpServerLibraryFeatureModel
    @Binding var draft: McpServerDraft
    let onClose: () -> Void

    @State private var didAttemptSave = false
    @State private var commandLine = ""
    @State private var commandError: String?

    private var original: McpServerRow? {
        guard let id = draft.originalRowID else { return nil }
        return feature.rows.first { $0.id == id }
    }

    private var validationMessage: String? {
        (draft.transport == .stdio ? commandError : nil) ?? feature.validationMessage(for: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let message = draft.setupMessage {
                        Text(message).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                    }
                    serverSection
                    if draft.transport == .stdio {
                        environmentSection
                    } else {
                        headersSection
                    }
                    agentsSection
                    if let message = validationMessage, didAttemptSave || commandError != nil {
                        LitheBanner(status: .warning) { Text(message).font(LitheTheme.smallFont) }
                    }
                    if let error = feature.error {
                        LitheBanner(status: .warning) {
                            Text(error).font(LitheTheme.smallFont).textSelection(.enabled)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Divider()
            footer
        }
        .onAppear {
            guard draft.transport == .stdio else { return }
            do { commandLine = try feature.tools.commandLine(draft) }
            catch { commandError = String(localized: "Could not read the command line.") }
        }
        .onChange(of: draft.transport) { value in
            if value == .stdio {
                do { commandLine = try feature.tools.commandLine(draft); commandError = nil }
                catch { commandError = String(localized: "Could not read the command line.") }
            }
        }
    }

    private var heading: some View {
        HStack(spacing: 8) {
            McpBrandIcon(entry: feature.catalogEntry(for: definition) ?? McpRegistryEntry(
                id: draft.name, title: draft.name, summary: "", version: "", website: nil, draft: definition))
            Text(draft.name.isEmpty ? String(localized: "New MCP server") : draft.name)
                .font(LitheTheme.uiFont(size: 16, weight: .semibold))
            Spacer(minLength: 8)

        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            McpSettingsRow("Name", info: "Use letters, digits, dots, dashes or underscores. The name must start with a letter or digit.") {
                TextField("Name", text: $draft.name)
                    .litheSettingsTextField()
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
                McpSettingsRow("Command", info: "Enter the executable and arguments as in a terminal. Quote paths with spaces. Lithe passes exact arguments without running a shell; pipes and redirects are not evaluated.") {
                    TextField("npx -y @playwright/mcp", text: $commandLine, axis: .vertical)
                        .font(LitheTheme.uiFont(size: 11.5, design: .monospaced))
                        .lineLimit(1...3).litheSettingsTextField()
                        .onChange(of: commandLine) { line in
                            do { try feature.tools.updateCommandLine(line, draft: &draft); commandError = nil }
                            catch { commandError = String(localized: "Check command-line quotes before saving.") }
                        }
                }
            } else {
                McpSettingsRow("URL") {
                    TextField("https://example.com/mcp", text: $draft.url)
                        .litheSettingsTextField()
                }
            }
        }
    }

    private var environmentSection: some View {
        McpSettingsRow("Environment variables", info: "Values are masked here but stored as plain text in the Agent's configuration file.") {
            McpKeyValueEditor(
                entries: $draft.env,
                keyPlaceholder: "Name",
                valuePlaceholder: "Value",
                addTitle: "Add variable"
            )
        }
    }

    private var headersSection: some View {
        McpSettingsRow("Headers", info: "Values are masked here but stored as plain text in the Agent's configuration file.") {
            McpKeyValueEditor(
                entries: $draft.headers,
                keyPlaceholder: "Header",
                valuePlaceholder: "Value",
                addTitle: "Add header"
            )
        }
    }

    private var agentsSection: some View {
        McpSettingsRow("Available to Agents", info: "Each Agent keeps its own configuration file. Turning an Agent off removes only the entry Lithe wrote; an entry created outside Lithe is never removed without taking ownership first.") {
            HStack(alignment: .top, spacing: 16) {
                Button("All") { draft.enabledAgents = Set(McpAgent.allCases) }
                    .buttonStyle(LitheActionButtonStyle())
                ForEach(McpAgent.allCases) { agent in
                    agentRow(agent)
                }
            }
        }
    }

    private func agentRow(_ agent: McpAgent) -> some View {
        let isOn = binding(for: agent)
        let owned = original?.ownedGlobalAgents.contains(agent) == true
        return VStack(alignment: .leading, spacing: 2) {
            McpAgentSelectionChip(agent: agent, selected: isOn.wrappedValue) { isOn.wrappedValue.toggle() }
            if isOn.wrappedValue, original != nil, !owned {
                HStack(spacing: 4) {
                    LitheInfoTip("Created outside Lithe.")
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

    private var footer: some View {
        HStack(spacing: LitheTheme.ActionButton.spacing) {
            if let original {
                Button("Remove from library", role: .destructive) {
                    guard feature.delete(original) else { return }; onClose()
                }.buttonStyle(.plain).foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer(minLength: 12)
            Button("Cancel", action: onClose)
                .buttonStyle(LitheActionButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                didAttemptSave = true
                guard feature.save(draft) else { return }
                onClose()
            }
            .buttonStyle(LitheActionButtonStyle(isPrimary: true))
            .disabled(validationMessage != nil)
        }
        .padding(.top, 2)
    }

    private var definition: McpServerDefinition {
        McpServerDefinition(name: draft.name, transport: draft.transport, command: draft.command,
            args: draft.arguments, env: draft.env, url: draft.url, headers: draft.headers, definitionHash: "")
    }
}

struct McpAgentSelectionChip: View {
    let agent: McpAgent
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                AgentBrandIcon(name: agent.displayName, size: 16, style: .brand)
                Text(agent.displayName).font(LitheTheme.settingsFont)
                if selected { Image(systemName: "checkmark").font(LitheTheme.smallFont) }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(selected ? LitheTheme.accent.opacity(0.10) : LitheTheme.settingsControlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? LitheTheme.accent.opacity(0.5) : LitheTheme.settingsControlBorder))
        }.buttonStyle(.plain).accessibilityLabel(Text(agent.displayName)).accessibilityValue(Text(selected ? "Selected" : "Not selected"))
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
                .frame(width: 155, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 30)
    }
}
