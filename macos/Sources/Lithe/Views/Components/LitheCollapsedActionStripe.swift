import SwiftUI

/// ExpandStripeButtonUI presentation shared with Git Log's Branches stripe.
struct LitheCollapsedActionStripe: View {
    let title: String
    let expandsToward: HorizontalEdge
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: LitheTheme.ActionStripe.spacing) {
                LitheIDEAIcon(resourcePath: expandsToward == .leading
                    ? "expui/general/chevronLeft.svg" : "expui/general/chevronRight.svg",
                    size: LitheTheme.ActionStripe.iconSize, preservesOriginalColors: true)
                Text(LocalizedStringKey(title))
                    .font(LitheTheme.ActionStripe.titleFont)
                    .foregroundStyle(LitheTheme.ActionStripe.titleColor)
                    .fixedSize()
                    .rotationEffect(.degrees(expandsToward == .leading ? 90 : -90))
                    .frame(width: LitheTheme.ActionStripe.buttonSize,
                        height: max(58, (String(localized: String.LocalizationValue(title)) as NSString)
                            .size(withAttributes: [.font: LitheTheme.uiNSFont(size: 11)]).width))
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .frame(width: LitheTheme.ActionStripe.width)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .background(isHovered ? LitheTheme.ActionStripe.collapsedHover(for: colorScheme) : .clear)
        .onHover { isHovered = $0 }
        .accessibilityLabel(LocalizedStringKey(title))
    }
}
