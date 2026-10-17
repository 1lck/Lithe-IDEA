import SwiftUI

/// A circled “i” that explains the setting next to it.
///
/// The explanation opens after the pointer rests on the icon briefly, so
/// moving across the page does not flash the dropdown; a click or the keyboard
/// (Space/Return when focused) opens it too, for users who do not hover. The
/// text is also the accessibility hint, so VoiceOver reads it without opening.
struct LitheInfoTip: View {
    private static let hoverDelayNanoseconds: UInt64 = 500_000_000

    private let text: Text
    @State private var isPresented = false
    @State private var isPinned = false
    @State private var hoverTask: Task<Void, Never>?

    init(_ text: LocalizedStringKey) {
        self.text = Text(text)
    }

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        Button {
            hoverTask?.cancel()
            isPinned.toggle()
            isPresented = isPinned
        } label: {
            Image(systemName: "info.circle")
                .font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(isPresented ? LitheTheme.accent : LitheTheme.secondaryText)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .lithePointer()
        .onHover { hovering in
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: Self.hoverDelayNanoseconds)
                    guard !Task.isCancelled else { return }
                    isPresented = true
                }
            } else if !isPinned {
                isPresented = false
            }
        }
        .litheDropdown(isPresented: $isPresented) {
            text
                .font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(LitheTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 320, alignment: .leading)
                .padding(12)
        }
        .onChange(of: isPresented) { presented in
            if !presented { isPinned = false }
        }
        .onDisappear { hoverTask?.cancel() }
        .accessibilityLabel(Text("More information"))
        .accessibilityHint(text)
    }
}

/// Keeps setting explanations beside their title without occupying a second row.
extension View {
    func litheSettingsInfo(_ text: LocalizedStringKey?) -> some View {
        HStack(spacing: 4) {
            self
            if let text {
                LitheInfoTip(text)
            }
        }
    }
}
