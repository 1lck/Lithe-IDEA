import AppKit
import SwiftUI
import Foundation
import Testing
import LitheModuleAPI
import LitheCoreContracts
import LitheApplicationKernel
import LitheSearchModule
@testable import Lithe

@Suite("Plugin UI icons", .serialized)
@MainActor
struct PluginUIIconTests {
    private func manifest(icon: [String: Any]?) throws -> Data {
        let data = try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/hello-lithe.plugin.json"))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var ui = try #require(object["ui"] as? [String: Any])
        for key in ["toolWindows", "commands"] {
            var entries = try #require(ui[key] as? [[String: Any]])
            entries[0]["icon"] = icon
            ui[key] = entries
        }
        object["ui"] = ui
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func image(_ format: String, color: NSColor) throws -> Data {
        if format == "svg" {
            let hex = color == .red ? "#ff0000" : "#0000ff"
            return Data("<svg version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\"><rect width=\"16\" height=\"16\" fill=\"\(hex)\"/></svg>".utf8)
        }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(bitmap.bitmapData)
        for index in 0..<256 {
            pixels[index * 4] = color == .red ? 255 : 0
            pixels[index * 4 + 1] = 0
            pixels[index * 4 + 2] = color == .red ? 0 : 255
            pixels[index * 4 + 3] = 255
        }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func snapshot<V: View>(_ view: V, dark: Bool, size: CGSize = CGSize(width: 40, height: 40)) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    @Test(arguments: ["svg", "png"])
    func installedResourcesReachEveryContributionAndRemainReadOnly(format: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-icons-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("icons"), withIntermediateDirectories: true)
        let declaration = try manifest(icon: ["path": "icons/light." + format, "darkPath": "icons/dark." + format, "mode": "original"])
        try declaration.write(to: package.appendingPathComponent("plugin.json"))
        let light = try image(format, color: .red), dark = try image(format, color: .blue)
        try light.write(to: package.appendingPathComponent("icons/light." + format))
        try dark.write(to: package.appendingPathComponent("icons/dark." + format))
        let store = MacPluginPackageStore(rootURL: root.appendingPathComponent("installed"),
            validator: DeclarativePluginTestSupport.operations,
            verifier: MacOfficialPluginSignatureVerifier(allowsLocalDevelopmentPackages: true))
        let installed = try store.installPackage(from: package, origin: .localDevelopment)
        let startup = MacPluginStartupLoader.withHostUIValidation(packageStore: store).load(recoveryStore: nil)
        #expect(startup.issues.isEmpty)
        #expect(startup.registeredPlugins.count == 1)
        let contributions = installed.manifest.modules.flatMap(\.contributions)
        let registry = try WorkbenchModuleUIComposition.registry(for: ValidatedPluginCatalog(
            manifests: BuiltInPluginCatalog.manifests + startup.registeredManifests,
            hostVersion: BuiltInPluginCatalog.hostVersion), iconResources: startup.iconResources)
        #expect(Set(contributions.map(\.placement)) == [.rightSidebar, .toolbar, .menu, .commandPalette])
        for contribution in contributions {
            #expect(contribution.uiIcon?.mode == .original)
            #expect(startup.iconResources[contribution.id]?.light == light)
            #expect(startup.iconResources[contribution.id]?.dark == dark)
            #expect(registry.icon(for: contribution, role: .action) != nil)
        }
        #expect(try Data(contentsOf: installed.packageURL.appendingPathComponent("plugin.json")) == declaration)
        #expect(try Data(contentsOf: installed.packageURL.appendingPathComponent("icons/light." + format)) == light)
        #expect(try Data(contentsOf: installed.packageURL.appendingPathComponent("icons/dark." + format)) == dark)
    }

    @Test(arguments: ["svg", "png"])
    func renderedTemplateAndBrandIconsAdaptToThemesAndHostSize(format: String) throws {
        let resources = try PluginUIIconResources(light: image(format, color: .red), dark: image(format, color: .blue))
        for mode in [PluginUIIcon.Mode.template, .original] {
            let asset = WorkbenchContributionIcon.Asset(.init(path: "icon." + format, darkPath: "dark." + format, mode: mode), resources: resources)
            for dark in [false, true] {
                let view = WorkbenchContributionIcon(asset: asset, role: .action).foregroundStyle(Color(red: 0, green: 1, blue: 0))
                let bitmap = try snapshot(view, dark: dark)
                let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
                if mode == .template { #expect(center.greenComponent > 0.8 && center.redComponent < 0.1 && center.blueComponent < 0.1) }
                else if dark { #expect(center.blueComponent > 0.8 && center.redComponent < 0.1) }
                else { #expect(center.redComponent > 0.8 && center.blueComponent < 0.1) }
                // A 16pt host role must not stretch to the surrounding 40pt canvas.
                #expect(bitmap.colorAt(x: 2, y: 2)?.alphaComponent == 0)
                let output = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent(".artifacts/ui-contributions")
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: output
                    .appendingPathComponent("icon-\(format)-\(mode.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
        let fallback = WorkbenchContributionIcon.Asset(.init(path: "icon." + format), resources: .init(light: resources.light))
        #expect(fallback.image(isDark: true) === fallback.light)
        #expect(WorkbenchContributionIcon.Role.toolWindow.size == 20)
        #expect(WorkbenchContributionIcon.Role.action.size == 16)
        #expect(WorkbenchContributionIcon.Role.header.size == 13)
    }

    @Test(arguments: [PluginUIIcon.Mode.template, .original], [false, true])
    func railSelectionAndDisabledStateBelongToHost(mode: PluginUIIcon.Mode, dark: Bool) throws {
        let resources = try PluginUIIconResources(light: image("png", color: .red))
        let asset = WorkbenchContributionIcon.Asset(.init(path: "brand.png", mode: mode), resources: resources)
        func render(selected: Bool, enabled: Bool) throws -> NSColor {
            let bitmap = try snapshot(Button {} label: {
                WorkbenchContributionIcon(asset: asset, role: .toolWindow)
            }.buttonStyle(LitheActivityBarButtonStyle(isSelected: selected)).disabled(!enabled), dark: dark)
            return try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        }
        let normal = try render(selected: false, enabled: true)
        let selected = try render(selected: true, enabled: true)
        let disabled = try render(selected: false, enabled: false)
        if mode == .original {
            // Compare rendered colors, allowing the display's color profile.
            #expect(normal.redComponent > normal.greenComponent + 0.6)
            #expect(abs(normal.redComponent - selected.redComponent) < 0.01)
            #expect(abs(normal.greenComponent - selected.greenComponent) < 0.01)
        } else {
            #expect(abs(normal.greenComponent - selected.greenComponent) > 0.1)
        }
        #expect(disabled.alphaComponent < normal.alphaComponent * 0.6)
    }

    @Test(arguments: [PluginUIIcon.Mode.template, .original], [
        (false, false, false), (false, true, false), (true, false, false), (true, true, false),
        (false, false, true), (false, true, true), (true, false, true), (true, true, true)
    ])
    func menuHoverUsesSharedSelectionWithoutRecoloringBrands(mode: PluginUIIcon.Mode, state: (Bool, Bool, Bool)) async throws {
        let (dark, enabled, submenu) = state
        let resources = try PluginUIIconResources(light: image("png", color: .red))
        let asset = WorkbenchContributionIcon.Asset(.init(path: "brand.png", mode: mode), resources: resources)
        let presenter = LitheContextMenuPresenter()
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 40, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { presenter.dismiss(); parent.close() }
        let icon = AnyView(WorkbenchContributionIcon(asset: asset, role: .action))
        var item: LitheContextMenuItem = submenu
            ? .submenu("Plugin window", icon: icon) { LitheContextMenuItem.action("Child", action: {}) }
            : .action("Plugin command", icon: icon, action: {})
        item.isEnabled = enabled
        presenter.show(items: [item],
            at: NSPoint(x: 150, y: 200), appearance: NSAppearance(named: dark ? .darkAqua : .aqua), locale: Locale(identifier: "en_US"), parentWindow: parent)
        let panel = try #require(parent.childWindows?.first { $0 is NSPanel })
        let host = try #require(panel.contentView)
        host.layoutSubtreeIfNeeded()
        func color(x: CGFloat = 22) throws -> NSColor {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            return try #require(bitmap.colorAt(x: Int(x * scale), y: Int(18 * scale))?.usingColorSpace(.deviceRGB))
        }
        func distance(_ first: NSColor, _ second: NSColor) -> CGFloat {
            max(abs(first.redComponent - second.redComponent), abs(first.greenComponent - second.greenComponent),
                abs(first.blueComponent - second.blueComponent))
        }
        let initial = try color()
        let rootWidth = host.bounds.width
        let initialBackground = try color(x: rootWidth - 12)
        let point = NSPoint(x: 22, y: host.bounds.height - 18)
        panel.sendEvent(try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(1))
        var hovered = initial
        var hoveredBackground = initialBackground
        if !enabled {
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            #expect(distance(try color(x: rootWidth - 12), initialBackground) < 0.01,
                    "Disabled menu actions must not acquire a hover highlight")
            #expect(distance(try color(), initial) < 0.01)
            return
        }
        repeat {
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            hovered = try color()
            hoveredBackground = try color(x: rootWidth - 12)
            if distance(hoveredBackground, initialBackground) > 0.05 { break }
        } while clock.now < deadline
        #expect(distance(hoveredBackground, initialBackground) > 0.05,
                "The actual pointer event must highlight the shared menu row")
        if mode == .template { #expect(abs(hovered.greenComponent - initial.greenComponent) > 0.1) }
        else {
            #expect(hovered.redComponent > hovered.greenComponent + 0.6)
            #expect(abs(hovered.greenComponent - initial.greenComponent) < 0.01)
        }
    }

    @Test(arguments: [PluginUIIcon.Mode.template, .original], [false, true])
    func registeredWindowHeaderRendersTheDeclaredThemeVariant(mode: PluginUIIcon.Mode, dark: Bool) async throws {
        let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: manifest(icon: [
            "path": "light.png", "darkPath": "dark.png", "mode": mode.rawValue]))
        let declaration = try #require(descriptor.pluginManifest.modules.first)
        let windowContribution = try #require(declaration.contributions.first { $0.kind == .toolWindow })
        let resources = try PluginUIIconResources(light: image("png", color: .red), dark: image("png", color: .blue))
        let registry = try WorkbenchModuleUIComposition.registry(for: ValidatedPluginCatalog(
            manifests: BuiltInPluginCatalog.manifests + [descriptor.pluginManifest],
            hostVersion: BuiltInPluginCatalog.hostVersion), iconResources: [windowContribution.id: resources])
        let suite = "lithe-icon-header-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacUserDefaultsStore(defaults: defaults), settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { _ in
            let renderer = try #require(registry.renderer(for: windowContribution))
            let bitmap = try snapshot(renderer.content(model).environmentObject(model).environmentObject(settings),
                dark: dark, size: CGSize(width: 300, height: 150))
            let scale = CGFloat(bitmap.pixelsWide) / 300
            let center = try #require(bitmap.colorAt(x: Int(18.5 * scale), y: Int(15 * scale))?.usingColorSpace(.deviceRGB))
            if mode == .original {
                if dark { #expect(center.blueComponent > center.redComponent + 0.6) }
                else { #expect(center.redComponent > center.blueComponent + 0.6) }
            } else { #expect(abs(center.redComponent - center.blueComponent) < 0.15) }
        }
    }

    @Test(arguments: [PluginUIIcon.Mode.template, .original], [false, true])
    func mainToolbarKeepsBrandColorsAndAppliesDisabledOpacity(mode: PluginUIIcon.Mode, dark: Bool) throws {
        let resources = try PluginUIIconResources(light: image("svg", color: .red), dark: image("svg", color: .blue))
        let asset = WorkbenchContributionIcon.Asset(.init(path: "light.svg", darkPath: "dark.svg", mode: mode), resources: resources)
        func color(enabled: Bool, active: Bool = false) throws -> NSColor {
            let bitmap = try snapshot(Button {} label: { WorkbenchContributionIcon(asset: asset, role: .action) }
                .buttonStyle(LitheMainToolbarButtonStyle(isActive: active)).foregroundStyle(LitheTheme.primaryText).disabled(!enabled), dark: dark)
            return try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        }
        let normal = try color(enabled: true), disabled = try color(enabled: false)
        let active = try color(enabled: true, active: true)
        #expect(abs(normal.redComponent - active.redComponent) < 0.01)
        #expect(abs(normal.blueComponent - active.blueComponent) < 0.01)
        if mode == .original {
            if dark { #expect(normal.blueComponent > normal.redComponent + 0.6) }
            else { #expect(normal.redComponent > normal.blueComponent + 0.6) }
        } else { #expect(abs(normal.redComponent - normal.blueComponent) < 0.15) }
        #expect(disabled.alphaComponent < normal.alphaComponent * 0.4)
    }

    @Test(arguments: [PluginUIIcon.Mode.template, .original], [false, true])
    func commandPaletteUsesSelectedTintAndPreservesBrands(mode: PluginUIIcon.Mode, dark: Bool) async throws {
        let feature = SearchFeatureModel(operations: RustWorkspaceOperations(core: RustCoreBridge()))
        let session = SearchSessionFeatureModel()
        session.everywhereQuery = "/"
        session.isSearchEverywhereVisible = true
        let resources = try PluginUIIconResources(light: image("png", color: .red), dark: image("png", color: .blue))
        let asset = WorkbenchContributionIcon.Asset(.init(path: "light.png", darkPath: "dark.png", mode: mode), resources: resources)
        let actions = ["first", "second", "disabled"].map {
            LitheAction(id: $0, title: $0, subtitle: "", group: .window, isEnabled: $0 != "disabled", perform: {})
        }
        var executed: [String] = []
        let view = SearchEverywhereView(feature: feature, session: session, actionMatches: { _ in actions },
            search: { _, _ in }, dismiss: {}, openResult: { _ in }, performAction: { executed.append($0.id) }, revealInFinder: { _ in },
            copyPath: { _, _ in }, relativePath: { _ in "" }, moduleLabel: { _ in "" },
            actionIcon: { _ in AnyView(WorkbenchContributionIcon(asset: asset, role: .action)) })
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, dark ? .dark : .light).frame(width: 1000, height: 400)))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            session.isSearchEverywhereVisible = false
            host.rootView = AnyView(EmptyView())
            window.contentView = nil
            window.close()
        }
        var captured: NSBitmapImageRep?
        func colors() throws -> (NSColor, NSColor) {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            captured = bitmap
            let scale = CGFloat(bitmap.pixelsWide) / 1000
            func color(row: Int) throws -> NSColor {
                try #require(bitmap.colorAt(x: Int(88 * scale), y: Int((185 + CGFloat(row) * 24) * scale))?.usingColorSpace(.deviceRGB))
            }
            return try (color(row: 0), color(row: 1))
        }
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(2))
        var (first, second) = try colors()
        repeat {
            await Task.yield()
            (first, second) = try colors()
            if mode == .template ? first.redComponent > 0.9 : max(first.redComponent, first.blueComponent) > 0.9 { break }
        } while clock.now < deadline
        let output = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent(".artifacts/ui-contributions")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let snapshot = try #require(captured)
        try #require(snapshot.representation(using: .png, properties: [:])).write(to: output
            .appendingPathComponent("palette-\(mode.rawValue)-\(dark ? "dark" : "light").png"))
        if mode == .template { #expect(first.redComponent > second.redComponent + 0.1) }
        else if dark { #expect(first.blueComponent > first.redComponent + 0.6) }
        else { #expect(first.redComponent > first.blueComponent + 0.6) }
        NSApp.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)))
        let changedDeadline = clock.now.advanced(by: .seconds(2))
        repeat {
            await Task.yield()
            (first, second) = try colors()
            if mode == .original || second.redComponent > first.redComponent + 0.1 { break }
        } while clock.now < changedDeadline
        if mode == .template { #expect(second.redComponent > first.redComponent + 0.1) }
        else {
            #expect(abs(first.redComponent - second.redComponent) < 0.01)
            #expect(abs(first.blueComponent - second.blueComponent) < 0.01)
        }
        func key(_ code: UInt16) throws {
            NSApp.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)))
        }
        try key(125) // Select the disabled row after the enabled second row.
        try key(36)
        #expect(executed.isEmpty)
        let location = NSPoint(x: 140, y: 400 - (185 + 2 * 24))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        #expect(executed.isEmpty)
        try key(126)
        try key(36)
        #expect(executed == ["second"])
    }

    @Test(arguments: [PluginUIIcon.Mode.template, .original])
    func existingIconViewFollowsLiveAppearanceChanges(mode: PluginUIIcon.Mode) async throws {
        let resources = try PluginUIIconResources(light: image("svg", color: .red), dark: image("svg", color: .blue))
        let asset = WorkbenchContributionIcon.Asset(.init(path: "light.svg", darkPath: "dark.svg", mode: mode), resources: resources)
        let host = NSHostingView(rootView: WorkbenchContributionIcon(asset: asset, role: .action)
            .foregroundStyle(LitheTheme.toolWindowText).frame(width: 40, height: 40))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func color() throws -> NSColor {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        }
        let light = try color()
        for dark in [false, true, false] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(1))
            var rendered = try color()
            repeat {
                await Task.yield()
                rendered = try color()
                if mode == .original {
                    if dark ? rendered.blueComponent > 0.9 : rendered.redComponent > 0.9 { break }
                } else if dark ? rendered.redComponent > light.redComponent + 0.1 : abs(rendered.redComponent - light.redComponent) < 0.02 { break }
            } while clock.now < deadline
            if mode == .original {
                if dark { #expect(rendered.blueComponent > rendered.redComponent + 0.6) }
                else { #expect(rendered.redComponent > rendered.blueComponent + 0.6) }
            } else if dark { #expect(rendered.redComponent > light.redComponent + 0.1) }
            else { #expect(abs(rendered.redComponent - light.redComponent) < 0.02) }
        }
    }

    @Test(arguments: [PluginUIIcon.Mode.template, .original], [false, true])
    func hostIconsHonorDeclaredColorModeAndTheme(mode: PluginUIIcon.Mode, dark: Bool) throws {
        let asset = WorkbenchContributionIcon.Asset(.init(host: "run", mode: mode), resources: nil)
        let hasHostAsset = LitheIcons.ideaImage(resourcePath: asset.hostPath!) != nil
        if Bundle.main.bundleURL.pathExtension == "app" { #expect(hasHostAsset, "Packaged tests must resolve the real host asset") }
        let bitmap = try snapshot(WorkbenchContributionIcon(asset: asset, role: .action)
            .foregroundStyle(Color(red: 1, green: 0, blue: 1)), dark: dark)
        let original = try snapshot(LitheIDEAIcon(resourcePath: asset.hostPath!, size: WorkbenchContributionIcon.Role.action.size,
            preservesOriginalColors: true), dark: dark)
        var paintedPixels = 0
        var minimumTintMargin: CGFloat = 1, maximumOriginalDifference: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                paintedPixels += 1
                if mode == .template || !hasHostAsset {
                    minimumTintMargin = min(minimumTintMargin, min(color.redComponent, color.blueComponent) - color.greenComponent)
                } else {
                    let expected = try #require(original.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    maximumOriginalDifference = max(maximumOriginalDifference,
                        max(abs(color.redComponent - expected.redComponent),
                            max(abs(color.greenComponent - expected.greenComponent), abs(color.blueComponent - expected.blueComponent))))
                }
            }
        }
        #expect(paintedPixels > 0)
        // An unbundled Swift runner has no IDEAIcons resources. Its native
        // fallback remains themed; the packaged renderer checks original pixels.
        if mode == .template || !hasHostAsset { #expect(minimumTintMargin > 0.5) }
        else { #expect(maximumOriginalDifference < 0.02) }
    }

    @Test func hostCatalogAndMissingIconUseExistingAssets() throws {
        for (id, path) in WorkbenchContributionIcon.Asset.hostPaths {
            let source = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("macos/Resources/IDEAIcons/" + path)
            #expect(NSImage(contentsOf: source) != nil)
            let darkSource = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("macos/Resources/IDEAIcons/" + LitheIcons.darkIdeaAssetPath(for: path))
            if FileManager.default.fileExists(atPath: darkSource.path) { #expect(NSImage(contentsOf: darkSource) != nil) }
            #expect(WorkbenchContributionIcon.Asset(.init(host: id), resources: nil).hostPath == path)
            _ = try DeclarativePluginTestSupport.operations.validate(manifest: manifest(icon: ["host": id]))
        }
        let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: manifest(icon: nil))
        let registry = try WorkbenchModuleUIComposition.registry(for: ValidatedPluginCatalog(
            manifests: [descriptor.pluginManifest], hostVersion: BuiltInPluginCatalog.hostVersion))
        for contribution in descriptor.pluginManifest.modules.flatMap(\.contributions) {
            #expect((registry.icon(for: contribution, role: .action) != nil) == (contribution.kind == .toolWindow))
        }
    }

    @Test(arguments: ["missing", "script", "event", "external", "doctype", "large", "broken", "symlink", "directory-link", "dark-missing", "oversized-png", "wrong-format"])
    func unsafeOrInvalidPackageIconsAreRejectedBeforeInstall(kind: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-icon-invalid-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("source")
        let icons = package.appendingPathComponent("icons")
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        let usePNG = ["oversized-png", "wrong-format"].contains(kind)
        let path = "icons/mark." + (usePNG ? "png" : "svg")
        var icon: [String: Any] = ["path": path]
        if kind == "dark-missing" { icon["darkPath"] = "icons/missing.svg" }
        try manifest(icon: icon).write(to: package.appendingPathComponent("plugin.json"))
        var data = try image("svg", color: .red)
        switch kind {
        case "script": data = Data("<svg width=\"16\" height=\"16\"><script>alert(1)</script></svg>".utf8)
        case "event": data = Data("<svg width=\"16\" height=\"16\" onload=\"alert(1)\"/>".utf8)
        case "external": data = Data("<svg width=\"16\" height=\"16\"><image href=\"https://example.com/a.png\"/></svg>".utf8)
        case "doctype": data = Data("<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><svg width=\"16\" height=\"16\">&x;</svg>".utf8)
        case "large": data = Data(repeating: 65, count: 262_145)
        case "broken": data = Data("<svg".utf8)
        case "oversized-png":
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1025, pixelsHigh: 1,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
            data = try #require(bitmap.representation(using: .png, properties: [:]))
        default: break
        }
        if kind != "missing" { try data.write(to: package.appendingPathComponent(path)) }
        if kind == "symlink" {
            let target = root.appendingPathComponent("outside.svg")
            try data.write(to: target)
            try FileManager.default.removeItem(at: package.appendingPathComponent(path))
            try FileManager.default.createSymbolicLink(at: package.appendingPathComponent(path), withDestinationURL: target)
        } else if kind == "directory-link" {
            let target = root.appendingPathComponent("outside")
            try FileManager.default.moveItem(at: icons, to: target)
            try FileManager.default.createSymbolicLink(at: icons, withDestinationURL: target)
        }
        let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: Data(contentsOf: package.appendingPathComponent("plugin.json")))
        #expect(throws: MacPluginUIIconLoader.InvalidIcon.self) { try MacPluginUIIconLoader.load(descriptor, at: package) }
        let store = MacPluginPackageStore(rootURL: root.appendingPathComponent("installed"), validator: DeclarativePluginTestSupport.operations,
            verifier: MacOfficialPluginSignatureVerifier(allowsLocalDevelopmentPackages: true))
        #expect(throws: (any Error).self) { try store.installPackage(from: package, origin: .localDevelopment) }
        #expect(try store.scanInstalledPlugins().packages.isEmpty)
    }
}
