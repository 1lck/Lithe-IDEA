import SwiftUI

/// A choice of an option field, shared by plugin settings and the fields of
/// project generators.
struct PluginFieldOption: Equatable, Hashable, Sendable {
    let value: String
    let title: String
    /// Heading the option is listed under; options of a group are adjacent.
    var group: String? = nil
}

/// A menu of checkboxes; the value is the checked options in declared order.
struct PluginMultiSelectField: View {
    let options: [PluginFieldOption]
    var width: CGFloat = 200
    let selected: [String]
    let accessibilityLabel: String
    let onChange: ([String]) -> Void

    private var summary: String {
        let titles = options.filter { selected.contains($0.value) }.map(\.title)
        if titles.isEmpty { return String(localized: "None") }
        return titles.joined(separator: ", ")
    }

    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 8) {
                Text(verbatim: summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(LitheTheme.uiFont(size: 9, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .rotationEffect(.degrees(isPresented ? 180 : 0))
            }
            .padding(.horizontal, 9)
            .frame(width: width, height: SettingsSelectMetrics.controlHeight, alignment: .leading)
            .litheSettingsControlChrome(
                background: LitheTheme.settingsSelectBackground,
                border: isPresented ? LitheTheme.settingsControlAccent : LitheTheme.settingsControlBorder,
                lineWidth: isPresented ? 2 : 1
            )
        }
        .buttonStyle(.litheNoPress)
        .lithePointer()
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .litheDropdown(isPresented: $isPresented) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element.value) { index, option in
                        // Options of one group are declared together; the
                        // heading goes before the first of them.
                        if let group = option.group, index == 0 || options[index - 1].group != group {
                            Text(LocalizedStringKey(group))
                                .font(LitheTheme.uiFont(size: 11, weight: .semibold))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .padding(.horizontal, SettingsSelectMetrics.itemHorizontalPadding)
                                .padding(.top, index == 0 ? 2 : 8)
                                .padding(.bottom, 2)
                        }
                        Button { toggle(option.value) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selected.contains(option.value) ? "checkmark" : "")
                                    .frame(width: 16)
                                Text(verbatim: option.title)
                                Spacer(minLength: 12)
                            }
                        }
                        .buttonStyle(LitheDropdownRowStyle(isSelected: false))
                    }
                }
            }
            .frame(width: width)
            .frame(maxHeight: SettingsSelectMetrics.maximumPopupHeight)
        }
    }

    private func toggle(_ value: String) {
        var next = Set(selected)
        if next.contains(value) { next.remove(value) } else { next.insert(value) }
        onChange(options.map(\.value).filter(next.contains))
    }
}

/// A one-line field saved whenever the text is acceptable. Rust Core's rules
/// (whole-match pattern, length, absolute paths) are mirrored by `accepts`,
/// and Core checks again before any value reaches a process.
struct PluginTextSettingField: View {
    let value: String
    let placeholder: String?
    let width: CGFloat
    var isFlexible = false
    let accessibilityLabel: String
    let savesWhileTyping: Bool
    let accepts: (String) -> Bool
    let onChange: (String) -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            LitheTextField(verbatim: placeholder ?? "", text: $text, focus: $isFocused)
                .frame(minWidth: isFlexible ? 0 : width, idealWidth: width, maxWidth: width)
                .accessibilityLabel(Text(verbatim: accessibilityLabel))
                .onSubmit(commit)
                .onChange(of: text) { _ in
                    if savesWhileTyping, isFocused, accepts(text), text != value { onChange(text) }
                }
                .onChange(of: isFocused) { focused in
                    guard !focused else { return }
                    if savesWhileTyping { text = value } else { commit() }
                }
            if !accepts(text) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LitheTheme.warning)
                    .help(Text(LocalizedStringKey("This value is not allowed.")))
            }
        }
        .onAppear { text = value }
        .onChange(of: value) { _ in
            if !isFocused { text = value }
        }
    }

    private func commit() {
        if accepts(text) {
            if text != value { onChange(text) }
        } else {
            text = value
        }
    }
}
