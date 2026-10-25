import SwiftUI
import LitheCoreContracts

/// Scope is the main navigation; Agent provenance is secondary filtering.
struct AgentSkillsSettingsView: View {
    @ObservedObject var feature: AgentSkillsFeatureModel
    let workspace: URL?
    var openProjects: [URL] = []
    var preferredAgentID: String?
    let onOpen: (URL) -> Void
    let onReveal: (URL) -> Void
    let onCopy: (String) -> Void
    let onChooseImport: (Bool, String, String) -> URL?
    @Environment(\.locale) private var locale
    @State private var selectedProjectPath = ""
    @State private var sheet: AgentSkillSheet?

    private var projectPaths: [String] {
        var paths = openProjects.map(\.path)
        if let path = workspace?.path { paths.insert(path, at: 0) }
        return paths.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    private var context: AgentSkillsFeatureModel.Context {
        let path = projectPaths.contains(selectedProjectPath) ? selectedProjectPath : projectPaths.first
        return .init(workspace: path.map { URL(fileURLWithPath: $0) })
    }
    private var busy: Bool { feature.isWriting || feature.phase == .loading }
    private var canAdd: Bool { !busy && (feature.scope != "repo" || context.workspace != nil) }
    private func text(_ key: String) -> String { AgentLocalization.message(key, locale: locale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Skills").font(LitheTheme.uiFont(size: 16, weight: .semibold))
                LitheInfoTip("Codex reports its discovered skills. Claude lists files in the selected project and user directories; inherited and plugin skills may also be available in its sessions.")
                Spacer(minLength: 0)
                if !projectPaths.isEmpty {
                    LitheSettingsSelect(selection: Binding(get: { context.workspace?.path ?? "" }, set: { selectedProjectPath = $0 }),
                        options: projectPaths, width: 190, accessibilityLabel: "Skill project", title: { URL(fileURLWithPath: $0).lastPathComponent }, localizesTitles: false)
                        .disabled(feature.isWriting)
                }
            }
            LitheSettingsSegmentedControl(selection: $feature.scope, options: ["user", "repo"], width: 300,
                title: { text($0 == "user" ? "Global skills" : "Project skills") + "  \(feature.count(in: $0))" })
                .disabled(feature.isWriting)
            LitheSearchField("Search skills", text: $feature.query)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { toolbar }
                VStack(alignment: .leading, spacing: 8) { toolbar }
            }
            feedback
            if feature.scope == "repo" && context.workspace == nil {
                Text("Open a project to manage its skills.").foregroundStyle(LitheTheme.secondaryText).padding(.vertical, 16)
            } else if feature.phase != .loading && feature.visibleItems.isEmpty {
                Text(feature.query.isEmpty ? "No skills in this scope." : "No matching skills.")
                    .foregroundStyle(LitheTheme.secondaryText).padding(.vertical, 16)
            }
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(feature.visibleItems) { item in row(item) }
            }
        }
        .font(LitheTheme.settingsFont)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: context) { await feature.refresh(context) }
        .onChange(of: context) { _ in sheet = nil }
        .onChange(of: workspace) { _ in selectedProjectPath = workspace?.path ?? "" }
        .onChange(of: feature.savedURL) { url in if url != nil { sheet = nil } }
        .onDisappear { feature.cancel() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .details(let item):
                AgentSkillDetailSheet(item: item, feature: feature,
                    onOpen: { open(item.skill.path) }, onReveal: { reveal(item.skill.path) })
            case .add(let source):
                AgentSkillCreateSheet(feature: feature, context: context, scope: feature.scope,
                    initialAgentID: initialAgentID, source: source)
            }
        }
    }

    private var initialAgentID: String {
        if AgentSkillsFeatureModel.agents.contains(feature.agentFilter) { return feature.agentFilter }
        return AgentSkillsFeatureModel.agents.contains(preferredAgentID ?? "") ? preferredAgentID! : "codex-acp"
    }

    @ViewBuilder private var toolbar: some View {
        LitheSettingsSelect(selection: $feature.agentFilter, options: ["all"] + AgentSkillsFeatureModel.agents,
            width: 140, accessibilityLabel: "Skill source", title: { $0 == "all" ? text("All sources") : ($0 == "codex-acp" ? "Codex" : "Claude") }, localizesTitles: false)
        HStack(spacing: LitheTheme.ActionButton.spacing) {
            Button { feature.reload(context) } label: {
                LitheIDEAIcon(resourcePath: "expui/general/refresh.svg", size: LitheTheme.Metrics.toolbarIconSize,
                              fallbackSystemImage: "arrow.clockwise", preservesOriginalColors: true)
            }.litheToolbarIconButton().help("Refresh skills").disabled(busy)
            LitheMenu {
                LitheContextMenuItem.action("Import SKILL.md") { chooseImport(directory: false) }
                LitheContextMenuItem.action("Import skill directory") { chooseImport(directory: true) }
            } label: { Text("Import") }.buttonStyle(LitheActionButtonStyle()).disabled(!canAdd)
            Button("New skill") { feature.dismissResult(); sheet = .add(nil) }
                .buttonStyle(LitheActionButtonStyle(isPrimary: true)).disabled(!canAdd)
        }
    }

    @ViewBuilder private var feedback: some View {
        if feature.phase == .loading { ProgressView().controlSize(.small) }
        Text("Switches save native Agent settings. Reconnect existing conversations to refresh available skills.")
            .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
        Text("Skill setting saved.").font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            .opacity(feature.didChangeEnablement ? 1 : 0)
            .accessibilityHidden(!feature.didChangeEnablement)
        if feature.savedURL != nil {
            Text("Skill saved. Refresh or reconnect the Agent if it does not appear in the conversation.")
                .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
        }
        if let error = feature.error { AgentSettingsIssue(text(error)) }
        ForEach(AgentSkillsFeatureModel.agents, id: \.self) { agentID in
            if feature.agentFilter == "all" || feature.agentFilter == agentID {
                if let error = feature.discoveryErrors[agentID] {
                    Text(verbatim: (agentID == "codex-acp" ? "Codex: " : "Claude: ") + text(error))
                        .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.warning).textSelection(.enabled)
                }
                ForEach(Array((feature.listings[agentID]?.issues ?? []).enumerated()), id: \.offset) { _, issue in
                    Text(verbatim: text(issue)).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.warning).textSelection(.enabled)
                }
            }
        }
    }

    private func row(_ item: AgentSkillsFeatureModel.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(verbatim: item.skill.name).font(LitheTheme.uiFont(size: 13, weight: .medium)).lineLimit(1)
                    AgentBadge(text: LocalizedStringKey(item.agentName), color: LitheTheme.secondaryText)
                    if item.skill.pluginId != nil { Text("Plugin").font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText) }
                    if item.skill.scope == "system" { Text("Built-in").font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText) }
                    if item.skill.scope == "admin" { Text("Managed").font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText) }
                }
                Text(verbatim: item.skill.description).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let enabled = feature.displayedEnablement(for: item) {
                Toggle("Enable skill", isOn: Binding(get: { enabled }, set: { feature.setEnabled($0, for: item, context: context) }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityLabel(Text(verbatim: text("Enable skill") + ": " + item.skill.name))
                    .help(item.agentID == "codex-acp"
                        ? "Codex saves this setting by path for all projects using this skill."
                        : "Claude saves visibility by name: global skills use user settings; project skills use project-local settings. Project and managed settings may override global settings. Skills with the same name share this setting.")
                    .disabled(!feature.canChangeEnablement(for: item))
            } else {
                Text("State unknown").font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            }
            Button("View skill") { sheet = .details(item) }.buttonStyle(LitheActionButtonStyle())
            LitheMenu {
                LitheContextMenuItem.action("Open SKILL.md") { open(item.skill.path) }
                LitheContextMenuItem.action("Reveal in Finder") { reveal(item.skill.path) }
                LitheContextMenuItem.action("Copy path") { onCopy(item.skill.path) }
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/more.svg", size: LitheTheme.Metrics.toolbarIconSize,
                              fallbackSystemImage: "ellipsis", preservesOriginalColors: true)
            }.litheToolbarIconButton().accessibilityLabel("Skill actions")
        }
        .padding(10)
        .background(LitheTheme.settingsControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius))
    }

    private func chooseImport(directory: Bool) {
        let title = text(directory ? "Import skill directory" : "Import skill")
        let source = onChooseImport(directory, title, text("Import"))
        if let source { feature.dismissResult(); sheet = .add(source) }
    }
    private func open(_ path: String) { onOpen(URL(fileURLWithPath: path)) }
    private func reveal(_ path: String) { onReveal(URL(fileURLWithPath: path)) }
}

private enum AgentSkillSheet: Identifiable {
    case details(AgentSkillsFeatureModel.Item)
    case add(URL?)
    var id: String {
        switch self { case .details(let item): "details:" + item.id; case .add(let source): "add:" + (source?.path ?? "new") }
    }
}
