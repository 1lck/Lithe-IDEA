import AppKit
import Foundation
import MetalKit
import SwiftTerm
import LitheTerminalModule

/// SwiftTerm's default link handler opens URLs in the system. Lithe needs the
/// link event so workspace-relative paths can open in its own editor instead.
final class LitheTerminalView: LocalProcessTerminalView {
    static let focusDidChange = Notification.Name("LitheTerminalView.focusDidChange")
    var onOpenLink: ((String, [String: String]) -> Void)?
    var onProcessOutput: ((Data) -> Void)?
    private var showsWorkbenchBackground = false
    private weak var metalActivationFailedWindow: NSWindow?
    private var metalFocusDelegates: [TerminalMetalFocusDelegate] = []
    private var shellShowsCursor = true
    /// App theme light/dark preference while the view is not yet in a window; nil follows the system appearance.
    var preferredAppearanceIsDark: (() -> Bool?)?
    private var lastReportedBackgroundPayload: String?
    private var backgroundChangeNotifications = MacTerminalBackgroundSubscription()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureRendererPolicy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureRendererPolicy()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
            if let window {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowFocusDidChange), name: name, object: window
                )
            }
        }
        windowFocusDidChange()
        guard let currentWindow = window,
              !isUsingMetalRenderer,
              currentWindow !== metalActivationFailedWindow else { return }

        do {
            try setUseMetal(true)
            metalActivationFailedWindow = nil
            invalidateCursorSurface()
        } catch {
            // A different window gets one fresh attempt because SwiftTerm's
            // CAMetalLayer must be rebound when the persistent terminal moves.
            metalActivationFailedWindow = currentWindow
            NSLog(
                "Lithe terminal Metal renderer could not be enabled; using Core Graphics: %@",
                String(describing: error)
            )
        }
    }

    private func configureRendererPolicy() {
        // Ghostty's renderer keeps unchanged terminal content on the GPU and
        // redraws only invalidated cells. SwiftTerm's persistent row mode gives
        // Lithe the same workload shape while its paused MTKView remains
        // event-driven instead of running a continuous display loop.
        metalBufferingMode = .perRowPersistent
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        // SwiftTerm's Metal surface only renders pixels. Returning it as the
        // mouse target leaves keyboard focus in the previously active editor.
        // Preserve interactive children such as the scrollbar and find field.
        return hitView is MTKView ? self : hitView
    }

    override func mouseDown(with event: NSEvent) {
        // Reclaim input before SwiftTerm handles selection or mouse reporting,
        // including when this persistent session has lost focus to an editor.
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override var hasFocus: Bool {
        // AppKit's actual responder is authoritative; SwiftTerm's cached flag
        // can outlive a responder transition while a persistent surface moves.
        get { window?.isKeyWindow == true && window?.firstResponder === self }
        set {
            super.hasFocus = newValue
            setNativeCursorVisible(newValue && window?.isKeyWindow == true && shellShowsCursor)
            invalidateCursorSurface()
            notifyFocusChange(newValue && window?.isKeyWindow == true)
        }
    }

    private func setNativeCursorVisible(_ visible: Bool) {
        if visible { super.showCursor(source: terminal) }
        else { super.hideCursor(source: terminal) }
    }

    @objc private func windowFocusDidChange() {
        setNativeCursorVisible(hasFocus && shellShowsCursor)
        invalidateCursorSurface()
        notifyFocusChange(hasFocus)
    }

    private func notifyFocusChange(_ focused: Bool) {
        NotificationCenter.default.post(
            name: Self.focusDidChange,
            object: self,
            userInfo: ["focused": focused]
        )
    }

    override func showCursor(source: Terminal) {
        shellShowsCursor = true
        if hasFocus { super.showCursor(source: source) }
        else { super.hideCursor(source: source) }
    }

    override func hideCursor(source: Terminal) {
        shellShowsCursor = false
        super.hideCursor(source: source)
    }

    @objc private func invalidateCursorSurface() {
        // SwiftTerm invalidates its Core Graphics caret on focus changes, but
        // its paused Metal surface also needs a frame when no output arrives.
        needsDisplay = true
        for case let renderer as MTKView in subviews {
            renderer.layer?.isOpaque = !showsWorkbenchBackground
            if !(renderer.delegate is TerminalMetalFocusDelegate), let delegate = renderer.delegate {
                let focusDelegate = TerminalMetalFocusDelegate(
                    view: renderer, terminalView: self, renderer: delegate
                )
                metalFocusDelegates.append(focusDelegate)
                renderer.delegate = focusDelegate
            }
            renderer.setNeedsDisplay(renderer.bounds)
        }
        metalFocusDelegates.removeAll { $0.view?.superview !== self }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let window else { return nil }
        LitheContextMenuPresenter.shared.show(
            items: [
                .action("Paste") { [weak self] in if let self { self.paste(self) } },
                .action("Copy") { [weak self] in if let self { self.copy(self) } },
                .action("Select All") { [weak self] in if let self { self.selectAll(self) } }
            ],
            at: window.convertPoint(toScreen: event.locationInWindow),
            appearance: effectiveAppearance,
            locale: .current
        )
        return nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeColors(theme: LitheTheme.activeTheme)
    }

    func applyThemeColors(theme: AppColorTheme, isDark requestedIsDark: Bool? = nil) {
        let isDark: Bool
        if let requestedIsDark {
            isDark = requestedIsDark
        } else if window == nil, let preferredAppearanceIsDark {
            isDark = preferredAppearanceIsDark()
                ?? (effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        } else {
            isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        let editorColor = LitheTheme.nsColor(.editor, theme: theme, isDark: isDark)
        let palette = MacTerminalPalette(
            preferences: UserDefaults.standard.persistentDomain(forName: "com.apple.Terminal"),
            backgroundColor: editorColor
        )
        // The SwiftUI pane supplies the shared editor color or wallpaper.
        // Canvas background: no wallpaper → opaque editor color, wallpaper → clear to (0, 0, 0, 0).
        // The pane behind already paints the editor color, and a transparent canvas lets the compositor blend it twice.
        // Metal clear colors are premultiplied; RGB with zero alpha over-exposes glyph edges on light backgrounds.
        let showsWallpaper = showsWorkbenchBackground
        nativeBackgroundColor = showsWallpaper ? .black.withAlphaComponent(0) : editorColor
        layer?.backgroundColor = (showsWallpaper ? NSColor.clear : editorColor).cgColor
        layer?.isOpaque = !showsWallpaper
        for case let renderer as MTKView in subviews {
            renderer.layer?.isOpaque = !showsWallpaper
        }
        // OSC 11 answers with this same color.
        // With a wallpaper the canvas is transparent, so applications are told black.
        // Reporting an opaque color there would make the compositor blend it twice.
        // Terminal.app profiles may use a foreground color that assumes their
        // own opaque background. The terminal is composited over Lithe's
        // editor or wallpaper, so keep the default text tied to the app theme.
        nativeForegroundColor = LitheTheme.nsColor(.primaryText, theme: theme, isDark: isDark)
        caretColor = isDark
            ? NSColor(srgbRed: 0.35, green: 0.67, blue: 0.98, alpha: 1)
            : NSColor(srgbRed: 0.18, green: 0.43, blue: 0.79, alpha: 1)
        selectedTextBackgroundColor = isDark
            ? NSColor(srgbRed: 0.16, green: 0.31, blue: 0.48, alpha: 1)
            : NSColor(srgbRed: 0.69, green: 0.82, blue: 0.98, alpha: 1)
        // Fall back per entry to the existing palette, including IDEA's
        // BLOCK_TERMINAL_BLUE and BLOCK_TERMINAL_BLUE_BRIGHT.
        installColors(MacTerminalPalette.fallbackANSIColors(isDark: isDark).enumerated().map { index, fallback in
            palette.ansiColors[index] ?? SwiftTerm.Color(
                red: UInt16((fallback >> 16) & 0xff) * 257,
                green: UInt16((fallback >> 8) & 0xff) * 257,
                blue: UInt16(fallback & 0xff) * 257
            )
        })
        needsDisplay = true
        reportBackgroundChangeIfNeeded()
    }

    /// Reports background changes only to programs subscribed to kitty DEC mode 2031.
    private func reportBackgroundChangeIfNeeded() {
        let payload = MacTerminalBackgroundReporting.osc11Payload(for: nativeBackgroundColor)
        guard payload != lastReportedBackgroundPayload else { return }
        lastReportedBackgroundPayload = payload
        guard process.running,
              let notification = MacTerminalBackgroundReporting.changeNotification(
                for: nativeBackgroundColor,
                isSubscribed: backgroundChangeNotifications.isSubscribed
              ) else { return }
        terminal.sendResponse(text: notification)
    }

    func updateWorkbenchSurface(isVisible: Bool) {
        showsWorkbenchBackground = isVisible
        applyThemeColors(theme: LitheTheme.activeTheme)
    }

    func updateWorkbenchSurface(isVisible: Bool, theme: AppColorTheme, isDark: Bool) {
        showsWorkbenchBackground = isVisible
        applyThemeColors(theme: theme, isDark: isDark)
    }


    override func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        onOpenLink?(link, params)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        backgroundChangeNotifications.feed(slice)
        onProcessOutput?(Data(slice))
        super.dataReceived(slice: slice)
    }

    func resetBackgroundChangeNotifications() {
        backgroundChangeNotifications.reset()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}


/// Reports changed backgrounds to subscribers; kitty DSR 997 uses 1 for dark and 2 for light.
enum MacTerminalBackgroundReporting {
    static func osc11Payload(for color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func channel(_ value: CGFloat) -> String {
            String(format: "%04x", UInt16(max(0, min(1, value)) * 65535))
        }
        return "rgb:\(channel(red))/\(channel(green))/\(channel(blue))"
    }

    static func reportsDarkBackground(for color: NSColor) -> Bool {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linearize(_ component: CGFloat) -> Double {
            let value = min(1, max(0, Double(component)))
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
        return luminance < 0.5
    }

    static func changeNotification(for color: NSColor, isSubscribed: Bool) -> String? {
        guard isSubscribed else { return nil }
        let backgroundState = reportsDarkBackground(for: color) ? 1 : 2
        return "\u{1b}]11;\(osc11Payload(for: color))\u{1b}\\\u{1b}[?997;\(backgroundState)n"
    }
}

/// Tracks kitty DEC mode 2031 so change notifications are sent only to programs that requested them.
struct MacTerminalBackgroundSubscription {
    private(set) var isSubscribed = false
    private var pendingEscape: [UInt8] = []

    private static let escape = UInt8(0x1b)
    private static let mode2031: [UInt8] = [0x32, 0x30, 0x33, 0x31]
    private static let altScreenModes: [[UInt8]] = [
        [0x34, 0x37],
        [0x31, 0x30, 0x34, 0x37],
        [0x31, 0x30, 0x34, 0x39],
    ]
    private static let maximumSequenceLength = 64

    init() {
        pendingEscape.reserveCapacity(Self.maximumSequenceLength)
    }

    mutating func feed<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for byte in bytes {
            if pendingEscape.isEmpty {
                if byte == Self.escape { pendingEscape.append(byte) }
                continue
            }
            if byte == Self.escape {
                pendingEscape = [Self.escape]
                continue
            }
            pendingEscape.append(byte)
            if pendingEscape == [Self.escape, 0x63] {
                isSubscribed = false
                pendingEscape.removeAll(keepingCapacity: true)
                continue
            }
            if pendingEscape.count == 2 {
                if byte != 0x5b { pendingEscape.removeAll(keepingCapacity: true) }
                continue
            }
            if pendingEscape.count == 3 {
                if byte != 0x3f { pendingEscape.removeAll(keepingCapacity: true) }
                continue
            }
            if (0x40...0x7e).contains(byte) {
                if byte == 0x68 || byte == 0x6c,
                   contains(Self.mode2031, in: pendingEscape[3..<(pendingEscape.count - 1)]) {
                    isSubscribed = byte == 0x68
                } else if byte == 0x6c,
                          leavesAltScreen(pendingEscape[3..<(pendingEscape.count - 1)]) {
                    // A subscribed TUI runs inside the alternate screen; when it leaves, the shell must not inherit pushes.
                    isSubscribed = false
                }
                pendingEscape.removeAll(keepingCapacity: true)
            } else if pendingEscape.count >= Self.maximumSequenceLength {
                pendingEscape.removeAll(keepingCapacity: true)
            }
        }
    }

    mutating func reset() {
        isSubscribed = false
        pendingEscape.removeAll(keepingCapacity: true)
    }

    private func contains(_ parameter: [UInt8], in parameters: ArraySlice<UInt8>) -> Bool {
        var start = parameters.startIndex
        for index in parameters.indices where parameters[index] == 0x3b {
            if parameters[start..<index].elementsEqual(parameter) { return true }
            start = parameters.index(after: index)
        }
        return parameters[start..<parameters.endIndex].elementsEqual(parameter)
    }

    private func leavesAltScreen(_ parameters: ArraySlice<UInt8>) -> Bool {
        Self.altScreenModes.contains { contains($0, in: parameters) }
    }
}

/// Read colors from Terminal.app's default profile. ANSI entries are imported
/// only when their WCAG contrast against Lithe's editor background is at least 4.5:1.
/// Missing or rejected entries fall back to Lithe's theme-aware ANSI defaults.
struct MacTerminalPalette {
    let textColor: NSColor?
    let ansiColors: [SwiftTerm.Color?]

    init(preferences: [String: Any]?, backgroundColor: NSColor? = nil) {
        let name = preferences?["Default Window Settings"] as? String ?? ""
        let profiles = preferences?["Window Settings"] as? [String: [String: Any]]
        let profile = profiles?[name] ?? [:]
        textColor = Self.decodeColor(profile["TextColor"])
        let names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        let usableBackground = backgroundColor.flatMap(Self.sRGBComponents)
        ansiColors = (names + names.map { "Bright" + $0 }).map { name in
            guard let color = Self.decodeColor(profile["ANSI\(name)Color"]) else { return nil }
            if let usableBackground, !Self.hasSufficientContrast(color, against: usableBackground) { return nil }
            return SwiftTerm.Color(
                red: UInt16((color.redComponent * 65535).rounded()),
                green: UInt16((color.greenComponent * 65535).rounded()),
                blue: UInt16((color.blueComponent * 65535).rounded())
            )
        }
    }

    static func fallbackANSIColors(isDark: Bool) -> [UInt32] {
        [
            isDark ? 0x000000 : 0x1F2328, isDark ? 0x990001 : 0xCF222E,
            isDark ? 0x00A603 : 0x1A7F37, isDark ? 0x999900 : 0x9A6700,
            isDark ? 0x5594FA : 0x0969DA, isDark ? 0xB200B2 : 0x8250DF,
            isDark ? 0x00A5B2 : 0x0A6670, isDark ? 0xBFBFBF : 0x59636E,
            isDark ? 0x8A898A : 0x59636E, isDark ? 0xE50001 : 0xA40E26,
            isDark ? 0x00D800 : 0x116329, isDark ? 0xE5E500 : 0x7D4E00,
            isDark ? 0x3399FF : 0x0550AE, isDark ? 0xE500E5 : 0x6639BA,
            isDark ? 0x00E5E5 : 0x055B63, isDark ? 0xE5E5E5 : 0x3D444D
        ]
    }

    private typealias SRGBComponents = (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
    private typealias LinearRGB = (red: CGFloat, green: CGFloat, blue: CGFloat)

    private static func sRGBComponents(_ color: NSColor) -> SRGBComponents? {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        let components = (color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
        guard components.0.isFinite, components.1.isFinite, components.2.isFinite, components.3.isFinite,
              (0...1).contains(components.0), (0...1).contains(components.1),
              (0...1).contains(components.2), (0...1).contains(components.3) else { return nil }
        return (components.0, components.1, components.2, components.3)
    }

    private static func hasSufficientContrast(_ color: NSColor, against background: SRGBComponents) -> Bool {
        guard let foreground = sRGBComponents(color) else { return false }
        let white: LinearRGB = (1, 1, 1)
        let backgroundLinear = composite(background, over: white)
        let foregroundLinear = composite(foreground, over: backgroundLinear)
        let backgroundLuminance = luminance(backgroundLinear)
        let foregroundLuminance = luminance(foregroundLinear)
        let lighter = max(backgroundLuminance, foregroundLuminance)
        let darker = min(backgroundLuminance, foregroundLuminance)
        return (lighter + 0.05) / (darker + 0.05) >= 4.5
    }

    private static func composite(_ color: SRGBComponents, over background: LinearRGB) -> LinearRGB {
        let alpha = color.alpha
        return (
            linearize(color.red) * alpha + background.red * (1 - alpha),
            linearize(color.green) * alpha + background.green * (1 - alpha),
            linearize(color.blue) * alpha + background.blue * (1 - alpha)
        )
    }

    private static func linearize(_ channel: CGFloat) -> CGFloat {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    private static func luminance(_ color: LinearRGB) -> CGFloat {
        0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
    }

    private static func decodeColor(_ value: Any?) -> NSColor? {
        guard let data = value as? Data,
              let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data),
              let color = decoded.usingColorSpace(.sRGB),
              [color.redComponent, color.greenComponent, color.blueComponent].allSatisfy({
                  $0.isFinite && (0...1).contains($0)
              }) else { return nil }
        return color
    }
}

/// SwiftTerm 1.15's Metal blink timer ignores focus. Draw the inactive cursor
/// transparently with a steady style, preserving shell state while hiding both
/// the caret and its blink animation outside the actual keyboard owner.
final class TerminalMetalFocusDelegate: NSObject, MTKViewDelegate {
    weak var view: MTKView?
    private weak var terminalView: LitheTerminalView?
    private let renderer: MTKViewDelegate

    init(view: MTKView, terminalView: LitheTerminalView, renderer: MTKViewDelegate) {
        self.view = view
        self.terminalView = terminalView
        self.renderer = renderer
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.mtkView(view, drawableSizeWillChange: size)
    }

    func draw(in view: MTKView) {
        guard let terminalView, !terminalView.hasFocus else {
            renderer.draw(in: view)
            return
        }
        let requestedStyle = terminalView.terminal.options.cursorStyle
        let requestedColor = terminalView.caretColor
        terminalView.terminal.options.cursorStyle = .steadyBlock
        terminalView.caretColor = .clear
        defer {
            terminalView.terminal.options.cursorStyle = requestedStyle
            terminalView.caretColor = requestedColor
        }
        // MTKView's paused, event-driven draw is synchronous on the main thread;
        // restore the protocol state before any subsequent shell input is parsed.
        renderer.draw(in: view)
    }
}

/// Owns one persistent SwiftTerm surface and the local PTY process connected to it.
/// The surface intentionally lives with the session instead of the SwiftUI view so
/// switching terminal tabs or hiding the tool window does not reset a TUI screen.
@MainActor
final class MacTerminalTransport: NSObject, TerminalTransport, @preconcurrency LocalProcessTerminalViewDelegate {
    static func availableShells(fileManager: FileManager = .default) -> [String] {
        MacTerminalShellDiscovery.availableShells(fileManager: fileManager)
    }
    let view: LitheTerminalView

    var onTermination: ((Int32?) -> Void)?
    var onOutput: ((Data) -> Void)?
    var onTitle: ((String) -> Void)?
    var onDirectoryUpdate: ((String?) -> Void)?
    var onLink: ((String, [String: String]) -> Void)?

    private var selectedShellPath: String?
    private var suppressNextTermination = false
    private let stoppedChildProcessReaper = MacStoppedChildProcessReaper()
    /// The PTY child is a session leader (`forkpty` calls `setsid`), so every
    /// job started in this terminal keeps its PID as session ID.
    private var session: MacTerminalSessionOwnership?
    private var launchedInteractiveShell = false
    private var pendingSessionTermination: Task<Void, Never>?

    var isRunning: Bool {
        view.process.running
    }

    var processID: Int32? {
        let processID = view.process.shellPid
        return processID > 0 ? processID : nil
    }

    var shellName: String {
        guard let selectedShellPath else { return "Shell" }
        return URL(fileURLWithPath: selectedShellPath).lastPathComponent
    }

    var nativeView: AnyObject { view }

    func configureInitialSurface(showsWorkbenchBackground: Bool) {
        view.updateWorkbenchSurface(isVisible: showsWorkbenchBackground)
    }

    // Keep the exported COLORFGBG in sync with the OSC 11 answer: wallpaper transparency reports black, so it must export dark.
    var reportsLightBackground: Bool? { !MacTerminalBackgroundReporting.reportsDarkBackground(for: view.nativeBackgroundColor) }

    private let scrollbackLines: Int

    init(scrollbackLines: Int = 2_000, preferredAppearanceIsDark: (() -> Bool?)? = nil) {
        self.scrollbackLines = scrollbackLines
        view = LitheTerminalView(frame: .zero)
        super.init()

        view.processDelegate = self
        view.onOpenLink = { [weak self] link, params in
            self?.onLink?(link, params)
        }
        view.onProcessOutput = { [weak self] data in
            self?.onOutput?(data)
        }
        view.font = Self.preferredTerminalFont()
        view.preferredAppearanceIsDark = preferredAppearanceIsDark
        view.applyThemeColors(theme: LitheTheme.activeTheme)
        view.allowMouseReporting = true
        view.linkReporting = .implicit
        view.linkHighlightMode = .hoverWithModifier

        var options = view.terminal.options
        options.termName = "xterm-256color"
        options.scrollback = scrollbackLines
        view.terminal.options = options
        view.terminal.setup(isReset: false)
    }

    private static func preferredTerminalFont() -> NSFont {
        let size: CGFloat = 12.5
        let fontNames = [
            "MesloLGS Nerd Font Mono",
            "JetBrainsMono Nerd Font Mono",
            "Hack Nerd Font Mono",
            "FiraCode Nerd Font Mono",
            "IosevkaTerm Nerd Font Mono",
            "Menlo"
        ]

        for name in fontNames {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func defaultShellPath() -> String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    var termProgramVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    func defaultEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment
    }

    func start(
        workingDirectory: String,
        shellPath: String,
        environment: [String: String]
    ) throws {
        _ = try startProcess(
            TerminalProcessLaunch(
                title: nil,
                executablePath: shellPath,
                arguments: MacTerminalShellDiscovery.startupArguments(for: shellPath),
                workingDirectory: workingDirectory
            ),
            environment: environment
        )
        launchedInteractiveShell = true
    }

    func startProcess(
        _ launch: TerminalProcessLaunch,
        environment: [String: String]
    ) throws -> Int32 {
        stop()
        suppressNextTermination = false
        launchedInteractiveShell = false
        let executablePath = try resolveExecutablePath(
            launch.executablePath,
            workingDirectory: launch.workingDirectory,
            environment: environment
        )
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: launch.workingDirectory,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw terminalError("The terminal working directory does not exist: \(launch.workingDirectory)")
        }
        selectedShellPath = executablePath

        view.terminal.resetToInitialState()
        view.resetBackgroundChangeNotifications()
        var options = view.terminal.options
        options.termName = environment["TERM"] ?? "xterm-256color"
        view.terminal.options = options
        view.terminal.setup(isReset: false)

        let environmentArray = environment.keys.sorted().map { key in
            "\(key)=\(environment[key] ?? "")"
        }

        view.startProcess(
            executable: executablePath,
            args: launch.arguments,
            environment: environmentArray,
            currentDirectory: launch.workingDirectory
        )

        guard view.process.running, let processID else {
            throw terminalError("Unable to start \(executablePath)")
        }
        session = MacProcessTable.info(processID: processID).map { MacTerminalSessionOwnership(leader: $0.identity) }
        return processID
    }

    func send(_ input: Data) throws {
        guard view.process.running else { return }
        view.process.send(data: Array(input)[...])
    }

    func interrupt() throws {
        guard view.process.running else { return }
        view.process.send(data: [UInt8(0x03)][...])
    }

    func focus() {
        guard let window = view.window else { return }
        window.makeFirstResponder(view)
    }

    func clear() {
        view.terminal.resetToInitialState()
    }

    func stop() {
        if let session {
            self.session = nil
            let previous = pendingSessionTermination
            // Closing the PTY only hangs up the foreground job; background and
            // disowned jobs live in other process groups of the same session.
            let gracePeriod = Self.terminationGracePeriod(settings: MacProcessSupervisor.storedSettings())
            pendingSessionTermination = Task {
                await previous?.value
                await MacProcessSessionTerminator.terminate(session, gracePeriod: gracePeriod)
            }
        }
        guard let processID else { return }
        suppressNextTermination = true
        if view.process.running {
            view.terminate()
        }
        stoppedChildProcessReaper.reapWhenExited(processID)
    }

    static func terminationGracePeriod(settings: ProcessTerminationSettings) -> Duration {
        .seconds(settings.gracefulStopSeconds)
    }

    func stopAndWait() async {
        stop()
        await pendingSessionTermination?.value
    }

    func runningPrograms() -> [TerminalRunningProgram] {
        guard let session else { return [] }
        return Self.runningPrograms(
            in: session.members(),
            sessionLeader: session.leader,
            interactiveShellPath: launchedInteractiveShell ? selectedShellPath : nil,
            arguments: MacProcessTable.arguments,
            listeningTCPPorts: MacProcessTable.listeningTCPPorts
        )
    }

    static func runningPrograms(
        in members: [MacProcessInfo],
        sessionLeader: MacProcessIdentity,
        interactiveShellPath: String?,
        arguments: (Int32) -> MacProcessArguments?,
        listeningTCPPorts: (Int32) -> [Int]
    ) -> [TerminalRunningProgram] {
        let programs = members.filter { member in
            guard member.identity == sessionLeader,
                  let interactiveShellPath,
                  let executablePath = arguments(member.processID)?.executablePath,
                  !executablePath.isEmpty else { return true }
            // exec keeps the PID and start time. Only omit the original shell
            // while the live executable still matches; unreadable evidence is
            // conservatively busy. Children without job control share its group
            // and must remain visible in the close/quit confirmation.
            return URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().standardizedFileURL
                != URL(fileURLWithPath: interactiveShellPath).resolvingSymlinksInPath().standardizedFileURL
        }
        return Dictionary(grouping: programs, by: \.processGroupID)
            .values
            .compactMap { group -> TerminalRunningProgram? in
                guard let representative = group.first(where: { $0.processID == $0.processGroupID })
                    ?? group.min(by: { $0.processID < $1.processID }) else { return nil }
                let commandLine = arguments(representative.processID)?.commandLine
                    ?? representative.name
                let ports = Set(group.flatMap { listeningTCPPorts($0.processID) })
                return TerminalRunningProgram(
                    processID: representative.processID,
                    commandLine: commandLine,
                    listeningPorts: ports.sorted(),
                    startedAt: Date(timeIntervalSince1970: Double(representative.identity.startTime) / 1_000_000)
                )
            }
            .sorted { $0.processID < $1.processID }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onTitle?(title)
    }

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        onDirectoryUpdate?(directory)
    }

    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        // Jobs that outlived the shell stay stoppable from this tab, but only by
        // identity: the session ID is reusable once they are gone too.
        if session?.pinMembers() == false { session = nil }
        if suppressNextTermination {
            suppressNextTermination = false
            return
        }
        onTermination?(exitCode)
    }

    private func resolveExecutablePath(
        _ executablePath: String,
        workingDirectory: String,
        environment: [String: String]
    ) throws -> String {
        let fileManager = FileManager.default
        let candidate: String?
        if executablePath.contains("/") {
            let url = executablePath.hasPrefix("/")
                ? URL(fileURLWithPath: executablePath)
                : URL(fileURLWithPath: workingDirectory, isDirectory: true)
                    .appendingPathComponent(executablePath)
            candidate = url.standardizedFileURL.path
        } else {
            candidate = environment["PATH"]?
                .split(separator: ":", omittingEmptySubsequences: false)
                .map(String.init)
                .map { directory in
                    URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent(executablePath)
                        .standardizedFileURL.path
                }
                .first { fileManager.isExecutableFile(atPath: $0) }
        }
        guard let candidate, fileManager.isExecutableFile(atPath: candidate) else {
            throw terminalError("The terminal executable is unavailable: \(executablePath)")
        }
        return candidate
    }

    private func terminalError(_ message: String) -> NSError {
        NSError(
            domain: "Lithe.Terminal",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
