import SwiftUI

/// A circled “i” that explains the setting next to it.
///
/// The explanation opens after the pointer rests on the icon for half a second,
/// so moving across the page does not flash the dropdown; a click or the keyboard
/// (Space/Return when focused) opens it too, for users who do not hover. The
/// text is also the accessibility hint, so VoiceOver reads it without opening.
struct LitheInfoTip: View {
    static let size: CGFloat = 18
    static let labelSpacing: CGFloat = 4
    private static let hoverDelayNanoseconds: UInt64 = 500_000_000

    private let text: Text
    @State private var isPresented = false
    @State private var isPinned = false
    /// Reference box rather than `@State`: assigning and cancelling the timer
    /// must not invalidate the page while the pointer sweeps across many icons.
    @State private var hoverTask = HoverTaskBox()

    init(_ text: LocalizedStringKey) {
        self.text = Text(text)
    }

    init(verbatim text: String) {
        self.text = Text(verbatim: text)
    }

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        Button {
            isPinned.toggle()
            isPresented = isPinned
        } label: {
            Image(systemName: "info.circle")
                .font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(isPresented ? LitheTheme.accent : LitheTheme.secondaryText)
                .frame(width: Self.size, height: Self.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .lithePointer()
        .onHover { hovering in
            hoverTask.task?.cancel()
            if hovering {
                hoverTask.task = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: Self.hoverDelayNanoseconds)
                    guard !Task.isCancelled else { return }
                    isPresented = true
                }
            } else if !isPinned {
                hoverTask.task?.cancel()
                hoverTask.task = nil
                isPresented = false
            }
        }
        // Only install the popover anchor while a tip is actually open. With
        // dozens of icons on a page, always-on NSViewRepresentable overlays
        // make every layout pass more expensive and make pointer movement feel
        // sluggish in debug builds.
        .overlay {
            if isPresented {
                LitheDropdownPopover(isPresented: $isPresented) {
                    text
                        .font(LitheTheme.uiFont(size: 12))
                        .foregroundStyle(LitheTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 320, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .onChange(of: isPresented) { presented in
            if !presented {
                isPinned = false
                hoverTask.task?.cancel()
                hoverTask.task = nil
            }
        }
        .onDisappear {
            hoverTask.task?.cancel()
            hoverTask.task = nil
        }
        .accessibilityLabel(Text("More information"))
        .accessibilityHint(text)
        // Explanations remain reachable when the surrounding field or section is disabled.
        .environment(\.isEnabled, true)
    }
}

private final class HoverTaskBox {
    var task: Task<Void, Never>?
}
