import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI
@testable import Lithe

/// Native presentation evidence over real Core plans and controlled Providers.
/// No build tool, backend process, or application process is started.
@MainActor
@Suite("Provider workflow presentation", .serialized)
struct ProviderWorkflowPresentationTests {
    @Test(arguments: [false, true])
    func nativeBuildDiscoveryAndDebugEntriesRemainVisible(dark: Bool) async throws {
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previousAccessibility, forAttribute: attribute) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("// fixture".utf8).write(to: root.appendingPathComponent("build.gradle"))
        let suite = "provider-ui-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backing = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: backing)
        let container = MacServiceContainer(store: backing, settings: settings)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        let core = RustCoreBridge()
        let descriptor = try RustDeclarativePluginOperations(core: core).validate(manifest: Data(contentsOf:
            DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/contracts/plugins/v1/fixtures/build-provider-debug-preparation.plugin.json")))
        let source = BuildSystemPluginSource(pluginID: descriptor.id.rawValue, manifest: descriptor.normalizedManifest,
            packageURL: root, buildSystems: descriptor.buildSystems)
        let service = BuildSystemService(planner: RustBuildSystemOperations(core: core), tools: PresentationBuildTools(),
            optionsStore: MacBuildOptionsStore(store: backing),
            stateLocator: MacBuildSystemStateLocator(directories: MacPluginStateDirectories(rootURL: root.appendingPathComponent("state")), fileStorage: MacFileStorage()),
            runner: PresentationBuildRunner(), providers: PresentationBuildProvider(), sources: { [source] })
        defer { service.stop() }
        let feature = BuildSystemsFeatureModel(service: service)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { _ in
            feature.reset(workspaceURL: root)
            _ = try await service.prepareLanguageImport(workspaceURL: root)
            let entryID = try #require(feature.entries.first?.id)
            let loaded = TestGate()
            let loadedObservation = service.$entries.sink { if $0.first?.modelState == .loaded { loaded.open() } }
            defer { loadedObservation.cancel() }
            feature.loadModel(entryID)
            try #require(await loaded.waitUntilOpen(timeout: .seconds(5)))
            let discovered = TestGate()
            let discoveryObservation = service.runEnded.sink { if $0.state == .succeeded { discovered.open() } }
            defer { discoveryObservation.cancel() }
            feature.discoverTests(entryID)
            try #require(await discovered.waitUntilOpen(timeout: .seconds(5)))
            guard case .loaded(let discovery)? = feature.testDiscovery(entryID) else {
                Issue.record("Expected discovered tests before rendering")
                return
            }
            #expect(discovery.tests.count == 2)
            let windowID = "provider-ui"
            let icons = BuildSystemToolWindowIcons(windowID: windowID,
                window: WorkbenchContributionIcon.Asset(nil, resources: nil), resources: [:])
            let view = HStack(spacing: 1) {
                BuildSystemToolWindowView(feature: feature, title: "Gradle", toolWindow: .init(rawValue: windowID),
                    pluginID: descriptor.id.rawValue, buildSystemID: "gradle", icons: icons).frame(width: 460)
                BuildOutputView(feature: feature)
            }.environmentObject(model).environmentObject(settings).defaultAppStorage(defaults)
                .environment(\.locale, Locale(identifier: "en")).environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view.frame(width: 1100, height: 540))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 540),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            try capture(host, name: "build-collapsed-" + (dark ? "dark" : "light"))
            // Use the shared tree's public accessibility actions, then wait for
            // visible children. A screenshot of collapsed rows is insufficient.
            for (branch, child) in [("Discovered Tests", "greetsByName"), ("Main", "Debug")] {
                let row = try #require(await element(in: host, containing: branch, role: .button))
                let expand = try #require(accessibilityElements(row).first {
                    $0.accessibilityRole?() == .button && $0.accessibilityLabel?() == "Expand"
                })
                try #require(expand.accessibilityPerformPress?() == true)
                try #require(await element(in: host, containing: child) != nil)
            }
            try capture(host, name: "build-discovery-debug-" + (dark ? "dark" : "light"))
        }
    }

    private func accessibilityElements(_ value: Any) -> [AnyObject] {
        let item = value as AnyObject
        return [item] + (item.accessibilityChildren?() ?? []).flatMap(accessibilityElements)
    }

    private func contains(_ item: AnyObject, text: String) -> Bool {
        let value: String? = item.accessibilityValue?()
        return (value ?? "").contains(text) || (item.accessibilityLabel?() ?? "").contains(text)
            || (item.accessibilityChildren?() ?? []).contains { contains($0 as AnyObject, text: text) }
    }

    private func element(in view: NSView, containing text: String, role: NSAccessibility.Role? = nil) async -> AnyObject? {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            view.layoutSubtreeIfNeeded()
            if let match = accessibilityElements(view).first(where: {
                (role == nil || $0.accessibilityRole?() == role) && contains($0, text: text)
            }) { return match }
            await Task.yield()
        } while clock.now < deadline
        return nil
    }
    private func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try nativeSRGBCapture(view)
        #expect(bitmap.pixelsWide == 2200 && bitmap.pixelsHigh == 1080)
        if let directory = ProcessInfo.processInfo.environment["LITHE_BUILD_CAPTURE_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}

@MainActor
private final class PresentationBuildTools: BuildToolResolving {
    func resolve(_ invocation: BuildInvocation, displayName: String, workspaceURL: URL,
                 checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck) async throws -> ResolvedBuildTool {
        ResolvedBuildTool(executableURL: URL(fileURLWithPath: "/fixture/bin/gradle"), environment: [:], executesProjectCode: false, version: "8.0")
    }
}

private struct PresentationBuildRunner: BuildCommandRunning {
    func run(_ request: BuildCommandRequest, onOutput: @escaping @Sendable (String) -> Void) async throws -> BuildCommandResult {
        Issue.record("A presentation fixture must never execute a command")
        throw CancellationError()
    }
}

@MainActor
private final class PresentationBuildProvider: BuildProviderRequesting {
    func prepareRun(_ request: BuildProviderRequest, on target: BuildProviderTarget, timeout: Duration,
                    progress: @escaping @MainActor @Sendable (BuildProviderProgress) -> Void) async throws -> ToolingJSONValue {
        Issue.record("A discovery presentation fixture must not prepare an application")
        throw CancellationError()
    }
    func execute(_ request: BuildProviderRequest, on target: BuildProviderTarget, timeout: Duration,
                 progress: @escaping @MainActor @Sendable (BuildProviderProgress) -> Void) async throws -> BuildProviderExecutionResult {
        Issue.record("A discovery presentation fixture must not execute a task")
        throw CancellationError()
    }
    func send(_ request: BuildProviderRequest, to target: BuildProviderTarget, timeout: Duration) async throws -> ToolingJSONValue {
        let json: String
        if request.method == "lithe/build/discoverTests" {
            json = #"{"format":"litheTestDiscovery","version":1,"tests":[{"suite":"DemoTest","case":"greetsByName","project":{"name":"demo","path":"."}},{"suite":"DemoTest","case":"keepsArguments","project":{"name":"demo","path":"."}}]}"#
        } else {
            json = #"{"format":"litheBuildModel","version":1,"projects":[{"id":"demo","name":"demo","path":"."}],"targets":[{"id":"main","projectID":"demo","name":"Main","path":"src/Main.java","tags":["application"]}]}"#
        }
        return try JSONDecoder().decode(ToolingJSONValue.self, from: Data(json.utf8))
    }
    func retainProviders(_ keep: (BuildProviderTarget) -> Bool) {}
}
