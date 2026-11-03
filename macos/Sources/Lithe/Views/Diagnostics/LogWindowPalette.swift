import AppKit
import SwiftUI

/// The log prototype owns these colors independently of the editor theme.
enum LogWindowPalette {
    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: alpha)
    }
    private static func adaptive(_ light: UInt32, _ dark: UInt32, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? hex(dark, alpha: darkAlpha) : hex(light)
        }
    }
    static let bg = adaptive(0xffffff, 0x0d1117)
    static let bg2 = adaptive(0xf6f8fa, 0x010409)
    static let bg3 = adaptive(0xeef1f4, 0x161b22)
    static let hl = adaptive(0xddf4ff, 0x1f2a3a)
    static let line = adaptive(0xe4e8ec, 0x21262d)
    static let bd = adaptive(0xd0d7de, 0x30363d)
    static let tx = adaptive(0x1f2328, 0xc9d1d9)
    static let tx2 = adaptive(0x59636e, 0x8b949e)
    static let tx3 = adaptive(0x8c959f, 0x6e7681)
    static let red = adaptive(0xcf222e, 0xff7b72)
    static let org = adaptive(0xbc4c00, 0xffa657)
    static let yel = adaptive(0x9a6700, 0xe3b341)
    static let grn = adaptive(0x1a7f37, 0x7ee787)
    static let cyn = adaptive(0x0550ae, 0x79c0ff)
    static let blu = adaptive(0x0969da, 0x58a6ff)
    static let pur = adaptive(0x8250df, 0xd2a8ff)
    static let pnk = adaptive(0xbf3989, 0xff9bce)
    static let errrow = adaptive(0xffebe9, 0xf85149, darkAlpha: 0.102)
    static let errsel = adaptive(0xffd8d3, 0x3b1d22)
    static let oprow = adaptive(0xfbefff, 0x2a1f3d)
    static let menu = adaptive(0xffffff, 0x161b22)
    static let foot = adaptive(0x0969da, 0x1f6feb)
    static let white = hex(0xffffff)
    static let pulse = hex(0x7ee787)
    /// The prototype's channel hues. Only the host's own `app` channel has a fixed color; every
    /// server, provider and plugin channel hashes its name so no plugin identity is special-cased.
    private static let appChannelColor: UInt32 = 0x8b949e
    private static let channelColors: [UInt32] = [0x2f81f7, 0xe16f24, 0xcf222e, 0xf78166, 0x2da44e, 0xa371f7]
    static func channel(_ name: String) -> NSColor {
        guard name != "app" else { return hex(appChannelColor) }
        let hash = name.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return hex(channelColors[Int(hash % UInt64(channelColors.count))])
    }
    static func level(_ level: String) -> NSColor {
        switch level { case "ERROR": red; case "WARN": yel; case "INFO": blu; default: tx3 }
    }
    static func symbol(_ level: String) -> String {
        switch level { case "ERROR": "✖"; case "WARN": "▲"; case "INFO": "●"; default: "·" }
    }
}

struct LogButtonStyle: ButtonStyle {
    var active = false
    var recording = false
    var height: CGFloat = 28
    var fullWidth = false
    var monospaced = true
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(monospaced ? LitheTheme.uiFont(size: 12, design: .monospaced) : .system(size: 12))
            .lineLimit(1).fixedSize(horizontal: !fullWidth, vertical: false)
            .padding(.horizontal, 9).frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading).frame(height: height)
            .foregroundStyle(Color(recording ? LogWindowPalette.grn : active ? LogWindowPalette.blu : LogWindowPalette.tx))
            .background(Color(configuration.isPressed ? LogWindowPalette.bg3 : LogWindowPalette.bg))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(active ? LogWindowPalette.blu : LogWindowPalette.bd), lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
    }
}

/// Measures only toolbar controls; rows stay in the native virtual table.
struct LogToolbarLayout: Layout {
    private func lines(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var result: [[(Int, CGSize)]] = [[]]
        var used: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if used > 0 && used + 6 + size.width > width { result.append([]); used = 0 }
            result[result.count - 1].append((index, size)); used += (used > 0 ? 6 : 0) + size.width
        }
        return result
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 1320
        return CGSize(width: width, height: lines(subviews, width: width).reduce(0) { $0 + ($1.map { $0.1.height }.max() ?? 0) + 6 } - 6)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            var x = bounds.minX
            let height = line.map { $0.1.height }.max() ?? 0
            let spare = max(0, bounds.width - line.reduce(0) { $0 + $1.1.width } - CGFloat(max(0, line.count - 1)) * 6)
            for (index, size) in line {
                let width = size.width + (index == 0 ? spare : 0)
                subviews[index].place(at: CGPoint(x: x, y: y + (height - size.height) / 2), proposal: .init(width: width, height: size.height))
                x += width + 6
            }
            y += height + 6
        }
    }
}
