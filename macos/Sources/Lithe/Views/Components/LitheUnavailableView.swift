import SwiftUI

struct LitheUnavailableView: View {
    let title: LocalizedStringKey
    let systemImage: String
    let description: Text?

    init(
        _ title: LocalizedStringKey,
        systemImage: String,
        description: Text? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(LitheTheme.uiFont(size: 28, weight: .light))
            Text(title)
                .font(LitheTheme.uiFont(size: 13, weight: .semibold))
            if let description {
                description
                    .font(LitheTheme.uiFont(size: 11.5))
                    .opacity(0.72)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
