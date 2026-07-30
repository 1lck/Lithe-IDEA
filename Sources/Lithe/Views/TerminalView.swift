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
        var rendered = ANSIAttributedString.render(session.output)
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

private enum ANSIAttributedString {
    private struct Style {
        var foreground = Color(red: 0.82, green: 0.84, blue: 0.86)
        var background: Color?
        var bold = false
    }

    static func render(_ source: String) -> AttributedString {
        let scalars = Array(source.unicodeScalars)
        var result = AttributedString()
        var buffer = ""
        var style = Style()
        var index = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            var run = AttributedString(buffer)
            run.foregroundColor = style.foreground
            run.backgroundColor = style.background
            if style.bold { run.font = .custom("Menlo-Bold", size: 12.5) }
            result.append(run)
            buffer = ""
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 27, index + 1 < scalars.count {
                flush()
                if scalars[index + 1] == "[" {
                    var end = index + 2
                    while end < scalars.count, !(64...126).contains(scalars[end].value) { end += 1 }
                    if end < scalars.count {
                        if scalars[end] == "m" {
                            let parameters = String(String.UnicodeScalarView(scalars[(index + 2)..<end]))
                            applySGR(parameters, to: &style)
                        }
                        index = end + 1
                        continue
                    }
                } else if scalars[index + 1] == "]" {
                    var end = index + 2
                    while end < scalars.count, scalars[end].value != 7 { end += 1 }
                    index = min(end + 1, scalars.count)
                    continue
                }
            }

            switch scalar.value {
            case 8, 127:
                if !buffer.isEmpty { buffer.removeLast() }
            case 13:
                break
            case 9, 10:
                buffer.unicodeScalars.append(scalar)
            case 0..<32:
                break
            default:
                buffer.unicodeScalars.append(scalar)
            }
            index += 1
        }
        flush()
        return result
    }

    private static func applySGR(_ parameters: String, to style: inout Style) {
        let codes = parameters.isEmpty ? [0] : parameters.split(separator: ";").compactMap { Int($0) }
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0: style = Style()
            case 1: style.bold = true
            case 22: style.bold = false
            case 30...37, 90...97: style.foreground = paletteColor(code)
            case 39: style.foreground = Style().foreground
            case 40...47, 100...107: style.background = paletteColor(code - 10)
            case 49: style.background = nil
            case 38, 48:
                let isForeground = code == 38
                if index + 2 < codes.count, codes[index + 1] == 5 {
                    setColor(color256(codes[index + 2]), foreground: isForeground, style: &style)
                    index += 2
                } else if index + 4 < codes.count, codes[index + 1] == 2 {
                    let color = Color(
                        red: Double(codes[index + 2]) / 255,
                        green: Double(codes[index + 3]) / 255,
                        blue: Double(codes[index + 4]) / 255
                    )
                    setColor(color, foreground: isForeground, style: &style)
                    index += 4
                }
            default: break
            }
            index += 1
        }
    }

    private static func setColor(_ color: Color, foreground: Bool, style: inout Style) {
        if foreground { style.foreground = color } else { style.background = color }
    }

    private static func paletteColor(_ code: Int) -> Color {
        let values: [Color] = [
            .black, Color(red: 0.80, green: 0.27, blue: 0.29),
            Color(red: 0.31, green: 0.72, blue: 0.39), Color(red: 0.86, green: 0.68, blue: 0.31),
            Color(red: 0.35, green: 0.55, blue: 0.90), Color(red: 0.72, green: 0.40, blue: 0.78),
            Color(red: 0.35, green: 0.72, blue: 0.75), Color(red: 0.78, green: 0.80, blue: 0.82)
        ]
        return values[(code >= 90 ? code - 90 : code - 30) % values.count]
    }

    private static func color256(_ value: Int) -> Color {
        if value < 16 { return paletteColor(value < 8 ? value + 30 : value - 8 + 90) }
        if value >= 232 {
            let component = Double(8 + (value - 232) * 10) / 255
            return Color(red: component, green: component, blue: component)
        }
        let offset = value - 16
        let components = [offset / 36, (offset / 6) % 6, offset % 6].map { $0 == 0 ? 0 : 55 + $0 * 40 }
        return Color(
            red: Double(components[0]) / 255,
            green: Double(components[1]) / 255,
            blue: Double(components[2]) / 255
        )
    }
}
