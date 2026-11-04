import AppKit
import SwiftUI

struct LogChannelRow: View {
    let row: LogWindowView.ChannelRow
    let selected: Bool
    let unread: Bool
    let action: () -> Void
    @State private var hovered = false
    private var shortName: String {
        var parts = row.id.split(separator: "/").map(String.init)
        if parts.count > 1 { parts.removeFirst() }
        if parts.count > 1 && parts.last == "host" { parts.removeLast() }
        return parts.joined(separator: "/")
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(row.id.isEmpty ? Color.clear : Color(LogWindowPalette.channel(row.id)))
                    .overlay { if row.id.isEmpty { RoundedRectangle(cornerRadius: 2).stroke(Color(LogWindowPalette.tx2)) } }
                    .frame(width: 8, height: 8)
                if row.id.isEmpty { Text("All channels") } else { Text(verbatim: shortName) }
                if unread { Circle().fill(Color(LogWindowPalette.red)).frame(width: 7, height: 7).accessibilityLabel(Text("Unread errors")) }
                Spacer(minLength: 0)
                Text(verbatim: row.count.formatted(.number.locale(Locale(identifier: "en_US"))))
                    .font(LitheTheme.uiFont(size: 11, design: .monospaced)).foregroundStyle(Color(LogWindowPalette.tx3))
            }.padding(.leading, 12).padding(.trailing, 12).frame(height: 25)
                .foregroundStyle(Color(selected ? LogWindowPalette.tx : LogWindowPalette.tx2))
                .background(Color(selected ? LogWindowPalette.hl : hovered ? LogWindowPalette.bg3 : LogWindowPalette.bg2))
                .overlay(alignment: .leading) { if selected { Color(LogWindowPalette.blu).frame(width: 2) } }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
    }
}

struct LogFollowingPulse: View {
    @State private var dimmed = false
    var body: some View {
        Circle().fill(Color(LogWindowPalette.pulse)).frame(width: 7, height: 7).opacity(dimmed ? 0.25 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dimmed = true } }
    }
}

/// Native titlebar attachment; this never replaces the system window controls.
struct LogWindowChrome: NSViewRepresentable {
    var title: String
    var shortcut: String
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor(); view.apply(title: title, shortcut: shortcut); return view
    }
    func updateNSView(_ view: Anchor, context: Context) { view.apply(title: title, shortcut: shortcut) }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.detach() }
    final class Anchor: NSView {
        private var title = ""
        private var shortcut = ""
        private weak var attached: NSWindow?
        private var accessory: NSTitlebarAccessoryViewController?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
        func apply(title: String, shortcut: String) {
            guard self.title != title || self.shortcut != shortcut else { return }
            self.title = title; self.shortcut = shortcut; install()
        }
        func detach() {
            if let accessory, let attached, let index = attached.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                attached.removeTitlebarAccessoryViewController(at: index)
            }
            accessory = nil; attached = nil
        }
        private func install() {
            guard let window else { detach(); return }
            if attached !== window { detach(); attached = window }
            if !title.isEmpty { window.title = title }
            guard window.styleMask.contains(.titled) else { return }
            if accessory == nil {
                let controller = NSTitlebarAccessoryViewController(); controller.layoutAttribute = .right
                accessory = controller; window.addTitlebarAccessoryViewController(controller)
            }
            let host = NSHostingView(rootView: Text(verbatim: shortcut).font(LitheTheme.uiFont(size: 11, design: .monospaced))
                .foregroundStyle(Color(LogWindowPalette.tx2)).padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(LogWindowPalette.bd))).padding(.trailing, 12))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            accessory?.view = host
        }
    }
}

/// Token coloring only: the text itself is Core's formatted copy output.
/// Prepared once when the selected record changes, never on table scroll or live batches.
enum LogJSONHighlight {
    static func attributed(_ text: String, fields: [String: String]) -> AttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.foregroundColor: LogWindowPalette.tx2,
            .font: LitheTheme.editorFont(size: 12.5)])
        // JSON tokens are presentation spans, not another record parser.
        let pattern = #""(?:\\.|[^"\\])*"|\b(?:true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return AttributedString(text) } // log-exempt: 预期的缺失：固定着色表达式不可用时保留 Core 原文
        let source = text as NSString
        var fieldKey: String?
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let token = source.substring(with: match.range)
            let tail = source.substring(from: NSMaxRange(match.range)).drop(while: { $0.isWhitespace })
            let key = token.hasPrefix("\"") && tail.first == ":"
            let redacted = token.contains("‹redacted›") || token.contains("<redacted>")
            let color = key ? LogWindowPalette.cyn : redacted ? LogWindowPalette.tx3 : token.hasPrefix("\"") ? LogWindowPalette.grn : token == "true" || token == "false" || token == "null" ? LogWindowPalette.pnk : LogWindowPalette.blu
            result.addAttribute(.foregroundColor, value: color, range: match.range)
            if key { fieldKey = String(token.dropFirst().dropLast()) }
            else if let fieldKey, fields[fieldKey] != nil, !redacted {
                var components = URLComponents(); components.scheme = "log-field"; components.host = fieldKey
                if let url = components.url { result.addAttribute(.link, value: url, range: match.range) }
            }
            if redacted { result.addAttribute(.obliqueness, value: 0.15, range: match.range) }
        }
        // NSAttributedString conversion preserves native fonts, colors and field links.
        return AttributedString(result)
    }
}
