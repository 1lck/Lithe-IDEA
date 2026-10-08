import AppKit
import SwiftUI

private enum SettingsSelectMetrics {
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

private struct LitheSettingsControlChrome: ViewModifier {
    let background: Color
    let border: Color
    let cornerRadius: CGFloat
    var lineWidth: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(background)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(border, lineWidth: lineWidth)
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

struct LitheSettingsSearchField: View {
    /// Height shared with the popups that host this field, so a searchable list
    /// reserves exactly the room the field occupies.
    static let height: CGFloat = 28

    @FocusState private var isFocused: Bool
    private let externalFocus: FocusState<Bool>.Binding?
    private let placeholder: LocalizedStringKey
    @Binding private var text: String
    private let onTextChanged: ((String) -> Void)?

    init(
        _ placeholder: LocalizedStringKey,
        text: Binding<String>,
        focus: FocusState<Bool>.Binding? = nil,
        onTextChanged: ((String) -> Void)? = nil
    ) {
        self.placeholder = placeholder
        _text = text
        externalFocus = focus
        self.onTextChanged = onTextChanged
    }

    var body: some View {
        HStack(spacing: 7) {
            LitheIDEAIcon(resourcePath: "expui/general/search.svg", size: 16, fallbackSystemImage: "magnifyingglass", preservesOriginalColors: true)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(LitheTheme.settingsFont)
                .focused(externalFocus ?? $isFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(LitheTheme.uiFont(size: 11))
                        .foregroundStyle(LitheTheme.tertiaryText)
                }
                .buttonStyle(.litheNoPress)
                .lithePointer()
                .help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: Self.height)
        .litheSettingsControlChrome(
            background: .clear,
            border: (externalFocus?.wrappedValue ?? isFocused) ? LitheTheme.settingsControlAccent : LitheTheme.settingsControlBorder
        )
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
                ? String(localized: String.LocalizationValue(text), locale: locale)
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
        return LitheSettingsSearchField.height
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
            let text = localizesTitles ? String(localized: String.LocalizationValue(title(option)), locale: locale) : title(option)
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
                LitheSettingsSearchField(searchPrompt, text: $state.query)
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
                        .font(LitheTheme.uiFont(size: 12, weight: .medium))
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
                    Text(title)
                        .font(LitheTheme.uiFont(size: 12.5))
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
        .accessibilityLabel(Text(accessibilityLabel))
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

private struct LitheSettingsTextFieldModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(LitheTheme.settingsFont)
            .focused($isFocused)
            .padding(.horizontal, 9)
            .frame(height: SettingsSelectMetrics.controlHeight)
            .litheSettingsControlChrome(
                background: LitheTheme.settingsTextFieldBackground,
                border: isFocused ? LitheTheme.settingsControlAccent : LitheTheme.settingsControlBorder
            )
            .opacity(isEnabled ? 1 : 0.55)
    }
}

private struct LitheSettingsTextEditorModifier: ViewModifier {
    @FocusState private var isFocused: Bool
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .font(LitheTheme.uiFont(size: 12, design: .monospaced))
            .focused($isFocused)
            .frame(height: height)
            .padding(5)
            .litheSettingsControlChrome(
                background: LitheTheme.settingsTextFieldBackground,
                border: isFocused ? LitheTheme.settingsControlAccent : LitheTheme.settingsControlBorder
            )
    }
}

extension View {
    func litheSettingsControlChrome(
        background: Color = LitheTheme.settingsControlBackground,
        border: Color = LitheTheme.settingsControlBorder,
        cornerRadius: CGFloat = SettingsSelectMetrics.controlCornerRadius,
        lineWidth: CGFloat = 1
    ) -> some View {
        modifier(LitheSettingsControlChrome(background: background, border: border, cornerRadius: cornerRadius, lineWidth: lineWidth))
    }

    func litheSettingsTextField() -> some View {
        modifier(LitheSettingsTextFieldModifier())
    }

    func litheSettingsTextEditor(height: CGFloat) -> some View {
        modifier(LitheSettingsTextEditorModifier(height: height))
    }
}
