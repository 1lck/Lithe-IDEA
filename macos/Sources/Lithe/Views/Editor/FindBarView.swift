import SwiftUI
import AppKit

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
                .frame(height: 28)
            if chrome.isReplaceVisible {
                replaceRow
                    .frame(height: 28)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.popupBackground, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(LitheTheme.panelBorder.opacity(0.35), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onHover { isInside in
            if isInside { NSCursor.arrow.set() }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
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
        HStack(spacing: 8) {
            Button { model.isReplaceVisible.toggle() } label: {
                Image(systemName: chrome.isReplaceVisible ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
            }
            .buttonStyle(FindBarButtonStyle(width: 20, height: 20))
            .accessibilityLabel(chrome.isReplaceVisible ? "Hide replace" : "Show replace")
            .help(chrome.isReplaceVisible ? "Hide replace" : "Show replace")

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(queryIsInvalidRegex ? LitheTheme.error : LitheTheme.secondaryText)
                    .help(queryIsInvalidRegex ? "Invalid regular expression" : "Find")
                TextField("Find in file", text: queryBinding)
                    .textFieldStyle(.plain)
                    .focused($findFocused)
                    .onContinuousHover { phase in
                        if case .active = phase { NSCursor.iBeam.set() }
                        else { NSCursor.arrow.set() }
                    }
                    .macReturnKeyHandler(isEnabled: findFocused) { isShiftPressed in
                        model.navigateFind(offset: isShiftPressed ? -1 : 1)
                    }
                optionButton("Cc", help: "Match Case", keyPath: \.matchCase)
                optionButton("W", help: "Whole Words", keyPath: \.wholeWords)
                optionButton(".*", help: "Regular Expression", keyPath: \.regularExpression)
            }
            .modifier(FindInputChrome(isFocused: findFocused))

            Text(matchLabel)
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
                .monospacedDigit()
                .frame(minWidth: 60)
                .fixedSize()

            Button { model.navigateFind(offset: -1) } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(FindBarButtonStyle())
            .disabled(chrome.findMatchCount == 0)
            .accessibilityLabel("Previous match")
            .help("Previous match (Shift+Return)")

            Button { model.navigateFind(offset: 1) } label: {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(FindBarButtonStyle())
            .disabled(chrome.findMatchCount == 0)
            .accessibilityLabel("Next match")
            .help("Next match (Return)")

            Spacer(minLength: 0)
            Button { model.hideFindBar() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
            }
            .buttonStyle(FindBarButtonStyle(width: 20, height: 20))
            .accessibilityLabel("Close find")
            .help("Close (Esc)")
        }
        .foregroundStyle(LitheTheme.secondaryText)
    }

    private var replaceRow: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 20)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(LitheTheme.secondaryText)
                TextField("Replace with", text: replaceBinding)
                    .textFieldStyle(.plain)
                    .focused($replaceFocused)
                    .onContinuousHover { phase in
                        if case .active = phase { NSCursor.iBeam.set() }
                        else { NSCursor.arrow.set() }
                    }
                    .macReturnKeyHandler(isEnabled: replaceFocused) { isShiftPressed in
                        if isShiftPressed {
                            model.replaceAllFindMatches()
                        } else {
                            model.replaceNextFindMatch()
                        }
                    }
            }
            .modifier(FindInputChrome(isFocused: replaceFocused))

            Button("Replace") { model.replaceNextFindMatch() }
                .buttonStyle(FindBarButtonStyle(isBordered: true))
                .disabled(chrome.findMatchCount == 0)
                .help("Replace current match (Return)")
            Button("Replace All") { model.replaceAllFindMatches() }
                .buttonStyle(FindBarButtonStyle(isBordered: true))
                .disabled(chrome.findMatchCount == 0)
                .help("Replace all matches (Shift+Return)")
            Spacer(minLength: 0)
        }
    }

    private func optionButton(
        _ title: String, help: String, keyPath: WritableKeyPath<FindInFileOptions, Bool>
    ) -> some View {
        let binding = optionBinding(keyPath)
        return Button { binding.wrappedValue.toggle() } label: {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(binding.wrappedValue ? LitheTheme.accent : LitheTheme.secondaryText)
                .frame(width: 22, height: 22)
                .background(binding.wrappedValue ? LitheTheme.accent.opacity(0.16) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(FindBarButtonStyle())
        .accessibilityLabel(help)
        .accessibilityValue(binding.wrappedValue ? "On" : "Off")
        .help(help)
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
        guard chrome.findMatchCount > 0 else { return "0 results" }
        let current = max(0, chrome.currentFindMatchIndex + 1)
        return "\(current)/\(chrome.findMatchCount)"
    }
}

private struct FindInputChrome: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12.5))
            .foregroundStyle(LitheTheme.primaryText)
            .padding(.horizontal, 7)
            .frame(height: 28)
            .frame(maxWidth: 360)
            .background(LitheTheme.popupBackground, in: RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(isFocused ? LitheTheme.accent : LitheTheme.panelBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

/// Compact toolbar controls keep disabled and cursor states independent of the editor underneath.
private struct FindBarButtonStyle: ButtonStyle {
    var isBordered = false
    var width: CGFloat = 28
    var height: CGFloat = 24
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5))
            .foregroundStyle(isEnabled ? LitheTheme.secondaryText : LitheTheme.secondaryText.opacity(0.4))
            .padding(.horizontal, isBordered ? 12 : 0)
            .frame(minWidth: width, minHeight: height)
            .background {
                RoundedRectangle(cornerRadius: 3)
                    .fill(isEnabled && (isHovering || configuration.isPressed)
                          ? LitheTheme.hoverBackground : Color.clear)
            }
            .overlay {
                if isBordered {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(LitheTheme.panelBorder.opacity(isEnabled ? 1 : 0.5), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovering = true
                    NSCursor.arrow.set()
                case .ended:
                    isHovering = false
                }
            }
    }
}
