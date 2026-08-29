import SwiftUI

/// Shared title-bar chrome for bottom tool windows. Individual windows provide
/// their own controls while the title, spacing, and minimize affordance remain
/// visually consistent.
struct LitheToolWindowHeader<Actions: View>: View {
    let title: String
    let systemImage: String?
    let ideaAssetPath: String?
    let subtitle: String?
    let actions: Actions
    let onMinimize: (() -> Void)?

    init(
        title: String,
        systemImage: String? = nil,
        ideaAssetPath: String? = nil,
        subtitle: String? = nil,
        onMinimize: (() -> Void)? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.ideaAssetPath = ideaAssetPath
        self.subtitle = subtitle
        self.actions = actions()
        self.onMinimize = onMinimize
    }

    var body: some View {
        HStack(spacing: 8) {
            if let ideaAssetPath {
                LitheIDEAIcon(
                    resourcePath: ideaAssetPath,
                    size: 13,
                    fallbackSystemImage: systemImage ?? "circle"
                )
                .foregroundStyle(LitheTheme.toolWindowText)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LitheTheme.toolWindowText)
            }
            Text(LocalizedStringKey(title))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LitheTheme.toolWindowText)
            if let subtitle, !subtitle.isEmpty {
                Text(LocalizedStringKey(subtitle))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            actions
            if let onMinimize {
                Button(action: onMinimize) {
                    Image(systemName: "minus")
                }
                .litheIconButton()
                .help("Hide \(title) tool window")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: LitheTheme.Metrics.toolWindowHeaderHeight)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
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
