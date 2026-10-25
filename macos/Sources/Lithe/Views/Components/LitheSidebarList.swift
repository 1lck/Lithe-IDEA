import SwiftUI

/// A plain heading above a group of sidebar rows, like "Generators".
struct LitheSidebarHeading: View {
    private let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(LitheTheme.uiFont(size: 12, weight: .medium))
            .foregroundStyle(LitheTheme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
