import AppKit
import Foundation
import SwiftUI
import LitheApplicationKernel
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI
import Testing
@testable import Lithe

/// The per-build-system tool windows: what the host reads from a build
/// system's presentation fields and the window it derives from them. The
/// fixtures are local copies of the shared Maven and Gradle fixtures with
/// the presentation fields filled in.
@Suite("Build system tool windows")
struct BuildSystemToolWindowTests {
    @Test
    func mavenPresentationFieldsDecodeThroughCore() throws {
        let descriptor = try Self.descriptor("maven-build")
        let maven = try #require(descriptor.buildSystems.first)

        #expect(maven.icon?.host == "tool-window")
        #expect(maven.option("profiles")?.presentation == .tree)
        #expect(maven.option("profiles")?.icon == nil)
        #expect(maven.option("skipTests")?.presentation == .toolbar)
        #expect(maven.option("skipTests")?.icon?.host == "run")
        #expect(maven.option("settingsFile")?.presentation == nil)
        #expect(maven.tasks.first { $0.id == "compile" }?.category == ["Lifecycle"])
        #expect(maven.tasks.first { $0.id == "goal" }?.category == [])
    }

    @Test
    func gradleTemplateCategoryIsTheDefaultOfModelTasks() throws {
        let gradle = try #require(try Self.descriptor("gradle-build").buildSystems.first)

        #expect(gradle.option("offline")?.presentation == .toolbar)
        #expect(gradle.tasks.first { $0.id == "gradle-task" }?.category == ["Tasks", "other"])
        #expect(gradle.tasks.first { $0.id == "build" }?.category == ["Tasks", "build"])
    }

    @Test
    func modelTasksCarryTheirOwnCategory() throws {
        let model = try JSONDecoder().decode(BuildModel.self, from: Data(#"""
        {"projects":[{"id":"app","path":".","name":"app"}],
         "tasks":[
           {"id":"app:compileJava","projectID":"app","name":"compileJava","path":".","template":"gradle-task",
            "group":"build","category":["Tasks","build"]},
           {"id":"app:compiler:compile","projectID":"app","name":"compiler:compile","path":".","template":"plugin-goal",
            "category":["Plugins","compiler"]},
           {"id":"app:custom","projectID":"app","name":"custom","path":".","template":"gradle-task"}
         ]}
        """#.utf8))

        #expect(model.tasks.map(\.category) == [["Tasks", "build"], ["Plugins", "compiler"], []])
    }

    @Test @MainActor
    func everyBuildSystemDerivesItsOwnWindowAndToggleCommand() throws {
        let descriptor = try Self.descriptor("gradle-build")
        let module = try #require(descriptor.pluginManifest.modules.first {
            $0.manifest.id == .buildSystemsExtension(descriptor.id.rawValue)
        })
        let gradle = try #require(descriptor.buildSystems.first)
        let windowID = DeclarativeBuildSystem.toolWindowID(pluginID: descriptor.id.rawValue, buildSystemID: gradle.id)
        let window = try #require(module.contributions.first { $0.kind == .toolWindow })
        let command = try #require(module.contributions.first { $0.kind == .command })

        #expect(window.id == windowID)
        #expect(window.title == gradle.displayName)
        #expect(window.placement == .rightSidebar)
        #expect(window.uiIcon == gradle.icon)
        #expect(window.visibility[DeclarativeBuildSystem.buildSystemIDKey] == gradle.id)
        #expect(command.placement == .commandPalette)
        #expect(command.visibility["toolWindowID"] == windowID)
        #expect(command.actionID != window.actionID)
        // Plugin UI ids cannot contain `:`, so the derived id never collides.
        #expect(windowID.contains(":"))

        let registry = try WorkbenchModuleUIRegistry(registrations: [
            WorkbenchModuleUIRegistry.buildSystemRegistration(module)
        ])
        try registry.validate(contributions: module.contributions)
        #expect(registry.renderer(for: window)?.rightSidebarBehavior == .docked)
    }

    @Test @MainActor
    func enabledBuildSystemWindowShowsInAWorkspaceWithoutAnInstance() throws {
        let descriptor = try Self.descriptor("gradle-build")
        let module = try #require(descriptor.pluginManifest.modules.first {
            $0.manifest.id == .buildSystemsExtension(descriptor.id.rawValue)
        })
        let window = try #require(module.contributions.first { $0.kind == .toolWindow })
        let command = try #require(module.contributions.first { $0.kind == .command })
        let registration = WorkbenchModuleUIRegistry.buildSystemRegistration(module)
        let renderer = try #require(registration.renderers.first { $0.id == window.rendererID })
        let toggle = try #require(registration.actions.first { $0.id == command.actionID })

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-build-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BuildSystemWindowTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services
        let model = AppModel(settings: settings, services: services)

        // Without a workspace there is nothing to build.
        #expect(!renderer.isVisible(model))
        #expect(!toggle.state(model).isVisible)

        // An empty folder has no Gradle marker; the window still shows so
        // the user can see the plugin is active.
        model.openProjectDirectly(root)
        #expect(renderer.isVisible(model))
        #expect(toggle.state(model).isVisible)
    }

    @Test @MainActor
    func tasksWithoutACategoryAreFiledByGroup() {
        #expect(BuildSystemToolWindowView.groupTitle(.lifecycle) == String(localized: "Lifecycle"))
        #expect(BuildSystemToolWindowView.groupTitle(.other) == String(localized: "Other"))
    }

    @Test @MainActor
    func argumentTasksPreserveRootProjectAndTargetScope() throws {
        let project = BuildModel.Project(id: "root", path: ".", name: "root")
        let child = BuildModel.Project(id: "app", path: "app", name: "app")
        func task(_ scopes: [BuildScope], tags: [String] = []) -> DeclarativeBuildSystem.Task {
            .init(id: "arguments", displayName: "Arguments", group: .run, scopes: scopes,
                  fromModel: false, targetTags: tags, requiresUserArguments: true, description: nil)
        }
        // A root that stands for the instance only uses workspace scope when
        // the declaration actually offers it; project-only tasks retain it.
        let projectRequest = try #require(BuildSystemToolWindowView.argumentRequest(task([.project]), project: project, isRoot: true))
        #expect(projectRequest.project == BuildSelection(project: project))
        #expect(BuildSystemToolWindowView.argumentRequest(task([.workspace, .project]), project: project, isRoot: true)?.project == nil)
        #expect(BuildSystemToolWindowView.argumentRequest(task([.workspace, .project]), project: child)?.project == BuildSelection(project: child))
        #expect(BuildSystemToolWindowView.argumentRequest(task([.project]), project: nil) == nil)
        #expect(BuildSystemToolWindowView.argumentRequest(task([.workspace]), project: child) == nil)

        let target = try JSONDecoder().decode(BuildModel.Target.self, from: Data(#"{"id":"app:test","projectID":"app","name":"test","path":"app","tags":["test"]}"#.utf8))
        let targetTask = task([.target], tags: ["test"])
        let targetRequest = try #require(BuildSystemToolWindowView.argumentRequest(targetTask, project: child, target: target))
        #expect(targetRequest.target == BuildSelection(target: target))
        #expect(targetRequest.project == BuildSelection(project: child))
        #expect(BuildSystemToolWindowView.argumentRequest(targetTask, project: child) == nil)
        #expect(BuildSystemToolWindowView.argumentRequest(task([.target], tags: ["example"]), project: child, target: target) == nil)
        #expect(BuildSystemToolWindowView.argumentRequest(task([.project]), project: child, target: target) == nil)
    }

    @Test @MainActor
    func restoringBuildWindowActivatesItsOwnerAndPaletteTracksPendingState() async throws {
        let descriptor = try Self.descriptor("gradle-build")
        let declaration = try #require(descriptor.pluginManifest.modules.first {
            $0.manifest.id == .buildSystemsExtension(descriptor.id.rawValue)
        })
        let registration = WorkbenchModuleUIRegistry.buildSystemRegistration(declaration)
        let window = try #require(declaration.contributions.first { $0.kind == .toolWindow })
        let command = try #require(declaration.contributions.first { $0.kind == .command })
        let suite = "lithe-build-window-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults), settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings)
        defer { container.moduleLifecycleCoordinator.stop() }
        try container.services.moduleRuntime.register(ModuleFactory(manifest: declaration.manifest, contributions: declaration.contributions) {
            DeclarativeWorkbenchModule(declaration: declaration)
        }, enabled: true)
        let model = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { scope in
            let activate = try #require(registration.actions.first { $0.id == window.actionID }?.activateOwner)
            try await scope.run("build window owner activation") { #expect(await activate(model)) }
            #expect(try container.services.moduleRuntime.snapshot(for: declaration.manifest.id).isInstantiated)
            let pending = Task<Void, Never> {}
            defer { pending.cancel(); model.contributionActivationTasks.removeValue(forKey: window.id) }
            try await scope.run("pending marker completion") { await pending.value }
            model.contributionActivationTasks[window.id] = pending
            let state = try #require(registration.actions.first { $0.id == command.actionID }).state(model)
            #expect(state.isPending && !state.isEnabled)
        }
    }

    @Test @MainActor
    func independentBuildWindowsRestoreDockAndVisibilityWithoutLegacyMavenEntries() throws {
        let first = try Self.descriptor("maven-build")
        let second = try Self.descriptor("gradle-build")
        let declarations = [first, second].flatMap { $0.pluginManifest.modules }.filter { !$0.contributions.isEmpty }
        let owners = Dictionary(uniqueKeysWithValues: declarations.map { ($0.manifest.id, $0.contributions) })
        let windows = declarations.flatMap(\.contributions).filter { $0.kind == .toolWindow }
        #expect(Set(windows.map(\.id)).count == 2)
        let suite = "lithe-build-window-layout-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkbenchLayoutStore(store: MacUserDefaultsStore(defaults: defaults))
        let workspace = URL(fileURLWithPath: "/fixture/build-windows")
        let workbench = WorkbenchFeatureModel(layoutStore: store)
        workbench.reconcileContributions(owners)
        _ = workbench.loadLayout(for: workspace)
        let firstWindow = WorkbenchFeatureModel.ToolWindow(rawValue: windows[0].id)
        let secondWindow = WorkbenchFeatureModel.ToolWindow(rawValue: windows[1].id)
        let secondary = DockPosition(anchor: .right, group: .secondary)
        workbench.move(firstWindow, to: secondary)
        workbench.setVisibility(firstWindow, isVisible: true)
        workbench.setVisibility(secondWindow, isVisible: true)
        workbench.saveLayout(.init(sidebarWidth: 310, topPaneHeight: 280), for: workspace)
        let restored = WorkbenchFeatureModel(layoutStore: store)
        restored.reconcileContributions(owners)
        _ = restored.loadLayout(for: workspace)
        #expect(restored.activeTool(in: secondary) == firstWindow)
        #expect(restored.activeRightToolWindow == secondWindow)
        #expect(restored.isVisible(firstWindow) && restored.isVisible(secondWindow))
        let builtinIDs = Set(BuiltInModuleCatalog.contributions(for: .execution).map(\.id))
        #expect(builtinIDs.isDisjoint(with: ["execution.maven", "execution.maven.output", "execution.build"]))
        #expect(LitheCommandCatalog.command(id: "toggle-maven") == nil)
    }

    @Test @MainActor
    func packagedBuildWindowAndOptionIconsRemainReadOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-build-icons-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = try #require(JSONSerialization.jsonObject(with: Self.descriptor("maven-build").normalizedManifest) as? [String: Any])
        var builds = try #require(manifest["buildSystems"] as? [[String: Any]])
        let icon: [String: Any] = ["path": "light.svg", "darkPath": "dark.svg", "mode": "original"]
        builds[0]["icon"] = icon
        var options = try #require(builds[0]["options"] as? [[String: Any]])
        let toolbar = try #require(options.firstIndex { $0["presentation"] as? String == "toolbar" })
        options[toolbar]["icon"] = icon
        builds[0]["options"] = options
        manifest["buildSystems"] = builds
        let data = try JSONSerialization.data(withJSONObject: manifest)
        let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: data)
        let light = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="#ff0000"/></svg>"##.utf8)
        let dark = Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="#0000ff"/></svg>"##.utf8)
        let files = ["plugin.json": data, "light.svg": light, "dark.svg": dark]
        for (name, bytes) in files { try bytes.write(to: root.appendingPathComponent(name)) }
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let resources = try MacPluginUIIconLoader.load(descriptor, at: root)
        let build = try #require(descriptor.buildSystems.first)
        let windowID = DeclarativeBuildSystem.toolWindowID(pluginID: descriptor.id.rawValue, buildSystemID: build.id)
        let option = try #require(build.options.first { $0.icon?.path != nil })
        let optionID = DeclarativeBuildSystem.optionIconID(toolWindowID: windowID, optionID: option.id)
        #expect(resources[windowID]?.light == light && resources[windowID]?.dark == dark)
        #expect(resources[optionID]?.light == light && resources[optionID]?.dark == dark)
        let icons = BuildSystemToolWindowIcons(windowID: windowID, window: .init(build.icon, resources: resources[windowID]), resources: resources)
        #expect(icons.option(option) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == before)
        for (name, bytes) in files { #expect(try Data(contentsOf: root.appendingPathComponent(name)) == bytes) }
    }

    @Test @MainActor
    func optionRootSelectionPreservesEachInstancesChoicesAndEffectiveValue() throws {
        let descriptor = try Self.descriptor("maven-build")
        let declaration = try #require(descriptor.buildSystems.first)
        let source = BuildSystemPluginSource(
            pluginID: descriptor.id.rawValue, manifest: descriptor.normalizedManifest,
            packageURL: URL(fileURLWithPath: "/fixture/plugin"), buildSystems: descriptor.buildSystems
        )
        func entry(_ root: String, feature: String) throws -> BuildSystemEntry {
            BuildSystemEntry(
                instance: BuildSystemInstance(
                    id: "fixture:" + root, pluginID: source.pluginID, buildSystemID: declaration.id,
                    displayName: "Fixture", root: root, markers: [], modelSource: .static,
                    optionFingerprint: "fixture", model: nil, modelError: nil
                ), declaration: declaration, source: source,
                options: [try Self.option(kind: "multiSelect", value: [feature], choices: [feature], allowCustom: false)]
            )
        }
        let entries = [try entry("a", feature: "cli"), try entry("b", feature: "gui")]
        let first = try #require(BuildSystemToolWindowView.optionEntry(in: entries, selectedID: nil))
        let second = try #require(BuildSystemToolWindowView.optionEntry(in: entries, selectedID: "fixture:b"))
        #expect(first.options.first?.choices.map(\.value) == ["cli"])
        #expect(first.options.first?.value == .array([.string("cli")]))
        #expect(second.options.first?.choices.map(\.value) == ["gui"])
        #expect(second.options.first?.value == .array([.string("gui")]))
        #expect(BuildSystemToolWindowView.optionEntry(in: [entries[0]], selectedID: "fixture:b") == entries[0])
        #expect(BuildSystemToolWindowView.optionRootTitle(try entry(".", feature: "cli")) == "Fixture")
    }

    @Test @MainActor
    func customSingleAndMultiSelectUseTheNativeMenuActions() throws {
        let single = try Self.option(kind: "singleSelect", value: "custom", choices: ["known"])
        var submitted: ToolingJSONValue?
        let singleItems = BuildOptionRow.choiceItems(option: single) { submitted = $0 }
        #expect(singleItems.map(\.title) == ["known", "custom"])
        #expect(singleItems.last?.isChecked == true)
        singleItems[0].action()
        #expect(submitted == .string("known"))
        #expect(BuildOptionEditing.customValue(" replacement ", in: single) == .string("replacement"))

        let multi = try Self.option(kind: "multiSelect", value: ["known", "custom"], choices: ["known"])
        let multiItems = BuildOptionRow.choiceItems(option: multi) { submitted = $0 }
        #expect(multiItems.map(\.title) == ["known", "custom"])
        #expect(multiItems.allSatisfy { $0.isChecked })
        multiItems[1].action()
        #expect(submitted == .array([.string("known")]))
        #expect(BuildOptionEditing.customValue("added", in: multi) == .array([.string("known"), .string("custom"), .string("added")]))
        #expect(BuildOptionEditing.customValue("custom", in: multi) == multi.value)
        #expect(BuildOptionEditing.customValue("  ", in: multi) == nil)
        let fixed = try Self.option(kind: "multiSelect", value: [], choices: ["known"], allowCustom: false)
        #expect(BuildOptionEditing.customValue("added", in: fixed) == nil)
    }

    @Test @MainActor
    func textFileAndDirectorySubmitEmptyString() throws {
        for kind in ["text", "file", "directory"] {
            let option = try Self.option(kind: kind, value: "default", choices: [])
            var changes: [ToolingJSONValue?] = []
            let host = NSHostingView(rootView: BuildOptionRow(option: option, indent: 0) { changes.append($0) })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 36),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.makeFirstResponder(nil); window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            let field = try #require(Self.descendants(host, of: NSTextField.self).first { $0.isEditable })
            #expect(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.string = ""
            field.stringValue = ""
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
            // Drive SwiftUI's actual native field action. The former nil-on-
            // empty onSubmit fails here even though service round-trip tests pass.
            #expect(field.sendAction(field.action, to: field.target))
            #expect(changes.count == 1)
            #expect(changes.first! == .string(""))
        }
    }

    @Test @MainActor
    func nativeOptionRowsRenderInBothAppearances() throws {
        for scheme in [ColorScheme.dark, .light] {
            let options = [
                try Self.option(kind: "singleSelect", value: "custom", choices: ["known"]),
                try Self.option(kind: "multiSelect", value: ["known", "custom"], choices: ["known"]),
                try Self.option(kind: "file", value: "", choices: [])
            ]
            let host = NSHostingView(rootView: VStack(spacing: 4) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    BuildOptionRow(option: option, indent: 0) { _ in }
                }
            }.padding(14).background(LitheTheme.sidebar).environment(\.colorScheme, scheme))
            host.frame = NSRect(x: 0, y: 0, width: 360, height: 140)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width > 0 && host.fittingSize.height > 0)
            if let directory = ProcessInfo.processInfo.environment["LITHE_BUILD_CAPTURE_DIR"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("build-options-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    @MainActor
    private static func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
    }

    private static func option(kind: String, value: Any, choices: [String], allowCustom: Bool = true) throws -> BuildResolvedOption {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "values", "displayName": "Values", "kind": kind, "value": value,
            "source": "user", "allowCustom": allowCustom,
            "choices": choices.map { ["value": $0, "fromModel": true] as [String: Any] }
        ])
        return try JSONDecoder().decode(BuildResolvedOption.self, from: data)
    }

    private static func descriptor(_ name: String) throws -> DeclarativePluginDescriptor {
        let url = try #require(Bundle.module.url(
            forResource: name + ".plugin", withExtension: "json", subdirectory: "Fixtures/BuildSystems"
        ))
        return try DeclarativePluginTestSupport.operations.validate(manifest: Data(contentsOf: url))
    }
}

private final class BuildSystemWindowTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
