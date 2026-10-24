import SwiftUI

/// Shared compact name entry used by project items and database folders.
struct LitheNamePopup: View {
    static let width: CGFloat = 340
    let title: LocalizedStringKey
    let validationMessage: String?
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String
    @FocusState private var nameFocused: Bool

    init(title: LocalizedStringKey, initialName: String = "", validationMessage: String? = nil,
         onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.validationMessage = validationMessage
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(LitheTheme.uiFont(size: 14, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            TextField("Name", text: $name)
                .lithePopupNameField()
                .focused($nameFocused)
                .onSubmit {
                    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    onSubmit(name)
                }
            if let validationMessage {
                Text(LocalizedStringKey(validationMessage))
                    .font(LitheTheme.uiFont(size: 13))
                    .foregroundStyle(LitheTheme.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13)
                    .accessibilityLabel(Text(LocalizedStringKey(validationMessage)))
            }
        }
        .padding(.vertical, 11)
        .frame(width: Self.width, height: validationMessage == nil ? 78 : nil)
        .litheContextMenuSurface()
        .task { await Task.yield(); nameFocused = true }
        .onExitCommand(perform: onCancel)
    }
}
