import SwiftUI

/// IDEA Islands tool-window tabs share colors and geometry across tool windows.
struct LitheToolWindowTabStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let isSelected: Bool
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .frame(height: 28)
            .background(isSelected ? selectedTabBackground : .clear)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? selectedTabBorder : .clear, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var selectedTabBackground: Color {
        guard LitheTheme.activeTheme == .lithe else {
            return isActive ? LitheTheme.activeTabBackground : LitheTheme.subtleSelection
        }
        if colorScheme == .dark {
            return isActive ? Color(red: 35/255, green: 53/255, blue: 88/255)
                                    : Color(red: 38/255, green: 40/255, blue: 44/255)
        }
        return isActive ? Color(red: 227/255, green: 235/255, blue: 254/255)
                                : Color(red: 233/255, green: 234/255, blue: 238/255)
    }

    private var selectedTabBorder: Color {
        guard LitheTheme.activeTheme == .lithe else {
            return isActive ? LitheTheme.accent.opacity(0.45) : LitheTheme.divider
        }
        if colorScheme == .dark {
            return isActive ? Color(red: 46/255, green: 77/255, blue: 137/255)
                                    : Color(red: 64/255, green: 67/255, blue: 74/255)
        }
        return isActive ? Color(red: 167/255, green: 197/255, blue: 255/255)
                                : Color(red: 209/255, green: 211/255, blue: 217/255)
    }

}

/// The circular hover background is part of IDEA's CloseHovered SVG.
struct LitheToolWindowTabCloseButton: View {
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            LitheIDEAIcon(
                resourcePath: isHovered && isEnabled
                    ? "expui/general/closeSmallHovered.svg" : "expui/general/closeSmall.svg",
                size: 16,
                fallbackSystemImage: "xmark",
                preservesOriginalColors: true
            )
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Close tab")
    }
}
