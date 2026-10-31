import LitheModuleAPI
import AppKit
import SwiftUI

enum SettingsSelectMetrics {
    static let controlHeight: CGFloat = 28
    static let controlCornerRadius: CGFloat = 4
    static let fontSize: CGFloat = LitheDropdownMetrics.fontSize
    static let popupCornerRadius: CGFloat = LitheTheme.Metrics.contextMenuCornerRadius
    static let itemHeight: CGFloat = LitheDropdownMetrics.rowHeight
    static let itemHorizontalPadding: CGFloat = LitheDropdownMetrics.itemHorizontalPadding
    static let popupPadding: CGFloat = LitheDropdownMetrics.popupPadding
    static let screenMargin: CGFloat = 24
    /// Rows shown before the popup scrolls. Also bounds a filtered searchable
    /// list so typing narrows the popup instead of growing it.
    static let maximumVisibleRows = 10
    static let maximumPopupHeight: CGFloat = CGFloat(maximumVisibleRows) * itemHeight + 2 * popupPadding
    /// Gap between the search field and the first row of a searchable list.
    static let searchSpacing: CGFloat = 6
}

/// DarculaNewUIUtil.paintRectangleImpl uses an outer-minus-inner rounded path.
private struct LitheSettingsControlBorder: Shape {
    let cornerRadius: CGFloat
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
            let innerRadius = max(0, cornerRadius - lineWidth)
            path.addRoundedRect(in: rect.insetBy(dx: lineWidth, dy: lineWidth),
                                cornerSize: CGSize(width: innerRadius, height: innerRadius))
        }
    }
}

private struct LitheSettingsControlChrome: ViewModifier {
    let background: Color
    let border: Color
    let cornerRadius: CGFloat
    var lineWidth: CGFloat = 1
    var borderOutset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(background)
            }
            .overlay {
                LitheSettingsControlBorder(cornerRadius: cornerRadius, lineWidth: lineWidth)
                    .fill(border, style: FillStyle(eoFill: true))
                    .padding(-borderOutset)
                    .allowsHitTesting(false)
            }
    }
}

struct LitheSettingsSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(LocalizedStringKey(title))
                    .font(LitheTheme.uiFont(size: 12, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize()
                accessory
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            LitheSettingsCard { content }
        }
        .font(LitheTheme.settingsFont)
        .foregroundStyle(LitheTheme.primaryText)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension LitheSettingsSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

/// The white rounded card a settings section draws its rows on. Each direct
/// child becomes one line of the card with a hairline between lines, the way
/// macOS System Settings groups its rows.
struct LitheSettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        _VariadicView.Tree(LitheSettingsCardLines()) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The hairline ring stands in for a drop shadow: a shadow on the
            // card would re-render every row offscreen on each resize frame.
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LitheTheme.settingsCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(LitheTheme.settingsCardRing, lineWidth: 0.5)
            )
    }
}

private struct LitheSettingsCardLines: _VariadicView_UnaryViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let firstID = children.first?.id
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in
                if child.id != firstID {
                    Rectangle()
                        .fill(LitheTheme.settingsCardDivider)
                        .frame(height: 1)
                }
                child
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// One setting: a bounded label column, the control after it, and optional
/// status pills on the trailing edge (effective value, scope, when it takes
/// effect). Matches the `.srow` row of the settings mockup.
struct LitheSettingsRow<Control: View, Badges: View>: View {
    static var labelWidth: CGFloat { 230 }

    private let title: LocalizedStringKey
    private let info: LocalizedStringKey?
    private let isModified: Bool
    private let control: Control
    private let badges: Badges

    init(
        _ title: LocalizedStringKey,
        info: LocalizedStringKey? = nil,
        isModified: Bool = false,
        @ViewBuilder control: () -> Control,
        @ViewBuilder badges: () -> Badges
    ) {
        self.title = title
        self.info = info
        self.isModified = isModified
        self.control = control()
        self.badges = badges()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 5) {
                Text(title)
                    .foregroundStyle(LitheTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let info { LitheInfoTip(info) }
            }
            .frame(minWidth: 0, idealWidth: Self.labelWidth, maxWidth: Self.labelWidth, alignment: .leading)
            HStack(spacing: 6) { control }
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) { badges }
                .fixedSize()
        }
        .frame(minHeight: 30)
        .overlay(alignment: .leading) {
            if isModified {
                Circle()
                    .fill(LitheTheme.accent)
                    .frame(width: 6, height: 6)
                    .offset(x: -10)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension LitheSettingsRow where Badges == EmptyView {
    init(
        _ title: LocalizedStringKey,
        info: LocalizedStringKey? = nil,
        isModified: Bool = false,
        @ViewBuilder control: () -> Control
    ) {
        self.init(title, info: info, isModified: isModified, control: control, badges: { EmptyView() })
    }
}

/// A small capsule that reports a fact about a setting, such as the value in
/// effect or whether this project overrides it.
struct LitheSettingsPill: View {
    enum Kind {
        case neutral, project, effect, value
    }

    private let text: Text
    private let kind: Kind
    /// A long value wraps onto more lines instead of keeping its full width,
    /// so it cannot push the row past its container.
    private let wraps: Bool

    init(_ title: LocalizedStringKey, kind: Kind = .neutral) {
        self.text = Text(title)
        self.kind = kind
        self.wraps = false
    }

    init(verbatim title: String, kind: Kind = .neutral, wraps: Bool = false) {
        self.text = Text(verbatim: title)
        self.kind = kind
        self.wraps = wraps
    }

    var body: some View {
        text
            .font(kind == .value
                  ? LitheTheme.uiFont(size: 10.5, design: .monospaced)
                  : LitheTheme.uiFont(size: 10.5))
            .lineLimit(wraps ? nil : 1)
            .multilineTextAlignment(.leading)
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: wraps ? 10 : 100, style: .continuous).fill(background)
            )
            .modifier(PillSizing(wraps: wraps))
    }

    private var foreground: Color {
        switch kind {
        case .neutral: LitheTheme.settingsPillText
        case .project: LitheTheme.settingsProjectPillText
        case .effect: LitheTheme.settingsEffectPillText
        case .value: LitheTheme.settingsValuePillText
        }
    }

    private var background: Color {
        switch kind {
        case .neutral: LitheTheme.settingsPill
        case .project: LitheTheme.settingsProjectPill
        case .effect: LitheTheme.settingsEffectPill
        case .value: LitheTheme.settingsValuePill
        }
    }
}

private struct PillSizing: ViewModifier {
    let wraps: Bool

    func body(content: Content) -> some View {
        if wraps {
            content.fixedSize(horizontal: false, vertical: true)
        } else {
            content.fixedSize()
        }
    }
}

/// A quiet heading inside a card that splits its rows into named groups.
struct LitheSettingsSubheading: View {
    private let title: Text

    init(_ title: LocalizedStringKey) { self.title = Text(title) }
    init(verbatim title: String) { self.title = Text(verbatim: title) }

    var body: some View {
        title
            .font(LitheTheme.uiFont(size: 11, weight: .semibold))
            .foregroundStyle(LitheTheme.tertiaryText)
            .padding(.top, 4)
    }
}

/// A card-styled strip at the top of a page, for who provides the page and
/// which layer the page edits.
struct LitheSettingsBanner<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .font(LitheTheme.uiFont(size: 12))
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LitheTheme.settingsCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(LitheTheme.settingsCardRing, lineWidth: 0.5)
            )
            .padding(.bottom, 12)
    }
}

/// The amber bar that says a change waits for a restart, with the action.
struct LitheSettingsNotice<Actions: View>: View {
    private let message: Text
    @ViewBuilder private let actions: Actions

    init(_ message: LocalizedStringKey, @ViewBuilder actions: () -> Actions) {
        self.message = Text(message)
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise")
            message.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions
        }
        .font(LitheTheme.uiFont(size: 12))
        .foregroundStyle(LitheTheme.settingsNoticeText)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(LitheTheme.settingsNoticeBackground))
        .padding(.bottom, 12)
    }
}

/// A setting label followed by an optional ⓘ explanation.
///
/// Settings pages put explanatory copy here instead of below the control, so a
/// page stays scannable and the explanation appears only when the pointer rests
/// on the icon. The tip opens after `LitheInfoTip`'s hover delay.
struct LitheSettingsLabel: View {
    private let title: Text
    private let info: LitheInfoTip?
    private var wrapsTitle = false

    init(_ title: LocalizedStringKey, info: LocalizedStringKey? = nil) {
        self.title = Text(title)
        self.info = info.map { LitheInfoTip($0) }
    }

    init(verbatim title: String, info: String? = nil) {
        self.title = Text(verbatim: title)
        self.info = info.map { LitheInfoTip(verbatim: $0) }
        wrapsTitle = true
    }

    init(_ title: Text, info: String? = nil) {
        self.title = title
        self.info = info.map { LitheInfoTip(verbatim: $0) }
        wrapsTitle = true
    }

    var body: some View {
        HStack(spacing: LitheInfoTip.labelSpacing) {
            title.fixedSize(horizontal: !wrapsTitle, vertical: false)
            if let info { info }
        }
    }
}

/// Matching rule for the searchable settings selector, kept separate from the
/// SwiftUI view so the filtering contract can be tested directly.
enum LitheSettingsSelectSearch {
    /// Case- and diacritic-insensitive containment. An empty or whitespace-only
    /// query matches everything, so clearing the field restores the full list.
    static func matches(_ candidate: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        return candidate.localizedStandardContains(trimmed)
    }
}

struct LitheSettingsSelect<Value: Hashable>: View {
    @Environment(\.locale) private var locale
    @Binding private var selection: Value
    private let options: [Value]
    private let width: CGFloat
    private let accessibilityLabel: String
    private let title: (Value) -> String
    private let localizesTitles: Bool
    private let expandsToFitOptions: Bool
    private let isAvailable: (Value) -> Bool
    private let onUnavailableSelection: ((Value) -> Void)?
    /// When set, the popup shows a search field above the rows and filters the
    /// options as the user types. Existing callers leave it nil and keep the
    /// plain, unfiltered list.
    private let searchPrompt: LocalizedStringKey?
    private let searchText: (Value) -> String
    @State private var isPresented = false
    @FocusState private var isFocused: Bool
    @State private var popupID = UUID()
    @State private var popupAnchor = LitheSettingsSelectAnchorReference()

    init(
        selection: Binding<Value>,
        options: [Value],
        width: CGFloat,
        accessibilityLabel: String,
        title: @escaping (Value) -> String,
        localizesTitles: Bool = true,
        expandsToFitOptions: Bool = false,
        isAvailable: @escaping (Value) -> Bool = { _ in true },
        onUnavailableSelection: ((Value) -> Void)? = nil,
        searchPrompt: LocalizedStringKey? = nil,
        searchText: ((Value) -> String)? = nil
    ) {
        _selection = selection
        self.options = options
        self.width = width
        self.accessibilityLabel = accessibilityLabel
        self.title = title
        self.localizesTitles = localizesTitles
        self.expandsToFitOptions = expandsToFitOptions
        self.isAvailable = isAvailable
        self.onUnavailableSelection = onUnavailableSelection
        self.searchPrompt = searchPrompt
        self.searchText = searchText ?? title
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
                (localizesTitles ? Text(LocalizedStringKey(title(selection))) : Text(verbatim: title(selection)))
                    .font(LitheTheme.settingsFont)
                    .foregroundStyle(isAvailable(selection) ? LitheTheme.primaryText : LitheTheme.tertiaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Image(systemName: "chevron.down")
                    .font(LitheTheme.uiFont(size: 9, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .rotationEffect(.degrees(isPresented ? 180 : 0))
            }
            .padding(.horizontal, 9)
            .frame(width: width, height: SettingsSelectMetrics.controlHeight, alignment: .leading)
            .litheSettingsControlChrome(
                background: LitheTheme.settingsSelectBackground,
                border: isPresented || isFocused ? LitheTheme.settingsControlAccent : LitheTheme.settingsControlBorder,
                lineWidth: isPresented || isFocused ? 2 : 1
            )
            .background(LitheSettingsSelectAnchorView(reference: popupAnchor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .focused($isFocused)
        .lithePointer()
        .accessibilityLabel(Text(LocalizedStringKey(accessibilityLabel)))
        .accessibilityValue(localizesTitles ? Text(LocalizedStringKey(title(selection))) : Text(verbatim: title(selection)))
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
            visibleIndicesProvider: visibleIndices(for:),
            isSearchEnabled: searchPrompt != nil
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
            localizesTitles: localizesTitles,
            expandsToFitOptions: expandsToFitOptions,
            isAvailable: isAvailable,
            searchPrompt: searchPrompt
        )
        let popupHeight = searchPrompt == nil
            ? measuredPopupHeight(content: content, visibleFrame: visibleFrame)
            : preferredPopupHeight(rows: state.visibleIndices.count)
        let popup = content.environment(\.locale, locale)
        LitheSettingsSelectPopupPresenter.shared.show(
            ownerID: popupID,
            content: AnyView(popup),
            state: state,
            anchorWindow: window,
            anchorFrame: anchorFrame,
            size: NSSize(width: popupWidth, height: popupHeight),
            visibleFrame: visibleFrame,
            appearance: window.effectiveAppearance
        ) {
            isPresented = false
        }
        // A filtered list is shorter than the unfiltered one, so the popup has to
        // follow the visible row count while the user types.
        state.onPreferredHeightChange = { [weak state] in
            guard let state else { return }
            LitheSettingsSelectPopupPresenter.shared.resize(
                ownerID: popupID,
                preferredHeight: preferredPopupHeight(rows: state.visibleIndices.count),
                state: state
            )
        }
        isPresented = true
    }

    /// Options matching the current query, as indices into `options`. Keeping
    /// indices (rather than copied values) lets selection and availability keep
    /// operating on the caller's own list.
    private func visibleIndices(for query: String) -> [Int] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Array(options.indices)
        }

        return options.indices.filter { index in
            let text = searchText(options[index])
            let searchable = localizesTitles
                ? L10n.string(String.LocalizationValue(text), locale: locale)
                : text
            return LitheSettingsSelectSearch.matches(searchable, query: query)
        }
    }

    /// Deterministic height for a searchable list: the search field plus whole
    /// rows, so filtering shrinks the popup instead of leaving empty space.
    /// Room the search field adds above the rows: its own height, the gap before
    /// the first row, and the same top padding the rows container already owns.
    private var searchFieldCost: CGFloat {
        guard searchPrompt != nil else { return 0 }
        return LitheSearchField<EmptyView>.height
            + SettingsSelectMetrics.searchSpacing
            + SettingsSelectMetrics.popupPadding
    }

    /// How many rows fit before the popup reaches the shared height cap. With
    /// search enabled the field takes part of that budget, so the popup stays
    /// within `maximumPopupHeight` instead of growing past it.
    private var maximumPopupRows: Int {
        let rowSpace = SettingsSelectMetrics.maximumPopupHeight
            - 2 * SettingsSelectMetrics.popupPadding
            - searchFieldCost
        return max(1, Int(rowSpace / SettingsSelectMetrics.itemHeight))
    }

    /// Deterministic height for a searchable list: whole rows plus the search
    /// field, so filtering shrinks the popup instead of leaving empty space.
    private func preferredPopupHeight(rows: Int) -> CGFloat {
        let visibleRows = max(1, min(rows, maximumPopupRows))
        return CGFloat(visibleRows) * SettingsSelectMetrics.itemHeight
            + 2 * SettingsSelectMetrics.popupPadding
            + searchFieldCost
    }

    /// Height for lists whose rows are not uniform, measured from the rows
    /// themselves exactly as before the searchable variant existed.
    private func measuredPopupHeight(
        content: LitheSettingsSelectPopupContent<Value>,
        visibleFrame: NSRect
    ) -> CGFloat {
        let measured = NSHostingView(rootView: content.rows.environment(\.locale, locale))
        return min(
            measured.fittingSize.height,
            SettingsSelectMetrics.maximumPopupHeight,
            max(1, visibleFrame.height - SettingsSelectMetrics.screenMargin)
        )
    }

    private func preferredPopupWidth(maximumWidth: CGFloat) -> CGFloat {
        guard expandsToFitOptions else { return width }
        let font = LitheTheme.uiNSFont(size: SettingsSelectMetrics.fontSize)
        let titleWidth = options.reduce(CGFloat.zero) { widest, option in
            let text = localizesTitles ? L10n.string(String.LocalizationValue(title(option)), locale: locale) : title(option)
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
    /// Row highlighted inside `visibleIndices`, not inside `options`.
    @Published var highlightedIndex: Int
    @Published var keyboardScrollIndex: Int?
    @Published var popupHeight: CGFloat = 0
    /// Options currently shown, as indices into the caller's `options`.
    @Published private(set) var visibleIndices: [Int]
    /// Search query owned by the popup so filtering and keyboard selection share
    /// one source of truth.
    @Published var query = "" {
        didSet { refreshVisibleIndices() }
    }
    let isSearchEnabled: Bool
    let onChoose: (Int) -> Void
    /// Reports the height the popup should adopt after the visible row count
    /// changes. Unused by the non-searchable variant.
    var onPreferredHeightChange: (() -> Void)?

    private let visibleIndicesProvider: (String) -> [Int]

    init(
        selectedIndex: Int,
        visibleIndicesProvider: @escaping (String) -> [Int],
        isSearchEnabled: Bool,
        onChoose: @escaping (Int) -> Void
    ) {
        self.selectedIndex = selectedIndex
        self.visibleIndicesProvider = visibleIndicesProvider
        self.isSearchEnabled = isSearchEnabled
        self.onChoose = onChoose
        let initialVisibleIndices = visibleIndicesProvider("")
        visibleIndices = initialVisibleIndices
        highlightedIndex = initialVisibleIndices.firstIndex(of: selectedIndex) ?? 0
    }

    func refreshVisibleIndices() {
        visibleIndices = visibleIndicesProvider(query)
        highlightedIndex = visibleIndices.firstIndex(of: selectedIndex) ?? 0
        keyboardScrollIndex = highlightedIndex
        onPreferredHeightChange?()
    }

    func handleKey(_ event: NSEvent, dismiss: () -> Void) -> Bool {
        switch event.keyCode {
        case 125, 126: // Down / Up
            guard !visibleIndices.isEmpty else { return true }
            let step = event.keyCode == 125 ? 1 : visibleIndices.count - 1
            highlightedIndex = (highlightedIndex + step) % visibleIndices.count
            keyboardScrollIndex = highlightedIndex
        case 36, 76: // Return / keypad Enter
            guard visibleIndices.indices.contains(highlightedIndex) else { return true }
            onChoose(visibleIndices[highlightedIndex])
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
    let localizesTitles: Bool
    let expandsToFitOptions: Bool
    let isAvailable: (Value) -> Bool
    let searchPrompt: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 0) {
            if let searchPrompt {
                LitheSearchField(searchPrompt, text: $state.query)
                    .padding(.horizontal, SettingsSelectMetrics.popupPadding)
                    .padding(.top, SettingsSelectMetrics.popupPadding)
                    .padding(.bottom, SettingsSelectMetrics.searchSpacing)
            }

            if state.visibleIndices.isEmpty {
                emptyState
            } else {
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
            }
        }
        .frame(width: width, height: state.popupHeight)
        .litheContextMenuSurface()
        .clipShape(RoundedRectangle(cornerRadius: SettingsSelectMetrics.popupCornerRadius))
    }

    /// Searchable lists can legitimately match nothing; say so instead of
    /// showing a blank panel that looks like a rendering failure.
    private var emptyState: some View {
        Text("No matching items")
            .font(LitheTheme.uiFont(size: SettingsSelectMetrics.fontSize))
            .foregroundStyle(LitheTheme.tertiaryText)
            .padding(.horizontal, SettingsSelectMetrics.itemHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: SettingsSelectMetrics.itemHeight, alignment: .leading)
            .padding(SettingsSelectMetrics.popupPadding)
    }

    var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(state.visibleIndices.enumerated()), id: \.offset) { row, optionIndex in
                let option = options[optionIndex]
                Button {
                    state.onChoose(optionIndex)
                } label: {
                    HStack {
                        (localizesTitles ? Text(LocalizedStringKey(title(option))) : Text(verbatim: title(option)))
                            .font(LitheTheme.uiFont(size: SettingsSelectMetrics.fontSize))
                            .foregroundStyle(
                                isAvailable(option)
                                    ? (state.highlightedIndex == row ? LitheTheme.settingsSelectionText : LitheTheme.primaryText)
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
                        isActive: state.highlightedIndex == row,
                        cornerRadius: SettingsSelectMetrics.controlCornerRadius,
                        activeBackground: LitheTheme.settingsSelection.opacity(isAvailable(option) ? 1 : 0.35)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
                .accessibilityAddTraits(state.selectedIndex == optionIndex ? .isSelected : [])
                .onHover { hovering in
                    if hovering { state.highlightedIndex = row }
                }
                .id(row)
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
    private weak var anchorWindow: NSWindow?
    private var anchorFrame: NSRect?
    private var visibleFrame: NSRect?
    private var ownerID: UUID?
    private var onDismiss: (() -> Void)?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    func show(
        ownerID: UUID,
        content: AnyView,
        state: LitheSettingsSelectPopupState,
        anchorWindow: NSWindow,
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
        panel.handleKey = { [weak self, weak state, weak panel] event in
            guard let state else { return false }
            // A composing input method owns navigation keys: intercepting them
            // would commit or cancel the composition instead of moving in the list.
            if state.isSearchEnabled, let panel, self?.isComposing(in: panel) == true { return false }
            return state.handleKey(event) { self?.dismiss(ownerID: ownerID) }
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
        self.anchorWindow = anchorWindow
        self.anchorFrame = anchorFrame
        self.visibleFrame = visibleFrame
        self.ownerID = ownerID
        self.onDismiss = onDismiss
        installEventMonitors()
        panel.setFrame(frame, display: true)
        anchorWindow.addChildWindow(panel, ordered: .above)
        panel.orderFrontRegardless()
        panel.makeKey()
        // The panel is key but has no text field of its own until the searchable
        // content is loaded, so the caret is placed after the first layout pass.
        if state.isSearchEnabled {
            panel.contentView?.layoutSubtreeIfNeeded()
            focusSearchField(in: panel)
        }
    }

    /// Resizes an open popup after a searchable list changed its visible row
    /// count. Reuses the anchored geometry so the popup keeps hugging its trigger
    /// and stays inside the visible frame.
    func resize(ownerID: UUID, preferredHeight: CGFloat, state: LitheSettingsSelectPopupState) {
        guard ownerID == self.ownerID, let panel, let anchorFrame, let visibleFrame else { return }
        let frame = LitheSettingsSelectPopupGeometry.frame(
            anchor: anchorFrame,
            size: NSSize(width: panel.frame.width, height: preferredHeight),
            visibleFrame: visibleFrame
        )
        state.popupHeight = frame.height
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func focusSearchField(in panel: NSPanel) {
        guard let content = panel.contentView, let field = searchField(in: content) else { return }
        panel.makeFirstResponder(field)
    }

    private func isComposing(in panel: NSPanel) -> Bool {
        guard let content = panel.contentView, let field = searchField(in: content) else { return false }
        return (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
    }

    private func searchField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, field.isEnabled { return field }
        return view.subviews.lazy.compactMap { self.searchField(in: $0) }.first
    }

    func dismiss(ownerID: UUID? = nil) {
        guard ownerID == nil || ownerID == self.ownerID else { return }
        removeEventMonitors()
        let callback = onDismiss
        onDismiss = nil
        self.ownerID = nil
        anchorWindow = nil
        anchorFrame = nil
        visibleFrame = nil
        let closingPanel = panel
        panel = nil
        if let closingPanel { closingPanel.parent?.removeChildWindow(closingPanel) }
        closingPanel?.delegate = nil
        closingPanel?.orderOut(nil)
        closingPanel?.close()
        callback?()
    }

    func windowDidResignKey(_ notification: Notification) {
        if !LitheDropdownAnchorGeometry.isAnchorClick(
            NSApp.currentEvent, anchorWindow: anchorWindow, anchorFrame: anchorFrame
        ) { dismiss() }
    }

    private func installEventMonitors() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel && !LitheDropdownAnchorGeometry.isAnchorClick(
                event, anchorWindow: self.anchorWindow, anchorFrame: self.anchorFrame
            ) { self.dismiss() }
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
    private let localizesTitles: Bool

    init(
        selection: Binding<Value>,
        options: [Value],
        width: CGFloat,
        title: @escaping (Value) -> String,
        localizesTitles: Bool = true
    ) {
        _selection = selection
        self.options = options
        self.width = width
        self.title = title
        self.localizesTitles = localizesTitles
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    (localizesTitles ? Text(LocalizedStringKey(title(option))) : Text(verbatim: title(option)))
                        .font(LitheTheme.uiFont(size: 12, weight: .medium))
                        .litheSettingsSegmentedOption(isSelected: selection == option)
                }
                .buttonStyle(.litheNoPress)
                .lithePointer()
                .accessibilityValue(selection == option ? Text("Selected") : Text("Not selected"))
            }
        }
        .litheSettingsSegmentedChrome(width: width)
    }
}

struct LitheSettingsCheckbox: View {
    @Binding var isOn: Bool
    private let title: Text?
    private let accessibilityLabel: Text

    init(isOn: Binding<Bool>, title: LocalizedStringKey) {
        _isOn = isOn
        self.title = Text(title)
        accessibilityLabel = Text(title)
    }

    init(isOn: Binding<Bool>, accessibilityLabel: LocalizedStringKey) {
        _isOn = isOn
        title = nil
        self.accessibilityLabel = Text(accessibilityLabel)
    }

    init(isOn: Binding<Bool>, verbatimTitle: String) {
        _isOn = isOn
        title = Text(verbatim: verbatimTitle)
        accessibilityLabel = Text(verbatim: verbatimTitle)
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Image(systemName: "checkmark")
                        .font(LitheTheme.uiFont(size: 9, weight: .bold))
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
                    title
                        .font(LitheTheme.uiFont(size: 12.5))
                        .foregroundStyle(LitheTheme.primaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .lithePointer()
        .accessibilityRepresentation {
            Toggle(isOn: $isOn) { accessibilityLabel }
        }
    }
}

struct LitheSettingsStepper<Value>: View where Value: Strideable & Comparable, Value.Stride: SignedNumeric & Comparable {
    @Binding private var value: Value
    private let range: ClosedRange<Value>
    private let step: Value.Stride
    private let width: CGFloat
    private let accessibilityLabel: Text
    private let title: (Value) -> String
    /// Turns typed text into a value; nil keeps the value read-only.
    private let parse: ((String) -> Value?)?
    @State private var draft = ""
    @FocusState private var isEditing: Bool

    init(
        value: Binding<Value>,
        in range: ClosedRange<Value>,
        step: Value.Stride,
        width: CGFloat,
        accessibilityLabel: LocalizedStringKey,
        title: @escaping (Value) -> String,
        parse: ((String) -> Value?)? = nil
    ) {
        _value = value
        self.range = range
        self.step = step
        self.width = width
        self.accessibilityLabel = Text(accessibilityLabel)
        self.title = title
        self.parse = parse
    }

    init(
        value: Binding<Value>, in range: ClosedRange<Value>, step: Value.Stride, width: CGFloat,
        verbatimAccessibilityLabel: String, title: @escaping (Value) -> String
    ) {
        _value = value
        self.range = range
        self.step = step
        self.width = width
        accessibilityLabel = Text(verbatim: verbatimAccessibilityLabel)
        self.title = title
        parse = nil
    }

    var body: some View {
        HStack(spacing: 0) {
            valueLabel
                .font(LitheTheme.settingsFont)
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
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var valueLabel: some View {
        if parse != nil {
            TextField(text: $draft) { accessibilityLabel }
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .focused($isEditing)
                .onSubmit(commitDraft)
                .onAppear { draft = title(value) }
                .onChange(of: isEditing) { editing in if !editing { commitDraft() } }
                .onChange(of: value) { newValue in if !isEditing { draft = title(newValue) } }
        } else {
            Text(title(value))
        }
    }

    /// Typed values are clamped to the range; text that does not parse restores the value.
    private func commitDraft() {
        if let parsed = parse?(draft) {
            value = min(range.upperBound, max(range.lowerBound, parsed))
        }
        draft = title(value)
    }

    private func stepButton(
        systemImage: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(LitheTheme.uiFont(size: 9, weight: .semibold))
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

extension View {
    func litheSettingsSegmentedOption(isSelected: Bool) -> some View {
        self
            .foregroundStyle(isSelected ? LitheTheme.settingsSelectionText : LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 24)
            .contentShape(Rectangle())
            .litheRowHover(
                isActive: isSelected,
                cornerRadius: SettingsSelectMetrics.controlCornerRadius,
                activeBackground: LitheTheme.settingsSelection
            )
    }

    func litheSettingsSegmentedChrome(width: CGFloat? = nil) -> some View {
        padding(2)
            .frame(width: width, height: SettingsSelectMetrics.controlHeight)
            .litheSettingsControlChrome()
    }

    func litheSettingsControlChrome(
        background: Color = LitheTheme.settingsControlBackground,
        border: Color = LitheTheme.settingsControlBorder,
        cornerRadius: CGFloat = SettingsSelectMetrics.controlCornerRadius,
        lineWidth: CGFloat = 1,
        borderOutset: CGFloat = 0
    ) -> some View {
        modifier(LitheSettingsControlChrome(background: background, border: border, cornerRadius: cornerRadius,
                                           lineWidth: lineWidth, borderOutset: borderOutset))
    }

}
