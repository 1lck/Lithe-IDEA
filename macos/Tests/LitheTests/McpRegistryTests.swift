import AppKit
import SwiftUI
import Testing
@testable import Lithe

@MainActor
struct McpRegistryTests {
    @Test func nativeDirectoryCardsReflowInLightAndDarkAppearances() throws {
        struct Payload: Encodable {}
        let root = DeclarativePluginTestSupport.repositoryRoot
        let page: McpRegistryPage = try RustCoreBridge().executeResult(command: "mcp.featuredRegistry", payload: Payload()).get()
        let directory = root.appendingPathComponent(".artifacts/mcp-discovery")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            var heights: [CGFloat] = []
            for width: CGFloat in [420, 780] {
                let view = McpRegistryCardsView(entries: page.entries, add: { _ in })
                    .padding(16).frame(width: width)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.locale, Locale(identifier: "zh-Hans"))
                    .background(LitheTheme.settingsSurface)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                #expect(abs(size.width - width) < 1)
                heights.append(size.height)
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("cards-\(dark ? "dark" : "light")-\(Int(width)).png"))
            }
            #expect(heights[0] > heights[1], "Narrow settings pages must stack the catalog cards.")
        }
    }

    @Test func landingCatalogDoesNotDependOnRegistryConnectivity() async throws {
        let registry = RegistryStub()
        registry.featuredEntries = try MacMcpRegistry(core: RustCoreBridge()).featured().entries
        registry.fail = true
        let feature = McpRegistryFeatureModel(registry: registry)
        #expect(feature.entries.count == 10)
        #expect(feature.entries.allSatisfy { $0.source == .featured && $0.draft != nil })
        await feature.search("  ")
        #expect(registry.requests.isEmpty)
        #expect(feature.entries.count == 10 && feature.error == nil)
        #expect(!feature.isLoading && feature.nextCursor == nil)
    }

    @Test func featuredMarksLoadOfflineAndPublicEntriesUseTheFallback() throws {
        let entries = try MacMcpRegistry(core: RustCoreBridge()).featured().entries
        for entry in entries {
            let image = try #require(McpBrandIconLoader.image(for: entry), "Missing bundled mark for \(entry.id)")
            #expect(!image.isTemplate)
            #expect(image.size == NSSize(width: 28, height: 28))
            var publicCopy = entry
            publicCopy.source = .registry
            #expect(McpBrandIconLoader.filename(for: publicCopy) == nil)
            #expect(McpBrandIconLoader.image(for: publicCopy) == nil)
            publicCopy.setup = .bearerToken
            #expect(McpServerDraft(entry: publicCopy)?.setup == nil)
        }
    }

    @Test func sharedSetupFixtureDecodesWithoutSelectingAgentsOrInventingInputs() throws {
        let path = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/fixtures/mcp/featured-setup-v1.json")
        let page = try JSONDecoder().decode(McpRegistryPage.self, from: Data(contentsOf: path))
        #expect(page.entries.map(\.setup) == [.bearerToken, .allowedDirectories])
        let token = try #require(McpServerDraft(entry: page.entries[0]))
        let folders = try #require(McpServerDraft(entry: page.entries[1]))
        #expect(token.headers == [McpKeyValue(key: "Authorization", value: "")])
        #expect(folders.arguments == ["-y", "@example/filesystem@1.2.3"])
        #expect(token.enabledAgents.isEmpty && folders.enabledAgents.isEmpty)
    }

    @Test func connectionFailureKeepsMatchesAndDirectRetryMustBeExplicit() async throws {
        let registry = RegistryStub()
        registry.featuredEntries = try MacMcpRegistry(core: RustCoreBridge()).featured().entries
        registry.failure = McpRegistryError.secureConnection
        let feature = McpRegistryFeatureModel(registry: registry)
        await feature.search("Context7")
        #expect(feature.entries.map(\.title) == ["Context7"])
        #expect(feature.error != nil && feature.canRetryDirectly)
        #expect(registry.routes == [.system])

        // The route changes only after a second explicit action, never on failure.
        registry.failure = nil
        registry.returnedEntries = []
        await feature.search("Context7", route: .direct)
        #expect(registry.routes == [.system, .direct])
        #expect(feature.error == nil && !feature.canRetryDirectly)
        #expect(feature.entries.map(\.title) == ["Context7"])
    }

    @Test func registryAndFeaturedEntriesShareOneConnectionCard() async throws {
        let registry = RegistryStub()
        let featured = try MacMcpRegistry(core: RustCoreBridge()).featured().entries
        registry.featuredEntries = featured
        registry.returnedEntries = [McpRegistryEntry(id: "io.example/context7", title: "Registry copy", summary: "", version: "", website: nil, draft: featured[0].draft)]
        let feature = McpRegistryFeatureModel(registry: registry)
        await feature.search("Context7")
        #expect(feature.entries.count == 1)
        #expect(feature.entries[0].source == .featured)
        #expect(feature.entries[0].publisher == "Upstash")
    }

    @Test func switchingRoutesDoesNotReuseAnotherRoutesPaginationCursor() async {
        let registry = RegistryStub()
        let feature = McpRegistryFeatureModel(registry: registry)
        await feature.search("docs")
        await feature.search("docs", loadMore: true, route: .direct)
        #expect(registry.routes == [.system, .direct])
        #expect(registry.requests[1].1 == nil)
        #expect(feature.entries.map(\.id) == ["one"])
    }

    @Test func coreRegistryFixtureProducesReviewableDrafts() throws {
        struct Payload: Encodable { let content: String }
        let url = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/contracts/mcp-registry-page.json")
        let page: McpRegistryPage = try RustCoreBridge().executeResult(command: "mcp.parseRegistry", payload: Payload(content: String(contentsOf: url, encoding: .utf8))).get()
        #expect(page.entries.count == 3)
        #expect(page.nextCursor == "opaque/+ cursor?")
        let draft = McpServerDraft(definition: try #require(page.entries[1].draft))
        #expect(draft.arguments == ["-y", "@example/browser@2.0.0"])
        #expect(draft.enabledAgents.isEmpty)
        #expect(draft.originalSources.isEmpty)
        #expect(page.entries[2].draft == nil)
    }

    @Test func paginationDeduplicatesAndStopsRepeatedCursors() async {
        let registry = RegistryStub()
        let feature = McpRegistryFeatureModel(registry: registry)
        await feature.search(" docs ")
        #expect(feature.entries.map(\.id) == ["one"])
        #expect(feature.nextCursor == "cursor")
        await feature.search("docs", loadMore: true)
        #expect(feature.entries.map(\.id) == ["one", "two"])
        #expect(feature.nextCursor == nil)
        #expect(registry.requests.map(\.0) == ["docs", "docs"])
        #expect(registry.requests[1].1 == "cursor")
        registry.fail = true
        await feature.search("other")
        #expect(feature.entries.isEmpty && feature.error != nil && !feature.isLoading)
    }

    @Test func cancelledSearchNeverPublishesItsResponse() async {
        let registry = RegistryStub()
        let feature = McpRegistryFeatureModel(registry: registry)
        let task = Task { await feature.search("cancelled") }
        task.cancel()
        await task.value
        #expect(feature.entries.isEmpty)
        #expect(feature.error == nil)
        #expect(!feature.isLoading)
    }

    @Test func anOlderResponseCannotReplaceANewerSearch() async {
        let registry = RegistryStub()
        let feature = McpRegistryFeatureModel(registry: registry)
        registry.beforeFirstResponse = { await feature.search("new") }
        await feature.search("old")
        #expect(feature.entries.map(\.id) == ["one"])
        #expect(registry.requests.map(\.0) == ["old", "new"])
        #expect(!feature.isLoading && feature.error == nil)
    }
}

@MainActor
private final class RegistryStub: McpRegistryProviding {
    var requests: [(String, String?)] = []
    var fail = false
    var failure: (any Error)?
    var featuredEntries: [McpRegistryEntry] = []
    var returnedEntries: [McpRegistryEntry]?
    var routes: [McpRegistryRoute] = []
    var beforeFirstResponse: (() async -> Void)?
    func featured() throws -> McpRegistryPage { McpRegistryPage(entries: featuredEntries, nextCursor: nil) }
    func search(query: String, cursor: String?, route: McpRegistryRoute) async throws -> McpRegistryPage {
        requests.append((query, cursor))
        routes.append(route)
        if let callback = beforeFirstResponse {
            beforeFirstResponse = nil
            await callback()
            return McpRegistryPage(entries: [McpRegistryEntry(id: "old", title: "old", summary: "", version: "1", website: nil, draft: nil)], nextCursor: nil)
        }
        if let failure { throw failure }
        if fail { throw URLError(.notConnectedToInternet) }
        let entries = returnedEntries ?? (cursor == nil ? ["one"] : ["one", "two"]).map {
            McpRegistryEntry(id: $0, title: $0, summary: "", version: "1", website: nil, draft: nil)
        }
        return McpRegistryPage(entries: entries, nextCursor: "cursor")
    }
}
