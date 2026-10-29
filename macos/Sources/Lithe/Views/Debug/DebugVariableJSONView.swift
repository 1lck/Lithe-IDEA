import AppKit
import SwiftUI
import LitheCoreContracts
import LitheDebugModule

/// A selectable read-only snapshot; the existing inspector owns scrolling and Watches.
struct DebugVariableJSONView: View {
    @ObservedObject var feature: GenericDebugFeatureModel
    @State private var text = ""
    @State private var loading = false
    @State private var collapsedLines: Set<Int> = []
    @State private var folding = DebugJSONFolding("")
    @State private var requestID = UUID()
    @Environment(\.colorScheme) private var scheme

    private struct Identity: Equatable {
        let session: DebugSessionID?
        let frame: Int?
        let scope: Int?
        let state: DebugAdapterState
        let roots: [DebugVariable]
        /// A step is in flight or its variables are still being swapped in.
        let isStepping: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // With a snapshot already on screen a refresh happens behind it, so the spinner
            // only covers the first load.
            if loading && text.isEmpty {
                ProgressView("Loading object fields…").controlSize(.small)
                    .font(LitheTheme.uiFont(size: 13))
            }
            if !text.isEmpty {
                // The copy button floats over the first line instead of taking a row of its own,
                // which left a blank band above the JSON; the lines reserve its width on the right.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(folding.visibleLines(collapsed: collapsedLines)) { line in
                        DebugJSONLineView(line: line, isCollapsed: collapsedLines.contains(line.id)) {
                            if !collapsedLines.insert(line.id).inserted { collapsedLines.remove(line.id) }
                        }
                    }
                }
                .padding(.trailing, LitheTheme.Metrics.toolbarIconButtonSize + 4)
                .id(scheme)
                .overlay(alignment: .topTrailing) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        LitheIDEAIcon(resourcePath: "expui/general/copy.svg", size: 16, preservesOriginalColors: true)
                    }
                    .litheToolbarIconButton()
                    .help("Copy JSON")
                    .accessibilityLabel("Copy JSON")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .task(id: Identity(session: feature.activeSessionID, frame: feature.selectedFrameID,
                           scope: feature.selectedScopeID, state: feature.state, roots: feature.presentedVariables,
                           isStepping: feature.isInspectionStale || feature.isRefreshingVariables)) {
            let id = UUID()
            requestID = id
            // Stepping keeps the previous snapshot readable until the next stop has been
            // loaded; the task runs again once the variables settle.
            if feature.isInspectionStale || feature.isRefreshingVariables { return }
            if feature.state != .paused {
                text = ""
                collapsedLines = []
                folding = DebugJSONFolding("")
            }
            loading = feature.state == .paused
            defer { if requestID == id { loading = false } }
            guard feature.state == .paused else { return }
            do {
                let snapshot = try await feature.variableJSONSnapshot()
                guard !Task.isCancelled, requestID == id else { return }
                let refreshed = DebugJSONFolding(snapshot)
                // Blocks the user folded stay folded as long as they still exist.
                collapsedLines.formIntersection(refreshed.foldableLines)
                text = snapshot
                folding = refreshed
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, requestID == id else { return }
                text = error.localizedDescription
                folding = DebugJSONFolding(text)
            }
        }
    }
}


/// Hover is confined to one full-width line; the gutter slot never changes size.
private struct DebugJSONLineView: View {
    let line: DebugJSONFolding.Line
    let isCollapsed: Bool
    let onToggle: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.isLithePaneResizing) private var isResizing

    private var showsToggle: Bool { !isResizing && (isHovered || isFocused) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if line.isFoldable {
                Button(action: onToggle) {
                    LitheIDEAIcon(resourcePath: isCollapsed
                        ? "expui/general/chevronRight.svg" : "expui/general/chevronDown.svg",
                        size: 16, preservesOriginalColors: true)
                }
                .buttonStyle(LitheIconButtonStyle(size: LitheTheme.Tree.iconSize))
                .focused($isFocused)
                .help(Text(LocalizedStringKey(isCollapsed ? "Expand JSON block" : "Collapse JSON block")))
                .accessibilityLabel(Text(LocalizedStringKey(isCollapsed ? "Expand JSON block" : "Collapse JSON block")))
                .accessibilityIdentifier("debug-json-fold-\(line.id)")
                .opacity(showsToggle ? 1 : 0)
                .allowsHitTesting(showsToggle)
                .accessibilityHidden(false)
            } else {
                Color.clear.frame(width: LitheTheme.Tree.iconSize, height: 1)
            }
            Text(DebugJSONSyntax.styled(line.text))
                .font(LitheTheme.uiFont(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if line.isFoldable && isHovered != hovering { isHovered = hovering }
        }
        .onDisappear { isHovered = false }
    }
}

/// Fold offsets are local to one immutable snapshot; the original JSON stays available for copying.
struct DebugJSONFolding {
    struct Line: Identifiable, Equatable {
        let id: Int
        let text: String
        let isFoldable: Bool
    }
    private let lines: [String]
    private let ends: [Int: Int]

    init(_ text: String) {
        lines = text.components(separatedBy: "\n")
        var stack: [(line: Int, closer: Character)] = []
        var ranges: [Int: Int] = [:]
        // ponytail: only JSONEncoder.prettyPrinted snapshots, not arbitrary JSON; use editor fold ranges if that scope expands.
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let last = trimmed.last, last == "{" || last == "[" {
                stack.append((index, last == "{" ? "}" : "]"))
            } else if let first = trimmed.first, first == "}" || first == "]",
                      let opening = stack.last, opening.closer == first {
                stack.removeLast()
                ranges[opening.line] = index
            }
        }
        ends = ranges
    }

    /// Lines that open a block and can therefore be folded.
    var foldableLines: Set<Int> { Set(ends.keys) }

    func visibleLines(collapsed: Set<Int>) -> [Line] {
        var result: [Line] = []
        var index = 0
        while index < lines.count {
            if let end = ends[index], collapsed.contains(index) {
                result.append(Line(id: index,
                    text: lines[index] + " … " + lines[end].trimmingCharacters(in: .whitespaces), isFoldable: true))
                index = end + 1
            } else {
                result.append(Line(id: index, text: lines[index], isFoldable: ends[index] != nil))
                index += 1
            }
        }
        return result
    }
}
