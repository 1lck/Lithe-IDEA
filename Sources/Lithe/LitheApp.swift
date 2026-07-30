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
                Button("Save") {
                    model.saveActiveDocument()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.activeDocument == nil)

                Button("Close Project") {
                    model.closeProject()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.workspaceURL == nil)
            }

            CommandMenu("Navigate") {
                Button("Go to Definition") {
                    model.goToDefinition()
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(model.activeDocument?.url.pathExtension.lowercased() != "java")

                Button("Find Usages") {
                    model.findJavaReferences()
                }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(model.activeDocument?.url.pathExtension.lowercased() != "java")

                Divider()

                Button("Search in Project") {
                    model.selectedSidebar = .search
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.workspaceURL == nil)
            }
        }
    }
}
