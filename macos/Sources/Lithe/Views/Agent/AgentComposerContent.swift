import SwiftUI
import LitheAgentConversationModule

/// Fixed strips and the flexible editor use the same sizes when computing the
/// split minimum. Commands never increase that minimum; attachments do.
enum AgentComposerMetrics {
    static let contextHeight: CGFloat = 30
    static let toolbarHeight: CGFloat = 38
    static let fileHeight: CGFloat = 34
    static let writingLineHeight: CGFloat = 36
    static let bottomInset: CGFloat = 8
    static let splitTopInset: CGFloat = 10

    static func minimumHeight(hasFiles: Bool) -> CGFloat {
        contextHeight + toolbarHeight + writingLineHeight + bottomInset + splitTopInset + (hasFiles ? fileHeight : 0)
    }
}

struct AgentComposerMinimumHeightKey: PreferenceKey {
    static let defaultValue = AgentComposerMetrics.minimumHeight(hasFiles: false)
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The production composer layout, also hosted in native regression tests.
struct AgentComposerContent<Context: View, Editor: View, Toolbar: View>: View {
    let files: [AgentFileReference]
    let commands: [AgentCommand]?
    let highlightedIndex: Int
    let onSelect: (AgentCommand) -> Void
    let onRemoveFile: (String) -> Void
    let onFocus: () -> Void
    @ViewBuilder let context: () -> Context
    @ViewBuilder let editor: () -> Editor
    @ViewBuilder let toolbar: () -> Toolbar

    var body: some View {
        VStack(spacing: 0) {
            context()
            if !files.isEmpty { AgentFileReferenceList(files: files, onRemove: onRemoveFile) }
            AgentComposerDraftArea(commands: commands, highlightedIndex: highlightedIndex, onSelect: onSelect) {
                ScrollView { editor() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onFocus)
            }
            toolbar()
        }
        .preference(key: AgentComposerMinimumHeightKey.self, value: AgentComposerMetrics.minimumHeight(hasFiles: !files.isEmpty))
    }
}
