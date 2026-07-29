import SwiftUI

enum LitheTheme {
    static let window = Color(red: 0.105, green: 0.112, blue: 0.124)
    static let titlebar = Color(red: 0.145, green: 0.153, blue: 0.165)
    static let sidebar = Color(red: 0.095, green: 0.101, blue: 0.112)
    static let editor = Color(red: 0.105, green: 0.110, blue: 0.120)
    static let raised = Color(red: 0.155, green: 0.163, blue: 0.178)
    static let selection = Color(red: 0.145, green: 0.260, blue: 0.455)
    static let subtleSelection = Color(red: 0.205, green: 0.218, blue: 0.240)
    static let divider = Color.white.opacity(0.075)
    static let primaryText = Color.white.opacity(0.86)
    static let secondaryText = Color.white.opacity(0.48)
    static let accent = Color(red: 0.31, green: 0.58, blue: 0.98)
    static let success = Color(red: 0.28, green: 0.72, blue: 0.39)
    static let warning = Color(red: 0.91, green: 0.63, blue: 0.20)

    static let uiFont = Font.system(size: 13, weight: .regular)
    static let smallFont = Font.system(size: 11, weight: .regular)
    static let codeFont = Font.system(size: 13, design: .monospaced)
}

extension View {
    func litheIconButton() -> some View {
        self
            .buttonStyle(.plain)
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
    }
}
