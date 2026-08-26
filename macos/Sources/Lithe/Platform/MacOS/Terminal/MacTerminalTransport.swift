import AppKit
import Foundation
import SwiftTerm
import LitheTerminalModule

/// SwiftTerm's default link handler opens URLs in the system. Lithe needs the
/// link event so workspace-relative paths can open in its own editor instead.
final class LitheTerminalView: LocalProcessTerminalView {
    var onOpenLink: ((String, [String: String]) -> Void)?
    private var showsWorkbenchBackground = false
    private weak var metalActivationFailedWindow: NSWindow?

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
        guard let currentWindow = window,
              !isUsingMetalRenderer,
              currentWindow !== metalActivationFailedWindow else { return }

        do {
            try setUseMetal(true)
            metalActivationFailedWindow = nil
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = true

        let paste = NSMenuItem(
            title: "Paste",
            action: #selector(paste(_:)),
            keyEquivalent: ""
        )
        paste.target = self
        menu.addItem(paste)

        let copy = NSMenuItem(
            title: "Copy",
            action: #selector(copy(_:)),
            keyEquivalent: ""
        )
        copy.target = self
        menu.addItem(copy)

        let selectAll = NSMenuItem(
            title: "Select All",
            action: #selector(selectAll(_:)),
            keyEquivalent: ""
        )
        selectAll.target = self
        menu.addItem(selectAll)

        return menu
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
}

extension LitheTerminalView: WorkbenchBackgroundRendering {}

/// Owns one persistent SwiftTerm surface and the local PTY process connected to it.
/// The surface intentionally lives with the session instead of the SwiftUI view so
/// switching terminal tabs or hiding the tool window does not reset a TUI screen.
@MainActor
final class MacTerminalTransport: NSObject, TerminalTransport, @preconcurrency LocalProcessTerminalViewDelegate {
    static func availableShells(fileManager: FileManager = .default) -> [String] {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let shell = environment["SHELL"], !shell.isEmpty { candidates.append(shell) }
        candidates.append(contentsOf: [
            "/bin/zsh",
            "/bin/bash",
            "/opt/homebrew/bin/bash",
            "/opt/homebrew/bin/pwsh"
        ])
        return candidates.reduce(into: [String]()) { result, path in
            guard fileManager.isExecutableFile(atPath: path), !result.contains(path) else { return }
            result.append(path)
        }
    }
    let view: LitheTerminalView

    var onTermination: ((Int32?) -> Void)?
    var onTitle: ((String) -> Void)?
    var onDirectoryUpdate: ((String?) -> Void)?
    var onLink: ((String, [String: String]) -> Void)?

    private var selectedShellPath: String?
    private var suppressNextTermination = false

    var isRunning: Bool {
        view.process.running
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
        stop()
        suppressNextTermination = false
        selectedShellPath = shellPath

        view.terminal.resetToInitialState()
        var options = view.terminal.options
        options.termName = environment["TERM"] ?? "xterm-256color"
        view.terminal.options = options
        view.terminal.setup(isReset: false)

        let environmentArray = environment.keys.sorted().map { key in
            "\(key)=\(environment[key] ?? "")"
        }

        view.startProcess(
            executable: shellPath,
            args: ["-l"],
            environment: environmentArray,
            currentDirectory: workingDirectory
        )

        guard view.process.running else {
            throw NSError(
                domain: "Lithe.Terminal",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Unable to start \(shellPath)"
                ]
            )
        }
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
        guard view.process.running else { return }
        suppressNextTermination = true
        view.terminate()
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
}
