import AppKit
import Foundation
import MetalKit
import SwiftTerm
import LitheTerminalModule

/// SwiftTerm's default link handler opens URLs in the system. Lithe needs the
/// link event so workspace-relative paths can open in its own editor instead.
final class LitheTerminalView: LocalProcessTerminalView {
    var onOpenLink: ((String, [String: String]) -> Void)?
    var onProcessOutput: ((Data) -> Void)?
    private var showsWorkbenchBackground = false
    private weak var metalActivationFailedWindow: NSWindow?
    private var metalFocusDelegates: [TerminalMetalFocusDelegate] = []
    private var shellShowsCursor = true

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
        }
    }

    private func setNativeCursorVisible(_ visible: Bool) {
        if visible { super.showCursor(source: terminal) }
        else { super.hideCursor(source: terminal) }
    }

    @objc private func windowFocusDidChange() {
        setNativeCursorVisible(hasFocus && shellShowsCursor)
        invalidateCursorSurface()
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
        applyThemeColors()
    }

    func applyThemeColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        nativeBackgroundColor = LitheTheme.nsColor(.editor, isDark: isDark)
            .withAlphaComponent(showsWorkbenchBackground ? 0 : 1)
        nativeForegroundColor = isDark
            ? NSColor(srgbRed: 0.86, green: 0.87, blue: 0.89, alpha: 1)
            : NSColor(srgbRed: 0.15, green: 0.16, blue: 0.18, alpha: 1)
        caretColor = isDark
            ? NSColor(srgbRed: 0.35, green: 0.67, blue: 0.98, alpha: 1)
            : NSColor(srgbRed: 0.18, green: 0.43, blue: 0.79, alpha: 1)
        selectedTextBackgroundColor = isDark
            ? NSColor(srgbRed: 0.16, green: 0.31, blue: 0.48, alpha: 1)
            : NSColor(srgbRed: 0.69, green: 0.82, blue: 0.98, alpha: 1)
        needsDisplay = true
    }

    func setWorkbenchBackgroundVisible(_ isVisible: Bool) {
        guard showsWorkbenchBackground != isVisible else { return }
        showsWorkbenchBackground = isVisible
        applyThemeColors()
    }

    override func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        onOpenLink?(link, params)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onProcessOutput?(Data(slice))
        super.dataReceived(slice: slice)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

extension LitheTerminalView: WorkbenchBackgroundRendering {}

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

    override init() {
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
        view.applyThemeColors()
        view.allowMouseReporting = true
        view.linkReporting = .implicit
        view.linkHighlightMode = .hoverWithModifier

        var options = view.terminal.options
        options.termName = "xterm-256color"
        options.scrollback = 2_000
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
    }

    func startProcess(
        _ launch: TerminalProcessLaunch,
        environment: [String: String]
    ) throws -> Int32 {
        stop()
        suppressNextTermination = false
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
        guard let processID else { return }
        suppressNextTermination = true
        if view.process.running {
            view.terminate()
        }
        stoppedChildProcessReaper.reapWhenExited(processID)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onTitle?(title)
    }

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        onDirectoryUpdate?(directory)
    }

    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
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
