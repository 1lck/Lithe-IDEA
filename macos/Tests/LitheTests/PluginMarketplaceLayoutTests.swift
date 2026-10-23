import AppKit
import LitheCoreContracts
import LitheModuleAPI
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Marketplace split bounds", .serialized)
struct PluginMarketplaceLayoutTests {
    @Test(arguments: ["en", "zh-Hans"], [ColorScheme.light, .dark])
    func marketplaceContentStaysOnItsSideDuringResizeAndDrag(language: String, scheme: ColorScheme) async throws {
        let service = MarketplaceLayoutService()
        let feature = PluginMarketplaceFeatureModel(service: service, pluginManager: MarketplaceLayoutManager())
        await feature.refreshIfNeeded()
        let domain = "lithe-marketplace-layout-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain); feature.endInstallationSession() }
        preferences.set(420.0, forKey: "lithe.settings.pluginMarketplaceListWidth")
        let host = NSHostingView(rootView: PluginMarketplaceView(feature: feature)
            .defaultAppStorage(preferences)
            .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        for (width, height) in [(1100.0, 700.0), (900, 500), (700, 700), (585, 700), (900, 900)] {
            window.setContentSize(NSSize(width: width, height: height))
            host.layoutSubtreeIfNeeded()
            if width == 585 { try Self.capture(host, name: "narrow-\(language)-\(scheme == .dark ? "dark" : "light")") }
            try await Self.checkBounds(host)
        }
        let handle = try #require(Self.descendants(host).compactMap { $0 as? SplitHandleInteractionView }.first)
        for distance in [-180.0, 240, -80] {
            let original = handle.convert(handle.bounds, to: host)
            let origin = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType, distance: CGFloat = 0) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: origin.x + distance, y: origin.y),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            }
            // Go through the product's native hit target and the window's drag
            // delivery, rather than invoking a layout callback directly.
            window.sendEvent(try event(.leftMouseDown))
            window.sendEvent(try event(.leftMouseDragged, distance: distance))
            window.sendEvent(try event(.leftMouseUp, distance: distance))
            try await Self.settle(host) { abs(handle.convert(handle.bounds, to: host).midX - original.midX) > 1 }
            try await Self.checkBounds(host)
            let moved = handle.convert(handle.bounds, to: host)
            // A late feature refresh must not move the divider after release.
            await feature.refreshAll()
            host.layoutSubtreeIfNeeded()
            #expect(abs(handle.convert(handle.bounds, to: host).midX - moved.midX) < 1)
            try await Self.checkBounds(host)
        }
        try Self.capture(host, name: "marketplace-\(language)-\(scheme == .dark ? "dark" : "light")")
    }

    private static func capture(_ host: NSView, name: String) throws {
        if let directory = ProcessInfo.processInfo.environment["LITHE_MARKETPLACE_LAYOUT_CAPTURES"] {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("\(name).png"))
        }
    }

    private static func checkBounds(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        let handle = try #require(descendants(host).compactMap { $0 as? SplitHandleInteractionView }.first)
        let divider = handle.convert(handle.bounds, to: host).midX
        let expected = (host.window?.contentView?.bounds.width ?? host.bounds.width)
        #expect(divider >= PluginManagementView.listMinimumWidth)
        #expect(divider < expected - PluginManagementView.detailMinimumWidth)
        let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
        let detail = try #require(scrolls.max { $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX })
        let viewport = detail.convert(detail.bounds, to: host)
        #expect(abs(viewport.minX - divider - SplitHandleView.thickness / 2) < 1)
        #expect(abs(viewport.maxX - host.bounds.maxX) < 1)
        let document = try #require(detail.documentView)
        let content = document.convert(document.bounds, to: host)
        for id in ["plugin-marketplace-name", "plugin-marketplace-install", "plugin-marketplace-description"] {
            let frame = try await AgentNativeControlTestSupport.frame(of: id, in: host)
            #expect(frame.minX >= divider, "\(id) crosses divider \(divider): \(frame)")
            #expect(frame.maxX <= content.maxX + 1, "\(id) overflows its scroll document: \(frame)")
            if id == "plugin-marketplace-name" {
                let top = host.isFlipped ? frame.minY - viewport.minY : viewport.maxY - frame.maxY
                #expect(top < 40, "Short plugin details must stay at the top: \(top)")
            }
        }
        for scroll in scrolls {
            let frame = scroll.convert(scroll.bounds, to: host)
            #expect(frame.minX >= -1 && frame.maxX <= host.bounds.maxX + 1)
        }
        // At 160pt the full source picker cannot fit. All content remains
        // reachable, with the native clip view still confined to the detail.
        if document.bounds.width > detail.contentView.bounds.width + 1 {
            detail.contentView.scroll(to: NSPoint(x: document.bounds.maxX - detail.contentView.bounds.width, y: 0))
            detail.reflectScrolledClipView(detail.contentView)
            #expect(abs(detail.contentView.documentVisibleRect.maxX - document.bounds.maxX) < 1)
            detail.contentView.scroll(to: .zero)
            detail.reflectScrolledClipView(detail.contentView)
        }
    }

    private static func settle(_ host: NSView, until predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            host.layoutSubtreeIfNeeded()
            if predicate() { return }
            await Task.yield()
        } while clock.now < deadline
        Issue.record("Marketplace split did not finish the native drag within two seconds")
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

@MainActor
private final class MarketplaceLayoutService: PluginMarketplaceServicing {
    let platform = "darwin-arm64"
    private let source = PluginMarketplaceSource(id: "layout-source", name: "Lithe Store",
        input: "https://github.com/example/plugins", indexURL: "https://example.invalid/index.json",
        repository: "https://github.com/example/plugins", isEnabled: true)
    private var index: PluginMarketplaceIndex {
        .init(plugins: [.init(id: "io.example.cargo", name: "Cargo", author: "Lithe Community",
            repository: "https://github.com/example/lithe-plugin-cargo", homepage: "https://example.invalid/cargo",
            description: "Cargo build integration with workspace and package tasks, release profiles, features and offline builds.",
            localizedDescriptions: ["zh-Hans": "Cargo 构建预发布插件：原生 workspace/包编译、检查、测试、清理及 binary/example 运行，支持 Release、Features 和 Offline。较新的版本需要支持对应能力的宿主。"],
            tags: ["build", "cargo", "rust", "testing"], license: "Apache-2.0", icon: nil,
            platforms: ["darwin-arm64", "darwin-x64"], latestVersion: "0.1.1", latestReleaseDate: "2026-10-22",
            availability: .available(.init(version: "0.1.0", pluginAPIVersion: 3, releaseDate: "2026-10-21",
                downloadURL: "https://example.invalid/plugin.zip", sha256: String(repeating: "a", count: 64))),
            versions: [.init(version: "0.1.0", pluginAPIVersion: 3, releaseDate: "2026-10-21", platforms: ["darwin-arm64", "darwin-x64"])])], rejected: [])
    }
    func loadSources() -> [PluginMarketplaceSource] {
        [source, .init(id: "other-layout-source", name: "Other Store", input: "https://github.com/example/other",
            indexURL: "https://example.invalid/other.json", repository: "https://github.com/example/other", isEnabled: true)]
    }
    func saveSources(_ sources: [PluginMarketplaceSource]) throws {}
    func resolveSource(_ input: String) throws -> PluginMarketplaceSourceResolution { throw PluginMarketplaceIconRejected() }
    func cachedIndex(for source: PluginMarketplaceSource) -> PluginMarketplaceIndexSnapshot? { .init(index: index, fetchedAt: nil) }
    func refreshIndex(for source: PluginMarketplaceSource) async throws -> PluginMarketplaceIndexSnapshot { .init(index: index, fetchedAt: nil) }
    func removeCache(for source: PluginMarketplaceSource) {}
    func iconData(from icon: String) async throws -> Data { throw PluginMarketplaceIconRejected() }
    func prepareInstall(entry: PluginMarketplaceEntry, download: PluginMarketplaceDownload, source: PluginMarketplaceSource,
                        approvedPrograms: [PluginProgram]?) async throws -> PreparedPluginPackage { throw PluginMarketplaceIconRejected() }
    func discard(_ prepared: PreparedPluginPackage) {}
    func prepareDiskInstall(at url: URL) async throws -> PreparedDiskPluginPackage { throw PluginMarketplaceIconRejected() }
    func discard(_ prepared: PreparedDiskPluginPackage) {}
}

@MainActor
private final class MarketplaceLayoutManager: PluginManaging {
    let snapshots: [PluginManagementSnapshot] = []
    let issues: [PluginManagementIssue] = []
    func setEnabled(_ enabled: Bool, for pluginID: PluginID) async throws {}
    func setSetting(_ value: ToolingJSONValue?, id settingID: String, for pluginID: PluginID) throws {}
    func installMarketplacePackage(at packageURL: URL, origin: PluginInstallationOrigin, provenance: PluginMarketplaceProvenance) throws {}
    func installDiskPackage(at packageURL: URL, provenance: PluginDiskProvenance) throws {}
    func installPackage(at packageURL: URL) throws {}
    func rollback(_ pluginID: PluginID) throws {}
    func uninstall(_ pluginID: PluginID) async throws {}
    func restore(_ pluginID: PluginID) throws {}
}
