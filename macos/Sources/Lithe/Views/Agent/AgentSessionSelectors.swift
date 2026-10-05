import SwiftUI
import LitheAgentConversationModule

private enum AgentSelectorLayout {
    static let choiceRowHeight: CGFloat = 26
    // Leave one point of slack for AppKit's fractional pixel rounding.
    static let modeRowHeight: CGFloat = 50
    static let modeViewportHeight: CGFloat = 320
    static let modeVerticalPadding: CGFloat = 5
}

/// Search and presentation only; the Agent still owns IDs, choices and confirmed values.
enum AgentSessionSelectorPresentation {
    static func filteredChoices(_ option: AgentSessionConfigOption, query: String) -> [AgentSessionConfigOption.Choice] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return option.choices }
        return option.choices.filter {
            [$0.name, $0.id, $0.group ?? ""].contains { $0.localizedStandardContains(query) }
        }
    }

    static func title(_ option: AgentSessionConfigOption) -> String {
        if option.category == "thought_level" { return String(localized: "Thinking level") }
        if option.id == "fast-mode" { return String(localized: "Speed") }
        return localized(option.name)
    }

    static func choiceTitle(_ choice: AgentSessionConfigOption.Choice, in option: AgentSessionConfigOption, bundle: Bundle = .main) -> String {
        if option.id == "fast-mode" {
            if choice.id == "off" { return localized("Standard", bundle: bundle) }
            if choice.id == "on" { return localized("Fast", bundle: bundle) }
        }
        // Agent-owned names must not collide with translations used elsewhere in the app.
        if option.category == "model" || option.category == "mode" || option.category == "thought_level" {
            return choice.name
        }
        return localized(choice.name, bundle: bundle)
    }

    static func currentTitle(_ option: AgentSessionConfigOption, bundle: Bundle = .main) -> String {
        option.choices.first { $0.id == option.currentValue }.map { choiceTitle($0, in: option, bundle: bundle) } ?? option.currentValue
    }

    static func choiceDescription(_ choice: AgentSessionConfigOption.Choice, in option: AgentSessionConfigOption, bundle: Bundle = .main) -> String? {
        if let description = choice.description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return localized(description, bundle: bundle)
        }
        let fallback: String?
        if option.id == "fast-mode" {
            switch choice.id {
            case "off": fallback = "Use the standard response speed"
            case "on": fallback = "Use fast processing"
            default: fallback = nil
            }
        } else if option.category == "thought_level" {
            // These are display hints for known upstream IDs, never a replacement
            // model capability list or a claim about default levels or billing.
            switch choice.id {
            case "low": fallback = "Quick responses with basic reasoning"
            case "medium": fallback = "Balanced reasoning"
            case "high": fallback = "Deep reasoning for complex tasks"
            case "xhigh": fallback = "Extra deep reasoning for demanding tasks"
            case "max": fallback = "Maximum reasoning depth"
            default: fallback = nil
            }
        } else {
            fallback = nil
        }
        return fallback.map { localized($0, bundle: bundle) }
    }

    static func modeIcon(_ id: String) -> String {
        switch id {
        case "read-only", "default", "manual": "bubble.left.and.bubble.right"
        case "agent", "auto": "checkmark.shield"
        case "agent-full-access", "bypassPermissions": "bolt"
        case "acceptEdits": "pencil"
        case "plan": "list.bullet.rectangle"
        default: "slider.horizontal.3"
        }
    }

    static func localized(_ text: String, bundle: Bundle = .main) -> String {
        String(localized: String.LocalizationValue(text), bundle: bundle)
    }
}

/// CC GUI-style bottom toolbar with separate approval and searchable model panels.
struct AgentSessionSelectors: View {
    let options: [AgentSessionConfigOption]
    let agentName: String?
    let isDisabled: Bool
    var appliesToNextTurn = false
    let onSelect: (String, String) -> Void
    @State private var showsModels = false
    @State private var showsModes = false

    private var model: AgentSessionConfigOption? { options.first { $0.category == "model" } }
    private var mode: AgentSessionConfigOption? { options.first { $0.category == "mode" } }
    private var settings: [AgentSessionConfigOption] {
        let remaining = options.filter { $0.id != model?.id && $0.id != mode?.id }
        return remaining.filter { $0.category == "model_config" }
            + remaining.filter { $0.category == "thought_level" }
            + remaining.filter { $0.category != "model_config" && $0.category != "thought_level" }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let mode {
                Button { showsModes.toggle() } label: {
                    selectorLabel {
                        Image(systemName: AgentSessionSelectorPresentation.modeIcon(mode.currentValue))
                        Text(AgentSessionSelectorPresentation.currentTitle(mode))
                    }
                }
                .buttonStyle(.litheNoPress)
                .help(appliesToNextTurn ? String(localized: "Changes apply to the next turn.") : AgentSessionSelectorPresentation.localized(mode.name))
                .accessibilityLabel(Text("Approval mode"))
                .accessibilityValue(AgentSessionSelectorPresentation.currentTitle(mode))
                .accessibilityIdentifier("agent-session-mode-selector")
                .litheDropdown(isPresented: $showsModes, opensUpward: true) {
                    AgentModePopover(option: mode) { value in select(mode.id, value) }
                        .onExitCommand { showsModes = false }
                }
            }
            if let model {
                Button { showsModels.toggle() } label: {
                    selectorLabel {
                        AgentBrandIcon(name: agentName, size: 12, style: .brand)
                        Text(modelSummary(model))
                    }
                }
                .buttonStyle(.litheNoPress)
                .help(appliesToNextTurn ? String(localized: "Changes apply to the next turn.") : model.currentLabel)
                .accessibilityLabel(Text("Model"))
                .accessibilityValue(model.currentLabel)
                .accessibilityIdentifier("agent-session-model-selector")
                .litheDropdown(isPresented: $showsModels, opensUpward: true) {
                    AgentModelPopover(option: model, settings: settings, agentName: agentName, onSelect: select)
                        .onExitCommand { showsModels = false }
                }
            } else if !settings.isEmpty {
                LitheMenu {
                    for option in settings {
                        LitheContextMenuItem.submenu(AgentSessionSelectorPresentation.title(option)) {
                            for choice in option.choices {
                                let title = AgentSessionSelectorPresentation.choiceTitle(choice, in: option)
                                LitheContextMenuItem.action(
                                    choice.group.map { "\($0): \(title)" } ?? title,
                                    checked: choice.id == option.currentValue
                                ) {
                                    select(option.id, choice.id)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(.litheNoPress)
                .fixedSize()
                .help("More session settings")
            }
        }
        .disabled(isDisabled)
        .onChange(of: isDisabled) { disabled in
            if disabled { showsModels = false; showsModes = false }
        }
    }

    private func modelSummary(_ model: AgentSessionConfigOption) -> String {
        let effort = options.first { $0.category == "thought_level" }
        return [model.currentLabel, effort.map { AgentSessionSelectorPresentation.currentTitle($0) }].compactMap { $0 }.joined(separator: " ")
    }

    private func selectorLabel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 5) {
            content()
            Image(systemName: "chevron.up").font(LitheTheme.uiFont(size: 8, weight: .semibold))
        }
        .font(LitheTheme.uiFont(size: 11))
        .foregroundStyle(LitheTheme.secondaryText)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 4)
        .frame(height: 28)
        .contentShape(Rectangle())
        .litheRowHover()
        .lithePointer()
    }

    private func select(_ id: String, _ value: String) {
        guard !isDisabled else { return }
        showsModels = false
        showsModes = false
        onSelect(id, value)
    }
}

struct AgentModelPopover: View {
    let option: AgentSessionConfigOption
    let settings: [AgentSessionConfigOption]
    let agentName: String?
    let onSelect: (String, String) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private var choices: [AgentSessionConfigOption.Choice] { AgentSessionSelectorPresentation.filteredChoices(option, query: query) }

    var body: some View {
        modelPanel
        .foregroundStyle(LitheTheme.primaryText)
        .background(LitheTheme.settingsPopupBackground)
        .onAppear { searchFocused = true }
    }

    private var modelPanel: some View {
        VStack(spacing: 0) {
            LitheSearchTextField("Search models", text: $query)
                .focused($searchFocused)
                .litheSearchField(isFocused: searchFocused)
                .padding(8)
                .onSubmit { if let choice = choices.first { onSelect(option.id, choice.id) } }
            if choices.isEmpty {
                Text("No matching models")
                    .font(LitheTheme.uiFont(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 36)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                            if let group = choice.group, index == 0 || choices[index - 1].group != group {
                                Text(group).font(LitheTheme.uiFont(size: 10)).foregroundStyle(LitheTheme.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 4)
                            }
                            AgentSelectorRow(isSelected: choice.id == option.currentValue, action: { onSelect(option.id, choice.id) }) {
                                AgentBrandIcon(name: agentName, size: 16, style: .brand)
                                Text(choice.name).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(height: min(240, CGFloat(choices.count) * AgentSelectorLayout.choiceRowHeight + CGFloat(choices.filter { $0.group != nil }.count * 20)))
            }
            if !settings.isEmpty {
                Divider().overlay(AgentPanelStyle.border).padding(.vertical, 4)
                ForEach(settings) { setting in
                    AgentModelSettingRow(option: setting, onSelect: onSelect)
                }
            }
        }
        .padding(.bottom, 5)
        .frame(width: 330)
    }
}

/// The shared presenter anchors a separate child panel to this row and keeps
/// the model panel fixed while handling screen edges and dismissal.
private struct AgentModelSettingRow: View {
    let option: AgentSessionConfigOption
    let onSelect: (String, String) -> Void
    @State private var menuRevision = UUID()

    var body: some View {
        LitheMenu(opensToSide: true) {
            for choice in option.choices {
                LitheContextMenuItem.action(
                    AgentSessionSelectorPresentation.choiceTitle(choice, in: option),
                    localizesTitle: false,
                    description: AgentSessionSelectorPresentation.choiceDescription(choice, in: option),
                    checked: choice.id == option.currentValue
                ) { onSelect(option.id, choice.id) }
            }
        } label: {
            HStack {
                Text(AgentSessionSelectorPresentation.title(option))
                Spacer()
                Text(AgentSessionSelectorPresentation.currentTitle(option)).foregroundStyle(LitheTheme.secondaryText)
                Image(systemName: "chevron.right").font(LitheTheme.uiFont(size: 9))
            }
            .frame(minHeight: LitheDropdownMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .id(menuRevision)
        .onChange(of: option) { _ in
            // Action menus retain an opening snapshot. Detach only this anchor
            // when upstream changes it; keep the model panel and search alive.
            menuRevision = UUID()
        }
        .lithePointer()
        .accessibilityIdentifier("agent-model-setting-\(option.id)")
        .accessibilityValue(AgentSessionSelectorPresentation.currentTitle(option))
    }
}

struct AgentModePopover: View {
    let option: AgentSessionConfigOption
    let onSelect: (String) -> Void
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(option.choices) { choice in
                    AgentSelectorRow(isSelected: choice.id == option.currentValue, minimumHeight: AgentSelectorLayout.modeRowHeight, action: { onSelect(choice.id) }) {
                        Image(systemName: AgentSessionSelectorPresentation.modeIcon(choice.id)).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AgentSessionSelectorPresentation.choiceTitle(choice, in: option)).lineLimit(1)
                            if let description = choice.description, !description.isEmpty {
                                Text(AgentSessionSelectorPresentation.localized(description))
                                    .font(LitheTheme.uiFont(size: 11))
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .background {
                GeometryReader { geometry in
                    // Cap the measurement so scrolling a long lazy list cannot keep resizing the popover.
                    Color.clear.preference(key: AgentModeContentHeightKey.self,
                                           value: min(AgentSelectorLayout.modeViewportHeight, geometry.size.height))
                }
            }
        }
        .onPreferenceChange(AgentModeContentHeightKey.self) { height in
            if abs(height - contentHeight) > 0.5 { contentHeight = height }
        }
        .padding(.vertical, AgentSelectorLayout.modeVerticalPadding)
        .frame(width: 350, height: min(AgentSelectorLayout.modeViewportHeight,
                                     max(CGFloat(option.choices.count) * AgentSelectorLayout.modeRowHeight, contentHeight))
                + 2 * AgentSelectorLayout.modeVerticalPadding)
        .background(LitheTheme.settingsPopupBackground)
    }
}

private struct AgentModeContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct AgentSelectorRow<Content: View>: View {
    let isSelected: Bool
    var minimumHeight: CGFloat = LitheDropdownMetrics.rowHeight
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                content
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(LitheTheme.uiFont(size: 11, weight: .semibold))
                    .foregroundStyle(LitheTheme.accent)
                    .opacity(isSelected ? 1 : 0)
            }
            .font(.system(size: 12))
            .foregroundStyle(AgentPanelStyle.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(LitheDropdownRowStyle(isSelected: isSelected))
        .lithePointer()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
