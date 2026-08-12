import AppKit
import SwiftUI

private let litheProcessLaunchDate = Date()

@MainActor
final class LitheAppDelegate: NSObject, NSApplicationDelegate {
    weak var projectSessions: ProjectSessionManager?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let projectSessions else { return .terminateNow }
        return Self.confirmUnsavedDocuments(for: projectSessions) ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        projectSessions?.stopAllSessions()
    }

    static func confirmUnsavedDocuments(for projectSessions: ProjectSessionManager) -> Bool {
        guard projectSessions.hasUnsavedDocuments else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes before quitting?"
        alert.informativeText = projectSessions.unsavedDocumentNames.joined(separator: ", ")
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return projectSessions.saveAllDocuments()
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
    @StateObject private var projectSessions: ProjectSessionManager
    @StateObject private var memoryUsageMonitor: MemoryUsageMonitor
    @StateObject private var updateChecker = UpdateChecker()

    init() {
        let store = MacUserDefaultsStore()
        let settings = AppSettings(store: store)
        _settings = StateObject(wrappedValue: settings)
        let projectSessions = ProjectSessionManager(
            settings: settings,
            modelFactory: {
                AppModel(
                    settings: settings,
                    services: MacServiceContainer(store: store, settings: settings).services
                )
            },
            newWindowOpener: Self.openProjectInNewWindow
        )
        if let startupProjectURL = Self.startupProjectURL {
            projectSessions.openStartupProject(startupProjectURL)
        }
        _projectSessions = StateObject(wrappedValue: projectSessions)
        _memoryUsageMonitor = StateObject(wrappedValue: MemoryUsageMonitor(
            startedAt: litheProcessLaunchDate,
            baselineReporter: { marker in
                guard let data = (marker + "\n").data(using: .utf8) else { return }
                FileHandle.standardError.write(data)
            }
        ))
        appDelegate.projectSessions = projectSessions
    }

    private var model: AppModel { projectSessions.activeModel }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(projectSessions)
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
                    model.showSettings()
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
                .disabled(!model.supportsLanguageServerFeature(.references))

                Button("Go to Implementation") {
                    model.goToImplementation()
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(!model.supportsLanguageServerFeature(.implementation))

                Button("Find Usages") {
                    model.findReferences()
                }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(!model.supportsLanguageServerFeature(.references))

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

    private static var startupProjectURL: URL? {
        guard let flagIndex = CommandLine.arguments.firstIndex(of: "--open-project"),
              CommandLine.arguments.indices.contains(flagIndex + 1) else { return nil }
        let url = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1]).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    private static func openProjectInNewWindow(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--open-project", url.path]
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        )
    }
}
