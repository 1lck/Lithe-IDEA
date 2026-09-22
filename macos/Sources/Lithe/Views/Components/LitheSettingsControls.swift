import AppKit
import SwiftUI

private enum SettingsSelectMetrics {
    static let fontSize: CGFloat = 12.5
    static let checkmarkWidth: CGFloat = 14
    static let itemSpacing: CGFloat = 8
    static let itemHorizontalPadding: CGFloat = 8
    static let popupPadding: CGFloat = 5
    static let screenMargin: CGFloat = 24
}

struct LitheSettingsSearchField: View {
    private let placeholder: LocalizedStringKey
    @Binding private var text: String
    private let onTextChanged: ((String) -> Void)?

    init(
        _ placeholder: LocalizedStringKey,
        text: Binding<String>,
        onTextChanged: ((String) -> Void)? = nil
    ) {
        self.placeholder = placeholder
        _text = text
        self.onTextChanged = onTextChanged
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LitheTheme.tertiaryText)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(LitheTheme.tertiaryText)
                }
                .buttonStyle(.plain)
                .lithePointer()
                .help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                .stroke(LitheTheme.inputBorder, lineWidth: 1)
        }
        .onChange(of: text) { value in
            onTextChanged?(value)
        }
    }
}

struct LitheSettingsSelect<Value: Hashable>: View {
    @Environment(\.locale) private var locale
    @Binding private var selection: Value
    private let options: [Value]
    private let width: CGFloat
    private let accessibilityLabel: String
    private let title: (Value) -> String
    private let expandsToFitOptions: Bool
    private let isAvailable: (Value) -> Bool
    private let onUnavailableSelection: ((Value) -> Void)?
    @State private var isPresented = false
    @State private var availablePopupWidth: CGFloat?

    init(
        selection: Binding<Value>,
        options: [Value],
        width: CGFloat,
        accessibilityLabel: String,
        title: @escaping (Value) -> String,
        expandsToFitOptions: Bool = false,
        isAvailable: @escaping (Value) -> Bool = { _ in true },
        onUnavailableSelection: ((Value) -> Void)? = nil
    ) {
        _selection = selection
        self.options = options
        self.width = width
        self.accessibilityLabel = accessibilityLabel
        self.title = title
        self.expandsToFitOptions = expandsToFitOptions
        self.isAvailable = isAvailable
        self.onUnavailableSelection = onUnavailableSelection
    }

    var body: some View {
        Button {
            if !isPresented {
                // Capture the presenting screen before the popover can become the key window.
                let screen = NSApp.keyWindow?.screen ?? NSScreen.main
                availablePopupWidth = screen.map {
                    max(1, $0.visibleFrame.width - 2 * SettingsSelectMetrics.screenMargin)
                }
            }
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(LocalizedStringKey(title(selection)))
                    .font(.system(size: 12.5))
                    .foregroundStyle(isAvailable(selection) ? LitheTheme.primaryText : LitheTheme.tertiaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .rotationEffect(.degrees(isPresented ? 180 : 0))
            }
            .padding(.horizontal, 9)
            .frame(width: width, height: 30, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                    .fill(LitheTheme.settingsControlBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                    .stroke(isPresented ? LitheTheme.inputFocusBorder : LitheTheme.inputBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
        .accessibilityLabel(Text(LocalizedStringKey(accessibilityLabel)))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                ForEach(options, id: \.self) { option in
                    Button {
                        if isAvailable(option) {
                            selection = option
                        } else {
                            onUnavailableSelection?(option)
                        }
                        isPresented = false
                    } label: {
                        HStack(spacing: SettingsSelectMetrics.itemSpacing) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(LitheTheme.accent)
                                .frame(width: SettingsSelectMetrics.checkmarkWidth)
                                .opacity(selection == option ? 1 : 0)

                            Text(LocalizedStringKey(title(option)))
                                .font(.system(size: SettingsSelectMetrics.fontSize))
                                .foregroundStyle(isAvailable(option) ? LitheTheme.primaryText : LitheTheme.tertiaryText)
                                .lineLimit(expandsToFitOptions ? nil : 1)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)

                            Spacer(minLength: SettingsSelectMetrics.itemSpacing)
                        }
                        .padding(.horizontal, SettingsSelectMetrics.itemHorizontalPadding)
                        .padding(.vertical, expandsToFitOptions ? 4 : 0)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .litheRowHover(
                            isActive: selection == option,
                            activeBackground: LitheTheme.subtleSelection.opacity(isAvailable(option) ? 1 : 0.35)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(LitheTreeRowButtonStyle())
                    .lithePointer()
                    .help(isAvailable(option) ? "" : "Shell is not available at this path")
                }
            }
            .padding(SettingsSelectMetrics.popupPadding)
            .frame(width: preferredPopupWidth)
            .lithePopupChrome(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
        }
    }

    private var preferredPopupWidth: CGFloat {
        guard expandsToFitOptions else { return width }
        let font = NSFont.systemFont(ofSize: SettingsSelectMetrics.fontSize)
        let titleWidth = options.reduce(CGFloat.zero) { widest, option in
            let text = String(localized: String.LocalizationValue(title(option)), locale: locale)
            return max(widest, (text as NSString).size(withAttributes: [.font: font]).width)
        }
        // Include the checkmark, both HStack gaps, trailing spacer, and both layers of padding.
        let chromeWidth = SettingsSelectMetrics.checkmarkWidth
            + 3 * SettingsSelectMetrics.itemSpacing
            + 2 * SettingsSelectMetrics.itemHorizontalPadding
            + 2 * SettingsSelectMetrics.popupPadding
        let contentWidth = max(width, ceil(titleWidth) + chromeWidth)
        // Derive the width from current titles so discovery updates also resize an open popover.
        return min(contentWidth, availablePopupWidth ?? width)
    }
}

struct LitheSettingsSegmentedControl<Value: Hashable>: View {
    @Binding private var selection: Value
    private let options: [Value]
    private let width: CGFloat
    private let title: (Value) -> String

    init(
        selection: Binding<Value>,
        options: [Value],
        width: CGFloat,
        title: @escaping (Value) -> String
    ) {
        _selection = selection
        self.options = options
        self.width = width
        self.title = title
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(LocalizedStringKey(title(option)))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == option ? Color.white : LitheTheme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .contentShape(Rectangle())
                        .litheRowHover(
                            isActive: selection == option,
                            cornerRadius: LitheTheme.Metrics.cornerRadius,
                            activeBackground: LitheTheme.settingsSelection
                        )
                }
                .buttonStyle(LitheTreeRowButtonStyle())
                .lithePointer()
            }
        }
        .padding(2)
        .frame(width: width, height: 30)
        .background(
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                .fill(LitheTheme.settingsControlBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                .stroke(LitheTheme.inputBorder, lineWidth: 1)
        }
    }
}

struct LitheSettingsCheckbox: View {
    @Binding var isOn: Bool
    private let title: LocalizedStringKey?
    private let accessibilityLabel: LocalizedStringKey

    init(isOn: Binding<Bool>, title: LocalizedStringKey) {
        _isOn = isOn
        self.title = title
        accessibilityLabel = title
    }

    init(isOn: Binding<Bool>, accessibilityLabel: LocalizedStringKey) {
        _isOn = isOn
        title = nil
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn ? LitheTheme.accent : LitheTheme.inputBackground)
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isOn ? LitheTheme.accent : LitheTheme.inputBorder, lineWidth: 1)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white)
                        .opacity(isOn ? 1 : 0)
                }
                .frame(width: 16, height: 16)

                if let title {
                    Text(title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(LitheTheme.primaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LitheTreeRowButtonStyle())
        .lithePointer()
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

struct LitheSettingsStepper<Value>: View where Value: Strideable & Comparable, Value.Stride: SignedNumeric & Comparable {
    @Binding private var value: Value
    private let range: ClosedRange<Value>
    private let step: Value.Stride
    private let width: CGFloat
    private let accessibilityLabel: LocalizedStringKey
    private let title: (Value) -> String

    init(
        value: Binding<Value>,
        in range: ClosedRange<Value>,
        step: Value.Stride,
        width: CGFloat,
        accessibilityLabel: LocalizedStringKey,
        title: @escaping (Value) -> String
    ) {
        _value = value
        self.range = range
        self.step = step
        self.width = width
        self.accessibilityLabel = accessibilityLabel
        self.title = title
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(title(value))
                .font(.system(size: 12.5))
                .foregroundStyle(LitheTheme.primaryText)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 8)

            Rectangle()
                .fill(LitheTheme.inputBorder)
                .frame(width: 1, height: 20)

            stepButton(systemImage: "minus", isDisabled: value <= range.lowerBound) {
                value = max(range.lowerBound, value.advanced(by: -step))
            }

            stepButton(systemImage: "plus", isDisabled: value >= range.upperBound) {
                value = min(range.upperBound, value.advanced(by: step))
            }
        }
        .frame(width: width, height: 30)
        .background(
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                .fill(LitheTheme.inputBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                .stroke(LitheTheme.inputBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private func stepButton(
        systemImage: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isDisabled ? LitheTheme.tertiaryText : LitheTheme.secondaryText)
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
                .litheRowHover(cornerRadius: 0)
        }
        .buttonStyle(LitheTreeRowButtonStyle())
        .disabled(isDisabled)
        .lithePointer()
    }
}

private struct LitheSettingsTextFieldModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                    .fill(LitheTheme.inputBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                    .stroke(LitheTheme.inputBorder, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.55)
    }
}

extension View {
    func litheSettingsTextField() -> some View {
        modifier(LitheSettingsTextFieldModifier())
    }
}
