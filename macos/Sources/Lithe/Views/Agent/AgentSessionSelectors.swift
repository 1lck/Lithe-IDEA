import SwiftUI
import LitheAgentConversationModule

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

    static func choiceTitle(_ choice: AgentSessionConfigOption.Choice, in option: AgentSessionConfigOption) -> String {
        if option.id == "fast-mode" {
            if choice.id == "off" { return String(localized: "Standard") }
            if choice.id == "on" { return String(localized: "Fast") }
        }
        return option.category == "model" ? choice.name : localized(choice.name)
    }

    static func currentTitle(_ option: AgentSessionConfigOption) -> String {
        option.choices.first { $0.id == option.currentValue }.map { choiceTitle($0, in: option) } ?? option.currentValue
    }

    static func modeIcon(_ id: String) -> String {
        switch id {
        case "read-only": "bubble.left.and.bubble.right"
        case "agent": "checkmark.shield"
        case "agent-full-access": "bolt"
        default: "slider.horizontal.3"
        }
    }

    static func localized(_ text: String) -> String {
        String(localized: String.LocalizationValue(text))
    }
}

/// CC GUI-style bottom toolbar with separate approval and searchable model panels.
struct AgentSessionSelectors: View {
    let options: [AgentSessionConfigOption]
    let agentName: String?
    let isDisabled: Bool
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
                .buttonStyle(.plain)
                .help(AgentSessionSelectorPresentation.localized(mode.name))
                .accessibilityLabel(Text("Approval mode"))
                .accessibilityValue(AgentSessionSelectorPresentation.currentTitle(mode))
                .popover(isPresented: $showsModes, arrowEdge: .top) {
                    AgentModePopover(option: mode) { value in select(mode.id, value) }
                        .onExitCommand { showsModes = false }
                }
            }
            if let model {
                Button { showsModels.toggle() } label: {
                    selectorLabel {
                        AgentBrandIcon(name: agentName, size: 12)
                        Text(modelSummary(model))
                    }
                }
                .buttonStyle(.plain)
                .help(model.currentLabel)
                .accessibilityLabel(Text("Model"))
                .accessibilityValue(model.currentLabel)
                .popover(isPresented: $showsModels, arrowEdge: .top) {
                    AgentModelPopover(option: model, settings: settings, agentName: agentName, onSelect: select)
                        .onExitCommand { showsModels = false }
                }
            } else if !settings.isEmpty {
                Menu {
                    ForEach(settings) { option in
                        Menu(AgentSessionSelectorPresentation.title(option)) {
                            AgentConfigChoices(option: option) { select(option.id, $0) }
                        }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
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
        return [model.currentLabel, effort.map(AgentSessionSelectorPresentation.currentTitle)].compactMap { $0 }.joined(separator: " ")
    }

    private func selectorLabel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 5) {
            content()
            Image(systemName: "chevron.up").font(.system(size: 8, weight: .semibold))
        }
        .font(.system(size: 11))
        .foregroundStyle(AgentPanelStyle.secondary)
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
    @State private var selectedSettingID: String?
    @FocusState private var searchFocused: Bool
    private var choices: [AgentSessionConfigOption.Choice] { AgentSessionSelectorPresentation.filteredChoices(option, query: query) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            modelPanel
            if let setting = settings.first(where: { $0.id == selectedSettingID }) {
                VStack(spacing: 0) {
                    Text(AgentSessionSelectorPresentation.title(setting))
                        .font(.system(size: 11)).foregroundStyle(AgentPanelStyle.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(setting.choices) { choice in
                                AgentSelectorRow(isSelected: choice.id == setting.currentValue, action: { onSelect(setting.id, choice.id) }) {
                                    Text(AgentSessionSelectorPresentation.choiceTitle(choice, in: setting))
                                }
                            }
                        }
                    }
                    .frame(height: min(240, CGFloat(setting.choices.count * 32)))
                }
                .padding(.bottom, 5)
                .frame(width: 180)
                .overlay(alignment: .leading) { Divider() }
            }
        }
        .foregroundStyle(AgentPanelStyle.text)
        .background(AgentPanelStyle.header)
        .onAppear { searchFocused = true }
    }

    private var modelPanel: some View {
        VStack(spacing: 0) {
            TextField("Search models", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(AgentPanelStyle.canvas, in: RoundedRectangle(cornerRadius: 4))
                .overlay { RoundedRectangle(cornerRadius: 4).stroke(searchFocused ? AgentPanelStyle.focus : AgentPanelStyle.border) }
                .padding(8)
                .onSubmit { if let choice = choices.first { onSelect(option.id, choice.id) } }
            if choices.isEmpty {
                Text("No matching models")
                    .font(.system(size: 12))
                    .foregroundStyle(AgentPanelStyle.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                            if let group = choice.group, index == 0 || choices[index - 1].group != group {
                                Text(group).font(.system(size: 10)).foregroundStyle(AgentPanelStyle.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 4)
                            }
                            AgentSelectorRow(isSelected: choice.id == option.currentValue, action: { onSelect(option.id, choice.id) }) {
                                AgentBrandIcon(name: agentName, size: 16)
                                Text(choice.name).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(height: min(240, CGFloat(choices.count * 32 + choices.filter { $0.group != nil }.count * 20)))
            }
            if !settings.isEmpty {
                Divider().overlay(AgentPanelStyle.border).padding(.vertical, 4)
                ForEach(settings) { setting in
                    AgentModelSettingRow(option: setting, isSelected: selectedSettingID == setting.id) {
                        selectedSettingID = selectedSettingID == setting.id ? nil : setting.id
                    }
                }
            }
        }
        .padding(.bottom, 5)
        .frame(width: 330)
    }
}

/// Child choices stay inside the same native popover, so opening them cannot dismiss the model panel.
private struct AgentModelSettingRow: View {
    let option: AgentSessionConfigOption
    let isSelected: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack {
                Text(AgentSessionSelectorPresentation.title(option))
                Spacer()
                Text(AgentSessionSelectorPresentation.currentTitle(option)).foregroundStyle(AgentPanelStyle.secondary)
                Image(systemName: "chevron.right").font(.system(size: 9))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(isSelected ? AgentPanelStyle.context : .clear)
            .contentShape(Rectangle())
            .litheRowHover()
        }
        .buttonStyle(.plain)
        .lithePointer()
    }
}

private struct AgentModePopover: View {
    let option: AgentSessionConfigOption
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(option.choices) { choice in
                    AgentSelectorRow(isSelected: choice.id == option.currentValue, minimumHeight: 64, action: { onSelect(choice.id) }) {
                        Image(systemName: AgentSessionSelectorPresentation.modeIcon(choice.id)).frame(width: 16)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AgentSessionSelectorPresentation.choiceTitle(choice, in: option)).lineLimit(1)
                            if let description = choice.description, !description.isEmpty {
                                Text(AgentSessionSelectorPresentation.localized(description))
                                    .font(.system(size: 11))
                                    .foregroundStyle(AgentPanelStyle.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .frame(width: 350, height: min(330, CGFloat(option.choices.count * 64 + 10)))
        .background(AgentPanelStyle.header)
    }
}

private struct AgentSelectorRow<Content: View>: View {
    let isSelected: Bool
    var minimumHeight: CGFloat = 32
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                content
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LitheTheme.success)
                    .opacity(isSelected ? 1 : 0)
            }
            .font(.system(size: 12))
            .foregroundStyle(AgentPanelStyle.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
            .background(isSelected ? AgentPanelStyle.selected : (isHovering ? AgentPanelStyle.context : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lithePointer()
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct AgentConfigChoices: View {
    let option: AgentSessionConfigOption
    let onSelect: (String) -> Void

    var body: some View {
        ForEach(option.choices) { choice in
            Button { onSelect(choice.id) } label: {
                let title = AgentSessionSelectorPresentation.choiceTitle(choice, in: option)
                if choice.id == option.currentValue {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(choice.group.map { "\($0): \(title)" } ?? title)
                }
            }
        }
    }
}
