import SwiftUI
import LitheAgentConversationModule

/// What a run of tool calls did, by ACP tool kind: "Ran 2 commands, read 3 files".
enum AgentToolGroupPresentation {
    enum Category: CaseIterable {
        case execute, read, edit, search, fetch, other

        init(kind: String?) {
            switch kind {
            case "execute": self = .execute
            case "read": self = .read
            case "edit", "delete", "move": self = .edit
            case "search": self = .search
            case "fetch": self = .fetch
            default: self = .other
            }
        }

        func format(count: Int) -> String {
            let one = count == 1
            switch self {
            case .execute: return one ? "Ran %lld command" : "Ran %lld commands"
            case .read: return one ? "Read %lld file" : "Read %lld files"
            case .edit: return one ? "Edited %lld file" : "Edited %lld files"
            case .search: return one ? "Searched %lld time" : "Searched %lld times"
            case .fetch: return one ? "Fetched %lld page" : "Fetched %lld pages"
            case .other: return one ? "Used %lld tool" : "Used %lld tools"
            }
        }

        var systemImage: String {
            switch self {
            case .execute: "terminal"
            case .read: "doc.text"
            case .edit: "pencil"
            case .search: "magnifyingglass"
            case .fetch: "globe"
            case .other: "wrench.and.screwdriver"
            }
        }
    }

    static func summary(_ messages: [AgentConversationMessage], locale: Locale) -> String {
        let counts = Dictionary(grouping: messages) { Category(kind: $0.toolDetails.kind) }.mapValues(\.count)
        let parts = Category.allCases.compactMap { category in
            counts[category].map { count in
                String(format: AgentLocalization.string(String.LocalizationValue(category.format(count: count)), locale: locale), count)
            }
        }
        return parts.dropFirst().reduce(parts.first ?? "") {
            String(format: AgentLocalization.string("%@, %@", locale: locale), $0, $1)
        }
    }
}

/// Tool calls between two replies: a quiet one-line summary that expands into
/// a rounded list, one row per call, each row opening its evidence. Rows are
/// plain stacks; a nested scroll view per group made transcript scrolling stutter.
struct AgentToolGroupView: View {
    @Environment(\.locale) private var locale
    let messages: [AgentConversationMessage]
    let searchText: String
    let onOpenFile: (AgentToolDetails.Location) -> Void
    var initiallyExpanded = false
    /// Activity panels already have a tab label and an outer shared surface.
    var embedded = false

    /// Long runs show their first rows until the user asks for the rest.
    static let collapsedRowLimit = 8

    @State private var expanded = false
    @State private var showsAllRows = false
    @State private var expandedToolID: String?

    private var failedCount: Int { messages.filter { $0.toolStatus == .failed }.count }
    private var isRunning: Bool { messages.contains { $0.toolStatus == .inProgress || $0.toolStatus == .pending } }
    private var hasExpandedDetails: Bool {
        messages.contains { $0.id == expandedToolID && !$0.toolDetails.isEmpty }
    }
    private var displayedMessages: [AgentConversationMessage] {
        searchText.isEmpty ? messages : messages.filter { AgentTranscriptItem.toolMatches($0, searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if embedded {
                // Activity popups keep a bounded viewport of four rows.
                ScrollView(.vertical) { rows(displayedMessages) }
                    .litheScrollViewChrome()
                    .frame(height: CGFloat(min(displayedMessages.count, 4)) * 35 + (hasExpandedDetails ? 168 : 8))
            } else {
                header
                if expanded {
                    rows(showsAllRows || !searchText.isEmpty
                         ? displayedMessages : Array(displayedMessages.prefix(Self.collapsedRowLimit)))
                        .background(LitheTheme.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(failedCount > 0 ? LitheTheme.error.opacity(0.5) : LitheTheme.panelBorder, lineWidth: 1))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if initiallyExpanded || !searchText.isEmpty { expanded = true } }
        .onChange(of: searchText) { _ in if !searchText.isEmpty { expanded = true } }
    }

    private var header: some View {
        let summary = AgentToolGroupPresentation.summary(messages, locale: locale)
        return Button { expanded.toggle() } label: {
            HStack(spacing: 5) {
                if isRunning { ProgressView().controlSize(.mini) }
                Text(verbatim: summary).lineLimit(1)
                if failedCount > 0 {
                    Text(verbatim: "·").foregroundStyle(LitheTheme.tertiaryText)
                    Text("\(failedCount) failed").foregroundStyle(LitheTheme.error)
                }
                Image(systemName: "chevron.down")
                    .font(LitheTheme.uiFont(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .font(LitheTheme.uiFont(size: 12.5))
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .lithePointer()
        .help(expanded ? "Hide tool details" : "Show tool details")
        .accessibilityLabel(Text(verbatim: summary))
        .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
        .accessibilityIdentifier("agent-tool-group-header")
    }

    private func rows(_ shown: [AgentConversationMessage]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, message in
                if index > 0 { Divider().overlay(LitheTheme.panelBorder) }
                toolRow(message)
            }
            if !embedded && !showsAllRows && searchText.isEmpty && displayedMessages.count > shown.count {
                Divider().overlay(LitheTheme.panelBorder)
                Button { showsAllRows = true } label: {
                    Text(String(format: AgentLocalization.string("Show %lld more", locale: locale),
                                displayedMessages.count - shown.count))
                        .font(LitheTheme.uiFont(size: 12))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .lithePointer()
            }
        }
    }

    private func toolRow(_ message: AgentConversationMessage) -> some View {
        let isExpanded = expandedToolID == message.id
        let hasDetails = !message.toolDetails.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if hasDetails { expandedToolID = isExpanded ? nil : message.id }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: AgentToolGroupPresentation.Category(kind: message.toolDetails.kind).systemImage)
                        .font(LitheTheme.uiFont(size: 11))
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .frame(width: 14)
                    Text(message.text)
                        .font(LitheTheme.uiFont(size: 12.5))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    status(message.toolStatus)
                    if hasDetails {
                        Image(systemName: "chevron.right")
                            .font(LitheTheme.uiFont(size: 9, weight: .semibold))
                            .foregroundStyle(LitheTheme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .litheRowHover()
            .help(message.text)
            .accessibilityValue(statusLabel(for: message.toolStatus))

            if isExpanded && hasDetails {
                AgentToolEvidenceView(details: message.toolDetails, onOpenFile: onOpenFile)
                    .padding(.leading, 34)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func status(_ status: AgentConversationMessage.ToolStatus?) -> some View {
        switch status {
        case .failed:
            Image(systemName: "exclamationmark.circle").foregroundStyle(LitheTheme.error)
                .font(LitheTheme.uiFont(size: 11))
        case .interrupted:
            Image(systemName: "pause.circle").foregroundStyle(LitheTheme.warning)
                .font(LitheTheme.uiFont(size: 11))
        case .inProgress, .pending:
            ProgressView().controlSize(.mini)
        case .completed, nil:
            EmptyView()
        }
    }

    private func statusLabel(for status: AgentConversationMessage.ToolStatus?) -> String {
        switch status {
        case .completed: AgentLocalization.string("Completed", locale: locale)
        case .failed: AgentLocalization.string("Failed", locale: locale)
        case .interrupted: AgentLocalization.string("Interrupted", locale: locale)
        case .inProgress: AgentLocalization.string("Running", locale: locale)
        case .pending, nil: AgentLocalization.string("Pending", locale: locale)
        }
    }
}
