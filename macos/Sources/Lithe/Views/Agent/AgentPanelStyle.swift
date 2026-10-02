import AppKit
import SwiftUI

/// Conversation surfaces follow the same live theme tokens as the workbench.
enum AgentPanelStyle {
    static var canvas: Color { LitheTheme.editor }
    static var header: Color { LitheTheme.toolHeader }
    static var context: Color { LitheTheme.raised }
    static var toolbar: Color { LitheTheme.editor }
    static var border: Color { LitheTheme.panelBorder }
    static let text = adaptive(dark: 0xcccccc, light: 0x333333)
    static let secondary = adaptive(dark: 0x888888, light: 0x666666)
    static let muted = adaptive(dark: 0x666666, light: 0x777777)
    static let logo = adaptive(dark: 0x555555, light: 0x777777)
    static let focus = adaptive(dark: 0x007fd4, light: 0x0078d4)
    static let selected = adaptive(dark: 0x094771, light: 0xcce7ff)
    static let versionText = adaptive(dark: 0xddd6fe, light: 0x6d28d9)
    static let versionAccent = Color(red: 139 / 255, green: 92 / 255, blue: 246 / 255)

    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255,
                alpha: 1
            )
        })
    }
}

/// Template SVGs use the same vendor silhouettes at welcome and toolbar sizes.
struct AgentBrandIcon: View {
    let name: String?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = AgentBrandIconLoader.image(name: name, size: size) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "sparkles")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
enum AgentBrandIconLoader {
    private struct CacheKey: Hashable {
        let bundleURL: URL
        let filename: String
        let size: Int
    }
    private static var images: [CacheKey: NSImage] = [:]

    static func image(
        name: String?, size: CGFloat = 64,
        resourceBundle: Bundle? = resolveResourceBundle()
    ) -> NSImage? {
        let filename: String
        switch name?.lowercased() {
        case "codex": filename = "openai"
        case "claude", "claude code": filename = "claude"
        default: return nil
        }
        guard let resourceBundle else { return nil }
        let key = CacheKey(bundleURL: resourceBundle.bundleURL, filename: filename, size: max(1, Int(size.rounded())))
        if let image = images[key] { return image }
        guard let url = resourceBundle.url(forResource: filename, withExtension: "svg", subdirectory: "AgentIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        // Native Menu labels read NSImage.size rather than the SwiftUI frame.
        image.size = NSSize(width: key.size, height: key.size)
        images[key] = image
        return image
    }

    nonisolated static func resolveResourceBundle(
        mainBundle: Bundle = .main,
        developmentBundle: () -> Bundle = { Bundle.module }
    ) -> Bundle? {
        // Packaged assets are read-only inputs. SwiftPM's generated accessor looks
        // beside the app or in the build tree, not in Contents/Resources.
        let packagedURL = mainBundle.resourceURL?
            .appendingPathComponent("Lithe_Lithe.bundle", isDirectory: true)
        if let packagedURL, let bundle = Bundle(url: packagedURL) {
            return bundle
        }
        // A damaged installed app must use the fallback glyph, never the fatal
        // SwiftPM accessor or an unrelated development machine's build output.
        guard mainBundle.bundleURL.pathExtension != "app" else { return nil }
        let adjacentURL = mainBundle.bundleURL
            .appendingPathComponent("Lithe_Lithe.bundle", isDirectory: true)
        return Bundle(url: adjacentURL) ?? developmentBundle()
    }
}

struct AgentToolbarButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LitheTheme.uiFont(size: 14, weight: .regular))
            .foregroundStyle(AgentPanelStyle.secondary)
            .frame(width: 28, height: 28)
            .background(
                configuration.isPressed || isHovering ? AgentPanelStyle.context : .clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}
