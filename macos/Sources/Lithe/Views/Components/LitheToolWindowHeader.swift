import SwiftUI

/// Shared title-bar chrome for bottom tool windows. Individual windows provide
/// their own controls while the title, spacing, and minimize affordance remain
/// visually consistent.
struct LitheToolWindowHeader<Actions: View>: View {
    let title: String
    let systemImage: String?
    let ideaAssetPath: String?
    let icon: AnyView?
    let subtitle: String?
    let actions: Actions
    let onMinimize: (() -> Void)?
    let usesWorkbenchSurface: Bool

    init(
        title: String,
        systemImage: String? = nil,
        ideaAssetPath: String? = nil,
        icon: AnyView? = nil,
        subtitle: String? = nil,
        onMinimize: (() -> Void)? = nil,
        usesWorkbenchSurface: Bool = true,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.ideaAssetPath = ideaAssetPath
        self.icon = icon
        self.subtitle = subtitle
        self.actions = actions()
        self.onMinimize = onMinimize
        self.usesWorkbenchSurface = usesWorkbenchSurface
    }

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                icon.foregroundStyle(LitheTheme.toolWindowText)
            } else if let ideaAssetPath {
                LitheIDEAIcon(
                    resourcePath: ideaAssetPath,
                    size: 13,
                    fallbackSystemImage: systemImage ?? "circle"
                )
                .foregroundStyle(LitheTheme.toolWindowText)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(LitheTheme.uiFont(size: 12, weight: .medium))
                    .foregroundStyle(LitheTheme.toolWindowText)
            }
            Text(LocalizedStringKey(title))
                .font(LitheTheme.uiFont(size: 12.5, weight: .semibold))
                .foregroundStyle(LitheTheme.toolWindowText)
            if let subtitle, !subtitle.isEmpty {
                Text(LocalizedStringKey(subtitle))
                    .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            actions
            if let onMinimize {
                LitheSidebarHideButton(title: title, action: onMinimize)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
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
        systemImage: String? = nil,
        ideaAssetPath: String? = nil,
        subtitle: String? = nil,
        onMinimize: (() -> Void)? = nil
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            ideaAssetPath: ideaAssetPath,
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
