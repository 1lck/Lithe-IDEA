import AppKit
import SwiftUI

private enum SettingsSelectMetrics {
    static let controlHeight: CGFloat = 28
    static let controlCornerRadius: CGFloat = 4
    static let fontSize: CGFloat = 12.5
    static let popupCornerRadius: CGFloat = 8
    static let itemHeight: CGFloat = 24
    static let itemHorizontalPadding: CGFloat = 8
    static let popupPadding: CGFloat = 6
    static let screenMargin: CGFloat = 24
    static let maximumPopupHeight: CGFloat = 10 * itemHeight + 2 * popupPadding
}

private struct LitheSettingsControlChrome: ViewModifier {
    let background: Color
    let border: Color
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(background)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(border, lineWidth: 1)
            }
    }
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
            LitheIDEAIcon(resourcePath: "expui/general/search.svg", size: 16, fallbackSystemImage: "magnifyingglass", preservesOriginalColors: true)

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
                .buttonStyle(.litheNoPress)
                .lithePointer()
                .help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .litheSettingsControlChrome(background: .clear)
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
    @State private var popupID = UUID()
    @State private var popupAnchor = LitheSettingsSelectAnchorReference()

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
            if isPresented {
                LitheSettingsSelectPopupPresenter.shared.dismiss(ownerID: popupID)
            } else {
                showPopup()
            }
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
            .frame(width: width, height: SettingsSelectMetrics.controlHeight, alignment: .leading)
            .litheSettingsControlChrome(border: isPresented ? LitheTheme.settingsControlAccent : LitheTheme.settingsControlBorder)
            .background(LitheSettingsSelectAnchorView(reference: popupAnchor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .lithePointer()
        .accessibilityLabel(Text(LocalizedStringKey(accessibilityLabel)))
        .accessibilityValue(Text(LocalizedStringKey(title(selection))))
        .onChange(of: options) { _ in
            if isPresented { showPopup() }
        }
        .onDisappear {
            LitheSettingsSelectPopupPresenter.shared.dismiss(ownerID: popupID)
        }
    }

    private func showPopup() {
        guard let anchor = popupAnchor.view, let window = anchor.window else { return }
        let anchorFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchorFrame
        let popupWidth = preferredPopupWidth(maximumWidth: max(1, visibleFrame.width - SettingsSelectMetrics.screenMargin))
        let state = LitheSettingsSelectPopupState(
            selectedIndex: options.firstIndex(of: selection) ?? 0,
            optionCount: options.count
        ) { index in
            let option = options[index]
            if isAvailable(option) {
                selection = option
            } else {
                onUnavailableSelection?(option)
            }
            LitheSettingsSelectPopupPresenter.shared.dismiss(ownerID: popupID)
        }
        let content = LitheSettingsSelectPopupContent(
            state: state,
            options: options,
            width: popupWidth,
            title: title,
            expandsToFitOptions: expandsToFitOptions,
            isAvailable: isAvailable
        )
        let measured = NSHostingView(rootView: content.rows.environment(\.locale, locale))
        let popupHeight = min(
            measured.fittingSize.height,
            SettingsSelectMetrics.maximumPopupHeight,
            max(1, visibleFrame.height - SettingsSelectMetrics.screenMargin)
        )
        let popup = content.environment(\.locale, locale)
        LitheSettingsSelectPopupPresenter.shared.show(
            ownerID: popupID,
            content: AnyView(popup),
            state: state,
            anchorFrame: anchorFrame,
            size: NSSize(width: popupWidth, height: popupHeight),
            visibleFrame: visibleFrame,
            appearance: window.effectiveAppearance
        ) {
            isPresented = false
        }
        isPresented = true
    }

    private func preferredPopupWidth(maximumWidth: CGFloat) -> CGFloat {
        guard expandsToFitOptions else { return width }
        let font = NSFont.systemFont(ofSize: SettingsSelectMetrics.fontSize)
        let titleWidth = options.reduce(CGFloat.zero) { widest, option in
            let text = String(localized: String.LocalizationValue(title(option)), locale: locale)
            return max(widest, (text as NSString).size(withAttributes: [.font: font]).width)
        }
        let chromeWidth = 2 * SettingsSelectMetrics.itemHorizontalPadding
            + 2 * SettingsSelectMetrics.popupPadding
        let contentWidth = max(width, ceil(titleWidth) + chromeWidth)
        // Derive the width from current titles when discovery refreshes an open list.
        return min(contentWidth, maximumWidth)
    }
}

private final class LitheSettingsSelectAnchorReference {
    weak var view: NSView?
}

private struct LitheSettingsSelectAnchorView: NSViewRepresentable {
    let reference: LitheSettingsSelectAnchorReference

    func makeNSView(context: Context) -> NSView {
        let view = LitheSettingsSelectAnchorNSView()
        reference.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        reference.view = view
    }
}

private final class LitheSettingsSelectAnchorNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class LitheSettingsSelectPopupState: ObservableObject {
    let selectedIndex: Int
    @Published var highlightedIndex: Int
    @Published var keyboardScrollIndex: Int?
    @Published var popupHeight: CGFloat = 0
    let optionCount: Int
    let onChoose: (Int) -> Void

    init(selectedIndex: Int, optionCount: Int, onChoose: @escaping (Int) -> Void) {
        self.selectedIndex = selectedIndex
        highlightedIndex = selectedIndex
        self.optionCount = optionCount
        self.onChoose = onChoose
    }

    func handleKey(_ event: NSEvent, dismiss: () -> Void) -> Bool {
        switch event.keyCode {
        case 125, 126: // Down / Up
            guard optionCount > 0 else { return true }
            highlightedIndex = (highlightedIndex + (event.keyCode == 125 ? 1 : optionCount - 1)) % optionCount
            keyboardScrollIndex = highlightedIndex
        case 36, 76: // Return / keypad Enter
            guard optionCount > 0 else { return true }
            onChoose(highlightedIndex)
        case 53: // Escape
            dismiss()
        default:
            return false
        }
        return true
    }
}

private struct LitheSettingsSelectPopupContent<Value: Hashable>: View {
    @ObservedObject var state: LitheSettingsSelectPopupState
    let options: [Value]
    let width: CGFloat
    let title: (Value) -> String
    let expandsToFitOptions: Bool
    let isAvailable: (Value) -> Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                rows
            }
            .onAppear { proxy.scrollTo(state.highlightedIndex) }
            .onChange(of: state.keyboardScrollIndex) { index in
                if let index { proxy.scrollTo(index) }
            }
        }
        .scrollContentBackground(.hidden)
        .frame(width: width, height: state.popupHeight)
        .litheSettingsControlChrome(
            background: LitheTheme.settingsPopupBackground,
            border: LitheTheme.settingsPopupBorder,
            cornerRadius: SettingsSelectMetrics.popupCornerRadius
        )
        .clipShape(RoundedRectangle(cornerRadius: SettingsSelectMetrics.popupCornerRadius))
    }

    var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button {
                    state.onChoose(index)
                } label: {
                    HStack {
                        Text(LocalizedStringKey(title(option)))
                            .font(.system(size: SettingsSelectMetrics.fontSize))
                            .foregroundStyle(
                                isAvailable(option)
                                    ? (state.highlightedIndex == index ? LitheTheme.settingsSelectionText : LitheTheme.primaryText)
                                    : LitheTheme.tertiaryText
                            )
                            .lineLimit(expandsToFitOptions ? nil : 1)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, SettingsSelectMetrics.itemHorizontalPadding)
                    .padding(.vertical, expandsToFitOptions ? 4 : 0)
                    .frame(maxWidth: .infinity, minHeight: SettingsSelectMetrics.itemHeight, alignment: .leading)
                    .litheRowHover(
                        isActive: state.highlightedIndex == index,
                        cornerRadius: SettingsSelectMetrics.controlCornerRadius,
                        activeBackground: LitheTheme.settingsSelection.opacity(isAvailable(option) ? 1 : 0.35)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .accessibilityAddTraits(state.selectedIndex == index ? .isSelected : [])
                .onHover { hovering in
                    if hovering { state.highlightedIndex = index }
                }
                .id(index)
                .help(isAvailable(option) ? "" : "Shell is not available at this path")
            }
        }
        .padding(SettingsSelectMetrics.popupPadding)
        .frame(width: width)
    }
}

struct LitheSettingsSelectPopupGeometry {
    static func frame(anchor: NSRect, size: NSSize, visibleFrame: NSRect) -> NSRect {
        let bounds = visibleFrame.insetBy(dx: 6, dy: 6)
        let width = min(size.width, bounds.width)
        let below = max(0, anchor.minY - bounds.minY - 2)
        let above = max(0, bounds.maxY - anchor.maxY - 2)
        let opensBelow = below >= size.height || below >= above
        let height = min(size.height, opensBelow ? below : above)
        let preferredY = opensBelow
            ? anchor.minY - height - 2
            : anchor.maxY + 2
        return NSRect(
            x: min(max(anchor.minX, bounds.minX), bounds.maxX - width),
            y: min(max(preferredY, bounds.minY), bounds.maxY - height),
            width: width,
            height: height
        )
    }
}

@MainActor
private final class LitheSettingsSelectPopupPanel: NSPanel {
    var handleKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
private final class LitheSettingsSelectPopupPresenter: NSObject, NSWindowDelegate {
    static let shared = LitheSettingsSelectPopupPresenter()

    private var panel: LitheSettingsSelectPopupPanel?
    private var ownerID: UUID?
    private var onDismiss: (() -> Void)?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    func show(
        ownerID: UUID,
        content: AnyView,
        state: LitheSettingsSelectPopupState,
        anchorFrame: NSRect,
        size: NSSize,
        visibleFrame: NSRect,
        appearance: NSAppearance,
        onDismiss: @escaping () -> Void
    ) {
        dismiss()
        let frame = LitheSettingsSelectPopupGeometry.frame(
            anchor: anchorFrame, size: size, visibleFrame: visibleFrame
        )
        state.popupHeight = frame.height
        let panel = LitheSettingsSelectPopupPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.handleKey = { [weak self, weak state] event in
            state?.handleKey(event) { self?.dismiss(ownerID: ownerID) } ?? false
        }
        panel.contentViewController = NSHostingController(rootView: content)
        panel.appearance = appearance
        panel.animationBehavior = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.delegate = self
        self.panel = panel
        self.ownerID = ownerID
        self.onDismiss = onDismiss
        installEventMonitors()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func dismiss(ownerID: UUID? = nil) {
        guard ownerID == nil || ownerID == self.ownerID else { return }
        removeEventMonitors()
        let callback = onDismiss
        onDismiss = nil
        self.ownerID = nil
        let closingPanel = panel
        panel = nil
        closingPanel?.delegate = nil
        closingPanel?.orderOut(nil)
        closingPanel?.close()
        callback?()
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    private func installEventMonitors() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel { self.dismiss() }
            return event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func removeEventMonitors() {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
        localEventMonitor = nil
        globalEventMonitor = nil
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
                        .foregroundStyle(selection == option ? LitheTheme.settingsSelectionText : LitheTheme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .contentShape(Rectangle())
                        .litheRowHover(
                            isActive: selection == option,
                            cornerRadius: SettingsSelectMetrics.controlCornerRadius,
                            activeBackground: LitheTheme.settingsSelection
                        )
                }
                .buttonStyle(.litheNoPress)
                .lithePointer()
                .accessibilityValue(selection == option ? Text("Selected") : Text("Not selected"))
            }
        }
        .padding(2)
        .frame(width: width, height: SettingsSelectMetrics.controlHeight)
        .litheSettingsControlChrome()
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
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white)
                        .opacity(isOn ? 1 : 0)
                }
                .frame(width: 16, height: 16)
                .litheSettingsControlChrome(
                    background: isOn ? LitheTheme.settingsControlAccent : LitheTheme.settingsControlBackground,
                    border: isOn ? LitheTheme.settingsControlAccent : LitheTheme.settingsControlBorder,
                    cornerRadius: 3
                )

                if let title {
                    Text(title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(LitheTheme.primaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .lithePointer()
        .accessibilityRepresentation {
            Toggle(accessibilityLabel, isOn: $isOn)
        }
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
                .fill(LitheTheme.settingsControlBorder)
                .frame(width: 1, height: 18)

            stepButton(systemImage: "minus", isDisabled: value <= range.lowerBound) {
                value = max(range.lowerBound, value.advanced(by: -step))
            }

            stepButton(systemImage: "plus", isDisabled: value >= range.upperBound) {
                value = min(range.upperBound, value.advanced(by: step))
            }
        }
        .frame(width: width, height: SettingsSelectMetrics.controlHeight)
        .litheSettingsControlChrome()
        .clipShape(RoundedRectangle(cornerRadius: SettingsSelectMetrics.controlCornerRadius))
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
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .litheRowHover(cornerRadius: 0)
        }
        .buttonStyle(.litheNoPress)
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
            .frame(height: SettingsSelectMetrics.controlHeight)
            .litheSettingsControlChrome(background: LitheTheme.settingsTextFieldBackground)
            .opacity(isEnabled ? 1 : 0.55)
    }
}

extension View {
    func litheSettingsControlChrome(
        background: Color = LitheTheme.settingsControlBackground,
        border: Color = LitheTheme.settingsControlBorder,
        cornerRadius: CGFloat = SettingsSelectMetrics.controlCornerRadius
    ) -> some View {
        modifier(LitheSettingsControlChrome(background: background, border: border, cornerRadius: cornerRadius))
    }

    func litheSettingsTextField() -> some View {
        modifier(LitheSettingsTextFieldModifier())
    }

    func litheSettingsTextEditor() -> some View {
        scrollContentBackground(.hidden)
            .litheSettingsControlChrome(background: LitheTheme.settingsTextFieldBackground)
    }
}
