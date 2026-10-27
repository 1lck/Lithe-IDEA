import LitheModuleAPI
import AppKit
import LitheTerminalModule
import SwiftUI

// Note: 统一子进程生命周期见 .agents/notes/proposed/architecture/2026-10-16-unified-child-process-lifecycle.md

/// Modal confirmations of the process exit flow.
///
/// Each terminal and each Agent task gets its own alert so that one click can
/// never end several things at once; background resources share one list.
@MainActor
final class MacProcessExitConfirmationPresenter: ProcessExitConfirmationPresenting {
    /// Coordinators hold presenters weakly; this instance lives for the app.
    static let shared = MacProcessExitConfirmationPresenter()

    func confirmTerminalOnQuit(_ terminal: TerminalExitCandidate, position: Int, count: Int) async -> TerminalExitAnswer {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: L10n.string("Terminal “%@” is still running"), terminal.title)
        alert.informativeText = Self.progress(position, count) + "\n\n" + Self.describe(terminal)
            + "\n\n" + L10n.string("Quitting Lithe ends these programs.")
        alert.addButton(withTitle: L10n.string("End This Terminal"))
        alert.addButton(withTitle: L10n.string("Show Terminal"))
        alert.addButton(withTitle: L10n.string("Cancel Quit"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .terminate
        case .alertSecondButtonReturn: return .reveal
        default: return .cancel
        }
    }

    func confirmTerminalClose(_ terminal: TerminalExitCandidate) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: L10n.string("Close terminal “%@”?"), terminal.title)
        alert.informativeText = Self.describe(terminal)
            + "\n\n" + L10n.string("Closing the terminal ends these programs.")
        alert.addButton(withTitle: L10n.string("Close Terminal"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func confirmStopRunServices(_ services: [RunServiceExitCandidate], purpose: RunServiceStopPurpose) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Run services are still running")
        let consequence = purpose == .quit
            ? L10n.string("Quitting Lithe stops these services and the processes they started.")
            : L10n.string("Closing the project stops these services and the processes they started.")
        alert.informativeText = services.map { service in
            let title = service.title.isEmpty ? L10n.string("Unnamed service") : service.title
            return service.projectName.isEmpty ? "• \(title)" : "• \(title) — \(service.projectName)"
        }.joined(separator: "\n") + "\n\n" + consequence
        alert.addButton(withTitle: purpose == .quit ? L10n.string("Stop and Quit") : L10n.string("Stop and Close"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func confirmAgentTask(
        _ task: AgentTaskCandidate,
        position: Int,
        count: Int,
        purpose: ProcessConfirmationPurpose
    ) async -> AgentTaskExitAnswer {
        // Only quitting can be cancelled; dismissing any other confirmation keeps the task.
        let dismissal: AgentTaskExitAnswer = purpose == .quit ? .cancel : .keep
        var answer = dismissal
        let panel = AgentTaskConfirmationPanel(
            contentRect: NSRect(x: 0, y: 0, width: AgentTaskExitConfirmationView.width, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let finish = { (result: AgentTaskExitAnswer) in
            answer = result
            NSApp.stopModal()
        }
        let content = AgentTaskExitConfirmationView(
            task: task,
            position: position,
            count: count,
            purpose: purpose,
            presentedAt: Date(),
            onCopyCommand: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.commandLine, forType: .string)
            },
            onAnswer: finish
        )
        panel.title = content.title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.animationBehavior = .alertPanel
        let owner = NSApp.keyWindow ?? NSApp.mainWindow
        // Follow the workbench theme; without a window the system appearance applies.
        panel.appearance = owner?.effectiveAppearance
        panel.backgroundColor = NSColor(name: nil) { appearance in
            LitheTheme.nsColor(.popupBackground, isDark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        }
        panel.onDismiss = { finish(dismissal) }
        let host = NSHostingView(rootView: content)
        panel.contentView = host
        // Let the command box measure itself before the window takes its size.
        host.layoutSubtreeIfNeeded()
        panel.setContentSize(host.fittingSize)
        if let owner {
            panel.setFrameOrigin(NSPoint(
                x: owner.frame.midX - panel.frame.width / 2,
                y: owner.frame.midY - panel.frame.height / 2
            ))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        panel.contentView = nil
        return answer
    }

    func chooseBackgroundResources(
        _ resources: [BackgroundResourceCandidate],
        purpose: ProcessConfirmationPurpose
    ) async -> BackgroundResourceAnswer? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        if purpose == .startupSweep {
            alert.messageText = L10n.string("Lithe closed unexpectedly last time and left programs running")
            alert.informativeText = L10n.string("These programs were started in Lithe before it closed unexpectedly. Checked items are ended now; unchecked items keep running and are not tracked anymore.")
        } else {
            alert.messageText = L10n.string("Background services started in Lithe are still running")
            alert.informativeText = L10n.string("These processes left their terminal or tool to keep running in the background, like daemons and dev servers. Checked items end when Lithe quits; unchecked items keep running.")
        }

        let selectionView = BackgroundResourceSelectionView(resources: resources)
        alert.accessoryView = selectionView

        if purpose == .startupSweep {
            alert.addButton(withTitle: L10n.string("End Checked"))
            alert.addButton(withTitle: L10n.string("End All"))
            alert.addButton(withTitle: L10n.string("Keep All"))
        } else {
            alert.addButton(withTitle: L10n.string("Quit with Selection"))
            alert.addButton(withTitle: L10n.string("End All and Quit"))
            alert.addButton(withTitle: L10n.string("Cancel Quit"))
        }
        let response = alert.runModal()
        let selected: Set<String>
        switch response {
        case .alertFirstButtonReturn:
            selected = selectionView.selectedIDs
        case .alertSecondButtonReturn:
            selected = Set(resources.map(\.id))
        default:
            return nil
        }
        return BackgroundResourceAnswer(terminate: selected, remember: selectionView.rememberCheckbox.state == .on)
    }

    private static func describe(_ terminal: TerminalExitCandidate) -> String {
        var lines: [String] = []
        if !terminal.projectName.isEmpty {
            lines.append(String(format: L10n.string("Project: %@"), terminal.projectName))
        }
        if !terminal.workingDirectory.isEmpty {
            lines.append(String(format: L10n.string("Directory: %@"), terminal.workingDirectory))
        }
        for program in terminal.programs {
            var line = "• " + program.commandLine
            if !program.listeningPorts.isEmpty {
                line += "  " + String(format: L10n.string("ports %@"),
                                      program.listeningPorts.map(String.init).joined(separator: ", "))
            }
            if let startedAt = program.startedAt {
                line += "  " + String(format: L10n.string("running for %@"), duration(since: startedAt))
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func progress(_ position: Int, _ count: Int) -> String {
        String(format: L10n.string("%lld of %lld"), position, count)
    }

    private static func duration(since date: Date) -> String {
        ProcessRunningTimeFormatter.string(from: date, to: Date())
    }
}

/// Window of the Agent task confirmation. Escape and the close button
/// dismiss it, which the presenter maps to the purpose's safe answer.
private final class AgentTaskConfirmationPanel: NSPanel {
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    override func performClose(_ sender: Any?) {
        onDismiss?()
    }
}
