import SwiftUI

/// 编辑器内的单文件查找栏：实时高亮、上/下一个、Esc 关闭。
struct FindBarView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    private var queryBinding: Binding<String> {
        Binding(
            get: { model.findBarQuery },
            set: { model.setFindBarQuery($0) }
        )
    }

    var body: some View {
        HStack(spacing: 7) {
            LitheSystemIcon(systemImage: "magnifyingglass")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)

            TextField("Find in file", text: queryBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .macReturnKeyHandler(isEnabled: focused) { isShiftPressed in
                    if isShiftPressed {
                        model.navigateFind(offset: -1)
                    } else {
                        model.navigateFind(offset: 1)
                    }
                }

            Text(matchLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(minWidth: 34, alignment: .trailing)
                .monospacedDigit()

            Button {
                model.navigateFind(offset: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .litheIconButton()
            .foregroundStyle(LitheTheme.secondaryText)
            .disabled(model.findMatchCount == 0)
            .help("Previous match (Shift+Return)")

            Button {
                model.navigateFind(offset: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .litheIconButton()
            .foregroundStyle(LitheTheme.secondaryText)
            .disabled(model.findMatchCount == 0)
            .help("Next match (Return)")

            Button {
                model.hideFindBar()
            } label: {
                Image(systemName: "xmark")
            }
            .litheIconButton()
            .foregroundStyle(LitheTheme.secondaryText)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .frame(maxWidth: 520)
        .lithePopupChrome(cornerRadius: 7)
        .onAppear { focused = true }
        .onExitCommand {
            model.hideFindBar()
        }
    }

    private var matchLabel: String {
        guard model.findMatchCount > 0 else { return "" }
        let current = max(0, model.currentFindMatchIndex + 1)
        return "\(current)/\(model.findMatchCount)"
    }
}
