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

        terminal.applyThemeColors(theme: .codex, isDark: true)

        #expect(terminal.nativeBackgroundColor != litheBackground)
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
    func `core graphics focus changes preserve shell cursor state`() throws {
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
        terminal.setCursorStyle(.steadyBar)
        terminal.applyThemeColors(theme: .lithe, isDark: true)
        // `caretColor` is not open, so Lithe records the requested theme caret in `applyThemeColors` and publishes it only while focused.
        let requestedCaret = NSColor(srgbRed: 0.35, green: 0.67, blue: 0.98, alpha: 1)
        #expect(window.makeFirstResponder(terminal))
        #expect(terminal.hasFocus)
        #expect(terminal.terminalStateSnapshot().cursorStyle == .steadyBar)
        #expect(terminal.caretColor == requestedCaret)

        // Lithe publishes the theme caret only while this view owns the keyboard.
        // The shell's requested cursor style must remain untouched.
        #expect(window.makeFirstResponder(editor))
        #expect(!terminal.hasFocus)
        #expect(terminal.terminalStateSnapshot().cursorStyle == .steadyBar)
        #expect(terminal.caretColor.alphaComponent == 0)
        #expect(window.makeFirstResponder(terminal))
        #expect(terminal.hasFocus)
        #expect(terminal.terminalStateSnapshot().cursorStyle == .steadyBar)
        #expect(terminal.caretColor == requestedCaret)
    }

    @Test
    func `only keyboard owner shows visible caret`() throws {
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
        terminal.applyThemeColors(theme: .lithe, isDark: true)
        // Lithe records the requested caret from the theme and publishes it only while this view owns the keyboard.
        let requestedColor = NSColor(srgbRed: 0.35, green: 0.67, blue: 0.98, alpha: 1)

        #expect(window.makeFirstResponder(terminal))
        #expect(terminal.hasFocus)
        #expect(terminal.caretColor == requestedColor)

        #expect(window.makeFirstResponder(editor))
        #expect(!terminal.hasFocus)
        #expect(terminal.caretColor.alphaComponent == 0,
                "A background terminal must not paint its caret")

        #expect(window.makeFirstResponder(terminal))
        #expect(terminal.hasFocus)
        #expect(terminal.caretColor == requestedColor)

        // OSC 12 sets the caret color directly.
        // The host keeps that color across focus changes instead of falling back to the theme color.
        terminal.caretColor = .systemRed
        #expect(window.makeFirstResponder(editor))
        #expect(terminal.caretColor.alphaComponent == 0)
        #expect(window.makeFirstResponder(terminal))
        #expect(terminal.hasFocus)
        #expect(terminal.caretColor == .systemRed,
                "An OSC 12 caret color must survive the focus round trip")

        // An OSC 12 write while unfocused must not paint a background caret.
        // Its color must survive until this view is focused again.
        #expect(window.makeFirstResponder(editor))
        terminal.caretColor = .systemGreen
        terminal.refreshCaretFocus()
        #expect(terminal.caretColor.alphaComponent == 0)
        #expect(window.makeFirstResponder(terminal))
        #expect(terminal.hasFocus)
        #expect(terminal.caretColor == .systemGreen,
                "An OSC 12 caret color set while unfocused must be restored")

        window.reportsKeyWindow = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!terminal.hasFocus)
        #expect(terminal.caretColor.alphaComponent == 0,
                "Resigning key must clear the caret while this view is still the responder")
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
        terminal.applyThemeColors(theme: .lithe, isDark: false)
        #expect(terminal.layer?.isOpaque == false)
        #expect(terminal.nativeBackgroundColor.alphaComponent == 0)
        terminal.hasFocus = false
        #expect(terminal.layer?.isOpaque == false)
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
            terminal.applyThemeColors(theme: .lithe, isDark: name == .darkAqua)
            #expect(terminal.layer?.isOpaque == true)
            #expect(terminal.nativeBackgroundColor.alphaComponent == 1)
        }
    }

    @Test
    func `attaching to window enables metal renderer`() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.borderless], backing: .buffered, defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView?.addSubview(terminal)

        guard !terminal.isUsingMetalRenderer else { return }
        // Staying on Core Graphics is only acceptable when this host genuinely cannot build the Metal device or shader pipeline.
        // Retrying the renderer distinguishes that from a regression in the attachment path.
        do {
            try terminal.setUseMetal(true)
        } catch {
            #expect(!terminal.isUsingMetalRenderer)
            return
        }
        Issue.record("Attaching the terminal to a window did not enable the Metal renderer")
    }

    @Test
    func canvasFollowsWorkbenchBackgroundChanges() {
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        terminal.appearance = NSAppearance(named: .aqua)
        terminal.applyThemeColors(theme: .lithe, isDark: false)
        terminal.updateWorkbenchSurface(isVisible: true, theme: .lithe, isDark: false)
        #expect(terminal.nativeBackgroundColor.alphaComponent == 0)
        #expect(terminal.nativeBackgroundColor.usingColorSpace(.sRGB)?.redComponent == 0)
        #expect(terminal.layer?.backgroundColor == NSColor.clear.cgColor)
        #expect(terminal.layer?.isOpaque == false)
        terminal.updateWorkbenchSurface(isVisible: false, theme: .lithe, isDark: false)
        #expect(terminal.nativeBackgroundColor.alphaComponent == 1)
        #expect(terminal.layer?.isOpaque == true)
    }

    @Test
    func osc11ReportedBackgroundMatchesCanvasClearColor() throws {
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        terminal.appearance = NSAppearance(named: .aqua)
        terminal.applyThemeColors(theme: .lithe, isDark: false)
        let editorColor = LitheTheme.nsColor(.editor, theme: .lithe, isDark: false).usingColorSpace(.sRGB)
        let expected = try #require(editorColor)
        let reported = try #require(terminal.nativeBackgroundColor.usingColorSpace(.sRGB))
        #expect(reported.redComponent == expected.redComponent)
        #expect(reported.greenComponent == expected.greenComponent)
        #expect(reported.blueComponent == expected.blueComponent)
        #expect(reported.alphaComponent == 1)
        terminal.updateWorkbenchSurface(isVisible: true, theme: .lithe, isDark: false)
        let transparent = try #require(terminal.nativeBackgroundColor.usingColorSpace(.sRGB))
        #expect(transparent.redComponent == 0)
        #expect(transparent.greenComponent == 0)
        #expect(transparent.blueComponent == 0)
        #expect(transparent.alphaComponent == 0)
    }

    @Test
    func mountedTerminalRefreshesTheSameSurfaceInDarkAppearance() async throws {
        try await assertMountedTerminalThemeRefresh(scheme: .dark)
    }

    @Test
    func mountedTerminalRefreshesTheSameSurfaceInLightAppearance() async throws {
        try await assertMountedTerminalThemeRefresh(scheme: .light)
    }

    /// SwiftTerm 1.99 round-trips native colors through its 16-bit terminal color model.
    /// The view's native colors therefore differ from the theme colors by encoding error.
    /// Compare components instead of using `isEqual`.
    private func colorsMatch(_ color: NSColor, _ expected: NSColor, tolerance: CGFloat = 0.001) -> Bool {
        guard let actual = color.usingColorSpace(.sRGB),
              let target = expected.usingColorSpace(.sRGB) else { return false }
        return abs(actual.redComponent - target.redComponent) <= tolerance
            && abs(actual.greenComponent - target.greenComponent) <= tolerance
            && abs(actual.blueComponent - target.blueComponent) <= tolerance
            && abs(actual.alphaComponent - target.alphaComponent) <= tolerance
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
        while !colorsMatch(terminal.nativeBackgroundColor, initialBackground)
            || !colorsMatch(terminal.nativeForegroundColor, initialForeground),
            ContinuousClock().now < initialDeadline
        {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        #expect(colorsMatch(terminal.nativeBackgroundColor, initialBackground))
        #expect(colorsMatch(terminal.nativeForegroundColor, initialForeground))
        #expect(session.isRunning)
        let clock = ContinuousClock()
        for theme in [AppColorTheme.codex, .linear, .lithe] {
            settings.colorTheme = theme
            let expected = LitheTheme.nsColor(.editor, theme: theme, isDark: isDark)
            let expectedForeground = LitheTheme.nsColor(.primaryText, theme: theme, isDark: isDark)
            let deadline = clock.now.advanced(by: .seconds(2))
            while !colorsMatch(terminal.nativeBackgroundColor, expected)
                || !colorsMatch(terminal.nativeForegroundColor, expectedForeground),
                clock.now < deadline
            {
                host.layoutSubtreeIfNeeded()
                await Task.yield()
            }
            let expectedSRGB = try #require(expected.usingColorSpace(.sRGB))
            let expectedForegroundSRGB = try #require(expectedForeground.usingColorSpace(.sRGB))
            let reported = try #require(terminal.nativeBackgroundColor.usingColorSpace(.sRGB))
            let reportedForeground = try #require(terminal.nativeForegroundColor.usingColorSpace(.sRGB))
            #expect(colorsMatch(terminal.nativeBackgroundColor, expected))
            #expect(colorsMatch(terminal.nativeForegroundColor, expectedForeground))
            #expect(abs(reported.redComponent - expectedSRGB.redComponent) <= 0.001)
            #expect(abs(reported.greenComponent - expectedSRGB.greenComponent) <= 0.001)
            #expect(abs(reported.blueComponent - expectedSRGB.blueComponent) <= 0.001)
            #expect(abs(reportedForeground.redComponent - expectedForegroundSRGB.redComponent) <= 0.001)
            #expect(abs(reportedForeground.greenComponent - expectedForegroundSRGB.greenComponent) <= 0.001)
            #expect(abs(reportedForeground.blueComponent - expectedForegroundSRGB.blueComponent) <= 0.001)
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
