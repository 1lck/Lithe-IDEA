import SwiftUI

struct TerminalView: View {
    @EnvironmentObject private var model: AppModel
    @State private var command = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            terminalToolbar
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            outputView
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            commandLine
        }
        .background(LitheTheme.editor)
    }

    private var terminalToolbar: some View {
        HStack(spacing: 4) {
            Image(systemName: "terminal")
                .foregroundStyle(LitheTheme.secondaryText)
            Text(model.terminalSession.shellName)
                .font(.system(size: 12.5, weight: .semibold))
            Circle()
                .fill(model.terminalSession.isRunning ? LitheTheme.success : LitheTheme.secondaryText)
                .frame(width: 6, height: 6)
            Spacer()
            Button {
                model.terminalSession.interrupt()
            } label: {
                Image(systemName: "stop.fill")
            }
            .litheIconButton()
            .disabled(!model.terminalSession.isRunning)
            .help("Interrupt terminal")

            Button {
                model.terminalSession.restart()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .litheIconButton()
            .help("Restart terminal")

            Button {
                model.terminalSession.clear()
            } label: {
                Image(systemName: "trash")
            }
            .litheIconButton()
            .help("Clear terminal")

            Button {
                model.isTerminalVisible = false
            } label: {
                Image(systemName: "xmark")
            }
            .litheIconButton()
            .help("Hide terminal")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 36)
        .foregroundStyle(LitheTheme.primaryText)
        .background(LitheTheme.toolHeader)
    }

    private var outputView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                Text(model.terminalSession.output.isEmpty ? "Terminal ready" : model.terminalSession.output)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                Color.clear.frame(height: 1).id("terminal-bottom")
            }
            .onChange(of: model.terminalSession.output) {
                proxy.scrollTo("terminal-bottom", anchor: .bottom)
            }
        }
    }

    private var commandLine: some View {
        HStack(spacing: 8) {
            Text("$")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(LitheTheme.success)
            TextField(model.terminalSession.isReady ? "Enter command" : "Starting shell...", text: $command)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .disabled(!model.terminalSession.isReady)
                .onSubmit(runCommand)
                .onKeyPress(.upArrow) {
                    moveHistory(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveHistory(by: 1)
                    return .handled
                }
            Button(action: runCommand) {
                Image(systemName: "return")
            }
            .litheIconButton()
            .disabled(
                !model.terminalSession.isReady ||
                    command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .help("Run command")
        }
        .padding(.leading, 11)
        .padding(.trailing, 4)
        .frame(height: 36)
        .background(LitheTheme.toolHeader)
    }

    private func runCommand() {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.terminalSession.send(value)
        if history.last != value {
            history.append(value)
        }
        historyIndex = nil
        command = ""
    }

    private func moveHistory(by offset: Int) {
        guard !history.isEmpty else { return }
        let current = historyIndex ?? history.count
        let next = min(history.count, max(0, current + offset))
        historyIndex = next == history.count ? nil : next
        command = next == history.count ? "" : history[next]
    }
}
