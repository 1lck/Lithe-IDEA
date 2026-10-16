import AppKit
import SwiftUI
import LitheAgentConversationModule

/// A presentation-only index: tools and reasoning belong to the preceding prompt,
/// but only actual Agent prose is used for the reply preview.
struct AgentTranscriptNavigationContent {
    struct Entry: Identifiable, Equatable {
        let id: String
        let prompt: String
        var reply: String = ""
    }

    var entries: [Entry] = []
    var turnByMessageID: [String: String] = [:]

    init(messages: [AgentConversationMessage]) {
        for message in messages {
            if message.role == .user {
                entries.append(Entry(id: message.id, prompt: String(message.text.prefix(320))))
            }
            guard let turnID = entries.last?.id else { continue }
            turnByMessageID[message.id] = turnID
            if message.role == .agent {
                let excerpt = String(message.text.prefix(640)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !excerpt.isEmpty { entries[entries.count - 1].reply = excerpt }
            }
        }
    }
}

extension Notification.Name {
    static let agentTranscriptNavigationRequested = Notification.Name("AgentTranscriptNavigationRequested")
}

/// Only the small navigation rail observes this state. Native viewport events
/// never publish geometry into the conversation feature or its SwiftUI parent.
@MainActor
final class AgentTranscriptNavigationState: ObservableObject {
    @Published private(set) var visibleTurnIDs: Set<String> = []
    private weak var scrollView: NSScrollView?
    private var rows: [ObjectIdentifier: WeakRow] = [:]
    private var pendingRefresh: DispatchWorkItem?

    private struct WeakRow { weak var view: AgentTranscriptNavigationAnchor.Probe? }

    func register(_ row: AgentTranscriptNavigationAnchor.Probe) {
        rows[ObjectIdentifier(row)] = WeakRow(view: row)
        requestRefresh()
    }

    func unregister(_ row: AgentTranscriptNavigationAnchor.Probe) {
        rows.removeValue(forKey: ObjectIdentifier(row))
        requestRefresh()
    }

    func attach(to scrollView: NSScrollView) {
        self.scrollView = scrollView
        requestRefresh()
    }

    func detach(from scrollView: NSScrollView?) {
        guard self.scrollView === scrollView else { return }
        pendingRefresh?.cancel()
        pendingRefresh = nil
        self.scrollView = nil
    }

    func requestRefresh() {
        guard pendingRefresh == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRefresh = nil
            self.refreshVisibleTurns()
        }
        pendingRefresh = work
        DispatchQueue.main.async(execute: work)
    }

    func refreshVisibleTurns() {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        // safeAreaInset reserves space inside the clip bounds. Covered rows
        // must not appear visible merely because they intersect that space.
        let insets = scrollView.contentInsets
        var viewport = clip.bounds
        viewport.origin.x += insets.left
        viewport.origin.y += clip.isFlipped ? insets.top : insets.bottom
        viewport.size.width = max(0, viewport.width - insets.left - insets.right)
        viewport.size.height = max(0, viewport.height - insets.top - insets.bottom)
        let visibleRect = viewport.height > 2 ? viewport.insetBy(dx: 0, dy: 1) : .zero
        var visible: Set<String> = []
        rows = rows.filter { $0.value.view != nil }
        for row in rows.values {
            guard let view = row.view, view.window != nil, view.enclosingScrollView === scrollView,
                  let turnID = view.turnID else { continue }
            let rect = view.convert(view.bounds, to: clip)
            if rect.height > 0 && !visibleRect.isEmpty && rect.intersects(visibleRect) { visible.insert(turnID) }
        }
        if visible != visibleTurnIDs { visibleTurnIDs = visible }
    }

    func beginNavigation() {
        guard let scrollView else { return }
        NotificationCenter.default.post(name: .agentTranscriptNavigationRequested, object: scrollView)
    }

    deinit { pendingRefresh?.cancel() }
}

/// Passive native row anchors keep lazy message rows and text selection intact.
struct AgentTranscriptNavigationAnchor: NSViewRepresentable {
    let state: AgentTranscriptNavigationState
    let turnID: String?

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.update(state: state, turnID: turnID) }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: NSView {
        private weak var state: AgentTranscriptNavigationState?
        fileprivate(set) var turnID: String?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); state?.requestRefresh() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { state?.register(self) } else { state?.unregister(self) }
        }
        func update(state: AgentTranscriptNavigationState, turnID: String?) {
            if self.state !== state { self.state?.unregister(self) }
            self.state = state
            self.turnID = turnID
            state.register(self)
        }
        func detach() { state?.unregister(self); state = nil }
    }
}

struct AgentTranscriptNavigationViewport: NSViewRepresentable {
    let state: AgentTranscriptNavigationState
    func makeNSView(context: Context) -> Probe { Probe(state: state) }
    func updateNSView(_ view: Probe, context: Context) { view.attach() }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: NSView {
        private let state: AgentTranscriptNavigationState
        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var insetObservation: NSKeyValueObservation?
        init(state: AgentTranscriptNavigationState) { self.state = state; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); attach(); state.requestRefresh() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() } else { attach() }
        }
        func attach() {
            guard window != nil, let enclosing = enclosingScrollView, scrollView !== enclosing else { return }
            detach()
            scrollView = enclosing
            state.attach(to: enclosing)
            insetObservation = enclosing.observe(\.contentInsets, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.state.requestRefresh() }
            }
            enclosing.contentView.postsBoundsChangedNotifications = true
            enclosing.contentView.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: enclosing.contentView,
                    queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.state.requestRefresh() }
                    })
            }
        }
        func detach() {
            state.detach(from: scrollView)
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            insetObservation?.invalidate()
            insetObservation = nil
            scrollView = nil
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

struct AgentTranscriptNavigationRail: View {
    @ObservedObject var state: AgentTranscriptNavigationState
    let entries: [AgentTranscriptNavigationContent.Entry]
    let onSelect: (String) -> Void
    @Environment(\.isLithePaneResizing) private var isResizing
    @State private var isHovered = false
    @FocusState private var focusedID: String?

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { reader in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            Button { onSelect(entry.id) } label: {
                                HStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    Capsule()
                                        .fill(state.visibleTurnIDs.contains(entry.id) ? AgentPanelStyle.text : AgentPanelStyle.muted)
                                        .frame(width: state.visibleTurnIDs.contains(entry.id) ? 24 : 12, height: 2)
                                        .opacity((isHovered || focusedID != nil) && !isResizing ? 1 : 0)
                                }
                                .frame(width: 28, height: 20)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focused($focusedID, equals: entry.id)
                            .accessibilityLabel(Text(verbatim: entry.prompt))
                            .accessibilityIdentifier("agent-turn-navigation-\(entry.id)")
                            .workbenchHoverCard(placement: .leading, maximumWidth: 360) {
                                AgentTranscriptNavigationPreview(entry: entry)
                            }
                            .id(entry.id)
                        }
                    }
                    .frame(minHeight: max(0, geometry.size.height), alignment: .center)
                }
                .allowsHitTesting(!isResizing)
                .accessibilityHidden(isResizing)
                .onChange(of: state.visibleTurnIDs) { visible in
                    guard !isHovered, let current = entries.first(where: { visible.contains($0.id) }) else { return }
                    reader.scrollTo(current.id, anchor: .center)
                }
            }
        }
        .frame(width: 32)
        .contentShape(Rectangle())
        .onHover { hovered in
            isHovered = hovered
            if !hovered { focusedID = nil }
        }
        .onChange(of: isResizing) { resizing in
            if resizing { isHovered = false; focusedID = nil }
        }
        .padding(.trailing, LitheScrollBarStyle.thickness + 2)
        .accessibilityElement(children: .contain)
    }
}

private struct AgentTranscriptNavigationPreview: View {
    let entry: AgentTranscriptNavigationContent.Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: entry.prompt)
                .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                .foregroundStyle(AgentPanelStyle.text)
                .lineLimit(2)
            if !entry.reply.isEmpty {
                Text(verbatim: entry.reply)
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(AgentPanelStyle.secondary)
                    .lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .litheHoverTooltipSurface()
    }
}
