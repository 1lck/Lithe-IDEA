import SwiftUI
import LitheAgentConversationModule

/// Fixed chrome stays compact; only the measured writing area grows with the draft.
enum AgentComposerMetrics {
    static let activityRowHeight = LitheDropdownMetrics.rowHeight
    static let activityVerticalInset: CGFloat = 2
    static let activitySpacing: CGFloat = 4
    static let toolbarHeight: CGFloat = 30
    static let fileHeight: CGFloat = 34
    // Product targets include text padding; long drafts scroll after reaching the cap.
    static let minimumWritingLines = 2
    static let writingLineHeight: CGFloat = 18
    static let writingVerticalInset: CGFloat = 7
    static let minimumWritingHeight = writingLineHeight * CGFloat(minimumWritingLines) + writingVerticalInset * 2
    static let maximumWritingHeight: CGFloat = 240
    static let inputMinimumHeight = minimumWritingHeight + toolbarHeight - 2
    static let bottomInset: CGFloat = 8
    static let horizontalInset: CGFloat = 8
    static let toolbarHorizontalInset: CGFloat = 5
    static let splitTopInset: CGFloat = 10

    static func minimumHeight(hasFiles: Bool) -> CGFloat {
        inputMinimumHeight + bottomInset + splitTopInset + (hasFiles ? fileHeight : 0)
    }
}

struct AgentComposerMinimumHeightKey: PreferenceKey {
    static let defaultValue = AgentComposerMetrics.minimumHeight(hasFiles: false)
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct AgentComposerWritingHeightKey: PreferenceKey {
    static let defaultValue = AgentComposerMetrics.minimumWritingHeight
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct AgentComposerMaximumWritingHeightKey: EnvironmentKey {
    static let defaultValue = AgentComposerMetrics.maximumWritingHeight
}

extension EnvironmentValues {
    var agentComposerMaximumWritingHeight: CGFloat {
        get { self[AgentComposerMaximumWritingHeightKey.self] }
        set { self[AgentComposerMaximumWritingHeightKey.self] = newValue }
    }
}

/// The production composer layout, also hosted in native regression tests.
struct AgentComposerContent<Editor: View, Toolbar: View>: View {
    @Environment(\.agentComposerMaximumWritingHeight) private var maximumWritingHeight
    @State private var writingHeight = AgentComposerMetrics.minimumWritingHeight
    let files: [AgentFileReference]
    let commands: [AgentCommand]?
    let highlightedIndex: Int
    let onSelect: (AgentCommand) -> Void
    let onRemoveFile: (String) -> Void
    let onFocus: () -> Void
    var isFocused = false
    @ViewBuilder let editor: () -> Editor
    @ViewBuilder let toolbar: () -> Toolbar

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if !files.isEmpty { AgentFileReferenceList(files: files, onRemove: onRemoveFile) }
                AgentComposerDraftArea(commands: commands, highlightedIndex: highlightedIndex, onSelect: onSelect) {
                    ScrollView {
                        editor()
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: AgentComposerWritingHeightKey.self, value: geometry.size.height)
                            })
                    }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .frame(height: min(maximumWritingHeight, max(AgentComposerMetrics.minimumWritingHeight, writingHeight)))
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onFocus)
                        .litheTextEditingCursor()
                }
                toolbar()
            }
            .litheSettingsControlChrome(
                background: LitheTheme.editor,
                border: isFocused ? LitheTheme.settingsControlAccent : LitheTheme.settingsControlBorder,
                lineWidth: isFocused ? 2 : 1,
                borderOutset: isFocused ? 1 : 0
            )
        }
        .onPreferenceChange(AgentComposerWritingHeightKey.self) { height in
            if abs(height - writingHeight) > 0.5 { writingHeight = height }
        }
        .preference(key: AgentComposerMinimumHeightKey.self, value: AgentComposerMetrics.minimumHeight(hasFiles: !files.isEmpty))
    }
}
