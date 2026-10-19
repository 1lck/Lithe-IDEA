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

    @Test(arguments: [ColorScheme.dark, .light])
    func consoleFontStylingDoesNotOverrideTheSharedSurface(scheme: ColorScheme) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var samples: [NSColor] = []
        for fontSize in [11.5, 17.0] {
            let host = NSHostingView(rootView:
                OutputTextView(output: "", searchRoots: [], fileExists: { _ in false },
                    emptyMessage: "No output", fontSize: fontSize,
                    onOpenLocation: { _, _, _ in })
                    .environment(\.colorScheme, scheme))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            samples.append(try sample(host))
        }
        #expect(samples[0] == samples[1], "Console text styling must preserve the same pane background")
    }

    @Test(arguments: [ColorScheme.dark, .light], [WorkbenchFeatureModel.ToolWindow.gitLog, .terminal])
    func retainedPaneCornersMatchWorkbenchGradient(scheme: ColorScheme, tool: WorkbenchFeatureModel.ToolWindow) async throws {
        let state = RetainedChromeState()
        let store = WorkbenchToolContentStore()
        let host = NSHostingView(rootView: RetainedChromeFixture(state: state, store: store, tool: tool)
            .environment(\.colorScheme, scheme))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        var retainedHost: NSView?
        // Upper sidebar, moved pane, project colour change, gradient off, wallpaper, restored.
        for step in 0..<6 {
            state.origin = step == 0 ? CGPoint(x: 40, y: 35) : CGPoint(x: 180, y: 100)
            state.size = step == 2 ? CGSize(width: 260, height: 220) : CGSize(width: 200, height: 180)
            state.glow = ProjectIdentityAppearance(colorIndex: step < 2 ? 6 : 0, isDark: scheme == .dark)
                .toolbarGlow(over: Color(nsColor: LitheTheme.nsColor(.titlebar, isDark: scheme == .dark)))
            state.gradient = step != 3
            state.hasImage = step == 4
            state.retained = false
            host.layoutSubtreeIfNeeded()
            let expected = try cornerSamples(host, origin: state.origin, size: state.size)
            state.retained = true
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            let actual = try cornerSamples(host, origin: state.origin, size: state.size)
            #expect(actual == expected,
                    "Retained corners must match the original workbench coordinates and current glow, step \(step): \(actual) versus \(expected)")
            let entry = try #require(store.entries[tool])
            if let retainedHost { #expect(entry.host === retainedHost) }
            else { retainedHost = entry.host }
            #expect(entry.chrome.frame == entry.host.frame)
        }
    }

    private func cornerSamples(_ host: NSView, origin: CGPoint, size: CGSize) throws -> [NSColor] {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        return try [CGPoint(x: 1, y: 1), CGPoint(x: size.width - 2, y: 1),
                    CGPoint(x: 1, y: size.height - 2), CGPoint(x: size.width - 2, y: size.height - 2)].map { point in
            try #require(bitmap.colorAt(x: Int((origin.x + point.x) * scale),
                                        y: Int((origin.y + point.y) * scale))?.usingColorSpace(.sRGB))
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

@MainActor
private final class RetainedChromeState: ObservableObject {
    @Published var retained = false
    @Published var origin = CGPoint(x: 40, y: 35)
    @Published var size = CGSize(width: 200, height: 180)
    @Published var glow = Color.clear
    @Published var gradient = true
    @Published var hasImage = false
}

private struct RetainedChromeFixture: View {
    @ObservedObject var state: RetainedChromeState
    let store: WorkbenchToolContentStore
    let tool: WorkbenchFeatureModel.ToolWindow

    var body: some View {
        ZStack(alignment: .topLeading) {
            wallpaperTestBackdrop
            Group {
                if state.retained {
                    RetainedWorkbenchToolPane(store: store, tool: tool, content: Color.red,
                                              showsFrameGradient: state.gradient)
                } else {
                    Color.red.workbenchPaneChrome(background: .clear, surrounding: LitheTheme.titlebar,
                        roundsCorners: !state.hasImage, showsFrameGradient: state.gradient)
                }
            }
            .frame(width: state.size.width, height: state.size.height)
            .padding(.leading, state.origin.x).padding(.top, state.origin.y)
        }
        .overlay { WorkbenchToolContentSurface(store: store) }
        .coordinateSpace(name: WorkbenchFrameGradient.coordinateSpace)
        .environment(\.workbenchToolbarGlow, state.glow)
        .environment(\.workbenchHasBackgroundImage, state.hasImage)
    }
}
