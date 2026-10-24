import SwiftUI

/// Agent selection in resource editors shares the MCP library's existing chip chrome.
struct AgentSelectionChip: View {
    let title: String
    var brandName: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let brandName { AgentBrandIcon(name: brandName, size: 16, style: .brand) }
                Text(verbatim: title).font(LitheTheme.settingsFont)
                if selected { Image(systemName: "checkmark").font(LitheTheme.smallFont) }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(selected ? LitheTheme.accent.opacity(0.10) : LitheTheme.settingsControlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? LitheTheme.accent.opacity(0.5) : LitheTheme.settingsControlBorder))
        }
        .buttonStyle(.plain).lithePointer()
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(selected ? "Selected" : "Not selected"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
