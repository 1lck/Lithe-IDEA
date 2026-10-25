import LitheModuleAPI
import SwiftUI

struct McpToolStatusBadge: View {
    @ObservedObject var feature: McpToolsFeatureModel
    let row: McpServerRow
    var body: some View {
        let state = feature.state(for: row)
        if state.isReady || state.isLoading {
            HStack(spacing: 4) {
                Circle().fill(state.isReady ? LitheTheme.success : LitheTheme.secondaryText).frame(width: 5, height: 5)
                Text(state.isLoading ? L10n.string("Detecting…") : String(format: L10n.string("%d tools"), state.tools.count))
                    .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            }
        }
    }
}

/// Expanding a row is read-only. Starting a local server always requires the
/// explicit Detect action and its execution notice; tool calls are never sent.
struct McpToolsPanel: View {
    @ObservedObject var feature: McpToolsFeatureModel
    let row: McpServerRow
    @State private var agent: McpAgent = .codex
    @State private var confirmsExecution = false

    private var state: McpToolsFeatureModel.State { feature.state(for: row) }
    private var policy: McpToolPolicySnapshot? { state.policies[agent] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(state.isReady ? LitheTheme.success : LitheTheme.secondaryText.opacity(0.5)).frame(width: 6, height: 6)
                Text(state.isLoading ? L10n.string("Detecting…") : (state.isReady ? String(format: L10n.string("%d tools"), state.tools.count) : L10n.string("Not detected")))
                    .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                LitheInfoTip("Detection connects to this server and lists tool metadata without calling any tool. Local commands may run code or download packages. Results describe this check, not the availability of an existing Agent session. Tool switches apply to the selected Agent's user configuration; project and managed policies can still restrict access. Start a new Agent session after changes.")
                Spacer()
                if state.isLoading {
                    Button("Cancel") { feature.cancelAll() }.buttonStyle(.plain)
                } else {
                    Button(state.isReady ? "Detect again" : "Detect tools") {
                        if row.definition.transport == .stdio { confirmsExecution = true }
                        else { feature.detect(row) }
                    }.buttonStyle(LitheActionButtonStyle())
                }
            }
            if let error = state.error {
                Text(error).font(LitheTheme.smallFont).foregroundStyle(LitheTheme.error).textSelection(.enabled)
                if state.isReady {
                    Button("Reload tool settings") { feature.loadPolicies(row) }.buttonStyle(.plain).foregroundStyle(LitheTheme.accent)
                }
            }
            if state.isReady && !state.tools.isEmpty {
                HStack(spacing: 8) {
                    ForEach(McpAgent.allCases.filter { row.enabledGlobalAgents.contains($0) }) { value in
                        McpAgentSelectionChip(agent: value, selected: agent == value) { agent = value }
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(state.tools) { tool in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: tool.name).font(LitheTheme.uiFont(size: 11.5, design: .monospaced))
                                if !tool.description.isEmpty {
                                    Text(verbatim: tool.description).font(LitheTheme.smallFont)
                                        .foregroundStyle(LitheTheme.secondaryText).lineLimit(4).help(tool.description)
                                }
                            }
                            Spacer(minLength: 8)
                            let permission = policy?.tools.first { $0.name == tool.name }
                            Toggle(isOn: Binding(get: { permission?.enabled == true }, set: {
                                feature.setEnabled($0, tool: tool.name, agent: agent, row: row)
                            })) { Text(verbatim: tool.name) }
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .disabled(permission?.editable != true || state.isLoading)
                            .accessibilityLabel(Text("\(tool.name) in \(agent.displayName)"))
                            if permission?.editable == false {
                                LitheInfoTip("This tool is restricted outside Lithe. Edit the native Agent policy to enable it.")
                            }
                        }
                        .padding(.vertical, 9)
                        if tool.id != state.tools.last?.id { Divider() }
                    }
                }
            } else if state.isReady {
                Text("This server reported no tools.").font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            }
        }
        .padding(12)
        .background(LitheTheme.settingsSurface)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .onAppear { if !row.enabledGlobalAgents.contains(agent) { agent = row.enabledGlobalAgents.first ?? .codex } }
        .alert("Run this MCP command?", isPresented: $confirmsExecution) {
            Button("Cancel", role: .cancel) { }
            Button("Run and detect") { feature.detect(row) }
        } message: {
            Text("Detection starts the configured executable and may download packages. Continue only if you trust this server. Lithe will list tools, then stop the probe process.")
        }
    }
}
