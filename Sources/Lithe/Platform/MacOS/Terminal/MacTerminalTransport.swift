import AppKit
import Foundation
import SwiftTerm

/// SwiftTerm's default link handler opens URLs in the system. Lithe needs the
/// link event so workspace-relative paths can open in its own editor instead.
final class LitheTerminalView: LocalProcessTerminalView {
    var onOpenLink: ((String, [String: String]) -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeColors()
    }

    func applyThemeColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        nativeBackgroundColor = isDark
            ? NSColor(srgbRed: 0.071, green: 0.075, blue: 0.081, alpha: 1)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
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

    override func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        onOpenLink?(link, params)
    }
}

/// Owns one persistent SwiftTerm surface and the local PTY process connected to it.
/// The surface intentionally lives with the session instead of the SwiftUI view so
/// switching terminal tabs or hiding the tool window does not reset a TUI screen.
@MainActor
final class MacTerminalTransport: NSObject, TerminalTransport, @preconcurrency LocalProcessTerminalViewDelegate {
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
