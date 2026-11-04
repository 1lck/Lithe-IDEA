import SwiftUI

@MainActor
enum WorkbenchSettingsMenu {
    static func items(model: AppModel) -> [LitheContextMenuItem] {
        [
            .action("Settings…", icon: AnyView(LitheIDEAIcon(resourcePath: "expui/general/settings.svg", size: 16)),
                initiallySelected: true, shortcut: model.keyboardShortcutFeature.displayText(for: "settings")) {
                model.showSettings()
            },
            .action("Plugins…", icon: AnyView(LitheIDEAIcon(resourcePath: "expui/nodes/plugin.svg", size: 16, preservesOriginalColors: true))) {
                model.showSettings(category: .plugins)
            },
            .action("Logs and Diagnostics…", icon: AnyView(LitheIDEAIcon(resourcePath: "fileTypes/text.svg", size: 16, preservesOriginalColors: true))) {
                model.openLogs()
            },
            .separator,
            .action("Theme…") { model.showSettings(category: .general) },
            .action("Keymap…") { model.showSettings(category: .keymap) }
        ]
    }
}
