import AppKit
import SwiftUI
import LitheAgentConversationModule

/// A compact, discrete presentation of the Agent's own ordered effort choices.
/// Drag previews stay in this view; only release, click or keyboard selection commits.
struct AgentReasoningEffortControl: View {
    private static let title = "Effort"
    let option: AgentSessionConfigOption
    let onSelect: (String, String) -> Void
    @Environment(\.locale) private var locale
    @Environment(\.isEnabled) private var isEnabled
    @GestureState private var previewIndex: Int?
    @FocusState private var isFocused: Bool
    @Namespace private var trackSpace

    private enum Metrics {
        static let trackHeight: CGFloat = 20
        static let thumbSize: CGFloat = 14
        static let dotSize: CGFloat = 4
        static let slotWidth: CGFloat = 20
        static let minimumTrackWidth: CGFloat = 80
        static let maximumTrackWidth: CGFloat = 144
        static let labelSpacing: CGFloat = 8
        static let horizontalInset = LitheDropdownMetrics.popupPadding + LitheDropdownMetrics.itemHorizontalPadding
    }

    static func trackWidth(for option: AgentSessionConfigOption) -> CGFloat {
        min(Metrics.maximumTrackWidth, max(Metrics.minimumTrackWidth, CGFloat(option.choices.count) * Metrics.slotWidth))
    }

    static func preferredWidth(for option: AgentSessionConfigOption, locale: Locale) -> CGFloat {
        let names = option.choices.map(\.name) + [AgentSessionSelectorPresentation.currentTitle(option, locale: locale)]
        let labelWidth = names.map {
            ("\(title) (\($0))" as NSString).size(withAttributes: [.font: LitheTheme.uiNSFont(size: LitheDropdownMetrics.fontSize)]).width
        }.max() ?? 0
        return ceil(labelWidth + Metrics.labelSpacing + trackWidth(for: option) + 2 * Metrics.horizontalInset)
    }

    private var selectedIndex: Int? { option.choices.firstIndex { $0.id == option.currentValue } }
    private var displayedName: String {
        if let previewIndex, option.choices.indices.contains(previewIndex) { return option.choices[previewIndex].name }
        return AgentSessionSelectorPresentation.currentTitle(option, locale: locale)
    }

    var body: some View {
        HStack(spacing: Metrics.labelSpacing) {
            (Text(verbatim: Self.title).foregroundColor(LitheTheme.primaryText)
                + Text(verbatim: " (\(displayedName))").foregroundColor(LitheTheme.secondaryText))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            track
        }
        .font(LitheTheme.uiFont(size: LitheDropdownMetrics.fontSize))
        .padding(.horizontal, Metrics.horizontalInset)
        .frame(minHeight: LitheDropdownMetrics.rowHeight)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-reasoning-effort-\(option.id)")
    }

    private var track: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(option.choices.enumerated()), id: \.element.id) { index, choice in
                    Button { commit(index) } label: {
                        Circle()
                            .fill((previewIndex ?? selectedIndex) == index ? LitheTheme.primaryText : LitheTheme.tertiaryText)
                            .frame(width: (previewIndex ?? selectedIndex) == index ? Metrics.thumbSize : Metrics.dotSize,
                                   height: (previewIndex ?? selectedIndex) == index ? Metrics.thumbSize : Metrics.dotSize)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(AgentSessionSelectorPresentation.choiceDescription(choice, in: option, locale: locale) ?? choice.name)
                    .accessibilityLabel(Text(verbatim: choice.name))
                    .accessibilityAddTraits(choice.id == option.currentValue ? .isSelected : [])
                    .accessibilityIdentifier("agent-model-choice-\(option.id)-\(choice.id)")
                }
            }
            .background(LitheTheme.hoverBackground, in: Capsule())
            .contentShape(Capsule())
            .coordinateSpace(name: trackSpace)
            .highPriorityGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(trackSpace))
                .updating($previewIndex) { value, preview, _ in
                    guard isEnabled, let index = index(at: value.location.x, width: geometry.size.width) else { return }
                    if preview != index { preview = index }
                }
                .onEnded { value in
                    if let index = index(at: value.location.x, width: geometry.size.width) { commit(index) }
                })
            .focusable().focused($isFocused)
            .onMoveCommand { direction in
                switch direction {
                case .left, .down: step(-1)
                case .right, .up: step(1)
                default: break
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: Self.title))
            .accessibilityValue(AgentSessionSelectorPresentation.currentTitle(option, locale: locale))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(1)
                case .decrement: step(-1)
                @unknown default: break
                }
            }
        }
        .frame(width: Self.trackWidth(for: option), height: Metrics.trackHeight)
        .transaction { $0.animation = nil }
    }

    private func index(at x: CGFloat, width: CGFloat) -> Int? {
        guard !option.choices.isEmpty, width > 0 else { return nil }
        return min(option.choices.count - 1, max(0, Int(floor(x / width * CGFloat(option.choices.count)))))
    }

    private func step(_ delta: Int) {
        let current = selectedIndex ?? (delta > 0 ? -1 : option.choices.count)
        commit(min(option.choices.count - 1, max(0, current + delta)))
    }

    private func commit(_ index: Int) {
        guard isEnabled, option.choices.indices.contains(index) else { return }
        isFocused = true
        let choice = option.choices[index]
        guard choice.id != option.currentValue else { return }
        onSelect(option.id, choice.id)
    }
}
