import SwiftUI
import LitheCoreContracts

struct AgentSkillDetailSheet: View {
    let item: AgentSkillsFeatureModel.Item
    @ObservedObject var feature: AgentSkillsFeatureModel
    let onOpen: () -> Void
    let onReveal: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var content: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: item.skill.name).font(LitheTheme.uiFont(size: 16, weight: .semibold))
            if let plugin = item.skill.pluginId { Text(verbatim: plugin).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText) }
            Text(verbatim: item.agentName).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            Text(verbatim: item.skill.description).font(LitheTheme.settingsFont).textSelection(.enabled)
            Text(verbatim: item.skill.path).font(LitheTheme.uiFont(size: 11, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText).textSelection(.enabled)
            if item.source == "directory" {
                Text("File inventory only. Claude determines whether this skill is available in a session.")
                    .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            } else if let enabled = item.skill.enabled {
                Text(enabled ? "Enabled in Agent" : "Disabled in Agent").font(LitheTheme.smallFont)
            }
            if let error { AgentSettingsIssue(error) }
            if let content {
                ScrollView {
                    Text(verbatim: content).font(LitheTheme.codeFont).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.litheScrollViewChrome(alwaysShowVertical: true, usesCompactScrollers: true)
            } else if error == nil { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
            HStack(spacing: LitheTheme.ActionButton.spacing) {
                Button("Open SKILL.md", action: onOpen).buttonStyle(LitheActionButtonStyle())
                Button("Reveal in Finder", action: onReveal).buttonStyle(LitheActionButtonStyle())
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(LitheActionButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 560, height: 570).background(LitheTheme.settingsSurface)
        .task(id: item.id) {
            do {
                let result = try await feature.read(item)
                if !Task.isCancelled { content = result }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

struct AgentSkillCreateSheet: View {
    @ObservedObject var feature: AgentSkillsFeatureModel
    let context: AgentSkillsFeatureModel.Context
    let scope: String
    let initialAgentID: String
    let source: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var agentID = "codex-acp"
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""

    private var valid: Bool {
        source != nil || (!name.isEmpty && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(source == nil ? "New skill" : "Import skill").font(LitheTheme.uiFont(size: 16, weight: .semibold))
            HStack(spacing: 8) {
                Text("Agent")
                LitheSettingsSelect(selection: $agentID, options: AgentSkillsFeatureModel.agents, width: 180,
                    accessibilityLabel: "Skill target Agent", title: { $0 == "codex-acp" ? "Codex" : "Claude" }, localizesTitles: false)
                Text(scope == "repo" ? "Project skills" : "Global skills").foregroundStyle(LitheTheme.secondaryText)
            }
            if let directory = feature.directory(agentID: agentID, scope: scope) {
                Text(verbatim: directory).font(LitheTheme.uiFont(size: 11, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText).textSelection(.enabled)
            }
            if let source {
                Text("Import source").font(LitheTheme.smallFont)
                Text(verbatim: source.path).font(LitheTheme.codeFont).textSelection(.enabled)
                Text("Directory imports preserve scripts, templates and other supporting files. Existing skills are never overwritten.")
                    .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                Spacer(minLength: 0)
            } else {
                LitheTextField("Skill name (lowercase-with-hyphens)", text: $name)
                LitheTextField("When should this skill be used?", text: $description)
                Text("Skill instructions").font(LitheTheme.smallFont)
                LitheTextEditor(text: $instructions, height: 230)
            }
            if let error = feature.error { AgentSettingsIssue(error) }
            HStack(spacing: LitheTheme.ActionButton.spacing) {
                if feature.isWriting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(LitheActionButtonStyle()).keyboardShortcut(.cancelAction)
                Button(source == nil ? "Create skill" : "Import") {
                    let request: AgentSkillWrite
                    if let source { request = .init(agentID: agentID, workspace: context.workspace, scope: scope, source: source) }
                    else { request = .init(agentID: agentID, workspace: context.workspace, scope: scope, name: name,
                                          description: description, instructions: instructions) }
                    feature.write(request, context: context)
                }.buttonStyle(LitheActionButtonStyle(isPrimary: true))
                    .disabled(!valid || feature.phase == .loading)
            }
        }
        .padding(20).frame(width: 540, height: source == nil ? 490 : 300)
        .background(LitheTheme.settingsSurface).disabled(feature.isWriting)
        .interactiveDismissDisabled(feature.isWriting)
        .onAppear { agentID = initialAgentID }
    }
}
