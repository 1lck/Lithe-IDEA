import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite(.serialized)
struct WorkbenchSurfaceBackgroundTests {
    @Test(arguments: [ColorScheme.dark, .light])
    func structuralPagesFollowWallpaperChangesWithoutReplacingTheirRoot(scheme: ColorScheme) throws {
        MacBundledFontRegistry.registerFonts()
        let pages: [AnyView] = [
            AnyView(AgentUnconfiguredConversationView(setupError: .featureDisabled,
                onOpenSettings: {}, onHide: {}, agentName: "Codex")),
            AnyView(AgentWelcomeView(onOpenAgent: { _ in }, onOpenProviders: {})),
            AnyView(WorkbenchModuleUIRegistry.moduleLoadingView),
            AnyView(OutputTextView(output: "", searchRoots: [], fileExists: { _ in false },
                                   emptyMessage: "No output", onOpenLocation: { _, _, _ in }))
        ]
        let reference = NSHostingView(rootView: wallpaperTestBackdrop.environment(\.colorScheme, scheme))
        let referenceWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                                       styleMask: [.borderless], backing: .buffered, defer: false)
        referenceWindow.isReleasedWhenClosed = false
        defer { referenceWindow.close() }
        referenceWindow.contentView = reference
        reference.frame.size = NSSize(width: 480, height: 640)
        reference.layoutSubtreeIfNeeded()
        let backdrop = try sample(reference)
        for page in pages {
            let state = WallpaperSurfaceState()
            let host = NSHostingView(rootView: WallpaperSurfaceHost(state: state, page: page)
                .environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let solid = try sample(host)
            let solidHeader = try sample(host, y: 16)
            state.hasImage = true
            host.layoutSubtreeIfNeeded()
            let image = try sample(host)
            // Compare the actual backing image after native colour management, not raw RGB inputs.
            #expect(try sample(host, y: 16) == backdrop, "Title bars also expose the backing image")
            #expect(image == backdrop, "Every structural layer must expose the same backing image")
            #expect(solid != image, "The page must release its opaque background when wallpaper is selected")
            state.hasImage = false
            host.layoutSubtreeIfNeeded()
            #expect(try sample(host, y: 16) == solidHeader)
            #expect(try sample(host) == solid, "Removing wallpaper restores the original theme surface")
        }
    }

    private func sample(_ host: NSView, y: CGFloat = 240) throws -> NSColor {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        // Blank left margin, away from text, status notices and editable controls.
        return try #require(bitmap.colorAt(x: Int(2 * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
    }
}

@MainActor
private final class WallpaperSurfaceState: ObservableObject {
    @Published var hasImage = false
}

private struct WallpaperSurfaceHost: View {
    @ObservedObject var state: WallpaperSurfaceState
    let page: AnyView

    var body: some View {
        ZStack {
            wallpaperTestBackdrop
            page.frame(maxWidth: .infinity, maxHeight: .infinity)
                // The workbench supplies a page base beneath content-specific layers.
                .litheWorkbenchSurface(LitheTheme.editor)
                .environment(\.workbenchHasBackgroundImage, state.hasImage)
        }
    }
}

private var wallpaperTestBackdrop: Color {
    Color(nsColor: NSColor(srgbRed: 0.8, green: 0.1, blue: 0.6, alpha: 1))
}
