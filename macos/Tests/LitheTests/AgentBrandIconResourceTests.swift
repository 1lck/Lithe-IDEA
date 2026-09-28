import AppKit
import Testing
@testable import Lithe

@MainActor
@Suite("Agent brand icon resources")
struct AgentBrandIconResourceTests {
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
