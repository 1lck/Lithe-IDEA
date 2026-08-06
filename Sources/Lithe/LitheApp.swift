import AppKit
import SwiftUI

@MainActor
final class LitheAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        return Self.confirmUnsavedDocuments(for: model) ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stopTerminalSessions()
    }

    static func confirmUnsavedDocuments(for model: AppModel) -> Bool {
        guard model.hasUnsavedDocuments else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes before quitting?"
        alert.informativeText = model.openDocuments
            .filter(\.isDirty)
            .map(\.displayName)
            .joined(separator: ", ")
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return model.saveAllDocuments()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}

@main
struct LitheApp: App {
    @NSApplicationDelegateAdaptor(LitheAppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var model: AppModel
    @StateObject private var memoryUsageMonitor: MemoryUsageMonitor
    @StateObject private var updateChecker = UpdateChecker()

    init() {
        let store = MacUserDefaultsStore()
        let settings = AppSettings(store: store)
        _settings = StateObject(wrappedValue: settings)
        let model = AppModel(
            settings: settings,
            services: MacServiceContainer(store: store).services
        )
        _model = StateObject(wrappedValue: model)
        _memoryUsageMonitor = StateObject(wrappedValue: MemoryUsageMonitor())
        appDelegate.model = model
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(settings)
                .environmentObject(memoryUsageMonitor)
                .environmentObject(updateChecker)
                .environment(\.locale, settings.language.locale)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
                .task {
                    memoryUsageMonitor.start()
                }
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

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    model.isSettingsPresented = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updateChecker.checkForUpdates(manual: true) }
                }
                .disabled(updateChecker.isChecking)
            }

            CommandMenu("Navigate") {
                Button("Search Everywhere…") {
                    model.toggleSearchEverywhere()
                }
                // 双 Shift 是主入口。IntelliJ 的 ⇧⌘A 是 Find Action，
                // 这里不再占用它，改用 ⇧⌘O（Go to File 家族）作为可见的菜单快捷键。
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.workspaceURL == nil)

                Divider()

                Button("Find in File…") {
                    model.showFindBar()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.activeDocument == nil)

                Button("Find Next") {
                    model.navigateFind(offset: 1)
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!model.isFindBarVisible || model.findMatchCount == 0)

                Button("Find Previous") {
                    model.navigateFind(offset: -1)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!model.isFindBarVisible || model.findMatchCount == 0)

                Divider()

                Button("Go to Usage") {
                    model.goToUsages()
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(model.activeDocument?.url.pathExtension.lowercased() != "java")

                Button("Go to Implementation") {
                    model.goToImplementation()
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(model.activeDocument?.url.pathExtension.lowercased() != "java")

                Button("Find Usages") {
                    model.findJavaReferences()
                }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(model.activeDocument?.url.pathExtension.lowercased() != "java")

                Divider()

                Button("Find in Files…") {
                    model.openProjectSearch()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.workspaceURL == nil)

                Button("Replace in Files…") {
                    model.openProjectReplace()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.workspaceURL == nil)
            }

            CommandMenu("History") {
                Button("Show Local History…") {
                    if let fileURL = model.activeDocument?.url {
                        model.showLocalHistory(for: fileURL)
                    }
                }
                .disabled(model.activeDocument == nil)

                Button("Show Project Local History…") {
                    model.showProjectLocalHistory()
                }
                .disabled(model.workspaceURL == nil)
            }
        }
    }
}
