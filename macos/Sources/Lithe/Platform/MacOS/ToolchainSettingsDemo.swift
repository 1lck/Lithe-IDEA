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
    private let logSink = MacLogStore()
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
        guard let defaults = UserDefaults(suiteName: domain), let workspace = Self.workspace(scratch: scratch, logSink: logSink) else {
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
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode, applicationLogging: logSink)
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
        do { try FileManager.default.removeItem(at: scratch) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { /* Workspace was never created. */ }
        catch { logSink.emit(AppDemoFailed(error: error, stage: "cleanup")) }
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
    private static func workspace(scratch: URL, logSink: (any LogSink)? = nil) -> URL? {
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
            logSink?.emit(AppDemoFailed(error: error, stage: "workspace"))
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

    /// Sample manifests standing in for installed official plugins; the host itself knows none of these tools.
    /// They are complete production manifests, so Core admits them and discovery scans this Mac for real.
    static let samplePlugins: [ToolchainSettingsPluginSource] = [
        sample("dev.lithe.sample.jvm", "JVM (sample)", definitions: [
            tool("java", "JDK", layout: "bin/java", version: (["-version"], #"version \"(?:1\.)?(\d+(?:\.\d+)*)"#),
                 variable: "JAVA_HOME", command: "java",
                 homeLayouts: [["match": "*.jdk", "home": "Contents/Home"], ["match": "*", "home": "."]],
                 discovery: [absolute("/Library/Java/JavaVirtualMachines", "*.jdk"),
                             home("Library/Java/JavaVirtualMachines/*.jdk"), home(".sdkman/candidates/java/*"),
                             absolute("/opt/homebrew/Cellar", "openjdk*/*")]),
            tool("maven", "Maven", layout: "bin/mvn", version: (["--version"], #"Apache Maven (\d+(?:\.\d+)*)"#),
                 variable: "MAVEN_HOME", command: "mvn",
                 discovery: [absolute("/opt/homebrew/Cellar", "maven/*"), home(".sdkman/candidates/maven/*")])
        ]),
        sample("dev.lithe.sample.node", "Node.js (sample)", definitions: [
            tool("node", "Node.js", layout: "bin/node", version: (["--version"], #"v(\d+(?:\.\d+)*)"#), command: "node",
                 discovery: [home(".nvm/versions/node/*"), absolute("/opt/homebrew/Cellar", "node/*"),
                             absolute("/opt/homebrew/Cellar", "node@*/*")])
        ], providers: [provider("nvm", "nvm", tools: ["node"], watch: [".nvmrc"])]),
        sample("dev.lithe.sample.python", "Python (sample)", definitions: [
            tool("python", "Python", layout: "bin/python3", version: (["--version"], #"Python (\d+(?:\.\d+)*)"#),
                 command: "python3", discovery: [home(".local/share/uv/python/cpython-*")])
        ], providers: [provider("uv", "uv", tools: ["python"], watch: [".python-version"])]),
        sample("dev.lithe.sample.mise", "mise (sample)", providers: [
            provider("mise", "mise", tools: ["java", "maven", "node", "python"], watch: ["mise.toml", ".tool-versions"])
        ])
    ]

    private static func sample(
        _ id: String, _ name: String, definitions: [[String: Any]] = [], providers: [[String: Any]] = []
    ) -> ToolchainSettingsPluginSource {
        var manifest: [String: Any] = [
            "schemaVersion": 2, "id": id, "displayName": name, "version": "1.0.0", "pluginAPIVersion": 3,
            "vendor": ["id": "dev.lithe.sample", "displayName": "Lithe samples", "signatureRequirement": "publisherPackage"]
        ]
        var requires: [String: Int] = [:]
        var permissions: [String] = []
        if !definitions.isEmpty {
            manifest["toolDefinitions"] = definitions
            requires.merge(["toolDefinitions": 1, "executableResolution": 2]) { $1 }
        }
        if !providers.isEmpty {
            manifest["toolchainProviders"] = providers
            manifest["backend"] = ["launch": ["kind": "packaged", "path": "bin/provider"], "arguments": ["--stdio"]]
            requires.merge(["toolchainProviders": 1, "backend": 2, "serverProcess": 1]) { $1 }
            permissions = ["backend.launch", "toolchains.provide"]
        }
        manifest["requires"] = requires
        manifest["permissions"] = permissions
        let data = (try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])) ?? Data()
        return ToolchainSettingsPluginSource(pluginID: id, name: name, manifest: data, isEnabled: true)
    }

    private static func tool(
        _ id: String, _ name: String, layout: String, version: ([String], String), variable: String? = nil,
        command: String, homeLayouts: [[String: String]] = [], discovery: [[String: Any]]
    ) -> [String: Any] {
        var executables: [[String: Any]] = [
            ["id": "pinned", "kind": "setting", "settingID": "executable", "layer": "project"],
            ["id": "project-request", "kind": "toolchain", "scope": "project"],
            ["id": "default", "kind": "setting", "settingID": "executable", "layer": "global"],
            ["id": "global-request", "kind": "toolchain", "scope": "global"]
        ]
        if let variable { executables.append(["id": "home", "kind": "environment", "variable": variable, "path": layout]) }
        executables += [["id": "shell", "kind": "command", "command": command],
                        ["id": "detected", "kind": "toolchain", "scope": "installed"]]
        var definition: [String: Any] = [
            "id": id, "displayName": name, "icon": ["host": "plugin"],
            "executableLayouts": [["path": layout]], "executables": executables,
            "version": ["arguments": version.0, "pattern": version.1],
            "homeLayouts": homeLayouts, "discovery": discovery,
            "commands": [command], "wrappers": [], "pathPrepend": ["${home}/bin"],
            "exports": variable.map { [["name": $0, "value": "${home}"]] } ?? [],
            "launch": ["${executable}", "${arguments}"]
        ]
        if let variable { definition["homeVariable"] = variable }
        return definition
    }

    private static func provider(_ id: String, _ name: String, tools: [String], watch: [String]) -> [String: Any] {
        ["id": id, "displayName": name, "tools": tools, "watchFiles": watch.map { ["pattern": $0, "reader": "native"] }]
    }

    private static func home(_ pattern: String) -> [String: Any] { ["root": ["kind": "home"], "pattern": pattern] }

    private static func absolute(_ path: String, _ pattern: String) -> [String: Any] {
        ["root": ["kind": "absolute", "path": path], "pattern": pattern]
    }
}
#endif
