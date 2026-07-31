import SwiftUI

enum LitheTheme {
    static let window = Color(red: 0.095, green: 0.101, blue: 0.110)
    static let titlebar = Color(red: 0.135, green: 0.145, blue: 0.153)
    static let toolHeader = Color(red: 0.090, green: 0.096, blue: 0.104)
    static let sidebar = Color(red: 0.082, green: 0.087, blue: 0.095)
    static let editor = Color(red: 0.085, green: 0.089, blue: 0.096)
    static let raised = Color(red: 0.150, green: 0.158, blue: 0.170)
    static let selection = Color(red: 0.170, green: 0.290, blue: 0.490)
    static let subtleSelection = Color(red: 0.205, green: 0.218, blue: 0.238)
    static let divider = Color.white.opacity(0.075)
    static let primaryText = Color.white.opacity(0.82)
    static let secondaryText = Color.white.opacity(0.47)
    static let accent = Color(red: 0.31, green: 0.58, blue: 0.98)
    static let success = Color(red: 0.28, green: 0.72, blue: 0.39)
    static let warning = Color(red: 0.91, green: 0.63, blue: 0.20)
    static let error = Color(red: 0.92, green: 0.33, blue: 0.33)

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
