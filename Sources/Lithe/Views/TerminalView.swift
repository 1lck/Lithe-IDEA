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
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            terminalCanvas
        }
        .background(Color(red: 0.071, green: 0.075, blue: 0.081))
        .onAppear { isInputFocused = true }
    }

    private var terminalToolbar: some View {
        HStack(spacing: 8) {
            Text("Terminal")
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 10)

            HStack(spacing: 7) {
                Text("Local")
                Button {
                    model.isTerminalVisible = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(LitheTheme.secondaryText)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(LitheTheme.raised.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }

            Button {
                session.restart()
                isInputFocused = true
            } label: {
                Image(systemName: "plus")
            }
            .litheIconButton()
            .help("New terminal session")

            Menu {
                ForEach(existingShells, id: \.self) { shell in
                    Button(shellLabel(for: shell)) {
                        session.restart(using: shell)
                        isInputFocused = true
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 28)
            .foregroundStyle(LitheTheme.secondaryText)
            .help("Select shell")

            Spacer()

            Menu {
                Button("Interrupt", action: session.interrupt)
                Button("Restart", action: session.restart)
                Button("Clear", action: session.clear)
            } label: {
                Image(systemName: "ellipsis.vertical")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .foregroundStyle(LitheTheme.secondaryText)

            Button {
                model.isTerminalVisible = false
            } label: {
                Image(systemName: "minus")
            }
            .litheIconButton()
            .help("Hide terminal")
        }
        .frame(height: 38)
        .foregroundStyle(LitheTheme.primaryText)
        .background(Color(red: 0.076, green: 0.081, blue: 0.087))
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
            .onTapGesture { isInputFocused = true }
            .overlay(alignment: .topLeading) {
                TextField("", text: $command)
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .opacity(0.001)
                    .frame(width: 1, height: 1)
                    .onSubmit(runCommand)
                    .onChange(of: session.isReady) {
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

    private func moveHistory(by offset: Int) {
        guard !history.isEmpty else { return }
        let current = historyIndex ?? history.count
        let next = min(history.count, max(0, current + offset))
        historyIndex = next == history.count ? nil : next
        command = next == history.count ? "" : history[next]
    }
}
