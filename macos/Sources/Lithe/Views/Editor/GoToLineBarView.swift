import SwiftUI

/// 编辑器内的按行号跳转条：输入 1-based 行号或“行:列”，Return 跳转并
/// 关闭，Esc 或点击编辑器任意位置直接关闭。与查找栏互斥，显隐由
/// `EditorChromeModel` 保证。
struct GoToLineBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var chrome: EditorChromeModel
    @FocusState private var lineFocused: Bool
    @State private var lineText = ""
    @State private var columnText = ""

    var body: some View {
        HStack(spacing: 7) {
            LitheSystemIcon(systemImage: "number")
                .font(.system(size: 11.5))
                .foregroundStyle(inputIsInvalid ? LitheTheme.error : LitheTheme.secondaryText)
                .help("Go to line. Format: line or line:column, both 1-based")

            TextField("Line", text: $lineText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .monospacedDigit()
                .focused($lineFocused)
                .frame(minWidth: 52)

            Text(":")
                .font(.system(size: 12.5))
                .foregroundStyle(LitheTheme.secondaryText)

            TextField("Column", text: $columnText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .monospacedDigit()
                .frame(minWidth: 52)

            if inputIsInvalid {
                Text("Invalid line")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LitheTheme.error)
            }

            Button {
                model.hideGoToLineBar()
            } label: {
                Image(systemName: "xmark")
            }
            .litheIconButton()
            .foregroundStyle(LitheTheme.secondaryText)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: 320, minHeight: 34)
        .lithePopupChrome(cornerRadius: 7)
        .onAppear(perform: prefillFromCaret)
        .onExitCommand { model.hideGoToLineBar() }
        .macReturnKeyHandler(isEnabled: inputIsValid) { _ in
            jump()
        }
        .onReceive(NotificationCenter.default.publisher(for: .litheGoToLineDismiss)) { _ in
            model.hideGoToLineBar()
        }
    }

    private var combinedInput: String {
        let line = lineText.trimmingCharacters(in: .whitespaces)
        // 行输入位直接粘贴“120:35”时忽略列输入位，避免拼出多冒号
        if line.contains(":") {
            return line
        }
        let column = columnText.trimmingCharacters(in: .whitespaces)
        guard !column.isEmpty else { return line }
        return "\(line):\(column)"
    }

    private var inputIsValid: Bool {
        GoToLineInput.parse(combinedInput) != nil
    }

    /// 行号必填；只有行输入位有内容且无法解析时才提示非法，
    /// 避免刚打开输入框就报错。
    private var inputIsInvalid: Bool {
        !lineText.trimmingCharacters(in: .whitespaces).isEmpty && !inputIsValid
    }

    private func prefillFromCaret() {
        lineText = "\(max(chrome.caret?.line ?? 0, 0) + 1)"
        lineFocused = true
    }

    private func jump() {
        guard inputIsValid else { return }
        model.goToLine(combinedInput)
        model.hideGoToLineBar()
    }
}

/// 跳转条的浮层挂载点：出现在编辑器区域右上，顶部滑入过渡，
/// 挂载方式对齐 EditorAreaView 的 FindBarOverlay。
struct GoToLineBarOverlay: View {
    @EnvironmentObject private var chrome: EditorChromeModel

    var body: some View {
        if chrome.isGoToLineVisible {
            GoToLineBarView()
                .padding(.top, 10)
                .padding(.trailing, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
