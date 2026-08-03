import AppKit
import SwiftUI

struct TerminalView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: TerminalSession
    @State private var isInputFocused = false
    @State private var focusRequestID = 0
    @State private var isCursorVisible = true

    private let availableShells = ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/bash", "/opt/homebrew/bin/pwsh"]

    var body: some View {
        VStack(spacing: 0) {
            terminalToolbar
            terminalCanvas
        }
        .background(Color(red: 0.071, green: 0.075, blue: 0.081))
        .task(id: session.id) {
            requestInputFocus()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(530))
                guard !Task.isCancelled else { return }
                isCursorVisible.toggle()
            }
        }
        .onChange(of: isInputFocused) {
            isCursorVisible = true
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
                TerminalInputAnchor(
                    isFocused: $isInputFocused,
                    focusRequestID: focusRequestID,
                    onInput: session.sendInput
                )
                .frame(width: 1, height: 1)
            }
            .onChange(of: session.output) {
                proxy.scrollTo("terminal-content", anchor: .bottom)
            }
        }
        .background(Color(red: 0.071, green: 0.075, blue: 0.081))
    }

    private var renderedTerminal: AttributedString {
        var rendered = ANSIOutputRenderer.render(session.output, fontSize: 12.5)

        if isInputFocused && isCursorVisible {
            var cursor = AttributedString("|")
            cursor.foregroundColor = Color(red: 0.78, green: 0.80, blue: 0.82)
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

    private func requestInputFocus() {
        guard session.isRunning else { return }
        focusRequestID &+= 1
    }
}

private struct TerminalInputAnchor: NSViewRepresentable {
    @Binding var isFocused: Bool
    let focusRequestID: Int
    let onInput: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isFocused: $isFocused,
            onInput: onInput
        )
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .clear
        field.alphaValue = 0.01
        field.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.isEditable = true
        field.isSelectable = true
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.isFocused = $isFocused
        context.coordinator.onInput = onInput

        guard context.coordinator.lastFocusRequestID != focusRequestID else { return }
        context.coordinator.lastFocusRequestID = focusRequestID
        DispatchQueue.main.async {
            guard let window = field.window, window.firstResponder !== field else { return }
            window.makeFirstResponder(field)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var isFocused: Binding<Bool>
        var onInput: (String) -> Void
        var lastFocusRequestID = -1
        private var isClearingInput = false

        init(
            isFocused: Binding<Bool>,
            onInput: @escaping (String) -> Void
        ) {
            self.isFocused = isFocused
            self.onInput = onInput
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let hasMarkedText = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
            guard !isClearingInput, !hasMarkedText else { return }
            let value = field.stringValue
            guard !value.isEmpty else { return }
            isClearingInput = true
            field.stringValue = ""
            isClearingInput = false
            onInput(value)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch NSStringFromSelector(commandSelector) {
            case "insertNewline:", "insertNewlineIgnoringFieldEditor:":
                onInput("\r")
                return true
            case "insertTab:", "insertTabIgnoringFieldEditor:":
                onInput("\t")
                return true
            case "moveUp:":
                onInput("\u{1b}[A")
                return true
            case "moveDown:":
                onInput("\u{1b}[B")
                return true
            case "moveLeft:":
                onInput("\u{1b}[D")
                return true
            case "moveRight:":
                onInput("\u{1b}[C")
                return true
            case "deleteBackward:":
                onInput("\u{7f}")
                return true
            case "deleteForward:":
                onInput("\u{1b}[3~")
                return true
            default:
                return false
            }
        }
    }
}
