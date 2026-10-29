import AppKit
import Foundation
import SwiftUI
import Testing
import LitheCoreContracts
import LitheModuleAPI
@testable import Lithe

@MainActor
@Suite("Java installation guidance presentation", .serialized)
struct PluginInstallationGuidancePresentationTests {
    @Test(arguments: [false, true])
    func missingJavaNotificationOffersAnExplicitMarketplaceAction(dark: Bool) async throws {
        let language = InterfaceLanguage.locale.identifier
        InterfaceLanguage.select("en")
        defer { InterfaceLanguage.select(language) }
        let feature = WorkbenchNotificationFeatureModel()
        feature.setApplicationActive(false)
        defer { feature.clear() }
        var searches: [String] = []
        feature.show("Java Support is installed separately. Install it from the Marketplace, or use Install from Disk for an offline package. Your Java settings are kept.",
                     arguments: [], action: WorkbenchNotification.Action(title: "Open Marketplace") { searches.append("Java Support") })
        let notification = try #require(feature.activeNotifications.first)
        let view = WorkbenchNotificationBanner(message: notification.message, occurrenceCount: 1,
            actionTitle: notification.action?.title, performAction: { feature.perform(notification.id) },
            dismiss: { feature.dismiss(notification.id) })
            .padding(20).frame(width: 400, height: 260, alignment: .top)
            .background(LitheTheme.editor)
        try await withHost(AnyView(view), size: NSSize(width: 400, height: 260), dark: dark) { host in
            let expand = try #require(await button("Expand notification", in: host))
            try #require(expand.accessibilityPerformPress?() == true)
            try #require(await button("Collapse notification", in: host) != nil)
            let action = try #require(await button("Open Marketplace", in: host))
            try capture(host, name: "java-missing-notification-" + (dark ? "dark" : "light"))
            #expect(searches.isEmpty)
            #expect(action.accessibilityPerformPress?() == true)
            #expect(searches == ["Java Support"])
            #expect(feature.activeNotifications.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func newProjectOffersJavaMavenAndSpringTemplatesWhenJavaIsMissing(dark: Bool) async throws {
        let language = InterfaceLanguage.locale.identifier
        InterfaceLanguage.select("en")
        defer { InterfaceLanguage.select(language) }
        let suite = "java-template-presentation-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let planner = RustProjectGeneratorOperations(core: RustCoreBridge())
        let service = ProjectGenerationService(planner: planner,
            platform: MacProjectGenerationPlatform(environment: { $0 }, executable: { _ in nil }, runner: GuidanceCommandRunner()),
            initializeGitRepository: { _ in nil }, recordJavaHome: { _, _ in })
        var searches: [String] = []
        let feature = NewProjectFeatureModel(environment: NewProjectEnvironment(
            sources: { [] }, iconResources: [:], javaRuntimes: { [] }, service: service,
            setPluginEnabled: { _ in Issue.record("A marketplace action must not enable a plugin") },
            openMarketplace: { searches.append($0) }, openProject: { _ in Issue.record("No project should be created") },
            store: MacUserDefaultsStore(defaults: defaults)))
        defer { feature.cancelCreation() }
        feature.location = "/fixture/projects"
        feature.reloadCatalog()
        #expect(feature.isJavaSupportMissing)
        try await withHost(AnyView(NewProjectView(feature: feature).defaultAppStorage(defaults)),
                           size: NSSize(width: 880, height: 660), dark: dark) { host in
            let action = try #require(await button("Install Java Support for Java, Maven and Spring templates…", in: host))
            try capture(host, name: "java-new-project-" + (dark ? "dark" : "light"))
            #expect(searches.isEmpty)
            #expect(action.accessibilityPerformPress?() == true)
            #expect(searches == ["Java Support"])
            #expect(!feature.isCreating)
        }
    }

    private func withHost(_ view: AnyView, size: NSSize, dark: Bool,
                          body: (NSView) async throws -> Void) async throws {
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = (application.accessibilityAttributeValue(attribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: attribute)
        defer { application.accessibilitySetValue(previous, forAttribute: attribute) }
        MacBundledFontRegistry.registerFonts()
        let host = NSHostingView(rootView: view.environment(\.locale, Locale(identifier: "en"))
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await body(host)
    }

    private func buttons(in value: Any) -> [AnyObject] {
        let item = value as AnyObject
        return (item.accessibilityRole?() == .button ? [item] : [])
            + (item.accessibilityChildren?() ?? []).flatMap { buttons(in: $0) }
    }

    private func button(_ title: String, in host: NSView) async -> AnyObject? {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            host.layoutSubtreeIfNeeded()
            if let result = buttons(in: host).first(where: { ($0.accessibilityLabel?() ?? $0.accessibilityTitle?()) == title }) {
                return result
            }
            await Task.yield()
        } while clock.now < deadline
        return nil
    }

    private func capture(_ host: NSView, name: String) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try nativeSRGBCapture(host)
        #expect(bitmap.pixelsWide == Int(host.bounds.width * 2))
        #expect(bitmap.pixelsHigh == Int(host.bounds.height * 2))
        if let directory = ProcessInfo.processInfo.environment["LITHE_JAVA_GUIDANCE_CAPTURE_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}

private struct GuidanceCommandRunner: BuildCommandRunning {
    func run(_ request: BuildCommandRequest, onOutput: @escaping @Sendable (String) -> Void) async throws -> BuildCommandResult {
        Issue.record("Installation guidance must not execute a tool")
        throw CancellationError()
    }
}
