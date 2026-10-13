import SwiftUI
import LitheAgentConversationModule

/// Conversation-local selection. Shared dropdown panels own positioning, outside-click
/// dismissal and keyboard handling, matching the existing Agent selectors.
struct AgentActivitySummaryBar: View {
    enum Panel: String, CaseIterable {
        case tasks, running, edits
        var title: LocalizedStringKey {
            switch self { case .tasks: "Tasks"; case .running: "Running"; case .edits: "Edits" }
        }
        var icon: String {
            switch self { case .tasks: "checklist"; case .running: "arrow.triangle.2.circlepath"; case .edits: "pencil" }
        }
    }

    let messages: [AgentConversationMessage]
    var plan: AgentPlan?
    var reviewed: [String: AgentFileChange] = [:]
    var isResponding = false
    var isReviewing = false
    var reviewError: String?
    var onOpenFile: (AgentToolDetails.Location) -> Void = { _ in }
    var onKeep: ([AgentFileChange]) -> Void = { _ in }
    var onRestore: ([AgentFileChange]) async -> Void = { _ in }
    @State private var panel: Panel?
    @State private var selectedDiff: AgentFileChange?
    @State private var confirmation: [AgentFileChange]?
    @State private var restoration: Restoration?

    private struct Restoration {
        let id = UUID()
        let changes: [AgentFileChange]
    }

    private var activity: AgentActivity { AgentActivity(messages: messages, reviewed: reviewed) }

    var body: some View {
        GeometryReader { geometry in
            tabs
                .litheDropdown(isPresented: Binding(get: { panel != nil }, set: { if !$0 { panel = nil } }), opensUpward: true) {
                    if let panel {
                        AgentActivityDetailsView(panel: panel, activity: activity, plan: plan, width: geometry.size.width,
                            isResponding: isResponding, isReviewing: isReviewing, reviewError: reviewError,
                            onOpenFile: onOpenFile, onDiff: { change in self.panel = nil; selectedDiff = change },
                            onKeep: onKeep, onRequestRestore: { changes in
                                self.panel = nil
                                confirmation = changes
                            })
                    }
                }
        }
        .frame(height: 32)
        .sheet(item: $selectedDiff) { change in
            AgentFileDiffView(change: change, onOpenFile: onOpenFile)
        }
        .alert("Roll back Agent changes?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            Button("Cancel", role: .cancel) { confirmation = nil }
            Button("Roll back", role: .destructive) {
                if let confirmation { restoration = Restoration(changes: confirmation) }
                confirmation = nil
            }
        } message: {
            Text("Only the reported Agent edits will be reversed. Conflicting changes and unsaved editor changes will be preserved.")
        }
        .task(id: restoration?.id) {
            guard let restoration else { return }
            await onRestore(restoration.changes)
            self.restoration = nil
            panel = .edits
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Panel.allCases, id: \.self) { item in
                if item != .tasks { Divider().frame(height: 14).overlay(AgentPanelStyle.border) }
                Button { panel = panel == item ? nil : item } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon).font(LitheTheme.uiFont(size: 11))
                        Text(item.title)
                        badge(item)
                    }
                    .foregroundStyle(panel == item ? AgentPanelStyle.text : AgentPanelStyle.secondary)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .background(panel == item ? AgentPanelStyle.context : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .litheRowHover()
                .accessibilityIdentifier("agent-activity-\(item.rawValue)")
                .accessibilityValue(count(item))
                .accessibilityAddTraits(panel == item ? .isSelected : [])
                .help(item.title)
            }
        }
        .font(LitheTheme.uiFont(size: 11))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(height: 32)
        .background(AgentPanelStyle.canvas, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(AgentPanelStyle.border, lineWidth: 1))
    }

    private func count(_ panel: Panel) -> String {
        switch panel {
        case .tasks:
            if let plan { return "\(plan.completedCount)/\(plan.entries.count)" }
            return String(activity.tools.count)
        case .running: return String(activity.running.count)
        case .edits: return String(activity.files.count)
        }
    }

    @ViewBuilder private func badge(_ item: Panel) -> some View {
        let count = count(item)
        if count != "0" {
            Text(count).font(LitheTheme.uiFont(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(item == .running && !activity.running.isEmpty ? LitheTheme.accent : AgentPanelStyle.text)
        }
    }
}

struct AgentActivityDetailsView: View {
    let panel: AgentActivitySummaryBar.Panel
    let activity: AgentActivity
    let plan: AgentPlan?
    let width: CGFloat
    let isResponding: Bool
    let isReviewing: Bool
    let reviewError: String?
    let onOpenFile: (AgentToolDetails.Location) -> Void
    let onDiff: (AgentFileChange) -> Void
    let onKeep: ([AgentFileChange]) -> Void
    let onRequestRestore: ([AgentFileChange]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch panel {
            case .tasks:
                if let plan, !plan.entries.isEmpty {
                    AgentPlanView(plan: plan, isResponding: isResponding, embedded: true)
                } else { tools(activity.tools, empty: "No tasks yet") }
            case .running: tools(activity.running, empty: "No tools running")
            case .edits: edits
            }
            if let reviewError {
                Text(reviewError).font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.error).textSelection(.enabled)
                    .padding(8)
            }
        }
        .frame(width: width)
        .foregroundStyle(AgentPanelStyle.text)
        .accessibilityIdentifier("agent-activity-content-\(panel.rawValue)")
    }

    @ViewBuilder private func tools(_ tools: [AgentConversationMessage], empty: LocalizedStringKey) -> some View {
        if tools.isEmpty { emptyState(empty) }
        else { AgentToolGroupView(messages: tools, searchText: "", onOpenFile: onOpenFile, embedded: true) }
    }

    private var edits: some View {
        VStack(alignment: .leading, spacing: 0) {
            if activity.files.isEmpty { emptyState("No file edits") }
            else {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Roll back all", role: .destructive) { onRequestRestore(activity.files) }
                        .disabled(isResponding || isReviewing || !activity.files.allSatisfy(\.canRevert))
                        .accessibilityIdentifier("agent-edits-revert-all")
                    Button("Keep all") { onKeep(activity.files) }
                        .disabled(isResponding || isReviewing || activity.files.contains(where: \.isPending))
                        .help("The Agent already saved these files. Mark the current changes as reviewed.")
                        .accessibilityIdentifier("agent-edits-keep-all")
                }
                .font(LitheTheme.uiFont(size: 11))
                .padding(8)
                .background(AgentPanelStyle.context)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(activity.files) { change in fileRow(change) }
                    }
                    .padding(4)
                }
                .litheScrollViewChrome()
                .frame(height: min(220, CGFloat(activity.files.count) * 34 + 6))
                if isReviewing { ProgressView().controlSize(.small).padding(8) }
            }
        }
    }

    private func fileRow(_ change: AgentFileChange) -> some View {
        HStack(spacing: 6) {
            Image(systemName: change.isDeletion ? "doc.badge.minus" : "doc.text")
                .foregroundStyle(change.isDeletion ? LitheTheme.error : LitheTheme.accent)
            Button { onOpenFile(AgentToolDetails.Location(path: change.path)) } label: {
                Text((change.path as NSString).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .help(change.path)
            .accessibilityIdentifier("agent-edits-open-\(change.path)")
            if let additions = change.additions, additions > 0 {
                Text("+\(additions)").foregroundStyle(LitheTheme.success)
            }
            if let deletions = change.deletions, deletions > 0 {
                Text("-\(deletions)").foregroundStyle(LitheTheme.error)
            }
            Button { onDiff(change) } label: { Image(systemName: "rectangle.split.2x1") }
                .buttonStyle(.litheNoPress)
                .disabled(change.diffs.isEmpty)
                .help("Show Agent diff")
                .accessibilityIdentifier("agent-edits-diff-\(change.path)")
            Button { onRequestRestore([change]) } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.litheNoPress)
                .disabled(isResponding || isReviewing || !change.canRevert)
                .help(change.canRevert ? "Roll back Agent changes" : "Original content is missing or incomplete.")
                .accessibilityIdentifier("agent-edits-revert-\(change.path)")
        }
        .font(LitheTheme.uiFont(size: 11))
        .padding(.horizontal, 4)
        .frame(height: 32)
        .litheRowHover()
    }

    private func emptyState(_ text: LocalizedStringKey) -> some View {
        Text(text).font(LitheTheme.uiFont(size: 11.5)).foregroundStyle(AgentPanelStyle.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(16)
    }
}
