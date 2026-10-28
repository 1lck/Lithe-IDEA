import AppKit
import Foundation
import MetalKit
import SwiftTerm
import LitheTerminalModule
import os

/// SwiftTerm's default link handler opens URLs in the system. Lithe needs the
/// link event so workspace-relative paths can open in its own editor instead.
final class LitheTerminalView: SwiftTerm.TerminalView, SwiftTerm.TerminalViewDelegate {
    static let focusDidChange = Notification.Name("LitheTerminalView.focusDidChange")
    var onOpenLink: ((String, [String: String]) -> Void)?
    var onTitle: ((String) -> Void)?
    var onDirectoryUpdate: ((String?) -> Void)?
    var onProcessTermination: ((Int32?) -> Void)?
    private nonisolated let processHostLock = NSLock()
    private nonisolated(unsafe) var storedProcessHost: MacTerminalProcessHost?
    /// Lock-protected because the parse-thread response path reads it.
    nonisolated var processHost: MacTerminalProcessHost? {
        get {
            processHostLock.lock()
            defer { processHostLock.unlock() }
            return storedProcessHost
        }
        set {
            processHostLock.lock()
            storedProcessHost = newValue
            processHostLock.unlock()
        }
    }
    private var showsWorkbenchBackground = false
    private var requestedCaretColor = NSColor.selectedControlColor
    private var visibleCaretColor: NSColor?
    private nonisolated let caretRefreshLock = NSLock()
    private nonisolated(unsafe) var caretRefreshScheduled = false
    private nonisolated(unsafe) var caretRefreshPending = false
    /// App theme light/dark preference while the view is not yet in a window; nil follows the system appearance.
    var preferredAppearanceIsDark: (() -> Bool?)?
    private static let logger = Logger(subsystem: "com.openres.Lithe", category: "Terminal")
    /// Windows whose Metal enablement already failed, so the fallback is logged once per window.
    private let metalFallbackWindows = NSHashTable<NSWindow>.weakObjects()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        terminalDelegate = self
    }

    init(frame: NSRect, font: NSFont?, startupOptions: TerminalOptions) {
        super.init(frame: frame, font: font, options: startupOptions)
        terminalDelegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        terminalDelegate = self
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
        enableMetalRendererIfAvailable()
    }

    /// Enables the Metal renderer once the view has a window to bind its `CAMetalLayer` to.
    /// A host without a usable Metal device or shader pipeline keeps the Core Graphics renderer.
    /// That fallback is logged once per window rather than thrown at the embedding view.
    private func enableMetalRendererIfAvailable() {
        guard let window, !isUsingMetalRenderer else { return }
        do {
            try setUseMetal(true)
            metalFallbackWindows.remove(window)
        } catch {
            guard !metalFallbackWindows.contains(window) else { return }
            metalFallbackWindows.add(window)
            Self.logger.error(
                "Metal renderer unavailable; keeping Core Graphics: \(String(describing: error), privacy: .public)",
            )
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        // SwiftTerm's Metal surface only renders pixels. Returning it as the
        // mouse target leaves keyboard focus in the previously active editor.
        // Preserve interactive children such as the scrollbar and find field.
        if hitView is MTKView {
            return self
        }
        if hitView?.layer is CAMetalLayer {
            return self
        }
        return hitView
    }

    override func mouseDown(with event: NSEvent) {
        // Reclaim input before SwiftTerm handles selection or mouse reporting,
        // including when this persistent session has lost focus to an editor.
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override var hasFocus: Bool {
        // SwiftTerm's cached flag is part of the answer: become/resign and the other first-responder transitions keep it synchronized.
        // AppKit's key-window and responder state guard against a stale cache while a persistent surface moves between windows.
        get { super.hasFocus && window?.isKeyWindow == true && window?.firstResponder === self }
        set {
            super.hasFocus = newValue
            applyCaretFocus(newValue && window?.isKeyWindow == true)
            invalidateCursorSurface()
            notifyFocusChange(newValue && window?.isKeyWindow == true)
        }
    }

    /// Hides the caret on an unfocused surface and restores the color that was visible there.
    /// An application-set OSC 12 color is therefore not replaced by Lithe's theme color on the next focus transition.
    private func applyCaretFocus(_ focused: Bool) {
        if focused {
            let color = super.caretColor.alphaComponent > 0
                ? super.caretColor
                : (visibleCaretColor ?? requestedCaretColor)
            super.caretColor = color
            visibleCaretColor = nil
        } else if super.caretColor.alphaComponent > 0 {
            visibleCaretColor = super.caretColor
            super.caretColor = .clear
        }
    }

    /// Records the theme caret while keeping the inactive surface transparent.
    ///
    /// SwiftTerm's `caretColor` is public but not open, so Lithe cannot override it.
    /// Every theme write goes through this helper instead.
    private func setCaretColor(_ color: NSColor) {
        let previous = requestedCaretColor
        requestedCaretColor = color
        if hasFocus {
            super.caretColor = color
            visibleCaretColor = nil
        } else {
            if super.caretColor.alphaComponent > 0 {
                visibleCaretColor = super.caretColor
            }
            if visibleCaretColor == nil || visibleCaretColor == previous {
                visibleCaretColor = color
            }
            super.caretColor = .clear
        }
    }

    /// Re-applies focus state after OSC 12 wrote the caret directly on main.
    func refreshCaretFocus() {
        guard !hasFocus else { return }
        applyCaretFocus(false)
        invalidateCursorSurface()
    }

    /// Coalesces caret refresh requests from the IO parse thread.
    /// At most one main-queue refresh is queued, but a request that arrives while the refresh runs schedules one more.
    /// An OSC 12 hop dispatched after the current refresh still gets the unfocused caret cleared.
    nonisolated func requestCaretRefresh() {
        caretRefreshLock.lock()
        caretRefreshPending = true
        if caretRefreshScheduled {
            caretRefreshLock.unlock()
            return
        }
        caretRefreshScheduled = true
        caretRefreshLock.unlock()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.runCaretRefresh()
            }
        }
    }

    private func runCaretRefresh() {
        caretRefreshLock.lock()
        caretRefreshPending = false
        caretRefreshScheduled = false
        caretRefreshLock.unlock()
        refreshCaretFocus()
        caretRefreshLock.lock()
        let again = caretRefreshPending
        caretRefreshLock.unlock()
        if again {
            requestCaretRefresh()
        }
    }

    @objc private func windowFocusDidChange() {
        applyCaretFocus(hasFocus)
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

    @objc private func invalidateCursorSurface() {
        needsDisplay = true
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
        layer?.isOpaque = !showsWallpaper
        // OSC 11 answers with this same color.
        // With a wallpaper the canvas is transparent, so applications are told black.
        // Reporting an opaque color there would make the compositor blend it twice.
        // Terminal.app profiles may use a foreground color that assumes their
        // own opaque background. The terminal is composited over Lithe's
        // editor or wallpaper, so keep the default text tied to the app theme.
        nativeForegroundColor = LitheTheme.nsColor(.primaryText, theme: theme, isDark: isDark)
        setCaretColor(isDark
            ? NSColor(srgbRed: 0.35, green: 0.67, blue: 0.98, alpha: 1)
            : NSColor(srgbRed: 0.18, green: 0.43, blue: 0.79, alpha: 1))
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
        updateColorScheme(showsWallpaper || isDark ? .dark : .light, notify: true)
        needsDisplay = true
    }

    func updateWorkbenchSurface(isVisible: Bool) {
        showsWorkbenchBackground = isVisible
        applyThemeColors(theme: LitheTheme.activeTheme)
    }

    func updateWorkbenchSurface(isVisible: Bool, theme: AppColorTheme, isDark: Bool) {
        showsWorkbenchBackground = isVisible
        applyThemeColors(theme: theme, isDark: isDark)
    }

    /// Current PTY window size derived from the rendered terminal grid.
    func currentWindowSize() -> winsize {
        let dimensions = terminalDimensions
        return windowSize(cols: dimensions.cols, rows: dimensions.rows)
    }

    private func windowSize(cols: Int, rows: Int) -> winsize {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return winsize(
            ws_row: UInt16(clamping: rows),
            ws_col: UInt16(clamping: cols),
            ws_xpixel: UInt16(clamping: Int((bounds.width * scale).rounded())),
            ws_ypixel: UInt16(clamping: Int((bounds.height * scale).rounded())),
        )
    }

    override func layout() {
        super.layout()
        processHost?.updateWindowSize(currentWindowSize())
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        processHost?.updateWindowSize(currentWindowSize())
    }

    func processTerminated(source _: LocalProcess, exitCode: Int32?) {
        onProcessTermination?(exitCode)
    }

    func processFailedToStart(source _: LocalProcess, error: LocalProcessError) {
        feed(text: "\r\nProcess launch failed: \(error)\r\n")
    }

    // MARK: TerminalViewDelegate

    /// Mirrors 1.15's synchronous path: DA/DSR/OSC replies go straight to the process that produced them, on its parse thread.
    /// SwiftTerm 1.99 routes them through `onMain`, where a restart could deliver an old reply to the new process.
    override nonisolated func send(source _: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {
        processHost?.process.send(data: data)
    }

    func send(source _: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        processHost?.process.send(data: data)
    }

    func sizeChanged(source _: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        processHost?.updateWindowSize(windowSize(cols: newCols, rows: newRows))
    }

    func setTerminalTitle(source _: SwiftTerm.TerminalView, title: String) {
        onTitle?(title)
    }

    func hostCurrentDirectoryUpdate(source _: SwiftTerm.TerminalView, directory: String?) {
        onDirectoryUpdate?(directory)
    }

    func scrolled(source _: SwiftTerm.TerminalView, position _: Double) {}

    func rangeChanged(source _: SwiftTerm.TerminalView, startY _: Int, endY _: Int) {}

    func requestOpenLink(source _: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        onOpenLink?(link, params)
    }

    /// OSC 52 parity: these preserve LocalProcessTerminalView's clipboard behavior from 1.15.
    /// They are not newly enabled by the 1.99 migration.
    func clipboardCopy(source _: SwiftTerm.TerminalView, content: Data) {
        guard let string = String(bytes: content, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([string as NSString])
    }

    func clipboardRead(source _: SwiftTerm.TerminalView) -> Data? {
        // Denied: 1.99 answers OSC 52 reads asynchronously on main, so an old process's reply can cross a PTY restart into the new child.
        // 1.15's synchronous path did not expose that window.
        // Writes remain for parity; reads return once a generation-checked or setting-based implementation exists.
        nil
    }

    deinit {

        NotificationCenter.default.removeObserver(self)
    }
}

/// Owns the PTY for one terminal surface so Lithe still sees every raw byte.
///
/// One host serves one launch.
/// A terminating `LocalProcess` cannot be reused, so a restart detaches the old host and installs a fresh one.
final class MacTerminalProcessHost: NSObject, LocalProcessDelegate {
    /// Caps queued raw output when the main queue is busy.
    /// The IO parse thread waits instead of growing memory, which also backpressures the PTY.
    private static let maximumPendingOutputBytes = 4 * 1024 * 1024

    private let condition = NSCondition()
    private var attached = true
    private weak var view: LitheTerminalView?
    private var outputSink: (@Sendable (Data) -> Void)?
    private var pendingOutput = Data()
    private var outputScheduled = false
    /// Data callbacks that have entered but not yet handed their slice over.
    private var activeDataReceives = 0
    /// Set by flush/detach so output that loses the race for the condition cannot be attributed to the next session.
    private var terminated = false

    private(set) var process: LocalProcess!
    private let windowSizeLock = NSLock()
    private var windowSize = winsize()

    var onOutput: (@Sendable (Data) -> Void)? {
        get {
            condition.lock()
            defer { condition.unlock() }
            return outputSink
        }
        set {
            condition.lock()
            outputSink = newValue
            if newValue == nil {
                pendingOutput.removeAll(keepingCapacity: false)
                outputScheduled = false
            }
            condition.broadcast()
            condition.unlock()
        }
    }

    init(view: LitheTerminalView) {
        self.view = view
        super.init()
        process = LocalProcess(delegate: self, dispatchQueue: .main, directDelivery: true)
    }

    /// Permanently stops this host from feeding the view or the transport.
    /// Callers replace it with a new host for the next launch.
    func detach() {
        condition.lock()
        attached = false
        terminated = true
        view = nil
        outputSink = nil
        pendingOutput.removeAll(keepingCapacity: false)
        outputScheduled = false
        condition.broadcast()
        condition.unlock()
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        // Runs on the IO parse thread; `feed` accepts bytes from any thread.
        // Holding the condition across the enqueue makes detach() wait until this batch has been handed over.
        // A detached host therefore never feeds.
        condition.lock()
        guard attached, !terminated, let view else {
            condition.unlock()
            return
        }
        activeDataReceives += 1
        view.feed(byteArray: slice)
        view.requestCaretRefresh()
        enqueueOutputLocked(Data(slice))
        activeDataReceives -= 1
        condition.broadcast()
        condition.unlock()
    }

    func getWindowSize() -> winsize {
        windowSizeLock.lock()
        defer { windowSizeLock.unlock() }
        return windowSize
    }

    func updateWindowSize(_ size: winsize) {
        windowSizeLock.lock()
        let changed = windowSize.ws_row != size.ws_row
            || windowSize.ws_col != size.ws_col
            || windowSize.ws_xpixel != size.ws_xpixel
            || windowSize.ws_ypixel != size.ws_ypixel
        windowSize = size
        windowSizeLock.unlock()
        guard changed, process.running else { return }
        var size = size
        _ = process.updateWindowSize(&size)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        MainActor.assumeIsolated {
            condition.lock()
            guard attached else {
                condition.unlock()
                return
            }
            let view = view
            condition.unlock()
            // The final read callback has already queued its bytes.
            // Flush them synchronously so termination cannot overtake output on `.main`.
            flushOutput()
            view?.processTerminated(source: source, exitCode: exitCode)
        }
    }

    func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        MainActor.assumeIsolated {
            condition.lock()
            guard attached else {
                condition.unlock()
                return
            }
            let view = view
            condition.unlock()
            view?.processFailedToStart(source: source, error: error)
        }
    }

    /// Appends one slice. The caller owns the condition lock and must unlock.
    private func enqueueOutputLocked(_ data: Data) {
        while attached, outputSink != nil,
              pendingOutput.count >= Self.maximumPendingOutputBytes
        {
            condition.wait()
        }
        guard attached, outputSink != nil else { return }
        pendingOutput.append(data)
        if !outputScheduled {
            outputScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.drainOutput()
            }
        }
    }

    private func drainOutput() {
        condition.lock()
        let data = pendingOutput
        pendingOutput.removeAll(keepingCapacity: false)
        outputScheduled = false
        let sink = attached ? outputSink : nil
        condition.broadcast()
        condition.unlock()
        if !data.isEmpty {
            sink?(data)
        }
    }

    /// Delivers queued output synchronously.
    /// Used before termination is forwarded so the transport sees the shell's last bytes first.
    private func flushOutput() {
        condition.lock()
        var data = pendingOutput
        pendingOutput.removeAll(keepingCapacity: false)
        outputScheduled = false
        // Drain first: this frees any data callback blocked at the size cap.
        condition.broadcast()
        // LocalProcess bounds its exit drain at 0.5 s, so a timed-out drain can deliver termination while one data callback is still in flight.
        // Wait it out briefly; the bound keeps the main thread from stalling.
        let deadline = Date(timeIntervalSinceNow: 1)
        while attached, activeDataReceives > 0 {
            if !condition.wait(until: deadline) {
                break
            }
        }
        if !pendingOutput.isEmpty {
            data.append(pendingOutput)
            pendingOutput.removeAll(keepingCapacity: false)
        }
        // Output that loses the race for this lock is dropped instead of being attributed to the next session.
        // The tombstone closes the pre-lock window without making main wait on a parse.
        terminated = true
        outputScheduled = false
        let sink = attached ? outputSink : nil
        condition.broadcast()
        condition.unlock()
        if !data.isEmpty {
            sink?(data)
        }
    }
}

/// Reports whether the terminal background is dark, using WCAG relative luminance.
enum MacTerminalBackgroundReporting {
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
/// Owns one persistent SwiftTerm surface and the local PTY process connected to it.
/// The surface intentionally lives with the session instead of the SwiftUI view so
/// switching terminal tabs or hiding the tool window does not reset a TUI screen.
@MainActor
final class MacTerminalTransport: NSObject, TerminalTransport {
    static func availableShells(fileManager: FileManager = .default) -> [String] {
        MacTerminalShellDiscovery.availableShells(fileManager: fileManager)
    }

    let view: LitheTerminalView
    private var processHost: MacTerminalProcessHost

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
        processHost.process.running
    }

    var processID: Int32? {
        let processID = processHost.process.shellPid
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

    init(scrollbackLines: Int = 2_000, preferredAppearanceIsDark: (() -> Bool?)? = nil) {
        var options = TerminalOptions.default
        options.termName = "xterm-256color"
        options.scrollback = scrollbackLines
        let terminalView = LitheTerminalView(
            frame: .zero,
            font: Self.preferredTerminalFont(),
            startupOptions: options,
        )
        view = terminalView
        processHost = MacTerminalProcessHost(view: terminalView)
        super.init()

        installProcessHost(processHost)
        terminalView.preferredAppearanceIsDark = preferredAppearanceIsDark
        terminalView.onOpenLink = { [weak self] link, params in
            self?.onLink?(link, params)
        }
        terminalView.onTitle = { [weak self] title in
            self?.onTitle?(title)
        }
        terminalView.onDirectoryUpdate = { [weak self] directory in
            self?.onDirectoryUpdate?(directory)
        }
        terminalView.onProcessTermination = { [weak self] exitCode in
            self?.handleProcessTerminated(exitCode: exitCode)
        }
        terminalView.applyThemeColors(theme: LitheTheme.activeTheme)
        terminalView.allowMouseReporting = true
        terminalView.linkReporting = .implicit
        terminalView.linkHighlightMode = .hoverWithModifier
    }

    /// Points the view and the transport at one fresh PTY host.
    private func installProcessHost(_ host: MacTerminalProcessHost) {
        // The host drains output on the main queue, which shares FIFO ordering with LocalProcess's `.main` termination callback.
        // The final output chunks therefore stay ahead of finishDecodedOutput().
        // Stay inline when already on main: an extra async hop would land after that termination callback.
        host.onOutput = { [weak self] data in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.view.refreshCaretFocus()
                    self?.onOutput?(data)
                }
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.view.refreshCaretFocus()
                    self?.onOutput?(data)
                }
            }
        }
        view.processHost = host
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
        processHost.detach()
        let host = MacTerminalProcessHost(view: view)
        processHost = host
        installProcessHost(host)
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

        view.resetToInitialState()

        let environmentArray = environment.keys.sorted().map { key in
            "\(key)=\(environment[key] ?? "")"
        }

        host.updateWindowSize(view.currentWindowSize())
        let launchResult = host.process.startProcessChecked(
            executable: executablePath,
            args: launch.arguments,
            environment: environmentArray,
            currentDirectory: launch.workingDirectory
        )
        if case let .failure(error) = launchResult {
            throw terminalError("Unable to start \(executablePath): \(error)")
        }

        guard host.process.running, let processID else {
            throw terminalError("Unable to start \(executablePath)")
        }
        session = MacProcessTable.info(processID: processID).map { MacTerminalSessionOwnership(leader: $0.identity) }
        return processID
    }

    func send(_ input: Data) throws {
        guard processHost.process.running else { return }
        processHost.process.send(data: Array(input)[...])
    }

    func interrupt() throws {
        guard processHost.process.running else { return }
        processHost.process.send(data: [UInt8(0x03)][...])
    }

    func focus() {
        guard let window = view.window else { return }
        window.makeFirstResponder(view)
    }

    func clear() {
        view.resetToInitialState()
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
        let shouldSuppress = processHost.process.running || processHost.process.windingDown
        if shouldSuppress {
            suppressNextTermination = true
            processHost.process.terminate()
        }
        guard let processID else { return }
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

    private func handleProcessTerminated(exitCode: Int32?) {
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
