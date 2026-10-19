import SwiftUI
import LitheAgentConversationModule

/// Totals are shown only when every visible file has complete upstream evidence.
/// Unknown, pending and overflowing reports must not become partial line counts.
enum AgentActivitySummaryPresentation {
    struct LineTotals: Equatable {
        var additions = 0
        var deletions = 0
    }

    static func lineTotals(_ files: [AgentFileChange]) -> LineTotals? {
        guard !files.isEmpty else { return nil }
        var totals = LineTotals()
        for file in files {
            guard !file.isPending, !file.hasMissingDiff,
                  let additions = file.additions, let deletions = file.deletions else { return nil }
            let added = totals.additions.addingReportingOverflow(additions)
            let removed = totals.deletions.addingReportingOverflow(deletions)
            guard !added.overflow, !removed.overflow else { return nil }
            totals.additions = added.partialValue
            totals.deletions = removed.partialValue
        }
        return totals
    }
}

/// Conversation-local summaries. Shared dropdown panels still own presentation,
/// outside-click dismissal and keyboard handling for the existing detail views.
struct AgentActivitySummaryBar: View {
    @Environment(\.locale) private var locale
    enum Panel: String, CaseIterable {
        case tasks, subagents, edits
        var title: String {
            switch self { case .tasks: "Tasks"; case .subagents: "Subagents"; case .edits: "Edits" }
        }
        var fallbackIcon: String {
            switch self { case .tasks: "checklist"; case .subagents: "arrow.triangle.2.circlepath"; case .edits: "pencil" }
        }
        var icon: String {
            switch self { case .tasks: "expui/build/taskGroup.svg"; case .subagents: "expui/general/refresh.svg"; case .edits: "expui/general/edit.svg" }
        }
    }

    let messages: [AgentConversationMessage]
    let sessionID: String?
    let plan: AgentPlan?
    let subagents: [AgentSubagent]
    let isResponding: Bool
    let isReviewing: Bool
    let reviewError: String?
    let onOpenFile: (AgentToolDetails.Location) -> Void
    let onKeep: ([AgentFileChange]) -> Void
    let onRestore: ([AgentFileChange]) async -> Void
    private let activity: AgentActivity
    private let lineTotals: AgentActivitySummaryPresentation.LineTotals?
    @State private var panel: Panel?
    @State private var selectedDiff: AgentFileChange?
    @State private var confirmation: [AgentFileChange]?
    @State private var restoration: Restoration?

    private struct Restoration {
        let id = UUID()
        let changes: [AgentFileChange]
    }

    init(messages: [AgentConversationMessage], sessionID: String? = nil, plan: AgentPlan? = nil,
         subagents: [AgentSubagent] = [], reviewed: [String: AgentFileChange] = [:],
         isResponding: Bool = false, isReviewing: Bool = false, reviewError: String? = nil,
         onOpenFile: @escaping (AgentToolDetails.Location) -> Void = { _ in },
         onKeep: @escaping ([AgentFileChange]) -> Void = { _ in },
         onRestore: @escaping ([AgentFileChange]) async -> Void = { _ in }) {
        self.messages = messages
        self.sessionID = sessionID
        self.plan = plan
        self.subagents = subagents
        self.isResponding = isResponding
        self.isReviewing = isReviewing
        self.reviewError = reviewError
        self.onOpenFile = onOpenFile
        self.onKeep = onKeep
        self.onRestore = onRestore
        let activity = AgentActivity(messages: messages, reviewed: reviewed)
        self.activity = activity
        self.lineTotals = AgentActivitySummaryPresentation.lineTotals(activity.files)
    }

    private var showsTasks: Bool { plan?.entries.isEmpty == false }
    private var showsSubagents: Bool { !subagents.isEmpty }
    private var showsProgress: Bool { showsTasks || showsSubagents }
    private var showsEdits: Bool { !activity.files.isEmpty || isReviewing || reviewError != nil }
    private var availablePanels: [Panel] {
        (showsTasks ? [.tasks] : []) + (showsSubagents ? [.subagents] : []) + (showsEdits ? [.edits] : [])
    }

    /// Known row geometry also feeds the production composer minimum. No measured
    /// popup or transcript height is published back into the conversation model.
    var contentHeight: CGFloat {
        guard showsProgress || showsEdits else { return 0 }
        return CGFloat((showsProgress ? 1 : 0) + (showsEdits ? 1 : 0)) * AgentComposerMetrics.activityRowHeight
            + (showsProgress && showsEdits ? 1 : 0) + 2 * AgentComposerMetrics.activityVerticalInset
    }

    var composerHeight: CGFloat { contentHeight == 0 ? 0 : contentHeight + AgentComposerMetrics.activitySpacing }

    var body: some View {
        Group {
            if contentHeight > 0 {
                VStack(spacing: 0) {
                    if showsProgress { progressRow }
                    if showsProgress && showsEdits { Divider().overlay(AgentPanelStyle.border) }
                    if showsEdits { editsRow }
                }
                .padding(.vertical, AgentComposerMetrics.activityVerticalInset)
                .frame(height: contentHeight)
                .background(AgentPanelStyle.header, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(AgentPanelStyle.border, lineWidth: 1).allowsHitTesting(false))
                .litheDropdown(isPresented: Binding(get: { panel != nil }, set: { if !$0 { panel = nil } }), opensUpward: true) {
                    if let panel {
                        AgentActivityDetailsView(panel: panel, activity: activity, plan: plan, subagents: subagents, messages: messages,
                            width: LitheDropdownMetrics.maximumWidth,
                            isResponding: isResponding, isReviewing: isReviewing, reviewError: reviewError,
                            onOpenFile: onOpenFile, onDiff: { change in self.panel = nil; selectedDiff = change },
                            onKeep: onKeep, onRequestRestore: { changes in self.panel = nil; confirmation = changes })
                    }
                }
            }
        }
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
        }
        .onChange(of: availablePanels) { panels in
            if let panel, !panels.contains(panel) { self.panel = nil }
        }
        .onChange(of: sessionID) { _ in
            panel = nil
            selectedDiff = nil
            confirmation = nil
        }
    }

    private var progressRow: some View {
        HStack(spacing: 0) {
            if let plan, showsTasks { taskRow(plan) }
            else { Spacer(minLength: 0) }
            if showsSubagents {
                Button { toggle(.subagents) } label: {
                    HStack(spacing: 5) {
                        icon(.subagents)
                        Text("Subagents").lineLimit(1)
                        Text(verbatim: String(subagents.count)).monospacedDigit()
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .frame(minHeight: AgentComposerMetrics.activityRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .litheRowHover()
                .accessibilityIdentifier("agent-activity-subagents")
                .accessibilityValue(count(.subagents))
                .help(AgentLocalization.string("Subagents", locale: locale) + " " + count(.subagents))
                .layoutPriority(1)
            }
        }
        .font(LitheTheme.uiFont(size: 11))
        .foregroundStyle(AgentPanelStyle.secondary)
    }

    private func taskRow(_ plan: AgentPlan) -> some View {
        let title = plan.isComplete ? AgentLocalization.string("All tasks completed", locale: locale)
            : String(format: AgentLocalization.string("Current: %@", locale: locale), plan.currentEntry?.content ?? "")
        return Button { toggle(.tasks) } label: {
            HStack(spacing: 6) {
                icon(.tasks)
                Text(verbatim: count(.tasks)).monospacedDigit().fixedSize()
                Text(verbatim: title).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                disclosure
            }
            .padding(.horizontal, 8)
            .frame(minHeight: AgentComposerMetrics.activityRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .litheRowHover()
        .accessibilityLabel(Text(verbatim: AgentLocalization.string("Tasks", locale: locale) + " · " + title))
        .accessibilityValue(count(.tasks))
        .accessibilityIdentifier("agent-activity-tasks")
        .help(title)
    }

    private var editsRow: some View {
        Button { toggle(.edits) } label: {
            HStack(spacing: 6) {
                icon(.edits)
                Text(verbatim: activity.files.isEmpty ? AgentLocalization.string("Review changes", locale: locale)
                     : String(format: AgentLocalization.string("Modified files: %lld", locale: locale), Int64(activity.files.count)))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let lineTotals {
                    Text(verbatim: "+\(lineTotals.additions)").foregroundStyle(LitheTheme.success).monospacedDigit().fixedSize()
                    Text(verbatim: "−\(lineTotals.deletions)").foregroundStyle(LitheTheme.error).monospacedDigit().fixedSize()
                }
                disclosure
            }
            .padding(.horizontal, 8)
            .frame(minHeight: AgentComposerMetrics.activityRowHeight)
            .contentShape(Rectangle())
        }
        .font(LitheTheme.uiFont(size: 11))
        .foregroundStyle(reviewError == nil ? AgentPanelStyle.secondary : LitheTheme.error)
        .buttonStyle(.litheNoPress)
        .litheRowHover()
        .accessibilityLabel(Text("Edits"))
        .accessibilityValue(count(.edits))
        .accessibilityIdentifier("agent-activity-edits")
    }

    private func icon(_ item: Panel) -> some View {
        LitheIDEAIcon(resourcePath: item.icon, size: LitheTheme.Metrics.toolbarIconSize,
                      fallbackSystemImage: item.fallbackIcon, preservesOriginalColors: true)
    }

    private var disclosure: some View {
        LitheIDEAIcon(resourcePath: "expui/general/chevronDown.svg", size: LitheTheme.Metrics.toolbarIconSize,
                      fallbackSystemImage: "chevron.down", preservesOriginalColors: true)
    }

    private func toggle(_ target: Panel) { panel = panel == target ? nil : target }

    private func count(_ panel: Panel) -> String {
        switch panel {
        case .tasks:
            guard let plan, !plan.entries.isEmpty else { return "0" }
            return "\(plan.completedCount)/\(plan.entries.count)"
        case .subagents:
            return "\(subagents.filter { $0.state == .completed }.count)/\(subagents.count)"
        case .edits: return String(activity.files.count)
        }
    }
}

struct AgentActivityDetailsView: View {
    let panel: AgentActivitySummaryBar.Panel
    let activity: AgentActivity
    let plan: AgentPlan?
    let subagents: [AgentSubagent]
    let messages: [AgentConversationMessage]
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
                } else { emptyState("No tasks yet") }
            case .subagents:
                if subagents.isEmpty { emptyState("No subagents yet") }
                else { AgentSubagentListView(subagents: subagents, messages: messages, onOpenFile: onOpenFile) }
            case .edits: edits
            }
            if let reviewError {
                LitheBanner(status: .error) { Text(reviewError).textSelection(.enabled) }
            }
        }
        .frame(width: width)
        .foregroundStyle(AgentPanelStyle.text)
        .accessibilityIdentifier("agent-activity-content-\(panel.rawValue)")
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
            Button { onDiff(change) } label: { LitheSystemIcon(systemImage: "rectangle.split.2x1", size: LitheTheme.Metrics.toolbarIconSize) }
                .litheToolbarIconButton()
                .disabled(change.diffs.isEmpty)
                .help("Show Agent diff")
                .accessibilityIdentifier("agent-edits-diff-\(change.path)")
            Button { onRequestRestore([change]) } label: { LitheSystemIcon(systemImage: "arrow.uturn.backward", size: LitheTheme.Metrics.toolbarIconSize) }
                .litheToolbarIconButton()
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
