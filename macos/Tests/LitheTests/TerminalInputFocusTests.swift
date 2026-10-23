import AppKit
import SwiftUI
import MetalKit
import os
import SwiftTerm
import Testing
@testable import Lithe
import LitheTerminalModule

@Suite("Terminal input focus")
@MainActor
struct TerminalInputFocusTests {
    @Test
    func terminalPaletteUsesDefaultProfileAndKeepsMissingColorsAvailableForFallback() throws {
        let text = NSColor(srgbRed: 0.8, green: 0.7, blue: 0.6, alpha: 0.5)
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        func archive(_ color: NSColor) throws -> Data {
            try NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
        }
        let palette = MacTerminalPalette(preferences: [
            "Default Window Settings": "Selected",
            "Window Settings": [
                "Selected": ["TextColor": try archive(text), "ANSIRedColor": try archive(red),
                             "ANSIBrightBlueColor": try archive(blue), "ANSIGreenColor": "invalid"],
                "Other": ["TextColor": try archive(red)]
            ]
        ])
        #expect(abs(try #require(palette.textColor).redComponent - 0.8) < 0.001)
        #expect(palette.textColor?.alphaComponent == 0.5)
        #expect(palette.ansiColors.count == 16)
        #expect(palette.ansiColors[1]?.red == 65535)
        #expect(palette.ansiColors[12]?.blue == 65535)
        #expect(palette.ansiColors[2] == nil)
        #expect(palette.ansiColors[4] == nil)
        let missing = MacTerminalPalette(preferences: nil)
        #expect(missing.textColor == nil)
        #expect(missing.ansiColors.allSatisfy { $0 == nil })
    }

    @Test
    func terminalPaletteRefreshesOnThemeChange() {
        let terminal = LitheTerminalView(frame: .zero)
        terminal.applyThemeColors(theme: .lithe, isDark: true)
        let litheBackground = terminal.nativeBackgroundColor
        let litheTerminalBackground = terminal.terminal.backgroundColor

        terminal.applyThemeColors(theme: .codex, isDark: true)

        #expect(terminal.nativeBackgroundColor != litheBackground)
        #expect(terminal.terminal.backgroundColor != litheTerminalBackground)
        #expect(terminal.nativeBackgroundColor == LitheTheme.nsColor(.editor, theme: .codex, isDark: true))
    }

    @Test
    func terminalPaletteAppliesContrastGatePerImportedEntry() throws {
        func archive(_ color: NSColor) throws -> Data {
            try NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
        }
        let paleCyan = NSColor(srgbRed: 0, green: 0.9, blue: 0.9, alpha: 1)
        let darkGreen = NSColor(srgbRed: 0, green: 0.25, blue: 0.25, alpha: 1)
        let preferences: [String: Any] = [
            "Default Window Settings": "Selected",
            "Window Settings": ["Selected": [
                "ANSIBrightCyanColor": try archive(paleCyan),
                "ANSIBrightGreenColor": try archive(darkGreen)
            ]]
        ]

        let lightEditor = LitheTheme.nsColor(.editor, isDark: false)
        let gated = MacTerminalPalette(preferences: preferences, backgroundColor: lightEditor)
        #expect(gated.ansiColors[14] == nil)
        #expect(gated.ansiColors[10]?.green == UInt16((darkGreen.greenComponent * 65535).rounded()))

        let ungated = MacTerminalPalette(preferences: preferences)
        #expect(ungated.ansiColors[14]?.green == UInt16((paleCyan.greenComponent * 65535).rounded()))
    }

    @Test
    func lightFallbackANSIColorsMeetContrastInvariant() {
        let editor = LitheTheme.nsColor(.editor, isDark: false)
        let colors = MacTerminalPalette.fallbackANSIColors(isDark: false)
        #expect(colors.count == 16)
        for value in colors {
            let color = NSColor(
                srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255,
                alpha: 1
            )
            #expect(contrastRatio(color, against: editor) >= 4.5)
        }
    }

    private func contrastRatio(_ foreground: NSColor, against background: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            let color = color.usingColorSpace(.sRGB)!
            func linear(_ channel: CGFloat) -> CGFloat {
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.redComponent)
                + 0.7152 * linear(color.greenComponent)
                + 0.0722 * linear(color.blueComponent)
        }
        let foregroundLuminance = luminance(foreground)
        let backgroundLuminance = luminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    @Test
    func terminalTabFocusNotificationTracksResponderAndWindow() throws {
        let window = CursorFocusTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let editor = TerminalOtherResponderView(frame: NSRect(x: 0, y: 200, width: 400, height: 50))
        content.addSubview(terminal)
        content.addSubview(editor)

        let focusStates = OSAllocatedUnfairLock(initialState: [Bool]())
        let observer = NotificationCenter.default.addObserver(
            forName: LitheTerminalView.focusDidChange, object: terminal, queue: nil
        ) { notification in
            let focused = notification.userInfo?["focused"] as? Bool ?? false
            focusStates.withLock { $0.append(focused) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(window.makeFirstResponder(terminal))
        #expect(focusStates.withLock { $0.last } == true)
        #expect(window.makeFirstResponder(editor))
        #expect(focusStates.withLock { $0.last } == false)
        #expect(window.makeFirstResponder(terminal))
        #expect(focusStates.withLock { $0.last } == true)
        window.reportsKeyWindow = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(focusStates.withLock { $0.last } == false)
    }

    @Test
    func coreGraphicsCaretIsRemovedOutsideKeyboardOwner() throws {
        let window = CursorFocusTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let editor = TerminalOtherResponderView(frame: NSRect(x: 0, y: 200, width: 400, height: 50))
        content.addSubview(terminal)
        content.addSubview(editor)
        try terminal.setUseMetal(false)
        #expect(window.makeFirstResponder(terminal))
        terminal.showCursor(source: terminal.terminal)
        let focusedChildren = Set(terminal.subviews.map(ObjectIdentifier.init))

        #expect(window.makeFirstResponder(editor))
        let inactiveChildren = Set(terminal.subviews.map(ObjectIdentifier.init))
        #expect(focusedChildren.subtracting(inactiveChildren).count == 1,
                "The fallback caret must be removed, not left as an inactive outline")
        #expect(window.makeFirstResponder(terminal))
        #expect(Set(terminal.subviews.map(ObjectIdentifier.init)) == focusedChildren)

        terminal.terminal.hideCursor()
        #expect(window.makeFirstResponder(editor))
        #expect(window.makeFirstResponder(terminal))
        #expect(Set(terminal.subviews.map(ObjectIdentifier.init)) == inactiveChildren,
                "Focus must not reveal a cursor hidden by the shell")
    }

    @Test
    func onlyKeyboardOwnerDrawsVisibleMetalCursorAndPreservesShellStyle() throws {
        let window = CursorFocusTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let editor = TerminalOtherResponderView(frame: NSRect(x: 0, y: 200, width: 400, height: 50))
        let content = try #require(window.contentView)
        content.addSubview(terminal)
        content.addSubview(editor)
        let view = MTKView(frame: terminal.bounds, device: nil)
        let renderer = CursorDrawingRecorder()
        let focusDelegate = TerminalMetalFocusDelegate(view: view, terminalView: terminal, renderer: renderer)
        let requestedColor = NSColor.systemBlue
        terminal.caretColor = requestedColor

        for requestedStyle in [CursorStyle.blinkBlock, .blinkBar, .blinkUnderline, .steadyBar] {
            terminal.terminal.setCursorStyle(requestedStyle)
            #expect(window.makeFirstResponder(editor))
            // Even a stale terminal flag must not animate a background panel.
            terminal.hasFocus = true
            #expect(!terminal.hasFocus)
            renderer.onDraw = {
                #expect(terminal.terminal.options.cursorStyle == .steadyBlock)
                #expect(terminal.caretColor.alphaComponent == 0)
            }
            focusDelegate.draw(in: view)
            #expect(terminal.terminal.options.cursorStyle == requestedStyle)
            #expect(terminal.caretColor == requestedColor)

            #expect(window.makeFirstResponder(terminal))
            #expect(terminal.hasFocus)
            renderer.onDraw = {
                #expect(terminal.terminal.options.cursorStyle == requestedStyle)
                #expect(terminal.caretColor == requestedColor)
            }
            focusDelegate.draw(in: view)
        }
        #expect(renderer.drawCount == 8)
        let resized = CGSize(width: 640, height: 320)
        focusDelegate.mtkView(view, drawableSizeWillChange: resized)
        #expect(renderer.drawableSize == resized)
        window.reportsKeyWindow = false
        renderer.onDraw = {
            #expect(terminal.terminal.options.cursorStyle == .steadyBlock)
            #expect(terminal.caretColor.alphaComponent == 0)
        }
        focusDelegate.draw(in: view)
        #expect(!terminal.hasFocus)
    }

    @Test
    func focusChangesInvalidateTheMetalCursorWithoutShellOutput() {
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let renderer = CursorInvalidationRecordingView(frame: terminal.bounds, device: nil)
        terminal.addSubview(renderer)
        renderer.requestedDisplay = false

        terminal.hasFocus = true
        #expect(renderer.requestedDisplay)
        renderer.requestedDisplay = false
        terminal.hasFocus = false
        #expect(renderer.requestedDisplay, "The inactive cursor must repaint without waiting for shell output")
    }

    @Test
    func renderingSurfaceRoutesClicksToTerminal() {
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        // Reproduce the renderer's hit-testing hierarchy without requiring a GPU or shell.
        let renderer = CursorInvalidationRecordingView(frame: terminal.bounds, device: nil)
        terminal.addSubview(renderer)

        #expect(terminal.hitTest(NSPoint(x: 100, y: 100)) === terminal)
        #expect(terminal.hitTest(NSPoint(x: -1, y: 100)) == nil)
    }

    @Test
    func scrollbarRemainsInteractiveAboveRenderer() {
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        terminal.addSubview(MTKView(frame: terminal.bounds, device: nil))
        let scroller = NSScroller(frame: NSRect(x: 380, y: 0, width: 20, height: 200))
        terminal.addSubview(scroller)

        #expect(terminal.hitTest(NSPoint(x: 390, y: 100)) === scroller)
    }

    @Test
    func windowFocusChangesInvalidateBothCursorSurfaces() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let editor = TerminalOtherResponderView(frame: NSRect(x: 0, y: 200, width: 400, height: 50))
        content.addSubview(terminal)
        content.addSubview(editor)
        let renderer = CursorInvalidationRecordingView(frame: terminal.bounds, device: nil)
        terminal.addSubview(renderer)
        #expect(window.makeFirstResponder(editor))

        for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
            editor.needsDisplay = false
            renderer.requestedDisplay = false
            // Deliver the native lifecycle boundary directly; no real focus-stealing
            // window activation or wall-clock blink interval is needed by the test.
            NotificationCenter.default.post(name: name, object: window)
            #expect(editor.needsDisplay)
            #expect(renderer.requestedDisplay)
        }

        terminal.removeFromSuperview()
        editor.removeFromSuperview()
        editor.needsDisplay = false
        renderer.requestedDisplay = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!editor.needsDisplay, "Detached editors must release their window observers")
        #expect(!renderer.requestedDisplay, "Detached terminals must release their window observers")
    }

    @Test
    func clickingTerminalRestoresFocusAfterAnotherControl() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let editor = TerminalOtherResponderView(frame: NSRect(x: 0, y: 200, width: 400, height: 50))
        content.addSubview(terminal)
        content.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        editor.needsDisplay = false
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 100, y: 100),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))

        terminal.mouseDown(with: click)

        #expect(window.firstResponder === terminal)
        #expect(editor.needsDisplay, "Losing focus must immediately erase the editor's painted caret")
        editor.needsDisplay = false
        #expect(window.makeFirstResponder(editor))
        #expect(editor.needsDisplay, "Returning to the editor must restore its caret")
    }
}

@Suite("Terminal canvas compositing", .serialized)
@MainActor
struct TerminalCanvasCompositingTests {
    @Test
    func unmountedTerminalUsesAppAppearancePreference() {
        let terminal = LitheTerminalView(frame: .zero)
        terminal.appearance = NSAppearance(named: .darkAqua)
        terminal.preferredAppearanceIsDark = { false }

        terminal.applyThemeColors(theme: .lithe)

        let expected = LitheTheme.nsColor(.editor, theme: .lithe, isDark: false)
        #expect(terminal.window == nil)
        #expect(terminal.nativeBackgroundColor.isEqual(expected))
    }

    @Test
    func canvasLeavesSharedPaneBackgroundVisibleWithWallpaper() {
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        terminal.updateWorkbenchSurface(isVisible: true, theme: .lithe, isDark: false)
        #expect(terminal.nativeBackgroundColor.alphaComponent == 0)
        // Metal clear colors are premultiplied, so a transparent canvas clears to black rather than the workbench color.
        let clearColor = terminal.nativeBackgroundColor.usingColorSpace(.sRGB)
        #expect(clearColor?.redComponent == 0)
        #expect(clearColor?.greenComponent == 0)
        #expect(clearColor?.blueComponent == 0)
        #expect(terminal.layer?.backgroundColor == NSColor.clear.cgColor)
        #expect(terminal.layer?.isOpaque == false)
        let renderer = MTKView(frame: terminal.bounds, device: nil)
        terminal.addSubview(renderer)
        terminal.applyThemeColors(theme: .lithe, isDark: false)
        #expect(renderer.layer?.isOpaque == false)
        terminal.hasFocus = false
        #expect(renderer.layer?.isOpaque == false)
    }

    @Test
    func canvasOwnsOpaqueBackgroundWithoutWallpaper() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            terminal.appearance = NSAppearance(named: name)
            terminal.applyThemeColors(theme: .lithe, isDark: name == .darkAqua)
            let editorColor = LitheTheme.nsColor(.editor, isDark: name == .darkAqua)
            #expect(terminal.nativeBackgroundColor.alphaComponent == 1)
            #expect(terminal.nativeBackgroundColor.isEqual(editorColor))
            #expect(terminal.layer?.backgroundColor == editorColor.cgColor)
            #expect(terminal.layer?.isOpaque == true)
            let renderer = MTKView(frame: terminal.bounds, device: nil)
            terminal.addSubview(renderer)
            terminal.applyThemeColors(theme: .lithe, isDark: name == .darkAqua)
            #expect(renderer.layer?.isOpaque == true)
        }
    }

    @Test
    func canvasFollowsWorkbenchBackgroundChanges() {
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        terminal.appearance = NSAppearance(named: .aqua)
        terminal.applyThemeColors(theme: .lithe, isDark: false)
        let renderer = MTKView(frame: terminal.bounds, device: nil)
        terminal.addSubview(renderer)
        terminal.updateWorkbenchSurface(isVisible: true, theme: .lithe, isDark: false)
        #expect(terminal.nativeBackgroundColor.alphaComponent == 0)
        #expect(terminal.nativeBackgroundColor.usingColorSpace(.sRGB)?.redComponent == 0)
        #expect(terminal.layer?.backgroundColor == NSColor.clear.cgColor)
        #expect(terminal.layer?.isOpaque == false)
        #expect(renderer.layer?.isOpaque == false)
        terminal.updateWorkbenchSurface(isVisible: false, theme: .lithe, isDark: false)
        #expect(terminal.nativeBackgroundColor.alphaComponent == 1)
        #expect(terminal.layer?.isOpaque == true)
        #expect(renderer.layer?.isOpaque == true)
    }

    @Test
    func osc11ReportedBackgroundMatchesCanvasClearColor() throws {
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        terminal.appearance = NSAppearance(named: .aqua)
        terminal.applyThemeColors(theme: .lithe, isDark: false)
        let editorColor = LitheTheme.nsColor(.editor, theme: .lithe, isDark: false).usingColorSpace(.sRGB)
        let expected = try #require(editorColor)
        let reported = terminal.terminal.backgroundColor
        #expect(reported.red == UInt16((expected.redComponent * 65535).rounded()))
        #expect(reported.green == UInt16((expected.greenComponent * 65535).rounded()))
        #expect(reported.blue == UInt16((expected.blueComponent * 65535).rounded()))
        terminal.updateWorkbenchSurface(isVisible: true, theme: .lithe, isDark: false)
        let transparent = terminal.terminal.backgroundColor
        #expect(transparent.red == 0)
        #expect(transparent.green == 0)
        #expect(transparent.blue == 0)
    }

    @Test
    func mountedTerminalRefreshesTheSameSurfaceInDarkAppearance() async throws {
        try await assertMountedTerminalThemeRefresh(scheme: .dark)
    }

    @Test
    func mountedTerminalRefreshesTheSameSurfaceInLightAppearance() async throws {
        try await assertMountedTerminalThemeRefresh(scheme: .light)
    }

    private func assertMountedTerminalThemeRefresh(scheme: ColorScheme) async throws {
        let domain = "Lithe.TerminalThemeRefresh.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let originalTheme = AppThemeRuntime.shared.activeTheme
        defer {
            defaults.removePersistentDomain(forName: domain)
            AppThemeRuntime.shared.activate(originalTheme)
        }
        let isDark = scheme == .dark
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        settings.themePreference = isDark ? .dark : .light
        settings.colorTheme = .lithe
        let model = AppModel(settings: settings,
            services: MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        let terminal = LitheTerminalView(frame: .zero)
        let transport = ThemeRefreshTestTransport(view: terminal)
        let session = TerminalSession(transport: transport)
        session.start(in: URL(fileURLWithPath: "/workspace/theme-refresh"), shellPath: "/bin/zsh")
        let host = NSHostingView(rootView: TerminalSurfaceView(session: session)
            .environmentObject(model).environmentObject(settings).environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.contentView = host
        let initialBackground = LitheTheme.nsColor(.editor, theme: .lithe, isDark: isDark)
        let initialForeground = LitheTheme.nsColor(.primaryText, theme: .lithe, isDark: isDark)
        let initialDeadline = ContinuousClock().now.advanced(by: .seconds(2))
        while (!terminal.nativeBackgroundColor.isEqual(initialBackground)
            || !terminal.nativeForegroundColor.isEqual(initialForeground)),
            ContinuousClock().now < initialDeadline {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        #expect(terminal.nativeBackgroundColor.isEqual(initialBackground))
        #expect(terminal.nativeForegroundColor.isEqual(initialForeground))
        #expect(session.isRunning)
        let clock = ContinuousClock()
        for theme in [AppColorTheme.codex, .linear, .lithe] {
            settings.colorTheme = theme
            let expected = LitheTheme.nsColor(.editor, theme: theme, isDark: isDark)
            let expectedForeground = LitheTheme.nsColor(.primaryText, theme: theme, isDark: isDark)
            let deadline = clock.now.advanced(by: .seconds(2))
            while (!terminal.nativeBackgroundColor.isEqual(expected)
                || !terminal.nativeForegroundColor.isEqual(expectedForeground)),
                clock.now < deadline {
                host.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            let sRGB = try #require(expected.usingColorSpace(.sRGB))
            let reported = terminal.terminal.backgroundColor
            let reportedForeground = terminal.terminal.foregroundColor
            let expectedForegroundSRGB = try #require(expectedForeground.usingColorSpace(.sRGB))
            #expect(terminal.nativeBackgroundColor.isEqual(expected))
            #expect(terminal.nativeForegroundColor.isEqual(expectedForeground))
            #expect(reported.red == UInt16(sRGB.redComponent * 65535))
            #expect(reported.green == UInt16(sRGB.greenComponent * 65535))
            #expect(reported.blue == UInt16(sRGB.blueComponent * 65535))
            #expect(abs(Int(reportedForeground.red) - Int(expectedForegroundSRGB.redComponent * 65535)) <= 1)
            #expect(abs(Int(reportedForeground.green) - Int(expectedForegroundSRGB.greenComponent * 65535)) <= 1)
            #expect(abs(Int(reportedForeground.blue) - Int(expectedForegroundSRGB.blueComponent * 65535)) <= 1)
            #expect(session.isRunning)
        }
        session.stop()
        window.contentView = nil
        window.close()
        await model.shutdownProjectSession()
    }
}
@MainActor
private final class ThemeRefreshTestTransport: TerminalTransport {
    let nativeView: AnyObject
    var isRunning = false
    var processID: Int32? { isRunning ? 1234 : nil }
    var shellName = "zsh"
    var onTermination: ((Int32?) -> Void)?
    var onOutput: ((Data) -> Void)?
    var onTitle: ((String) -> Void)?
    var onDirectoryUpdate: ((String?) -> Void)?
    var onLink: ((String, [String: String]) -> Void)?

    init(view: LitheTerminalView) { nativeView = view }
    func defaultShellPath() -> String { "/bin/zsh" }
    func defaultEnvironment() -> [String: String] { [:] }
    func start(workingDirectory: String, shellPath: String, environment: [String: String]) throws { isRunning = true }
    func startProcess(_ launch: TerminalProcessLaunch, environment: [String: String]) throws -> Int32 { isRunning = true; return 1234 }
    func send(_ input: Data) throws {}
    func interrupt() throws {}
    func focus() {}
    func clear() {}
    func stop() { isRunning = false }
}

@MainActor
private final class CursorFocusTestWindow: NSWindow {
    var reportsKeyWindow = true
    override var isKeyWindow: Bool { reportsKeyWindow }
}

@MainActor
private final class CursorInvalidationRecordingView: MTKView {
    var requestedDisplay = false

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        requestedDisplay = true
        super.setNeedsDisplay(invalidRect)
    }
}

// Tests invoke these delegate callbacks synchronously on the main actor.
// Older SDKs expose MTKViewDelegate without actor isolation.
@MainActor
private final class CursorDrawingRecorder: NSObject, MTKViewDelegate {
    var onDraw: () -> Void = {}
    var drawCount = 0
    var drawableSize: CGSize?

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            drawCount += 1
            onDraw()
        }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated {
            drawableSize = size
        }
    }
}

/// The terminal must release its caret for any other keyboard owner, regardless
/// of which editor renderer the application embeds.
@MainActor
private final class TerminalOtherResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Appearance resolution behind the exported COLORFGBG and the OSC 11 answer.
@Suite("MacOS appearance resolution")
@MainActor
struct MacTerminalAppearanceResolutionTests {
    @Test
    func themePreferenceOverridesSystemAppearanceBeforeMount() {
        let transport = MacTerminalTransport(preferredAppearanceIsDark: { true })
        let view = transport.nativeView as! LitheTerminalView
        view.appearance = NSAppearance(named: .aqua)
        view.applyThemeColors(theme: LitheTheme.activeTheme)
        #expect(transport.reportsLightBackground == false)
    }

    @Test
    func effectiveAppearanceUsedWhenNoPreference() {
        let transport = MacTerminalTransport(preferredAppearanceIsDark: { nil })
        let view = transport.nativeView as! LitheTerminalView
        view.appearance = NSAppearance(named: .aqua)
        view.applyThemeColors(theme: LitheTheme.activeTheme)
        #expect(transport.reportsLightBackground == true)
    }

    @Test
    func wallpaperConfiguredBeforeSpawnReportsDarkAndAnswersBlack() {
        let transport = MacTerminalTransport(preferredAppearanceIsDark: { nil })
        let view = transport.nativeView as! LitheTerminalView
        view.appearance = NSAppearance(named: .aqua)
        view.applyThemeColors(theme: LitheTheme.activeTheme)
        #expect(transport.reportsLightBackground == true)
        transport.configureInitialSurface(showsWorkbenchBackground: true)
        #expect(transport.reportsLightBackground == false)
        // The canvas is transparent; OSC 11 answers this same black, so the env export stays consistent.
        #expect(view.nativeBackgroundColor == NSColor.black.withAlphaComponent(0))
    }
}
