import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
@Suite("Agent brand icon resources")
struct AgentBrandIconResourceTests {
    @Test(arguments: ["Claude", "Codex"], [false, true])
    func composerBrandMarksStayVisibleInNativeMenus(name: String, isDark: Bool) throws {
        let host = NSHostingView(rootView: AgentComposerView(
            agents: [.init(id: "example-agent", name: name)],
            selectedAgent: .init(id: "example-agent", name: name),
            isResponding: false, isBlocked: false, onSend: { _, _ in }, onCancel: {},
            onSelectAgent: { _ in }, onOpenSettings: {}, onError: { _ in }
        ).environment(\.colorScheme, isDark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        // Crop the real native Menu label, excluding neighboring controls and
        // the text-field caret. No visible window or image baseline is required.
        let region = NSRect(x: 46, y: host.isFlipped ? host.bounds.height - 42 : 10, width: 28, height: 26)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: region))
        host.cacheDisplay(in: region, to: bitmap)
        var markPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let red = color.redComponent, green = color.greenComponent, blue = color.blueComponent
                if name == "Claude" {
                    if red > 0.5, red > green * 1.3, green > blue * 1.1 { markPixels += 1 }
                } else if abs(red - green) < 0.05, abs(green - blue) < 0.05 {
                    if isDark ? min(red, green, blue) > 0.6 : max(red, green, blue) < 0.4 { markPixels += 1 }
                }
            }
        }
        #expect(markPixels > 10, "The native selector must show a visible orange Claude or contrasting Codex mark")
        #expect(try #require(AgentBrandIconLoader.image(name: name, size: 18)).isTemplate,
                "Coloring the toolbar must not mutate the shared template used by other views")
    }

    @Test
    func installedAppLoadsBothMarksWithoutDevelopmentResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root)
        let resources = try #require(app.resourceURL)
        let packagedURL = resources.appendingPathComponent("Lithe_Lithe.bundle")
        try FileManager.default.createDirectory(at: packagedURL, withIntermediateDirectories: true)
        let source = try #require(AgentBrandIconLoader.resolveResourceBundle()?.resourceURL)
        try FileManager.default.copyItem(
            at: source.appendingPathComponent("AgentIcons"),
            to: packagedURL.appendingPathComponent("AgentIcons")
        )
        let before = try contents(at: resources)
        let bundle = try #require(AgentBrandIconLoader.resolveResourceBundle(mainBundle: app) {
            Issue.record("An installed app must not access the SwiftPM development fallback")
            return Bundle.main
        })
        #expect(bundle.bundleURL.standardizedFileURL == packagedURL.standardizedFileURL)
        for name in ["Codex", "Claude"] {
            let image = try #require(AgentBrandIconLoader.image(name: name, size: 16, resourceBundle: bundle))
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 16, height: 16))
        }
        // Reading icons must preserve the signed release/update baseline.
        #expect(try contents(at: resources) == before)
    }

    @Test
    func missingInstalledResourcesUseFallbackEvenAfterCacheIsWarm() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root)
        _ = try #require(AgentBrandIconLoader.image(name: "Codex"))
        let bundle = AgentBrandIconLoader.resolveResourceBundle(mainBundle: app) {
            Issue.record("Missing installed resources must not call the fatal SwiftPM accessor")
            return Bundle.main
        }
        #expect(bundle == nil)
        #expect(AgentBrandIconLoader.image(name: "Codex", resourceBundle: bundle) == nil)
        let emptyURL = try #require(app.resourceURL).appendingPathComponent("Empty.bundle")
        try FileManager.default.createDirectory(at: emptyURL, withIntermediateDirectories: true)
        let emptyBundle = try #require(Bundle(url: emptyURL))
        #expect(AgentBrandIconLoader.image(name: "Codex", resourceBundle: emptyBundle) == nil)
    }

    private func makeApp(at root: URL) throws -> Bundle {
        let appURL = root.appendingPathComponent("Fixture.app")
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true
        )
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "test.agent-icons", "CFBundlePackageType": "APPL"],
            format: .xml, options: 0
        )
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        return try #require(Bundle(url: appURL))
    }

    private func contents(at root: URL) throws -> [String: Data] {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        var result: [String: Data] = [:]
        for path in paths {
            let url = root.appendingPathComponent(path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            result[path] = values.isRegularFile == true ? try Data(contentsOf: url) : Data()
        }
        return result
    }
}
