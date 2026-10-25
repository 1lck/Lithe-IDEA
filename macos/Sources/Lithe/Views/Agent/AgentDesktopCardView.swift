import AppKit
import SwiftUI
import WebKit
import LitheAgentConversationModule

// Note: Claude Desktop 机制在 Agent 面板中的呈现见 .agents/notes/implemented/feature/2026-10-24-agent-transcript-images-and-task-notifications.md

/// A Claude Desktop mechanism shown the way Desktop shows it: chapters as
/// dividers, suggested replies and tasks as buttons, pull requests and
/// visualizations as cards. Actions only fill the composer; nothing is sent
/// until the user sends it.
struct AgentDesktopCardView: View {
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    let card: AgentDesktopCard
    /// Fills the composer, in a new conversation when the flag is set.
    let onDraft: (String, Bool) -> Void

    var body: some View {
        switch card {
        case .chapter(let title, let summary):
            chapter(title: title, summary: summary)
        case .nextStep(let actions):
            LitheChipFlowLayout(spacing: 6) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Button { onDraft(action.message, false) } label: {
                        Text(verbatim: action.label)
                            .font(LitheTheme.uiFont(size: 12))
                            .foregroundStyle(AgentPanelStyle.text)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(AgentPanelStyle.context, in: Capsule())
                            .overlay(Capsule().strokeBorder(AgentPanelStyle.border, lineWidth: 1))
                    }
                    .buttonStyle(.litheNoPress)
                    .lithePointer()
                    .help(action.message)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(AgentLocalization.string("Suggested replies", locale: locale))
            .accessibilityIdentifier("agent-desktop-next-step")
        case .task(let title, let summary, let prompt, let state):
            task(title: title, summary: summary, prompt: prompt, state: state)
        case .pullRequest(let action, let url, let number, let autoFix, let enabled):
            line(systemImage: "arrow.triangle.pull",
                 text: pullRequestText(action, number: number, autoFix: autoFix, enabled: enabled)) {
                Button { openURL(url) } label: {
                    Text(verbatim: number.map { "#\($0)" } ?? url.lastPathComponent)
                        .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
                        .foregroundStyle(LitheTheme.link)
                }
                .buttonStyle(.litheNoPress)
                .lithePointer()
                .help(url.absoluteString)
            }
        case .directory(let action, let path):
            line(systemImage: "folder",
                 text: String(format: AgentLocalization.string(action == .changed ? "Changed the working directory to %@" : "Asked for access to %@", locale: locale), path)) {
                EmptyView()
            }
        case .widget(let title, let code):
            AgentDesktopWidgetCard(title: title, code: code, onPrompt: { onDraft($0, false) })
        }
    }

    private func chapter(title: String, summary: String?) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(AgentPanelStyle.border).frame(height: 1)
            Label {
                Text(verbatim: title).lineLimit(1).truncationMode(.tail)
            } icon: {
                Image(systemName: "bookmark")
            }
            .font(LitheTheme.uiFont(size: 11.5, weight: .semibold))
            .foregroundStyle(AgentPanelStyle.secondary)
            .layoutPriority(1)
            Rectangle().fill(AgentPanelStyle.border).frame(height: 1)
        }
        .padding(.vertical, 2)
        .help(summary ?? title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: AgentLocalization.string("Chapter: %@", locale: locale), title))
        .accessibilityIdentifier("agent-desktop-chapter")
    }

    private func task(title: String, summary: String?, prompt: String?, state: AgentDesktopCard.TaskState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(LitheTheme.uiFont(size: 10.5))
                    .foregroundStyle(state == .withdrawn ? AgentPanelStyle.muted : LitheTheme.accent)
                Text(verbatim: title)
                    .font(LitheTheme.uiFont(size: 12, weight: .semibold))
                    .foregroundStyle(state == .withdrawn ? AgentPanelStyle.muted : AgentPanelStyle.text)
                    .strikethrough(state == .withdrawn)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(verbatim: taskStateText(state))
                    .font(LitheTheme.uiFont(size: 10.5, weight: .medium))
                    .foregroundStyle(AgentPanelStyle.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AgentPanelStyle.context, in: Capsule())
            }
            if let summary {
                Text(verbatim: summary)
                    .font(LitheTheme.uiFont(size: 11.5))
                    .foregroundStyle(AgentPanelStyle.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            // Desktop runs the task in a session of its own; here it starts a new conversation.
            if let prompt, state != .withdrawn {
                Button { onDraft(prompt, true) } label: {
                    Label("Start in new conversation", systemImage: "plus.bubble")
                        .font(LitheTheme.uiFont(size: 11.5))
                }
                .buttonStyle(LitheIconButtonStyle(size: 24, isIconOnly: false))
                .help(prompt)
                .accessibilityIdentifier("agent-desktop-task-start")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentPanelStyle.header, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(AgentPanelStyle.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-desktop-task")
    }

    private func line<Trailing: View>(systemImage: String, text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(LitheTheme.uiFont(size: 10.5))
                .foregroundStyle(AgentPanelStyle.secondary)
            Text(verbatim: text)
                .font(LitheTheme.uiFont(size: 11.5))
                .foregroundStyle(AgentPanelStyle.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            trailing()
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func taskStateText(_ state: AgentDesktopCard.TaskState) -> String {
        switch state {
        case .proposed: AgentLocalization.string("Suggested", locale: locale)
        case .withdrawn: AgentLocalization.string("Withdrawn", locale: locale)
        case .started: AgentLocalization.string("Started in Claude Desktop", locale: locale)
        case .handedOff: AgentLocalization.string("Handed off", locale: locale)
        }
    }

    private func pullRequestText(_ action: AgentDesktopCard.PullRequestAction, number: Int?, autoFix: Bool?, enabled: Bool?) -> String {
        switch action {
        case .bound: AgentLocalization.string("Linked this conversation to a pull request", locale: locale)
        case .unbound: AgentLocalization.string("Unlinked the pull request", locale: locale)
        case .monitored: autoFix == true
            ? AgentLocalization.string("Watching pull request checks and fixing failures", locale: locale)
            : AgentLocalization.string("Watching pull request checks", locale: locale)
        case .autoMerge: enabled == false
            ? AgentLocalization.string("Turned off auto-merge", locale: locale)
            : AgentLocalization.string("Turned on auto-merge", locale: locale)
        }
    }
}

/// A visualization the agent drew. The page is built only when the user opens it.
private struct AgentDesktopWidgetCard: View {
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let code: String
    let onPrompt: (String) -> Void
    @State private var expanded = false
    @State private var height: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(LitheTheme.uiFont(size: 10.5))
                        .foregroundStyle(LitheTheme.accent)
                    Text(verbatim: title.isEmpty ? AgentLocalization.string("Visualization", locale: locale) : title)
                        .font(LitheTheme.uiFont(size: 11.5, weight: .semibold))
                        .foregroundStyle(AgentPanelStyle.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    LitheIDEAIcon(resourcePath: expanded ? "expui/general/chevronDown.svg" : "expui/general/chevronRight.svg",
                                  size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(LitheIconButtonStyle(size: 28, isIconOnly: false))
            .help(expanded ? "Hide visualization" : "Show visualization")
            if expanded {
                Rectangle().fill(AgentPanelStyle.border).frame(height: 1)
                AgentDesktopWidgetWebView(code: code, isDark: colorScheme == .dark, height: $height, onPrompt: onPrompt)
                    .frame(height: height)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentPanelStyle.header, in: RoundedRectangle(cornerRadius: 5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(AgentPanelStyle.border, lineWidth: 1))
        .accessibilityIdentifier("agent-desktop-widget")
    }
}

/// Renders agent-written HTML or SVG offline: the page cannot load anything,
/// keeps no storage, and cannot navigate or open links. Inline scripts run so interactive
/// explainers work; `sendPrompt` only fills the composer, and only right after
/// the user clicked or typed in the page, since the page's script is agent-written
/// and must not replace a draft or take focus on its own.
struct AgentDesktopWidgetWebView: NSViewRepresentable {
    static let messageName = "litheWidgetPrompt"
    static let heightRange: ClosedRange<CGFloat> = 80...720
    /// How long after a click or key press in the page a `sendPrompt` still counts as the user's.
    static let gestureWindow: TimeInterval = 2
    let code: String
    let isDark: Bool
    @Binding var height: CGFloat
    let onPrompt: (String) -> Void

    /// Only the page this view loaded itself. A link never leaves the page, not even
    /// to the system browser: a script can click its own link, and WebKit reports that
    /// like a user's click, so opening it would let the page send its content to any address.
    static func allowsNavigation(_ type: WKNavigationType, url: URL?) -> Bool {
        type == .other && url?.absoluteString == "about:blank"
    }

    /// A prompt is honoured only shortly after the user's own click or key press in the page.
    static func isFollowingUserGesture(_ lastGesture: TimeInterval?, now: TimeInterval) -> Bool {
        guard let lastGesture else { return false }
        return (0...gestureWindow).contains(now - lastGesture)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let prompt = WKUserScript(
            source: "window.sendPrompt = (text) => window.webkit.messageHandlers.\(Self.messageName).postMessage(String(text));",
            injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(prompt)
        configuration.userContentController.add(WeakMessageHandler(context.coordinator), name: Self.messageName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(Self.document(code: code, isDark: isDark), baseURL: nil)
        context.coordinator.loadedDark = isDark
        context.coordinator.trackUserGestures(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedDark != isDark {
            context.coordinator.loadedDark = isDark
            webView.loadHTMLString(Self.document(code: code, isDark: isDark), baseURL: nil)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
        coordinator.stopTrackingUserGestures()
    }

    /// The agent's code inside a page whose policy forbids every network load,
    /// with the theme variables Claude Desktop gives its widgets.
    static func document(code: String, isDark: Bool) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>:root{color-scheme:\(isDark ? "dark" : "light");\(themeVariables(isDark: isDark))}
        html,body{margin:0;padding:8px;background:transparent;color:var(--text-primary);font-family:var(--font-sans);font-size:13px}
        .sr-only{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0,0,0,0)}</style>
        </head><body>\(code)</body></html>
        """
    }

    private static func themeVariables(isDark: Bool) -> String {
        func color(_ token: LitheTheme.ResolvedColorToken) -> String {
            MonacoWorkbenchThemeConfiguration.cssColor(LitheTheme.nsColor(token, isDark: isDark))
        }
        let text = color(.primaryText), secondary = color(.secondaryText), border = color(.divider)
        let variables = [
            "--text-primary": text, "--text-secondary": secondary,
            "--text-muted": "color-mix(in srgb, \(secondary) 75%, transparent)",
            "--text-accent": color(.accent), "--text-danger": color(.error),
            "--text-success": color(.success), "--text-warning": color(.warning),
            "--surface-0": color(.editor), "--surface-1": color(.sidebar), "--surface-2": color(.toolHeader),
            "--surface-3": color(.popupBackground), "--surface-panel": color(.sidebar),
            "--surface-popover": color(.popupBackground), "--page-bg": "transparent",
            "--border": border, "--border-strong": secondary, "--border-accent": color(.accent),
            "--fill-primary": color(.accent), "--on-primary": "#ffffff", "--fill-accent": color(.accent),
            "--bg-accent": "color-mix(in srgb, \(color(.accent)) 16%, transparent)",
            "--bg-success": "color-mix(in srgb, \(color(.success)) 16%, transparent)",
            "--bg-warning": "color-mix(in srgb, \(color(.warning)) 16%, transparent)",
            "--bg-danger": "color-mix(in srgb, \(color(.error)) 16%, transparent)",
            "--font-sans": "-apple-system, system-ui, sans-serif",
            "--font-mono": "ui-monospace, SFMono-Regular, Menlo, monospace",
            "--radius": "6px"
        ]
        return variables.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value);" }.joined()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: AgentDesktopWidgetWebView
        var loadedDark = false
        private var gestureMonitor: Any?
        /// `NSEvent.timestamp` of the user's latest click or key press inside the page.
        private var lastGesture: TimeInterval?

        init(_ parent: AgentDesktopWidgetWebView) { self.parent = parent }

        deinit { stopTrackingUserGestures() }

        /// WebKit gives the page no trustworthy user-gesture signal, so the host watches
        /// the real input events delivered to this view.
        func trackUserGestures(in webView: WKWebView) {
            stopTrackingUserGestures()
            gestureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) {
                [weak self, weak webView] event in
                guard let webView, let window = webView.window, event.window === window else { return event }
                let isInside = event.type == .keyDown
                    ? window.firstResponder.map { ($0 as? NSView)?.isDescendant(of: webView) == true } ?? false
                    : webView.bounds.contains(webView.convert(event.locationInWindow, from: nil))
                if isInside { self?.lastGesture = event.timestamp }
                return event
            }
        }

        func stopTrackingUserGestures() {
            if let gestureMonitor { NSEvent.removeMonitor(gestureMonitor) }
            gestureMonitor = nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(AgentDesktopWidgetWebView.allowsNavigation(action.navigationType, url: action.request.url)
                            ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] value, _ in
                guard let self, let measured = value as? Double else { return }
                let height = min(max(CGFloat(measured), AgentDesktopWidgetWebView.heightRange.lowerBound),
                                 AgentDesktopWidgetWebView.heightRange.upperBound)
                if abs(parent.height - height) > 1 { parent.height = height }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let text = message.body as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  AgentDesktopWidgetWebView.isFollowingUserGesture(lastGesture, now: ProcessInfo.processInfo.systemUptime)
            else { return }
            parent.onPrompt(String(text.prefix(16_384)))
        }
    }

    /// The content controller retains its handlers; this keeps it from retaining the view.
    private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        init(_ target: WKScriptMessageHandler) { self.target = target }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(controller, didReceive: message)
        }
    }
}
