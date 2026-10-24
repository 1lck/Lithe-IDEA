import SwiftUI

/// One selectable row of a window's sidebar list, shared by the settings
/// window and the New Project window so both lists look and behave alike.
struct LitheSidebarRow<Leading: View, Trailing: View>: View {
    enum Style {
        /// A top-level page with its icon tile.
        case page
        /// A page nested under a group heading.
        case nested
        /// An entry of a flat list with a small icon, like New Project's.
        case item
    }

    private let title: Text
    private let style: Style
    private let isSelected: Bool
    private let isFocused: Bool
    private let spacing: CGFloat
    private let action: () -> Void
    private let leading: Leading
    private let trailing: Trailing

    init(
        _ title: Text,
        style: Style,
        isSelected: Bool,
        isFocused: Bool,
        spacing: CGFloat = 8,
        action: @escaping () -> Void,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.style = style
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.spacing = spacing
        self.action = action
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: spacing) {
                leading
                title
                    .font(font)
                    .foregroundStyle(style == .nested && !isSelected ? LitheTheme.secondaryText : LitheTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                trailing
            }
            .padding(.leading, style == .nested ? 36 : 8)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .litheSelectionRow(isSelected: isSelected, isFocused: isFocused, cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .padding(.top, style == .page ? 2 : 0)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var font: Font {
        switch style {
        case .page: LitheTheme.uiFont(size: 13, weight: .medium)
        case .nested: LitheTheme.uiFont(size: 12.5, weight: isSelected ? .medium : .regular)
        case .item: LitheTheme.uiFont(size: 13)
        }
    }

    private var height: CGFloat {
        switch style {
        case .page: 30
        case .nested: 26
        case .item: 28
        }
    }
}

extension LitheSidebarRow where Trailing == EmptyView {
    init(
        _ title: Text,
        style: Style,
        isSelected: Bool,
        isFocused: Bool,
        action: @escaping () -> Void,
        @ViewBuilder leading: () -> Leading
    ) {
        self.init(title, style: style, isSelected: isSelected, isFocused: isFocused, action: action,
                  leading: leading, trailing: { EmptyView() })
    }
}

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
