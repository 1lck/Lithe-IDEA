#if DEBUG
import AppKit
import Combine
import SwiftUI
import LitheModuleAPI

/// Debug preview of the toolchain settings pages driven by the production loader.
///
/// Only the plugin manifests are samples: the workspace is real files (a generated
/// sample under the temporary directory, or `--toolchain-demo-workspace <path>`),
/// pins and version files are read by the real loader and Core, and the login shell
/// is read like a first launch with its cache in the same temporary directory.
@MainActor
final class ToolchainSettingsDemo: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: AppModel?
    private var quitMonitor: Any?
    private var presetObservation: AnyCancellable?
    private let domain = "Lithe.ToolchainSettingsDemo.\(UUID().uuidString)"
    private let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("lithe-toolchain-demo-\(UUID().uuidString)", isDirectory: true)

    static func run() {
        let app = NSApplication.shared
        let delegate = ToolchainSettingsDemo()
        // Same point in startup as production: before any other thread reads the environment.
        MacLoginShellEnvironment.activate(cacheURL: delegate.scratch.appendingPathComponent("login-path"))
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let defaults = UserDefaults(suiteName: domain), let workspace = Self.workspace(scratch: scratch) else {
            NSApp.terminate(nil)
            return
        }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store, logDirectoryProvider: MacServiceContainer.makeLogDirectoryProvider())
        settings.language = .simplifiedChinese
        settings.themePreference = .light
        defaults.set(226.0, forKey: "lithe.settings.categorySidebarWidth")
        InterfaceLanguage.select(settings.language.rawValue)
        MacBundledFontRegistry.registerFonts()
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode)
        let directories = Self.directories(in: workspace)
        container.services.toolchainSettingsLoader = MacToolchainSettingsLoader(
            sources: { Self.samplePlugins },
            directories: { $0 == workspace ? directories : [] })
        let model = AppModel(settings: settings, services: container.services)
        // The settings pages load whatever workspace the model has open, as in the app.
        model.workspaceSessionCoordinator.beginWorkspace(at: workspace)
        self.model = model
        applyPresetOnFirstLoad(model.toolchainSettingsFeature)
        let category: SettingsCategory = CommandLine.arguments.contains("--toolchain-sources-demo") ? .toolchainSources : .toolchainEnvironment
        let viewState = SettingsViewState(initialCategory: category)
        let root = SettingsView(settings: settings, viewState: viewState, initialCategory: category)
            .environmentObject(model)
            .environmentObject(settings)
            .environmentObject(SettingsModelContext(model: model))
            .environmentObject(UpdateChecker(preferences: defaults))
            .environment(\.locale, settings.language.locale)
            .environment(\.colorScheme, .light)
            .environment(\.lithePointingHandCursorEnabled, false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.string("Runtime Environment — Isolated Preview")
        SettingsWindowChrome.configure(window, title: window.title, themePreference: .light)
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: SettingsAppearanceContainer(themePreference: .light) { root })
        hosting.sizingOptions = []
        // The SwiftUI production scene already owns its content safe area.
        // The AppKit preview instead opts out of full-size content after sharing
        // the production titlebar appearance, so controls cannot sit underneath it.
        window.styleMask.remove(.fullSizeContentView)
        window.contentView = hosting
        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        window.contentMinSize = NSSize(width: 900, height: 668 + titlebarHeight)
        self.window = window
        quitMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "q" {
                NSApp.terminate(nil)
                return nil
            }
            return event
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        let size = Self.size(default: NSSize(width: 1180, height: 820))
        window.setContentSize(NSSize(width: size.width, height: size.height + titlebarHeight))
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        model?.toolchainSettingsFeature.close()
        model?.workspaceSessionCoordinator.clearSession()
        if let quitMonitor { NSEvent.removeMonitor(quitMonitor) }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: scratch)
    }

    /// `--toolchain-demo-directory <id>` and `--toolchain-demo-expand <tool,…>` open a state to look at,
    /// applied once the first snapshot has loaded.
    private func applyPresetOnFirstLoad(_ feature: ToolchainSettingsFeatureModel) {
        let directory = Self.argument("--toolchain-demo-directory")
        let expanded = Self.argument("--toolchain-demo-expand")?.split(separator: ",").map(String.init) ?? []
        guard directory != nil || !expanded.isEmpty else { return }
        presetObservation = feature.$snapshot.compactMap { $0 }.first().receive(on: RunLoop.main).sink { [weak feature] _ in
            if let directory { feature?.selectDirectory(directory) }
            expanded.forEach { feature?.toggleExpanded($0) }
        }
    }

    private static func argument(_ name: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// `--toolchain-demo-size <width>x<height>` for checking narrower and wider windows.
    private static func size(default fallback: NSSize) -> NSSize {
        let parts = argument("--toolchain-demo-size")?.split(separator: "x").compactMap { Double($0) } ?? []
        return parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : fallback
    }

    /// The workspace named on the command line, or a generated sample of real files.
    private static func workspace(scratch: URL) -> URL? {
        if let path = argument("--toolchain-demo-workspace") {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        let root = scratch.appendingPathComponent("sample-workspace", isDirectory: true)
        let files = [
            "mise.toml": "[tools]\njava = \"21\"\nnode = \"22\"\n",
            "packages/web/.nvmrc": "22\n",
            "services/api/.python-version": "3.12\n",
            ".lithe/toolchains/local.json": """
                {"version": 1, "toolchains": {}, "pins": {"services/api": {"python": {
                  "home": "/opt/homebrew/opt/python@3.12", "version": "3.12",
                  "provider": "dev.lithe.sample.python:uv"}}}}
                """
        ]
        do {
            for (path, contents) in files {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: url)
            }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return root
    }

    /// Visible workspace-relative directories, breadth-first and bounded like the project tree projection.
    private static func directories(in workspace: URL) -> [String] {
        var result: [String] = []
        var queue = [(url: workspace, id: ".")]
        while !queue.isEmpty, result.count < 1_024 {
            let (url, id) = queue.removeFirst()
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                guard values?.isDirectory == true, values?.isPackage != true, result.count < 1_024 else { continue }
                let childID = id == "." ? child.lastPathComponent : id + "/" + child.lastPathComponent
                result.append(childID)
                queue.append((child, childID))
            }
        }
        return result
    }

    /// Sample manifests standing in for installed plugins; the host itself knows none of these tools.
    private static let samplePlugins: [ToolchainSettingsPluginSource] = [
        sample("dev.lithe.sample.jvm", "JVM (sample)", """
            "toolDefinitions": [
              {"id": "java", "displayName": "JDK", "executables": [
                {"kind": "environment", "variable": "JAVA_HOME", "path": "bin/java"},
                {"kind": "command", "command": "java"}]},
              {"id": "maven", "displayName": "Maven", "executables": [
                {"kind": "environment", "variable": "MAVEN_HOME", "path": "bin/mvn"},
                {"kind": "command", "command": "mvn"}]}]
            """),
        sample("dev.lithe.sample.node", "Node.js (sample)", """
            "toolDefinitions": [
              {"id": "node", "displayName": "Node.js", "executables": [{"kind": "command", "command": "node"}]}],
            "toolchainProviders": [
              {"id": "nvm", "displayName": "nvm", "tools": ["node"], "watchFiles": [{"pattern": ".nvmrc"}]}]
            """),
        sample("dev.lithe.sample.python", "Python (sample)", """
            "toolDefinitions": [
              {"id": "python", "displayName": "Python", "executables": [{"kind": "command", "command": "python3"}]}],
            "toolchainProviders": [
              {"id": "uv", "displayName": "uv", "tools": ["python"], "watchFiles": [{"pattern": ".python-version"}]}]
            """),
        sample("dev.lithe.sample.mise", "mise (sample)", """
            "toolchainProviders": [
              {"id": "mise", "displayName": "mise", "tools": ["java", "maven", "node", "python"],
               "watchFiles": [{"pattern": "mise.toml"}, {"pattern": ".tool-versions"}]}]
            """)
    ]

    private static func sample(_ id: String, _ name: String, _ contributions: String) -> ToolchainSettingsPluginSource {
        ToolchainSettingsPluginSource(pluginID: id, name: name,
                                      manifest: Data("{\"id\": \"\(id)\", \(contributions)}".utf8), isEnabled: true)
    }
}
#endif
