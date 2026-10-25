import AppKit
import SwiftUI

/// IDEA CheckboxTree/ChangesTree: a 24pt ThreeStateCheckBox with a 16pt painted square.
struct LitheTreeCheckbox: View {
    let state: NSControl.StateValue
    let accessibilityTitle: String
    var title: Text? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    static func assetPath(state: NSControl.StateValue, enabled: Bool, focused: Bool) -> String {
        let name = state == .mixed ? "checkBoxIndeterminateSelected" : state == .on ? "checkBoxSelected" : "checkBox"
        let suffix = !enabled ? "Disabled" : focused ? "Focused" : ""
        return "commit/" + name + suffix + ".svg"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: LitheTheme.Tree.iconTextGap) {
                LitheIDEAIcon(resourcePath: Self.assetPath(state: state, enabled: isEnabled, focused: isFocused),
                              size: LitheTheme.Tree.rowHeight, preservesOriginalColors: true)
                if let title { title.font(LitheTheme.uiFont(size: 13)).lineLimit(1) }
            }
            .frame(maxWidth: title == nil ? nil : .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .focused($isFocused)
        .accessibilityRepresentation {
            Toggle(isOn: Binding(get: { state == .on }, set: { _ in action() })) {
                title ?? Text(LocalizedStringKey(accessibilityTitle))
            }
                .accessibilityValue(Text(state == .mixed ? "Partially selected" : state == .on ? "Selected" : "Not selected"))
        }
    }
}
