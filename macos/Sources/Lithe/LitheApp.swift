import AppKit
import SwiftUI

private let litheProcessLaunchDate = Date()

@MainActor
final class LitheAppDelegate: NSObject, NSApplicationDelegate {
    private var pendingFileURLs: [URL] = []
    weak var projectSessions: ProjectSessionManager? {
        didSet {
            guard let projectSessions else { return }
            let pendingURLs = pendingFileURLs
            pendingFileURLs.removeAll()
            pendingURLs.forEach { projectSessions.openStandaloneFile($0) }
        }
    }
    var recordCleanPluginShutdown: (() -> Void)?
    var authorizationCallbackRouter: MacExternalAuthorizationCallbackRouter?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // SwiftUI normally forwards this event to the delegate methods below,
        // but older Finder/AppKit launch paths can bypass that forwarding.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let projectSessions else { return .terminateNow }
        return Self.confirmUnsavedDocuments(for: projectSessions) ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
        projectSessions?.stopAllSessions()
        recordCleanPluginShutdown?()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let projectSessions else { return }
        Task { await projectSessions.resumeGitObservationAfterActivation() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handleOpenedURLs(urls)
    }

    // Finder can deliver document-open Apple Events through these older
    // delegate methods, depending on whether the app was already running.
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        handleOpenedURLs([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        handleOpenedURLs(filenames.map(URL.init(fileURLWithPath:)))
        sender.reply(toOpenOrPrint: .success)
    }

    @objc private func handleOpenDocuments(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor?
    ) {
        guard let fileList = event.paramDescriptor(forKeyword: keyDirectObject) else { return }

        var urls: [URL] = []
        guard fileList.numberOfItems > 0 else { return }
        for index in 1...fileList.numberOfItems {
            guard let aliasDescriptor = fileList.atIndex(index),
                  let fileURLDescriptor = aliasDescriptor.coerce(toDescriptorType: typeFileURL),
                  let url = URL(dataRepresentation: fileURLDescriptor.data, relativeTo: nil) else {
                continue
            }
            urls.append(url)
        }

        handleOpenedURLs(urls)
    }

    private func handleOpenedURLs(_ urls: [URL]) {
        for url in urls {
            if url.scheme == "lithe" {
                authorizationCallbackRouter?.route(url)
            } else if url.isFileURL {
                if let projectSessions {
                    projectSessions.openStandaloneFile(url)
                } else if !pendingFileURLs.contains(where: {
                    $0.standardizedFileURL == url.standardizedFileURL
                }) {
                    pendingFileURLs.append(url.standardizedFileURL)
                }
            }
        }
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
    @StateObject private var frameRateMonitor = FrameRateMonitor()
    @StateObject private var updateChecker = UpdateChecker()
    private let applicationLogWriter: MacApplicationLogWriter

    init() {
        let store = MacUserDefaultsStore()
        let settings = AppSettings(
            store: store,
            logDirectoryProvider: MacServiceContainer.makeLogDirectoryProvider()
        )
        let applicationLogWriter = MacServiceContainer.makeApplicationLogWriter()
        if !Self.redirectApplicationLogs(applicationLogWriter, to: settings.logDirectory),
           settings.customLogDirectory != nil {
            settings.setCustomLogDirectory(nil)
            _ = Self.redirectApplicationLogs(applicationLogWriter, to: settings.defaultLogDirectory)
        }
        settings.addLogDirectoryObserver { [weak settings] directory in
            guard !Self.redirectApplicationLogs(applicationLogWriter, to: directory),
                  settings?.customLogDirectory != nil else { return }
            settings?.setCustomLogDirectory(nil)
        }
        self.applicationLogWriter = applicationLogWriter
        MacBundledFontRegistry.registerFonts { message in
            Self.appendApplicationLog(applicationLogWriter, message: message)
        }
        let processRegistry = ManagedProcessRegistry()
        let moduleStore = MacModuleConfigurationStore(store: store)
        let pluginRuntimeRecovery = MacPluginRuntimeRecoveryCoordinator()
        let authorizationCallbackRouter = MacExternalAuthorizationCallbackRouter()
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
                        pluginRuntimeRecovery: pluginRuntimeRecovery,
                        authorizationCallbackRouter: authorizationCallbackRouter
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
                Self.appendApplicationLog(applicationLogWriter, message: marker + "\n")
            },
            logsPerformanceBaseline: ProcessInfo.processInfo.environment["LITHE_PERFORMANCE_BASELINE"] == "1",
            processRegistry: processRegistry,
            memorySampler: MacProcessMemorySampler()
        ))
        appDelegate.projectSessions = projectSessions
        appDelegate.authorizationCallbackRouter = authorizationCallbackRouter
        appDelegate.recordCleanPluginShutdown = {
            pluginRuntimeRecovery.recordCleanShutdown(using: moduleStore)
        }
    }

    private static func redirectApplicationLogs(
        _ writer: MacApplicationLogWriter,
        to directory: URL
    ) -> Bool {
        do {
            try writer.redirect(to: directory)
            return true
        } catch {
            let message = "Could not redirect Lithe logs to \(directory.path): \(error.localizedDescription)\n"
            if let data = message.data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
            return false
        }
    }

    private static func appendApplicationLog(
        _ writer: MacApplicationLogWriter,
        message: String
    ) {
        do {
            try writer.append(message)
        } catch {
            let fallback = "Could not write Lithe log: \(error.localizedDescription)\n"
            if let data = fallback.data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
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
                .environmentObject(frameRateMonitor)
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
                    frameRateMonitor.start()
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

                Button("Close File") {
                    model.closeStandaloneFile()
                }
                .disabled(model.standaloneFileURL == nil)
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
                    Button("Back") {
                        model.navigateBack()
                    }
                    .litheKeyboardShortcut(
                        model.keyboardShortcutFeature.primaryKeyPress(for: "navigate-back")
                    )
                    .disabled(!model.canNavigateBack)

                    Button("Forward") {
                        model.navigateForward()
                    }
                    .litheKeyboardShortcut(
                        model.keyboardShortcutFeature.primaryKeyPress(for: "navigate-forward")
                    )
                    .disabled(!model.canNavigateForward)

                    Divider()

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

                    Button("Replace in File…") {
                        model.showReplaceBar()
                    }
                    .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "replace-in-file"))
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

                    Button("Go to Line…") {
                        model.showGoToLineBar()
                    }
                    .litheKeyboardShortcut(model.keyboardShortcutFeature.primaryKeyPress(for: "go-to-line"))
                    .disabled(model.activeDocument == nil)
                }

                Divider()

                Button("Go to Definition") {
                    model.goToDefinition()
                }
                .litheKeyboardShortcut(
                    model.keyboardShortcutFeature.primaryKeyPress(for: "go-to-definition")
                )
                .disabled(!model.canPerformShortcutCommand(id: "go-to-definition"))

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

        Window(settingsWindowTitle(for: settings.language), id: LitheWindowID.settings) {
            SettingsWindow(
                model: model,
                settings: settings
            )
            .environmentObject(settings)
            .environmentObject(updateChecker)
            .environment(\.locale, settings.language.locale)
        }
        .defaultSize(width: 1040, height: 720)
        .windowResizability(.contentMinSize)
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

private struct SettingsWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @StateObject private var windowReference = SettingsWindowReference()
    @StateObject private var viewState: SettingsViewState

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        _viewState = StateObject(wrappedValue: SettingsViewState(
            initialCategory: model.requestedSettingsCategory
        ))
    }

    var body: some View {
        SettingsAppearanceContainer(themePreference: settings.themePreference) {
            SettingsView(
                settings: settings,
                viewState: viewState,
                initialCategory: model.requestedSettingsCategory,
                onDismiss: close
            )
            .environmentObject(model)
        }
        .background(
            SettingsWindowAccessor(
                reference: windowReference,
                title: settingsWindowTitle(for: settings.language),
                themePreference: settings.themePreference
            )
        )
        .onDisappear {
            model.isSettingsPresented = false
        }
    }

    private func close() {
        model.isSettingsPresented = false
        windowReference.window?.performClose(nil)
    }
}

struct SettingsAppearanceContainer<Content: View>: View {
    let themePreference: AppThemePreference
    let content: Content

    init(
        themePreference: AppThemePreference,
        @ViewBuilder content: () -> Content
    ) {
        self.themePreference = themePreference
        self.content = content()
    }

    var body: some View {
        content.preferredColorScheme(themePreference.preferredColorScheme)
    }
}

@MainActor
private final class SettingsWindowReference: ObservableObject {
    weak var window: NSWindow?
}

private final class SettingsTitlebarBackgroundView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class SettingsWindowProbe: NSView {
    var onEffectiveAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }
}

private struct SettingsWindowAccessor: NSViewRepresentable {
    let reference: SettingsWindowReference
    let title: String
    let themePreference: AppThemePreference

    func makeNSView(context: Context) -> SettingsWindowProbe {
        let view = SettingsWindowProbe(frame: .zero)
        bindAppearanceUpdates(to: view)
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ view: SettingsWindowProbe, context: Context) {
        bindAppearanceUpdates(to: view)
        configureWindow(for: view)
    }

    private func bindAppearanceUpdates(to view: SettingsWindowProbe) {
        view.onEffectiveAppearanceChange = { [weak view] in
            guard let view else { return }
            configureWindow(for: view)
        }
    }

    private func configureWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            reference.window = window
            window.title = title
            let windowAppearance = themePreference.windowAppearance
            if window.appearance?.name != windowAppearance?.name {
                window.appearance = windowAppearance
            }
            if window.contentView?.appearance?.name != windowAppearance?.name {
                window.contentView?.appearance = windowAppearance
            }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .visible
            window.titlebarSeparatorStyle = .none
            window.isOpaque = true
            let settingsSurface = LitheTheme.settingsSurfaceNSColor(
                for: window.effectiveAppearance
            )
            window.backgroundColor = settingsSurface
            applySettingsSurface(toTitlebarOf: window, color: settingsSurface)
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
            window.standardWindowButton(.zoomButton)?.isEnabled = true
        }
    }

    private func applySettingsSurface(toTitlebarOf window: NSWindow, color: NSColor) {
        // AppKit places the titlebar in multiple nested views. Styling only
        // the close-button's immediate superview leaves the opaque theme
        // frame above it untouched, which is the extra strip seen in the
        // settings window. Apply the same surface to each titlebar ancestor.
        var view = window.standardWindowButton(.closeButton)?.superview
        var titlebarHost: NSView?
        while let current = view, current !== window.contentView {
            current.wantsLayer = true
            current.layer?.backgroundColor = color.cgColor
            if current.bounds.width >= window.frame.width * 0.8,
               current.bounds.height <= 100 {
                titlebarHost = current
            }
            view = current.superview
        }

        guard let titlebarHost else { return }
        let backgroundView: SettingsTitlebarBackgroundView
        if let existing = titlebarHost.subviews.first(where: {
            $0 is SettingsTitlebarBackgroundView
        }) as? SettingsTitlebarBackgroundView {
            backgroundView = existing
        } else {
            backgroundView = SettingsTitlebarBackgroundView(frame: titlebarHost.bounds)
            titlebarHost.addSubview(backgroundView, positioned: .below, relativeTo: nil)
        }
        backgroundView.frame = titlebarHost.bounds
        backgroundView.autoresizingMask = [.width, .height]
        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = color.cgColor
    }
}

private func settingsWindowTitle(for language: AppLanguage) -> String {
    String(
        localized: "Settings",
        bundle: .main,
        locale: language.locale
    )
}

private extension AppThemePreference {
    var windowAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
