import SwiftUI
import LitheAgentConversationModule
import LitheLocalHistoryModule
import LitheGitModule

/// Reuses the existing comparison builder and native diff surface. Each reported
/// excerpt stays separate; it is never presented as a complete session baseline.
struct AgentFileDiffView: View {
    let change: AgentFileChange
    let onOpenFile: (AgentToolDetails.Location) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(change.path).font(LitheTheme.uiFont(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Open file") { onOpenFile(AgentToolDetails.Location(path: change.path)) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            if change.diffs.count > 1 {
                LitheSettingsSelect(selection: $selectedIndex, options: Array(change.diffs.indices), width: 120,
                    accessibilityLabel: String(localized: "Reported change"),
                    title: { "\($0 + 1)/\(change.diffs.count)" }, localizesTitles: false)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Text("Agent-reported changes; excerpts may not include the entire file.")
                .font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.secondaryText).padding(.bottom, 8)
            if change.diffs.indices.contains(selectedIndex) {
                AgentReportedDiffView(diff: change.diffs[selectedIndex])
            }
        }
        .frame(minWidth: 600, idealWidth: 860, minHeight: 360, idealHeight: 560)
        .background(AgentPanelStyle.canvas)
    }
}

private struct AgentReportedDiffView: View {
    let diff: AgentToolDetails.Diff
    /// Family for the excerpt comparison. The Agent activity bar that presents
    /// this sheet is deliberately environment-independent (its presentation tests
    /// host it with only a colour scheme) and the transcript tree has no
    /// `AppModel` in scope, so the Agent excerpt stays on the bundled monospaced
    /// family instead of acquiring a required `AppSettings` environment object.
    /// Threading it here would mean adding a parameter through five view levels.
    var fontFamily: String = EditorFontDefaults.monospacedFamily
    var body: some View {
        VStack(spacing: 0) {
            if diff.isTruncated {
                Text("The Agent diff is too large to display completely. Rollback is unavailable.")
                    .font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.warning).padding(8)
            }
            if withinComparisonBudget {
                DiffPaneView(rows: LocalHistoryDiffBuilder.rows(old: diff.oldText ?? "", current: diff.newText).map(DiffRow.init),
                             fileExtension: (diff.path as NSString).pathExtension, minimumWidth: 600,
                             fontFamily: fontFamily)
            } else {
                Text("This diff has too many lines for comparison. Showing the reported before and after text.")
                    .font(LitheTheme.uiFont(size: 11)).foregroundStyle(LitheTheme.secondaryText).padding(8)
                HStack(alignment: .top) {
                    textColumn("Before", text: diff.oldText ?? "")
                    Divider()
                    textColumn("After", text: diff.newText)
                }
            }
        }
    }

    private var withinComparisonBudget: Bool {
        // Keep adversarial many-line reports out of the synchronous diff builder.
        [diff.oldText ?? "", diff.newText].allSatisfy { $0.split(separator: "\n", maxSplits: 1_000, omittingEmptySubsequences: false).count <= 1_000 }
    }

    private func textColumn(_ title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(LitheTheme.uiFont(size: 12, weight: .semibold))
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: text).font(LitheTheme.uiFont(size: 11, design: .monospaced)).textSelection(.enabled)
            }
            .litheScrollViewChrome()
        }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
