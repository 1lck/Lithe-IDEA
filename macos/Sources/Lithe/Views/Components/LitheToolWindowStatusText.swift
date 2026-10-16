import SwiftUI

/// Community StatusText: label font, GRAYED_ATTRIBUTES, centered above the midpoint.
struct LitheToolWindowStatusText: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(text)
                .font(LitheTheme.uiFont(size: LitheTheme.ToolWindowEmptyState.fontSize, weight: .regular))
                .foregroundStyle(LitheTheme.ToolWindowEmptyState.text)
                .fixedSize()
                .frame(height: LitheTheme.ToolWindowEmptyState.rowHeight)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
    }
}
