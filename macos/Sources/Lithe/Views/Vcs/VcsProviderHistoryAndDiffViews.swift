import LitheModuleAPI
import LitheCoreContracts
import LitheGitModule // DiffRow, the shared diff row model
import LitheLocalHistoryModule
import SwiftUI

// Note: 统一 VCS 模型见 .agents/notes/proposed/architecture/2026-10-22-unified-vcs-provider-model.md

/// Revisions of a root, or of one file in it, a page at a time. Each row
/// expands to the full message and the paths the revision changed.
struct VcsHistoryListView: View {
    @ObservedObject var feature: VcsProvidersFeatureModel
    let rootID: String
    /// Root-relative file; nil lists the whole root.
    let path: String?
    @State private var entries: [VcsHistoryEntry] = []
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var failure: String?
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    row(entry)
                    Rectangle().fill(LitheTheme.divider).frame(height: 1)
                }
                if let failure {
                    LitheBanner(status: .error, layout: .editor) {
                        Text(verbatim: failure).lineLimit(6).textSelection(.enabled)
                        Button(L10n.string("Retry")) { Task { await load() } }
                    }
                } else if isLoading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(12)
                } else if nextCursor != nil {
                    Button(L10n.string("Load More")) { Task { await load() } }
                        .buttonStyle(.link)
                        .frame(maxWidth: .infinity)
                        .padding(12)
                } else if entries.isEmpty {
                    Text("No revisions")
                        .font(LitheTheme.uiFont(size: 12))
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(20)
                }
            }
        }
        .litheWorkbenchSurface(LitheTheme.sidebar)
        .task { await load() }
    }

    private func row(_ entry: VcsHistoryEntry) -> some View {
        let isExpanded = expanded.contains(entry.id)
        let firstLine = entry.message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                if isExpanded { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
            } label: {
                HStack(spacing: 6) {
                    LitheIDEAIcon(resourcePath: isExpanded ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg",
                                  size: LitheTheme.Tree.iconSize, preservesOriginalColors: true)
                    Text(verbatim: entry.revision.display)
                        .font(LitheTheme.uiFont(size: 12, weight: .semibold, design: .monospaced))
                    if let author = entry.author {
                        Text(verbatim: author).foregroundStyle(LitheTheme.secondaryText).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let date = entry.date {
                        Text(verbatim: Self.displayDate(date))
                            .font(LitheTheme.uiFont(size: 11))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            Text(verbatim: isExpanded ? entry.message : firstLine)
                .lineLimit(isExpanded ? nil : 1)
                .textSelection(.enabled)
                .padding(.leading, 22)
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entry.changes, id: \.self) { change in
                        HStack(spacing: 6) {
                            Text(verbatim: change.status.letter)
                                .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                                .foregroundStyle(change.status.listColor)
                            Text(verbatim: change.oldPath.map { "\(change.path) ← \($0)" } ?? change.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    if entry.changesTruncated {
                        Text("More paths changed than are shown.")
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                }
                .font(LitheTheme.uiFont(size: 11))
                .padding(.leading, 22)
            }
        }
        .font(LitheTheme.uiFont(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        failure = nil
        defer { isLoading = false }
        do {
            let page = if let path {
                try await feature.fileHistory(path, in: rootID, cursor: nextCursor)
            } else {
                try await feature.history(in: rootID, cursor: nextCursor)
            }
            let known = Set(entries.map(\.id))
            entries += page.entries.filter { !known.contains($0.id) }
            nextCursor = page.nextCursor
        } catch is CancellationError {
        } catch {
            failure = VcsProvidersFeatureModel.message(for: error)
        }
    }

    /// Providers send ISO 8601; anything else is shown as sent.
    static func displayDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date.formatted(date: .abbreviated, time: .shortened) }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date.formatted(date: .abbreviated, time: .shortened) }
        return value
    }
}

/// Presents the diff a window's VCS feature asks for, from its tool window
/// or its project tree.
struct VcsDiffPresentation: ViewModifier {
    let feature: VcsProvidersFeatureModel?
    let fontFamily: String
    let openFile: (URL) -> Void

    func body(content: Content) -> some View {
        if let feature {
            content.modifier(Presenter(feature: feature, fontFamily: fontFamily, openFile: openFile))
        } else {
            content
        }
    }

    private struct Presenter: ViewModifier {
        @ObservedObject var feature: VcsProvidersFeatureModel
        let fontFamily: String
        let openFile: (URL) -> Void

        func body(content: Content) -> some View {
            content.sheet(item: $feature.presentedDiff) { diff in
                VcsFileDiffSheet(diff: diff, fontFamily: fontFamily) {
                    feature.presentedDiff = nil
                    openFile(diff.fileURL)
                }
            }
        }
    }
}

/// A change next to its base revision. Rows are built off the main thread;
/// a very long file is shown as two plain texts instead.
struct VcsFileDiffSheet: View {
    /// Above this many lines in total, the line diff takes too long.
    static let lineLimit = 20_000

    let diff: VcsFileDiff
    let fontFamily: String
    let openFile: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [DiffRow]?
    @State private var isOverLimit = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: diff.path)
                    .font(LitheTheme.uiFont(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(L10n.string("Open File"), action: openFile)
                    .disabled(diff.current == nil && !diff.isBinary && !diff.isTooLarge)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            content
        }
        .frame(minWidth: 640, idealWidth: 960, minHeight: 400, idealHeight: 640)
        .background(LitheTheme.editor)
        .task(id: diff.id) { await buildRows() }
    }

    @ViewBuilder
    private var content: some View {
        if diff.isBinary {
            message(L10n.string("Binary files cannot be compared."))
        } else if diff.isTooLarge {
            message(L10n.string("The file is too large to compare."))
        } else if isOverLimit {
            HStack(alignment: .top, spacing: 0) {
                textColumn(L10n.string("Base revision"), text: diff.base ?? "")
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                textColumn(L10n.string("Local"), text: diff.current ?? "")
            }
        } else if let rows {
            DiffPaneView(rows: rows, fileExtension: (diff.path as NSString).pathExtension,
                         minimumWidth: 600, fontFamily: fontFamily)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func message(_ text: String) -> some View {
        Text(verbatim: text)
            .font(LitheTheme.uiFont(size: 12))
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func textColumn(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(LitheTheme.uiFont(size: 12, weight: .semibold))
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: text)
                    .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .litheScrollViewChrome()
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func buildRows() async {
        guard !diff.isBinary, !diff.isTooLarge else { return }
        let base = diff.base ?? ""
        let current = diff.current ?? ""
        let limit = Self.lineLimit
        let built = await Task.detached(priority: .userInitiated) { () -> [LocalHistoryDiffRow]? in
            let lines = base.utf8.lazy.filter { $0 == 0x0A }.count + current.utf8.lazy.filter { $0 == 0x0A }.count
            guard lines <= limit else { return nil }
            return LocalHistoryDiffBuilder.rows(old: base, current: current)
        }.value
        guard !Task.isCancelled else { return }
        if let built {
            rows = built.map(DiffRow.init)
        } else {
            isOverLimit = true
        }
    }
}
