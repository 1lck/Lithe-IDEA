import AppKit
import SwiftUI
import Testing
@testable import LitheGitModule
@testable import Lithe

/// Re-plans the layout inside `body`, exactly as `RepositoryDiffView.diffContent` does, so every
/// render hands the pane a freshly planned layout.
@MainActor
private final class LayoutIdentityHostModel: ObservableObject {
    @Published var rows: [DiffRow]
    @Published var tick = 0
    private(set) var evaluations = 0

    init(rows: [DiffRow]) { self.rows = rows }

    func recordEvaluation() { evaluations += 1 }
}

private struct LayoutIdentityHost: View {
    @ObservedObject var model: LayoutIdentityHostModel

    var body: some View {
        _ = model.tick
        model.recordEvaluation()
        let display = model.rows.enumerated().map { DiffDisplayRow.row($0.element, index: $0.offset) }
        let kinds = model.rows.map(\.kind)
        let layout = DiffSplitLayout.plan(displayRows: display, kinds: kinds)
        return DiffSplitPaneView(displayRows: display, kinds: kinds, layout: layout,
            fileExtension: "swift", contentWidth: 1_100, viewportWidth: 900, onExpand: { _ in })
    }
}

/// A layout's identity decides whether the native text storage is rebuilt, so it must follow the
/// content: SwiftUI plans a new layout on every render, and rebuilding a whole file's text on each
/// of them froze the main thread when several large diffs were open.
@Suite("Diff layout identity", .serialized)
@MainActor
struct DiffLayoutIdentityTests {
    private func rows(count: Int = 40) -> [DiffRow] {
        (0..<count).map { index in
            DiffRow(oldLine: index + 1, newLine: index + 1,
                left: index % 2 == 0 ? "let value = \(index) // 当前调试传输" : "return \(index)",
                right: nil, kind: .context, sequence: index)
        }
    }

    private func plan(_ rows: [DiffRow], gutterWidth: CGFloat? = nil) -> DiffSplitLayout {
        DiffSplitLayout.plan(
            displayRows: rows.enumerated().map { DiffDisplayRow.row($0.element, index: $0.offset) },
            kinds: rows.map(\.kind), gutterWidth: gutterWidth)
    }

    @Test
    func identityFollowsTheContentOfTheLayout() {
        let base = rows()
        #expect(plan(base).identity == plan(base).identity)
        #expect(DiffUnifiedLayout(rows: base).identity == DiffUnifiedLayout(rows: base).identity)

        // Same row identity, different text: the prepared text must be rebuilt.
        var edited = base
        edited[7] = DiffRow(oldLine: 8, newLine: 8, left: "return 7 // 已修改", right: nil, kind: .context, sequence: 7)
        #expect(plan(edited).identity != plan(base).identity)
        #expect(DiffUnifiedLayout(rows: edited).identity != DiffUnifiedLayout(rows: base).identity)

        var reclassified = base
        reclassified[3] = DiffRow(oldLine: 4, newLine: 4, left: base[3].left, right: "return 3 // new",
            kind: .changed, sequence: 3)
        #expect(plan(reclassified).identity != plan(base).identity)

        #expect(plan(Array(base.dropLast())).identity != plan(base).identity)
        #expect(plan(base, gutterWidth: 40).identity != plan(base, gutterWidth: 48).identity)
    }

    @Test
    func rerenderingUnchangedRowsKeepsThePreparedTextButChangedRowsRebuildIt() async throws {
        let model = LayoutIdentityHostModel(rows: rows())
        let hosting = NSHostingView(rootView: LayoutIdentityHost(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }

        func settle() async {
            hosting.layoutSubtreeIfNeeded()
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
        }
        func revisions() -> [Int] {
            var found: [Int] = []
            func walk(_ view: NSView) {
                if let editor = view as? DiffNativeTextView, let column = editor.column { found.append(column.revision) }
                view.subviews.forEach(walk)
            }
            walk(hosting)
            return found
        }

        await settle()
        let mounted = revisions()
        try #require(mounted.count == 2)
        let evaluationsAfterMount = model.evaluations

        // A render that plans a new layout from identical rows, as any Git model publish causes.
        model.tick += 1
        await settle()
        try #require(model.evaluations > evaluationsAfterMount)
        #expect(revisions() == mounted)

        // Control: really different rows must still rebuild the text.
        let evaluationsBeforeEdit = model.evaluations
        var edited = model.rows
        edited[5] = DiffRow(oldLine: 6, newLine: 6, left: "return 5 // 已修改", right: nil, kind: .context, sequence: 5)
        model.rows = edited
        await settle()
        try #require(model.evaluations > evaluationsBeforeEdit)
        #expect(revisions() == mounted.map { $0 + 1 })
    }
}
