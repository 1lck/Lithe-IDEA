import SwiftUI
import LitheAgentConversationModule

private enum AgentSelectorLayout {
    static let choiceRowHeight = LitheDropdownMetrics.rowHeight
    static let minimumModelPanelWidth: CGFloat = 300
}

/// Presentation only; the Agent still owns IDs, choices and confirmed values.
enum AgentSessionSelectorPresentation {
    static func title(_ option: AgentSessionConfigOption, locale: Locale = .current) -> String {
        if option.category == "thought_level" { return AgentLocalization.string("Thinking level", locale: locale) }
        if option.id == "fast-mode" { return AgentLocalization.string("Speed", locale: locale) }
        return localized(option.name, locale: locale)
    }

    static func choiceTitle(_ choice: AgentSessionConfigOption.Choice, in option: AgentSessionConfigOption, bundle: Bundle = .main, locale: Locale = .current) -> String {
        if option.id == "fast-mode" {
            if choice.id == "off" { return localized("Standard", bundle: bundle, locale: locale) }
            if choice.id == "on" { return localized("Fast", bundle: bundle, locale: locale) }
        }
        // Agent-owned names must not collide with translations used elsewhere in the app.
        if option.category == "model" || option.category == "mode" || option.category == "thought_level" {
            return choice.name
        }
        return localized(choice.name, bundle: bundle, locale: locale)
    }

    static func currentTitle(_ option: AgentSessionConfigOption, bundle: Bundle = .main, locale: Locale = .current) -> String {
        option.choices.first { $0.id == option.currentValue }.map { choiceTitle($0, in: option, bundle: bundle, locale: locale) } ?? option.currentValue
    }

    static func choiceDescription(_ choice: AgentSessionConfigOption.Choice, in option: AgentSessionConfigOption, bundle: Bundle = .main, locale: Locale = .current) -> String? {
        if let description = choice.description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return localized(description, bundle: bundle, locale: locale)
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
        return fallback.map { localized($0, bundle: bundle, locale: locale) }
    }

    static func localized(_ text: String, bundle: Bundle = .main, locale: Locale = .current) -> String {
        AgentLocalization.string(String.LocalizationValue(text), locale: locale, bundle: bundle)
    }
}

/// CC GUI-style bottom toolbar with separate approval and model panels.
struct AgentSessionSelectors: View {
    @Environment(\.locale) private var locale
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
                            AgentSessionSelectorPresentation.choiceTitle(choice, in: mode, locale: locale),
                            localizesTitle: false,
                            checked: choice.id == mode.currentValue,
                            leadingCheckmark: true,
                            initiallySelected: choice.id == mode.currentValue
                        ) { select(mode.id, choice.id) }
                    }
                } label: {
                    selectorLabel(expandsDownward: true) {
                        Text(AgentSessionSelectorPresentation.currentTitle(mode, locale: locale))
                            .font(LitheTheme.settingsFont)
                    }
                }
                .litheToolbarIconButton(isIconOnly: false)
                .id(isDisabled)
                .help(appliesToNextTurn ? AgentLocalization.string("Changes apply to the next turn.", locale: locale)
                      : mode.choices.first(where: { $0.id == mode.currentValue })
                        .flatMap { AgentSessionSelectorPresentation.choiceDescription($0, in: mode, locale: locale) }
                        ?? AgentSessionSelectorPresentation.localized(mode.name, locale: locale))
                .accessibilityLabel(Text("Approval mode"))
                .accessibilityValue(AgentSessionSelectorPresentation.currentTitle(mode, locale: locale))
                .accessibilityIdentifier("agent-session-mode-selector")
            }
            if let model {
                Button { showsModels.toggle() } label: {
                    selectorLabel(expandsDownward: true) {
                        AgentBrandIcon(name: agentName, size: 12, style: .brand)
                        Text(modelSummary(model))
                    }
                }
                .litheToolbarIconButton(isIconOnly: false)
                .help(appliesToNextTurn ? AgentLocalization.string("Changes apply to the next turn.", locale: locale) : model.currentLabel)
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
                        LitheContextMenuItem.submenu(AgentSessionSelectorPresentation.title(option, locale: locale)) {
                            for choice in option.choices {
                                let title = AgentSessionSelectorPresentation.choiceTitle(choice, in: option, locale: locale)
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
    }

    private func modelSummary(_ model: AgentSessionConfigOption) -> String {
        let effort = options.first { $0.category == "thought_level" }
        return [model.currentLabel, effort.map { AgentSessionSelectorPresentation.currentTitle($0, locale: locale) }].compactMap { $0 }.joined(separator: " ")
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
        // Effort supports repeated adjustment in place. Pending configuration
        // disables the open panel until acknowledgement instead of dismissing it.
        if options.first(where: { $0.id == id })?.category != "thought_level" {
            showsModels = false
        }
        onSelect(id, value)
    }
}

struct AgentModelPopover: View {
    let option: AgentSessionConfigOption
    let settings: [AgentSessionConfigOption]
    let agentName: String?
    let onSelect: (String, String) -> Void
    @Environment(\.locale) private var locale
    private var choices: [AgentSessionConfigOption.Choice] { option.choices }

    private var reasoning: [AgentSessionConfigOption] { settings.filter { $0.category == "thought_level" } }
    private var otherSettings: [AgentSessionConfigOption] { settings.filter { $0.category != "thought_level" } }
    private var panelWidth: CGFloat {
        let modelItems = option.choices.map {
            LitheContextMenuItem.action($0.name, localizesTitle: false, leadingCheckmark: true) {}
        }
        let settingItems = settings.flatMap { setting -> [LitheContextMenuItem] in
            if setting.category == "thought_level" {
                return setting.choices.map { LitheContextMenuItem.action($0.name, localizesTitle: false, leadingCheckmark: true) {} }
            }
            return [.action(AgentSessionSelectorPresentation.title(setting, locale: locale) + "  " + AgentSessionSelectorPresentation.currentTitle(setting, locale: locale),
                            localizesTitle: false, systemImage: "chevron.right") {}]
        }
        let menuWidth = LitheContextMenuPresenter.menuWidth(for: modelItems + settingItems, locale: locale)
        let effortWidth = reasoning.map { AgentReasoningEffortControl.preferredWidth(for: $0, locale: locale) }.max() ?? 0
        return min(LitheDropdownMetrics.maximumWidth,
                   max(AgentSelectorLayout.minimumModelPanelWidth, max(menuWidth, effortWidth)))
    }

    var body: some View {
        modelPanel
        .foregroundStyle(LitheTheme.primaryText)
        .background(LitheTheme.settingsPopupBackground)
    }

    private var modelPanel: some View {
        VStack(spacing: 0) {
            Text("Model").font(LitheTheme.settingsStrongFont)
                .frame(maxWidth: .infinity, minHeight: LitheDropdownMetrics.rowHeight)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if choices.isEmpty {
                            Text("No models available")
                                .font(LitheTheme.settingsFont).foregroundStyle(LitheTheme.secondaryText)
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                            if let group = choice.group, index == 0 || choices[index - 1].group != group {
                                Text(group).font(LitheTheme.uiFont(size: 10)).foregroundStyle(LitheTheme.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 4)
                            }
                            AgentSelectorRow(isSelected: choice.id == option.currentValue, action: { onSelect(option.id, choice.id) }) {
                                Text(choice.name).lineLimit(1).truncationMode(.tail)
                            }
                            .help(choice.description ?? choice.name)
                        }
                    }
                    .padding(.horizontal, LitheDropdownMetrics.popupPadding)
                }
                .litheScrollViewChrome()
                .frame(height: min(LitheDropdownMetrics.rowHeight * 15,
                    CGFloat(choices.count) * AgentSelectorLayout.choiceRowHeight
                    + CGFloat(choices.enumerated().filter { index, choice in
                        choice.group != nil && (index == 0 || choices[index - 1].group != choice.group)
                    }.count) * 20 + (choices.isEmpty ? 36 : 0)))
            ForEach(reasoning) { setting in
                AgentReasoningEffortControl(option: setting, onSelect: onSelect)
                    .padding(.vertical, 4)
            }
            if !otherSettings.isEmpty {
                Divider().overlay(AgentPanelStyle.border).padding(.vertical, 4)
                ForEach(otherSettings) { setting in
                    AgentModelSettingRow(option: setting, onSelect: onSelect)
                }
            }
        }
        .padding(.bottom, 5)
        .frame(width: panelWidth)
        .font(LitheTheme.settingsFont)
    }
}

/// The shared presenter anchors a separate child panel to this row and keeps
/// the model panel fixed while handling screen edges and dismissal.
private struct AgentModelSettingRow: View {
    @Environment(\.locale) private var locale
    let option: AgentSessionConfigOption
    let onSelect: (String, String) -> Void
    @State private var menuRevision = UUID()

    var body: some View {
        LitheMenu(opensToSide: true) {
            for choice in option.choices {
                LitheContextMenuItem.action(
                    AgentSessionSelectorPresentation.choiceTitle(choice, in: option, locale: locale),
                    localizesTitle: false,
                    description: AgentSessionSelectorPresentation.choiceDescription(choice, in: option, locale: locale),
                    checked: choice.id == option.currentValue
                ) { onSelect(option.id, choice.id) }
            }
        } label: {
            HStack {
                Text(AgentSessionSelectorPresentation.title(option, locale: locale))
                Spacer()
                Text(AgentSessionSelectorPresentation.currentTitle(option, locale: locale)).foregroundStyle(LitheTheme.secondaryText)
                Image(systemName: "chevron.right").font(LitheTheme.uiFont(size: 9))
            }
            .frame(minHeight: LitheDropdownMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .id(menuRevision)
        .onChange(of: option) { _ in
            // Action menus retain an opening snapshot. Detach only this anchor
            // when upstream changes it; keep the model panel alive.
            menuRevision = UUID()
        }
        .accessibilityIdentifier("agent-model-setting-\(option.id)")
        .accessibilityValue(AgentSessionSelectorPresentation.currentTitle(option, locale: locale))
    }
}

private struct AgentSelectorRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                LitheIDEAIcon(resourcePath: "expui/actions/checked.svg", size: LitheDropdownMetrics.iconSize,
                              fallbackSystemImage: "checkmark")
                    .opacity(isSelected ? 1 : 0)
                content
                Spacer(minLength: 0)
            }
            .font(LitheTheme.uiFont(size: LitheDropdownMetrics.fontSize))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(LitheDropdownRowStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
