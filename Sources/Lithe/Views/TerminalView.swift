import AppKit
import SwiftUI

struct TerminalView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: TerminalSession
    @State private var command = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int?
    @State private var hasPendingSubmission = false
    @FocusState private var isInputFocused: Bool

    private let availableShells = ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/bash", "/opt/homebrew/bin/pwsh"]

    var body: some View {
        VStack(spacing: 0) {
            terminalToolbar
            terminalCanvas
        }
        .background(Color(red: 0.071, green: 0.075, blue: 0.081))
        .task {
            await Task.yield()
            requestInputFocus()
        }
    }

    private var terminalToolbar: some View {
        LitheToolWindowHeader(
            title: "Terminal",
            systemImage: "terminal",
            subtitle: "Local",
            onMinimize: { model.isTerminalVisible = false }
        ) {
            Button {
                session.restart()
                requestInputFocus()
            } label: {
                Image(systemName: "plus")
            }
            .litheIconButton()
            .help("New terminal session")

            Menu {
                ForEach(existingShells, id: \.self) { shell in
                Button(shellLabel(for: shell)) {
                    session.restart(using: shell)
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
            .help("Select shell")

            Menu {
                Button("Interrupt", action: session.interrupt)
                Button("Restart", action: session.restart)
                Button("Clear", action: session.clear)
            } label: {
                LitheSystemIcon(systemImage: "ellipsis.vertical")
            }
            .menuStyle(.borderlessButton)
            .lithePointer()
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .foregroundStyle(LitheTheme.secondaryText)
        }
    }

    private var terminalCanvas: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                Text(renderedTerminal)
                    .font(.custom("Menlo", size: 12.5))
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .id("terminal-content")
            }
            .contentShape(Rectangle())
            .onTapGesture { requestInputFocus() }
            .overlay(alignment: .topLeading) {
                TextField("", text: $command)
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .opacity(0.001)
                    .frame(width: 1, height: 1)
                    .onSubmit(runCommand)
                    .onChange(of: session.isReady) {
                        requestInputFocus()
                        if session.isReady, hasPendingSubmission {
                            runCommand()
                        }
                    }
                    .onKeyPress(.upArrow) {
                        moveHistory(by: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveHistory(by: 1)
                        return .handled
                    }
            }
            .onChange(of: session.output) {
                proxy.scrollTo("terminal-content", anchor: .bottom)
            }
            .onChange(of: command) {
                proxy.scrollTo("terminal-content", anchor: .bottom)
            }
        }
        .background(Color(red: 0.071, green: 0.075, blue: 0.081))
    }

    private var renderedTerminal: AttributedString {
        var rendered = ANSIOutputRenderer.render(session.output, fontSize: 12.5)
        var input = AttributedString(command)
        input.foregroundColor = Color(red: 0.82, green: 0.84, blue: 0.86)
        rendered.append(input)

        if isInputFocused {
            var cursor = AttributedString(" ")
            cursor.backgroundColor = Color(red: 0.78, green: 0.80, blue: 0.82)
            rendered.append(cursor)
        }
        return rendered
    }

    private var existingShells: [String] {
        availableShells.filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func shellLabel(for path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return path == "/bin/\(name)" ? name : "\(name) (\(path))"
    }

    private func runCommand() {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard session.isReady else {
            hasPendingSubmission = true
            session.prepareForInput()
            return
        }
        hasPendingSubmission = false
        session.send(value)
        if history.last != value { history.append(value) }
        historyIndex = nil
        command = ""
    }

    private func requestInputFocus() {
        Task { @MainActor in
            await Task.yield()
            isInputFocused = true
        }
    }

    private func moveHistory(by offset: Int) {
        guard !history.isEmpty else { return }
        let current = historyIndex ?? history.count
        let next = min(history.count, max(0, current + offset))
        historyIndex = next == history.count ? nil : next
        command = next == history.count ? "" : history[next]
    }
}
