import AppKit
import SwiftUI

struct TerminalView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: TerminalSession
    @State private var focusRequestID = 0

    private let availableShells = ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/bash", "/opt/homebrew/bin/pwsh"]

    var body: some View {
        VStack(spacing: 0) {
            terminalToolbar
            terminalCanvas
        }
        .background(Color(red: 0.071, green: 0.075, blue: 0.081))
        .task(id: session.id) {
            requestInputFocus()
        }
    }

    private var terminalToolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
            Text("Terminal")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(model.terminalSessions) { terminalSession in
                        terminalTab(terminalSession)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            terminalStatus

            Button {
                model.createTerminalSession()
                requestInputFocus()
            } label: {
                Image(systemName: "plus")
            }
            .litheIconButton()
            .help("New terminal session")

            Menu {
                ForEach(existingShells, id: \.self) { shell in
                    Button("New \(shellLabel(for: shell))") {
                        model.createTerminalSession(shellPath: shell)
                        requestInputFocus()
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .lithePointer()
            .menuIndicator(.hidden)
            .frame(width: 26, height: 28)
            .contentShape(Rectangle())
            .foregroundStyle(LitheTheme.secondaryText)
            .help("New terminal with shell")

            Menu {
                Button("Interrupt", action: session.interrupt)
                Button("Restart") {
                    model.restartActiveTerminal()
                    requestInputFocus()
                }
                Button("Clear", action: session.clear)
                Divider()
                Button("Close Terminal") {
                    model.closeTerminalSession(session)
                }
            } label: {
                LitheSystemIcon(systemImage: "ellipsis.vertical")
            }
            .menuStyle(.borderlessButton)
            .lithePointer()
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .foregroundStyle(LitheTheme.secondaryText)
            .help("Terminal actions")

            Button {
                model.isTerminalVisible = false
            } label: {
                Image(systemName: "minus")
            }
            .litheIconButton()
            .help("Hide Terminal tool window")
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: LitheTheme.Metrics.toolWindowHeaderHeight)
        .background(LitheTheme.toolHeader)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
        }
    }

    private var terminalStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 5) {
                Circle()
                    .fill(session.isRunning ? Color.green : LitheTheme.secondaryText)
                    .frame(width: 6, height: 6)

                Text(session.displayTitle)
                    .lineLimit(1)

                if let directory = session.displayDirectory {
                    Text(directory)
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .lineLimit(1)
                }

                if let exitCode = session.lastExitCode {
                    Text("Exit \(exitCode)")
                        .foregroundStyle(exitCode == 0 ? Color.green : Color.orange)
                }

                if let elapsed = session.elapsedDescription(at: context.date) {
                    Text(elapsed)
                        .monospacedDigit()
                        .foregroundStyle(LitheTheme.tertiaryText)
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(LitheTheme.secondaryText)
            .lineLimit(1)
            .frame(maxWidth: 240, alignment: .trailing)
            .help("Command-click a file path or URL to open it")
        }
    }

    private func terminalTab(_ terminalSession: TerminalSession) -> some View {
        let isActive = model.activeTerminalSessionID == terminalSession.id
            || (model.activeTerminalSessionID == nil && model.terminalSessions.first?.id == terminalSession.id)

        return HStack(spacing: 1) {
            Button {
                model.selectTerminalSession(terminalSession)
                requestInputFocus()
            } label: {
                Text(model.terminalTitle(for: terminalSession))
                    .font(.system(size: 11.5, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? LitheTheme.primaryText : LitheTheme.secondaryText)
                    .padding(.leading, 9)
                    .padding(.trailing, 5)
                    .frame(height: 26)
            }
            .buttonStyle(.plain)

            Button {
                model.closeTerminalSession(terminalSession)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close \(model.terminalTitle(for: terminalSession))")
        }
        .background(isActive ? LitheTheme.subtleSelection : .clear)
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(isActive ? LitheTheme.inputFocusBorder : .clear, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .lithePointer()
    }

    private var terminalCanvas: some View {
        Group {
            if let nativeView = session.nativeView as? NSView {
                SwiftTermSurface(
                    nativeView: nativeView,
                    focusRequestID: focusRequestID
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            } else {
                Color(red: 0.071, green: 0.075, blue: 0.081)
            }
        }
        .background(Color(red: 0.071, green: 0.075, blue: 0.081))
    }

    private var existingShells: [String] {
        availableShells.filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func shellLabel(for path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return path == "/bin/\(name)" ? name : "\(name) (\(path))"
    }

    private func requestInputFocus() {
        guard session.isRunning else { return }
        focusRequestID &+= 1
        session.focus()
    }
}

private struct SwiftTermSurface: NSViewRepresentable {
    let nativeView: NSView
    let focusRequestID: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        nativeView
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.lastFocusRequestID != focusRequestID else { return }
        context.coordinator.lastFocusRequestID = focusRequestID
        DispatchQueue.main.async {
            guard let window = view.window, window.firstResponder !== view else { return }
            window.makeFirstResponder(view)
        }
    }

    final class Coordinator: NSObject {
        var lastFocusRequestID = -1
    }
}
