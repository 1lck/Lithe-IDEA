import SwiftUI
import LitheAgentConversationModule

private enum AgentSelectorLayout {
    static let choiceRowHeight: CGFloat = 26
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
                LitheMenu(opensUpward: true) {
                    LitheContextMenuItem.heading("Mode", centered: true)
                    for choice in mode.choices {
                        LitheContextMenuItem.action(
                            AgentSessionSelectorPresentation.choiceTitle(choice, in: mode),
                            localizesTitle: false,
                            checked: choice.id == mode.currentValue,
                            leadingCheckmark: true,
                            initiallySelected: choice.id == mode.currentValue
                        ) { select(mode.id, choice.id) }
                    }
                } label: {
                    selectorLabel(expandsDownward: true) {
                        Text(AgentSessionSelectorPresentation.currentTitle(mode))
                            .font(LitheTheme.settingsFont)
                    }
                }
                .litheToolbarIconButton(isIconOnly: false)
                .id(isDisabled)
                .help(appliesToNextTurn ? String(localized: "Changes apply to the next turn.")
                      : mode.choices.first(where: { $0.id == mode.currentValue })
                        .flatMap { AgentSessionSelectorPresentation.choiceDescription($0, in: mode) }
                        ?? AgentSessionSelectorPresentation.localized(mode.name))
                .accessibilityLabel(Text("Approval mode"))
                .accessibilityValue(AgentSessionSelectorPresentation.currentTitle(mode))
                .accessibilityIdentifier("agent-session-mode-selector")
            }
            if let model {
                Button { showsModels.toggle() } label: {
                    selectorLabel {
                        AgentBrandIcon(name: agentName, size: 12, style: .brand)
                        Text(modelSummary(model))
                    }
                }
                .litheToolbarIconButton(isIconOnly: false)
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
                    LitheIDEAIcon(resourcePath: "expui/general/moreHorizontal.svg", size: LitheTheme.Metrics.toolbarIconSize,
                                  fallbackSystemImage: "ellipsis", preservesOriginalColors: true)
                }
                .litheToolbarIconButton()
                .fixedSize()
                .help("More session settings")
            }
        }
        .disabled(isDisabled)
        .onChange(of: isDisabled) { disabled in
            if disabled { showsModels = false }
        }
    }

    private func modelSummary(_ model: AgentSessionConfigOption) -> String {
        let effort = options.first { $0.category == "thought_level" }
        return [model.currentLabel, effort.map { AgentSessionSelectorPresentation.currentTitle($0) }].compactMap { $0 }.joined(separator: " ")
    }

    private func selectorLabel<Content: View>(expandsDownward: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 5) {
            content()
            LitheIDEAIcon(resourcePath: expandsDownward ? "expui/general/chevronDown.svg" : "expui/general/chevronUp.svg", size: LitheTheme.Metrics.toolbarIconSize,
                          fallbackSystemImage: expandsDownward ? "chevron.down" : "chevron.up", preservesOriginalColors: true)
        }
        .font(LitheTheme.uiFont(size: 11))
        .foregroundStyle(LitheTheme.secondaryText)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 4)
    }

    private func select(_ id: String, _ value: String) {
        guard !isDisabled else { return }
        showsModels = false
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
            .font(LitheTheme.uiFont(size: LitheDropdownMetrics.fontSize))
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
