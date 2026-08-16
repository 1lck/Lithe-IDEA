import AppKit
import SwiftUI

private let litheProcessLaunchDate = Date()

@MainActor
final class LitheAppDelegate: NSObject, NSApplicationDelegate {
    weak var projectSessions: ProjectSessionManager?
    var recordCleanPluginShutdown: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let projectSessions else { return .terminateNow }
        return Self.confirmUnsavedDocuments(for: projectSessions) ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        projectSessions?.stopAllSessions()
        recordCleanPluginShutdown?()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let projectSessions else { return }
        Task { await projectSessions.resumeGitObservationAfterActivation() }
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
        let processRegistry = ManagedProcessRegistry()
        let moduleStore = MacModuleConfigurationStore(store: store)
        let pluginRuntimeRecovery = MacPluginRuntimeRecoveryCoordinator()
        pluginRuntimeRecovery.recoverPreviousSession(using: moduleStore)
        _settings = StateObject(wrappedValue: settings)
        let projectSessions = ProjectSessionManager(
            settings: settings,
            modelFactory: {
                AppModel(
                    settings: settings,
                    services: MacServiceContainer(
                        store: store,
                        settings: settings,
                        processRegistry: processRegistry,
                        moduleLaunchMode: CommandLine.arguments.contains("--safe-mode")
                            ? .safeMode
                            : .normal,
                        moduleStore: moduleStore,
                        pluginRuntimeRecovery: pluginRuntimeRecovery
                    ).services
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
            },
            logsPerformanceBaseline: ProcessInfo.processInfo.environment["LITHE_PERFORMANCE_BASELINE"] == "1",
            processRegistry: processRegistry,
            memorySampler: MacProcessMemorySampler()
        ))
        appDelegate.projectSessions = projectSessions
        appDelegate.recordCleanPluginShutdown = {
            pluginRuntimeRecovery.recordCleanShutdown(using: moduleStore)
        }
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
                // SwiftUI does not consistently re-resolve every existing
                // LocalizedStringKey when only the locale environment value
                // changes. Re-identify the root so a language selection takes
                // effect immediately across every workspace, including sheets.
                .id(settings.language)
                .preferredColorScheme(settings.themePreference.preferredColorScheme)
                .task {
                    memoryUsageMonitor.start()
                }
        }
        .defaultSize(
            width: LitheWindowLayout.welcomeContentSize.width,
            height: LitheWindowLayout.welcomeContentSize.height
        )
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") {
                    model.chooseProject()
                }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "open-project"))
            }

            CommandGroup(after: .saveItem) {
                Button("Save") {
                    model.saveActiveDocument()
                }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "save"))
                .disabled(model.activeDocument == nil)

                Button("Close Project") {
                    model.closeProject()
                }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "close-project"))
                .disabled(model.workspaceURL == nil)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    model.showSettings()
                }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "settings"))
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updateChecker.checkForUpdates(manual: true) }
                }
                .disabled(updateChecker.isChecking)
            }

            CommandMenu("Navigate") {
                Group {
                    Button("Search Everywhere…") {
                        model.toggleSearchEverywhere()
                    }
                    .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "search-everywhere"))
                    .disabled(model.workspaceURL == nil)

                    Divider()

                    Button("Find in File…") {
                        model.showFindBar()
                    }
                    .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "find-in-file"))
                    .disabled(model.activeDocument == nil)

                    Button("Find Next") {
                        model.navigateFind(offset: 1)
                    }
                    .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "find-next"))
                    .disabled(!model.isFindBarVisible || model.findMatchCount == 0)

                    Button("Find Previous") {
                        model.navigateFind(offset: -1)
                    }
                    .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "find-previous"))
                    .disabled(!model.isFindBarVisible || model.findMatchCount == 0)
                }

                Divider()

                Button("Go to Usage") {
                    model.goToUsages()
                }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "go-to-usage"))
                .disabled(!model.supportsLanguageServerFeature(.references))

                Button("Go to Implementation") {
                    model.goToImplementation()
                }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "go-to-implementation"))
                .disabled(!model.supportsLanguageServerFeature(.implementation))

                Button("Find Usages") {
                    model.findReferences()
                }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "find-usages"))
                .disabled(!model.supportsLanguageServerFeature(.references))

                Divider()

                Button("Find in Files…") {
                    model.openProjectSearch()
                }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "search-in-project"))
                .disabled(model.workspaceURL == nil)

                Button("Replace in Files…") {
                    model.openProjectReplace()
                }
                .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "replace-in-project"))
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

private extension AppThemePreference {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
