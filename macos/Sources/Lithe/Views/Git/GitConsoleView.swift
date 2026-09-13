import AppKit
import SwiftUI
import LitheGitModule

/// Streaming, disclosure and scrolling state stay in the console, away from the Git page.
struct GitConsoleView: View {
    @ObservedObject var feature: GitFeatureModel
    @State private var wrapsLines = false
    @State private var followsOutput = true
    @State private var searchOpen = false
    @State private var search = ""
    @State private var matchIndex = 0
    @State private var navigation = 0
    @State private var expanded: [String: Set<String>] = [:]
    @State private var expandedGroups: Set<String> = []
    @State private var bundle: Bundle?
    @FocusState private var searchFocused: Bool

    private struct Bundle {
        let entries: [GitConsoleEntry]
        let request: GitConsolePresentationRequest
        let presentation: GitConsolePresentation?
    }
    private var request: GitConsolePresentationRequest {
        GitConsolePresentationRequest(entries: feature.gitConsoleEntries, search: search, repositoryRoots: feature.availableRepositoryRoots)
    }
    private var records: [GitConsoleEntry] { bundle?.entries ?? feature.gitConsoleEntries }
    private var selectedHit: GitConsolePresentation.SearchHit? {
        guard bundle?.request.search == search, let matches = bundle?.presentation?.matches,
              matches.indices.contains(matchIndex) else { return nil }
        return matches[matchIndex]
    }

    var body: some View {
        HStack(spacing: 0) {
            toolbar
            Rectangle().fill(LitheTheme.divider).frame(width: 1)
            VStack(spacing: 0) {
                if searchOpen { searchBar }
                if let bundle, bundle.presentation == nil {
                    Text("Compression is unavailable. Showing complete retained output.")
                        .font(.system(size: 12, weight: .regular, design: .monospaced)).foregroundStyle(LitheTheme.secondaryText)
                }
                contents
            }
        }
        .task(id: request) {
            let captured = request
            let entries = feature.gitConsoleEntries
            let result = await feature.consolePresentation(captured)
            guard !Task.isCancelled else { return }
            bundle = Bundle(entries: entries, request: captured, presentation: result)
            let ids = Set(entries.map { $0.id.uuidString })
            expanded = expanded.filter { ids.contains($0.key) }
            expandedGroups.formIntersection(ids)
            if matchIndex >= (result?.matches.count ?? 0) { matchIndex = 0 }
        }
        .onChange(of: feature.gitRepositoryRoot) { _ in
            bundle = nil; expanded = [:]; expandedGroups = []; matchIndex = 0
        }
        .onChange(of: search) { _ in matchIndex = 0; navigation += 1 }
    }

    private var toolbar: some View {
        VStack(spacing: 3) {
            Button { searchOpen.toggle(); if !searchOpen { search = "" }; searchFocused = searchOpen } label: { Image(systemName: "magnifyingglass") }
                .help("Find in Git console")
            Button { wrapsLines.toggle() } label: { Image(systemName: "text.word.spacing") }
                .foregroundStyle(wrapsLines ? LitheTheme.accent : LitheTheme.secondaryText).help("Use soft wraps")
            Button { followsOutput = true; navigation += 1 } label: { Image(systemName: "arrow.down.to.line") }
                .foregroundStyle(followsOutput ? LitheTheme.accent : LitheTheme.secondaryText).help("Scroll to new Git output")
            Button(action: feature.cancelGitExecutions) { Image(systemName: "stop.fill") }
                .disabled(!feature.isGitExecutionRunning).help("Cancel running Git operations")
            Button {
                feature.clearGitConsole(); bundle = nil; expanded = [:]; expandedGroups = []
            } label: { Image(systemName: "trash") }
                .disabled(feature.gitConsoleEntries.isEmpty).help("Clear Git console")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(records.map(\.copyText).joined(separator: "\n\n"), forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .disabled(records.isEmpty).help("Copy complete console")
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain).litheIconButton()
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(.top, 6).frame(width: 28)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            TextField("Find in Git console", text: $search).textFieldStyle(.plain).focused($searchFocused)
                .onSubmit { moveMatch(1) }
                .onExitCommand { searchOpen = false; search = "" }
                .onChange(of: search) { value in if value.utf8.count > 1024 { search = String(value.prefix(256)) } }
            Text("\((bundle?.presentation?.totalMatches ?? 0) == 0 ? 0 : matchIndex + 1)/\(bundle?.presentation?.totalMatches ?? 0)")
            if let presentation = bundle?.presentation, presentation.totalMatches > presentation.matches.count {
                Text("First \(presentation.matches.count) locations")
            }
            Button { moveMatch(-1) } label: { Image(systemName: "arrow.up") }.help("Previous match")
            Button { moveMatch(1) } label: { Image(systemName: "arrow.down") }.help("Next match")
            Button { searchOpen = false; search = "" } label: { Image(systemName: "xmark") }.help("Close search")
        }
        .font(.system(size: 12, weight: .regular, design: .monospaced)).padding(6)
    }

    private func moveMatch(_ delta: Int) {
        let count = bundle?.presentation?.matches.count ?? 0
        if count > 0 { matchIndex = (matchIndex + delta + count) % count }
        followsOutput = false
        navigation += 1
    }

    private var contents: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(wrapsLines ? .vertical : [.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if feature.gitConsoleHistoryTruncated {
                            Text("Earlier Git commands were truncated to limit memory use.")
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(LitheTheme.secondaryText)
                        }
                        if records.isEmpty {
                            Text("Git command output will appear here.").font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                        rows
                        Color.clear.frame(width: 1, height: 1).id("git-console-bottom")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .frame(minWidth: max(0, geometry.size.width), minHeight: max(0, geometry.size.height), alignment: .topLeading)
                    .background(GitConsoleScrollObserver(find: { searchOpen = true; searchFocused = true }) { isAtEnd in
                        // Only state transitions are published, not every scroll-wheel event.
                        if followsOutput != isAtEnd { followsOutput = isAtEnd }
                    })
                }
                .litheScrollViewChrome()
                .onChange(of: bundle?.request) { _ in
                    if followsOutput { proxy.scrollTo("git-console-bottom", anchor: .bottom) }
                }
                .task(id: SearchNavigation(hit: selectedHit?.anchor, revision: navigation)) {
                    if followsOutput { proxy.scrollTo("git-console-bottom", anchor: .bottom); return }
                    guard let hit = selectedHit else { return }
                    expand(hit)
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(hit.anchor, anchor: .center)
                }
                .onChange(of: selectedHit) { hit in
                    guard let hit else { return }
                    followsOutput = false
                    expand(hit)
                    navigation += 1
                }
            }
        }
    }
    private struct SearchNavigation: Hashable { let hit: String?; let revision: Int }

    private func expand(_ hit: GitConsolePresentation.SearchHit) {
        expanded[hit.recordId, default: []].insert(hit.fragmentId)
        if let group = bundle?.presentation?.groups.first(where: { $0.recordIds.contains(hit.recordId) }) {
            expandedGroups.insert(group.id)
        }
    }

    private var rows: some View {
        let plans = Dictionary(uniqueKeysWithValues: (bundle?.presentation?.entries ?? []).map { ($0.id, $0) })
        let groups = bundle?.presentation?.groups ?? []
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id.uuidString, $0) })
        let groupByRecord = Dictionary(uniqueKeysWithValues: groups.flatMap { group in group.recordIds.map { ($0, group) } })
        return ForEach(records) { entry in
            let id = entry.id.uuidString
            let group = groupByRecord[id]
            if group == nil || group?.id == id || expandedGroups.contains(group?.id ?? "") {
                GitConsoleEntryView(entry: entry, wrapsLines: wrapsLines, presentation: plans[id], selectedHit: selectedHit,
                    expanded: Binding(get: { expanded[id, default: []] }, set: { expanded[id] = $0 }))
                    .id(entry.id)
                if let group, group.id == id, group.recordIds.count > 1 {
                    Button {
                        if expandedGroups.contains(id) { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
                    } label: {
                        HStack(spacing: 4) {
                            Text(expandedGroups.contains(id) ? "▾" : "▸")
                            Text("Automatic query ×\(group.recordIds.count), identical results")
                            if group.matches > 0 { Text(" · \(group.matches) matches") }
                            Text(verbatim: " · " + GitConsoleEntryView.timestampFormatter.string(from: entry.timestamp) + "–"
                                + GitConsoleEntryView.timestampFormatter.string(from: byID[group.recordIds.last ?? id]?.timestamp ?? entry.timestamp))
                        }
                    }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .regular, design: .monospaced)).foregroundStyle(LitheTheme.secondaryText)
                }
            }
        }
    }
}

/// Observes only user scrolling; layout growth must not disable automatic following.
private struct GitConsoleScrollObserver: NSViewRepresentable {
    let find: () -> Void
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> Probe { Probe(find: find, changed: changed) }
    func updateNSView(_ view: Probe, context: Context) { view.changed = changed; view.find = find }
    final class Probe: NSView {
        var find: () -> Void
        var changed: (Bool) -> Void
        private var keyMonitor: Any?
        private var tokens: [NSObjectProtocol] = []
        private weak var observed: NSScrollView?
        private var lastValue: Bool?
        init(find: @escaping () -> Void, changed: @escaping (Bool) -> Void) { self.find = find; self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        override func layout() { super.layout(); configure() }
        private func configure() {
            guard window != nil, let scroll = enclosingScrollView else { removeObservers(); return }
            guard observed !== scroll else { return }
            removeObservers(); observed = scroll
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak scroll] event in
                guard let self, let scroll, event.window === scroll.window,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "f",
                      let focused = scroll.window?.firstResponder as? NSView,
                      focused === scroll || focused.isDescendant(of: scroll) else { return event }
                self.find(); return nil
            }
            for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: scroll, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.publishPosition() }
                })
            }
        }
        private func publishPosition() {
            guard let scroll = observed else { return }
            let clip = scroll.contentView
            let atEnd = clip.documentRect.maxY - clip.bounds.maxY < 32
            guard lastValue != atEnd else { return }
            lastValue = atEnd; changed(atEnd)
        }
        private func removeObservers() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
            tokens.forEach(NotificationCenter.default.removeObserver); tokens.removeAll(); observed = nil; lastValue = nil
        }
        deinit {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
