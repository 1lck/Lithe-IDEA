import SwiftUI

/// 编辑器内的单文件查找栏：实时高亮、上/下一个、Esc 关闭；
/// 可展开替换行（Replace / Replace All）并携带 Match Case、Whole Words、
/// Regular Expression 选项。
struct FindBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var chrome: EditorChromeModel
    @FocusState private var findFocused: Bool
    @FocusState private var replaceFocused: Bool

    private var queryBinding: Binding<String> {
        Binding(
            get: { chrome.findBarQuery },
            set: { model.setFindBarQuery($0) }
        )
    }

    private var replaceBinding: Binding<String> {
        Binding(
            get: { chrome.findReplaceText },
            set: { model.setFindReplaceText($0) }
        )
    }

    var body: some View {
        VStack(spacing: 6) {
            findRow
                .frame(height: 34)
            if chrome.isReplaceVisible {
                replaceRow
                    .frame(height: 34)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: 520)
        .lithePopupChrome(cornerRadius: 7)
        .onAppear { findFocused = true }
        .onChange(of: chrome.isReplaceVisible) { isVisible in
            // 替换行展开后焦点移动到替换输入框，收起时还给查找框
            if isVisible {
                replaceFocused = true
            } else {
                findFocused = true
            }
        }
        .onExitCommand {
            model.hideFindBar()
        }
    }

    private var findRow: some View {
        HStack(spacing: 7) {
            optionsMenu

            LitheSystemIcon(systemImage: "magnifyingglass")
                .font(.system(size: 11.5))
                .foregroundStyle(queryIsInvalidRegex ? LitheTheme.error : LitheTheme.secondaryText)
                .help(queryIsInvalidRegex ? "Invalid regular expression" : "")

            TextField("Find in file", text: queryBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($findFocused)
                .macReturnKeyHandler(isEnabled: findFocused) { isShiftPressed in
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
            .disabled(chrome.findMatchCount == 0)
            .help("Previous match (Shift+Return)")

            Button {
                model.navigateFind(offset: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .litheIconButton()
            .foregroundStyle(LitheTheme.secondaryText)
            .disabled(chrome.findMatchCount == 0)
            .help("Next match (Return)")

            Button {
                model.isReplaceVisible.toggle()
            } label: {
                Image(systemName: chrome.isReplaceVisible ? "chevron.down" : "chevron.right")
            }
            .litheIconButton()
            .foregroundStyle(chrome.isReplaceVisible ? LitheTheme.accent : LitheTheme.secondaryText)
            .help(chrome.isReplaceVisible ? "Hide replace" : "Show replace")

            Button {
                model.hideFindBar()
            } label: {
                Image(systemName: "xmark")
            }
            .litheIconButton()
            .foregroundStyle(LitheTheme.secondaryText)
            .help("Close (Esc)")
        }
    }

    private var replaceRow: some View {
        HStack(spacing: 7) {
            LitheSystemIcon(systemImage: "arrow.left.arrow.right")
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.leading, 22)

            TextField("Replace with", text: replaceBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($replaceFocused)
                .macReturnKeyHandler(isEnabled: replaceFocused) { isShiftPressed in
                    if isShiftPressed {
                        model.replaceAllFindMatches()
                    } else {
                        model.replaceNextFindMatch()
                    }
                }

            Button {
                model.replaceNextFindMatch()
            } label: {
                Text("Replace")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(chrome.findMatchCount == 0 ? LitheTheme.secondaryText : LitheTheme.accent)
            .disabled(chrome.findMatchCount == 0)
            .help("Replace current match (Return)")

            Button {
                model.replaceAllFindMatches()
            } label: {
                Text("Replace All")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(chrome.findMatchCount == 0 ? LitheTheme.secondaryText : LitheTheme.accent)
            .disabled(chrome.findMatchCount == 0)
            .help("Replace all matches (Shift+Return)")
        }
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Match Case", isOn: optionBinding(\.matchCase))
            Toggle("Whole Words", isOn: optionBinding(\.wholeWords))
            Toggle("Regular Expression", isOn: optionBinding(\.regularExpression))
        } label: {
            LitheSystemIcon(
                systemImage: hasActiveOptions ? "slider.horizontal.3.circle.fill" : "slider.horizontal.3"
            )
            .font(.system(size: 11.5))
            .foregroundStyle(hasActiveOptions ? LitheTheme.accent : LitheTheme.secondaryText)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .lithePointer()
        .help("Find options")
    }

    private var hasActiveOptions: Bool {
        chrome.findOptions != .default
    }

    private var queryIsInvalidRegex: Bool {
        !chrome.findBarQuery.isEmpty
            && chrome.findOptions.regularExpression
            && !FindInFileMatcher(query: chrome.findBarQuery, options: chrome.findOptions).isValid
    }

    private func optionBinding(_ keyPath: WritableKeyPath<FindInFileOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { chrome.findOptions[keyPath: keyPath] },
            set: { newValue in
                var options = chrome.findOptions
                options[keyPath: keyPath] = newValue
                model.setFindOptions(options)
            }
        )
    }

    private var matchLabel: String {
        guard chrome.findMatchCount > 0 else { return "" }
        let current = max(0, chrome.currentFindMatchIndex + 1)
        return "\(current)/\(chrome.findMatchCount)"
    }
}
