import SwiftUI

/// Shared title-bar chrome for tool windows. Individual windows provide
/// their own controls while the title, spacing, and minimize affordance remain
/// visually consistent.
struct LitheToolWindowHeader<Actions: View>: View {
    let title: String
    let subtitle: String?
    let actions: Actions
    let onMinimize: (() -> Void)?
    let usesWorkbenchSurface: Bool

    init(
        title: String,
        subtitle: String? = nil,
        onMinimize: (() -> Void)? = nil,
        usesWorkbenchSurface: Bool = true,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
        self.onMinimize = onMinimize
        self.usesWorkbenchSurface = usesWorkbenchSurface
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(LitheTheme.uiFont(size: 13, weight: .bold))
                .foregroundStyle(LitheTheme.toolWindowText)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(LocalizedStringKey(subtitle))
                    .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            HStack(spacing: LitheTheme.ActionToolbar.actionSpacing) {
                actions
                if let onMinimize {
                    LitheSidebarHideButton(title: title, action: onMinimize)
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: LitheTheme.Metrics.toolWindowHeaderHeight)
        .background {
            // Opaque feature panels also use this header outside the wallpaper host.
            if usesWorkbenchSurface {
                Color.clear.litheWorkbenchSurface(LitheTheme.toolHeader)
            } else {
                LitheTheme.toolHeader
            }
        }
        .litheContextMenu {
            onMinimize.map { minimize in
                [
                    .action("Hide \(title) Tool Window", systemImage: "minus", action: minimize)
                ]
            } ?? []
        }
    }
}

extension LitheToolWindowHeader where Actions == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        onMinimize: (() -> Void)? = nil
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            onMinimize: onMinimize
        ) {
            EmptyView()
        }
    }
}

struct LitheSidebarHideButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LitheIDEAIcon(
                resourcePath: "expui/general/hide.svg",
                size: LitheTheme.Metrics.toolbarIconSize,
                fallbackSystemImage: "minus",
                preservesOriginalColors: false
            )
            .foregroundStyle(LitheTheme.ActionToolbar.icon)
        }
        .litheToolbarIconButton()
        .foregroundStyle(LitheTheme.ActionToolbar.icon)
        .help("Hide \(title) tool window")
        .accessibilityLabel("Hide \(title) tool window")
        .modifier(LitheToolWindowHoverAction())
    }
}

private struct ToolWindowHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isToolWindowHovered: Bool {
        get { self[ToolWindowHoveredKey.self] }
        set { self[ToolWindowHoveredKey.self] = newValue }
    }
}

/// Applied inside each tool's hosting root, including retained AppKit panes.
struct LitheToolWindowHoverRegion: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .environment(\.isToolWindowHovered, isHovered)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

/// Keep layout and keyboard/VoiceOver access while hiding inactive mouse actions.
struct LitheToolWindowHoverAction: ViewModifier {
    @Environment(\.isToolWindowHovered) private var isHovered
    @FocusState private var isFocused: Bool
    @AccessibilityFocusState private var isAccessibilityFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .accessibilityFocused($isAccessibilityFocused)
            .opacity(isHovered || isFocused || isAccessibilityFocused ? 1 : 0)
            .allowsHitTesting(isHovered || isFocused || isAccessibilityFocused)
    }
}
