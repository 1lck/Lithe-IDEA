import AppKit
import Combine
import SwiftUI
import WebKit

// Note: HTML 预览作为内嵌浏览器的决策见 .agents/notes/implemented/feature/2026-10-22-html-preview-embedded-browser.md

/// The shortcuts that drive find in page while the page has focus.
enum HTMLPreviewFind {
    enum Command: Equatable {
        case show
        case next
        case previous
    }

    /// Scripts the preview itself runs, in a world the page cannot reach.
    static let contentWorld = WKContentWorld.world(name: "LitheHTMLPreviewFind")

    /// `WKWebView.find` continues from the end of the current match, so typing
    /// one more letter would jump past a match that still fits. Putting the
    /// caret at the start of the match lets the longer text match where it is.
    static let collapseSelectionScript = """
        (() => {
            const selection = window.getSelection();
            if (selection && selection.rangeCount > 0) selection.collapseToStart();
        })();
        """

    /// Maps ⌘F, ⌘G and ⇧⌘G to a find command. Any other modifier means the shortcut belongs to someone else.
    static func command(forKey key: String, modifiers: NSEvent.ModifierFlags) -> Command? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), flags.isDisjoint(with: [.option, .control]) else { return nil }
        // Shift upper-cases the characters, so ⇧⌘G reports "G".
        switch (key.lowercased(), flags.contains(.shift)) {
        case ("f", false): return .show
        case ("g", false): return .next
        case ("g", true): return .previous
        default: return nil
        }
    }
}

/// Find in page for the HTML preview, backed by `WKWebView.find`.
///
/// WebKit selects and highlights the match inside the page and reports only
/// whether one was found, so there is no match counter.
@MainActor
final class HTMLPreviewFindModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case found
        case notFound
    }

    @Published private(set) var isVisible = false
    @Published var query = ""
    @Published private(set) var status = Status.idle
    /// Counts the requests to focus the field, so ⌘F pressed while the bar is
    /// already open brings the cursor back to it.
    @Published private(set) var focusRequest = 0
    /// Counts the searches WebKit has answered. The status stays the same when a
    /// later match is found, so this is what tells that a step has finished.
    @Published private(set) var completedSearches = 0

    private weak var webView: WKWebView?
    /// Numbers the searches; an answer to an older one is ignored.
    private var generation = 0
    private var cancellables = Set<AnyCancellable>()

    init(webView: WKWebView) {
        self.webView = webView
        // `$query` publishes before the property changes, so the new text comes from the value.
        $query.dropFirst().removeDuplicates()
            .sink { [weak self] text in self?.queryDidChange(to: text) }
            .store(in: &cancellables)
    }

    func handle(_ command: HTMLPreviewFind.Command) {
        switch command {
        case .show: show()
        case .next: step(backwards: false)
        case .previous: step(backwards: true)
        }
    }

    /// Opens the bar (or moves the cursor back to it) and highlights the text in it again.
    func show() {
        isVisible = true
        focusRequest += 1
        if !query.isEmpty { search(query, backwards: false, fromStartOfMatch: true) }
    }

    /// Closes the bar and returns the keyboard to the page. The last match stays selected.
    func hide() {
        guard isVisible else { return }
        isVisible = false
        generation += 1
        status = .idle
        hideFindUI()
        if let webView, let window = webView.window { window.makeFirstResponder(webView) }
    }

    /// Goes to the next or previous match of the text in the field. With no
    /// text there is nothing to step through, so the bar opens for typing.
    func step(backwards: Bool) {
        guard !query.isEmpty else { return show() }
        if !isVisible {
            isVisible = true
            focusRequest += 1
        }
        search(query, backwards: backwards, fromStartOfMatch: false)
    }

    /// The highlights belong to the page that is gone. The bar and its text stay.
    func pageDidChange() {
        generation += 1
        if status != .idle { status = .idle }
    }

    private func queryDidChange(to text: String) {
        guard isVisible else { return }
        guard !text.isEmpty else {
            generation += 1
            status = .idle
            hideFindUI()
            return
        }
        search(text, backwards: false, fromStartOfMatch: true)
    }

    private func search(_ text: String, backwards: Bool, fromStartOfMatch: Bool) {
        guard let webView else { return }
        generation += 1
        let request = generation
        let run = { [weak self, weak webView] in
            guard let self, let webView, request == generation else { return }
            let configuration = WKFindConfiguration()
            configuration.backwards = backwards
            configuration.caseSensitive = false
            configuration.wraps = true
            webView.find(text, configuration: configuration) { [weak self] result in
                guard let self, request == generation else { return }
                status = result.matchFound ? .found : .notFound
                if !result.matchFound { hideFindUI() }
                completedSearches += 1
            }
        }
        guard fromStartOfMatch else { return run() }
        webView.evaluateJavaScript(
            HTMLPreviewFind.collapseSelectionScript,
            in: nil,
            in: HTMLPreviewFind.contentWorld
        ) { _ in run() }
    }

    /// The yellow indicator WebKit draws around a match is cleared through an
    /// SPI; without it the indicator is simply left to fade.
    private func hideFindUI() {
        let selector = NSSelectorFromString("_hideFindUI")
        guard let webView, webView.responds(to: selector) else { return }
        _ = webView.perform(selector)
    }
}

/// The find bar shown under the toolbar while find is open.
struct HTMLPreviewFindBar: View {
    @ObservedObject var find: HTMLPreviewFindModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        if find.isVisible {
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    LitheSearchTextField("Find in page", text: $find.query)
                        .focused($fieldFocused)
                        .litheSearchField(isFocused: fieldFocused)
                        .onSubmit {
                            // Return goes forward and Shift-Return back, as in a browser.
                            find.step(backwards: NSEvent.modifierFlags.contains(.shift))
                        }
                        .onExitCommand { find.hide() }
                    if find.status == .notFound {
                        Text("No matches")
                            .font(LitheTheme.uiFont(size: 11))
                            .foregroundStyle(LitheTheme.error)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                    }
                    barButton("Previous Match", systemImage: "chevron.up") { find.step(backwards: true) }
                        .disabled(find.query.isEmpty)
                    barButton("Next Match", systemImage: "chevron.down") { find.step(backwards: false) }
                        .disabled(find.query.isEmpty)
                    barButton("Close Find", systemImage: "xmark") { find.hide() }
                }
                .padding(.horizontal, 6)
                .frame(height: 36)
                .background(LitheTheme.toolHeader)
                LitheToolWindowHeaderDivider()
            }
            .onAppear { focusField() }
            .onChange(of: find.focusRequest) { _ in focusField() }
        }
    }

    /// The field is created in the same update that shows the bar, so it can
    /// only take focus once that update has finished.
    private func focusField() {
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func barButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { LitheSystemIcon(systemImage: systemImage, size: 14) }
            .buttonStyle(LitheIconButtonStyle(size: LitheTheme.Metrics.toolbarIconButtonSize))
            .help(title)
            .accessibilityLabel(title)
    }
}
