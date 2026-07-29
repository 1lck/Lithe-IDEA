import SwiftUI

@main
struct LitheApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") {
                    model.chooseProject()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(after: .saveItem) {
                Button("Close Project") {
                    model.closeProject()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.workspaceURL == nil)
            }
        }
    }
}
