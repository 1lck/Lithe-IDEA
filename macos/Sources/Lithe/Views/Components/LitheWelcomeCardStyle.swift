import SwiftUI

/// Shared chrome for the compact choices in the Agent welcome page.
enum LitheWelcomeCardStyle {
    static let cornerRadius: CGFloat = 8
    static let spacing: CGFloat = 8
    static let rowHeight: CGFloat = 40
}

struct LitheWelcomeRow<Icon: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    let action: () -> Void
    @ViewBuilder let icon: Icon

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon.frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(LitheTheme.settingsFont)
                        .foregroundStyle(LitheTheme.primaryText)
                    if let subtitle {
                        Text(subtitle)
                            .font(LitheTheme.smallFont)
                            .foregroundStyle(LitheTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                LitheIDEAIcon(resourcePath: "expui/general/chevronRight.svg", size: LitheTheme.Metrics.toolbarIconSize,
                              preservesOriginalColors: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, subtitle == nil ? 0 : 8)
            .frame(maxWidth: .infinity, minHeight: LitheWelcomeCardStyle.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .litheRowHover(cornerRadius: LitheWelcomeCardStyle.cornerRadius)
        .background(LitheTheme.raised, in: RoundedRectangle(cornerRadius: LitheWelcomeCardStyle.cornerRadius))
    }
}
