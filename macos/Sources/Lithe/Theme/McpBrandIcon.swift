import AppKit
import SwiftUI

/// Only reviewed, bundled marks may identify a featured publisher. Registry
/// responses cannot cause image requests or choose arbitrary bundle paths.
@MainActor
enum McpBrandIconLoader {
    private static var images: [String: NSImage] = [:]

    static func filename(for entry: McpRegistryEntry) -> String? {
        guard entry.source == .featured else { return nil }
        switch entry.id {
        case "lithe.featured/context7": return "context7.png"
        case "lithe.featured/playwright": return "playwright.svg"
        case "lithe.featured/chrome-devtools": return "chrome-devtools.png"
        case "lithe.featured/microsoft-learn": return "microsoft-learn.png"
        case "lithe.featured/github": return "github.png"
        case "lithe.featured/deepwiki": return "deepwiki.png"
        case "lithe.featured/exa": return "exa.png"
        case "lithe.featured/filesystem", "lithe.featured/fetch", "lithe.featured/memory": return "mcp.png"
        default: return nil
        }
    }

    static func image(for entry: McpRegistryEntry) -> NSImage? {
        guard let filename = filename(for: entry) else { return nil }
        if let image = images[filename] { return image }
        // Reuse the packaged/SwiftPM resolver's damaged-app fallback. Assets are
        // immutable source inputs, never downloaded or rewritten at runtime.
        guard let bundle = AgentBrandIconLoader.resolveResourceBundle(),
              let url = bundle.url(forResource: filename, withExtension: nil, subdirectory: "McpIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = false
        image.size = NSSize(width: 28, height: 28)
        images[filename] = image
        return image
    }
}

struct McpBrandIcon: View {
    let entry: McpRegistryEntry

    var body: some View {
        Group {
            if let image = McpBrandIconLoader.image(for: entry) {
                Image(nsImage: image).resizable().renderingMode(.original)
                    .aspectRatio(contentMode: .fit).padding(4)
                    // A neutral tile preserves dark publisher marks in dark mode.
                    .background(Color.white)
            } else {
                Image(systemName: entry.draft?.transport == .stdio ? "terminal" : "network")
                    .font(LitheTheme.uiFont(size: 17)).foregroundStyle(LitheTheme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LitheTheme.accent.opacity(0.08))
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LitheTheme.settingsControlBorder, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
