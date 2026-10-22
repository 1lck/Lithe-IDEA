import Foundation
import Testing
@testable import Lithe

@Suite("Plugin repository sheet presentation")
struct PluginRepositoryPresentationTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let locale = Locale(identifier: "en_US")

    private func refreshedTime(secondsAgo: TimeInterval) -> String {
        PluginMarketplacePresentation.refreshedTime(
            Self.now.addingTimeInterval(-secondsAgo),
            now: Self.now,
            locale: Self.locale
        )
    }

    private static func source(
        id: String,
        input: String,
        indexURL: String
    ) -> PluginMarketplaceSource {
        PluginMarketplaceSource(
            id: id, name: "Example", input: input, indexURL: indexURL, repository: nil, isEnabled: true
        )
    }

    /// Lithe Store is listed by its GitHub repository, as the user would paste
    /// it, and the built-in source by its index path in the Lithe repository;
    /// neither shows the long raw.githubusercontent.com address.
    @Test
    func rowsShowWhatTheUserRecognizesInsteadOfTheRawIndexURL() {
        let official = Self.source(
            id: PluginMarketplaceSource.officialID,
            input: "https://raw.githubusercontent.com/Lithe-IDEA/Lithe-IDEA/HEAD/Plugins/marketplace/index.json",
            indexURL: "https://raw.githubusercontent.com/Lithe-IDEA/Lithe-IDEA/HEAD/Plugins/marketplace/index.json"
        )
        let store = Self.source(
            id: PluginMarketplaceSource.communityID,
            input: "https://github.com/Lithe-IDEA/Lithe-store",
            indexURL: PluginMarketplaceSource.communityIndexURL
        )
        let custom = Self.source(
            id: "source-custom",
            input: "https://plugins.example.dev/lithe-plugin-index.json",
            indexURL: "https://plugins.example.dev/lithe-plugin-index.json"
        )

        #expect(PluginMarketplacePresentation.sourceLocation(official) == "Plugins/marketplace/index.json")
        #expect(PluginMarketplacePresentation.sourceLocation(store) == "https://github.com/Lithe-IDEA/Lithe-store")
        #expect(PluginMarketplacePresentation.sourceLocation(custom) == "https://plugins.example.dev/lithe-plugin-index.json")
    }

    /// An official index that does not live on raw.githubusercontent.com has
    /// no repository path to cut out, so the row falls back to the address.
    @Test
    func officialSourceOnAnotherHostKeepsItsAddress() {
        let official = Self.source(
            id: PluginMarketplaceSource.officialID,
            input: "https://mirror.example.dev/lithe/index.json",
            indexURL: "https://mirror.example.dev/lithe/index.json"
        )

        #expect(PluginMarketplacePresentation.sourceLocation(official) == "https://mirror.example.dev/lithe/index.json")
    }

    /// The sheet shows "Refreshed just now" right after a refresh; a fetch time
    /// slightly ahead of the clock (the user moved it back) must not turn into
    /// "in 30 seconds".
    @Test
    func fetchUnderAMinuteOldReadsJustNow() {
        #expect(refreshedTime(secondsAgo: 0) == "just now")
        #expect(refreshedTime(secondsAgo: 59) == "just now")
        #expect(refreshedTime(secondsAgo: -30) == "just now")
    }

    @Test
    func fetchUnderAWeekOldReadsAsRelativePhrase() {
        #expect(refreshedTime(secondsAgo: 5 * 60) == "5 minutes ago")
        #expect(refreshedTime(secondsAgo: 3 * 60 * 60) == "3 hours ago")
        #expect(refreshedTime(secondsAgo: 2 * 24 * 60 * 60) == "2 days ago")
    }

    /// "3 weeks ago" would hide which day the index was fetched, so older
    /// fetches fall back to the date.
    @Test
    func fetchOlderThanAWeekReadsAsDate() {
        let fetchedAt = Self.now.addingTimeInterval(-8 * 24 * 60 * 60)
        let text = PluginMarketplacePresentation.refreshedTime(fetchedAt, now: Self.now, locale: Self.locale)

        #expect(!text.contains("ago"))
        #expect(text == fetchedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Self.locale)))
    }

    /// The built-in source and the preset Lithe Store carry the "Official"
    /// tag; a repository the user added, even another GitHub one, is
    /// "Community".
    @Test
    func litheRunSourcesAreTaggedOfficialAndOthersCommunity() {
        let official = Self.source(
            id: PluginMarketplaceSource.officialID,
            input: "https://raw.githubusercontent.com/Lithe-IDEA/Lithe-IDEA/HEAD/Plugins/marketplace/index.json",
            indexURL: "https://raw.githubusercontent.com/Lithe-IDEA/Lithe-IDEA/HEAD/Plugins/marketplace/index.json"
        )
        let store = Self.source(
            id: PluginMarketplaceSource.communityID,
            input: "https://github.com/Lithe-IDEA/Lithe-store",
            indexURL: PluginMarketplaceSource.communityIndexURL
        )
        let userAdded = Self.source(
            id: PluginMarketplaceSource.id(forIndexURL: "https://raw.githubusercontent.com/someone/plugins/HEAD/lithe-plugin-index.json"),
            input: "https://github.com/someone/plugins",
            indexURL: "https://raw.githubusercontent.com/someone/plugins/HEAD/lithe-plugin-index.json"
        )

        #expect(PluginMarketplacePresentation.isLitheRun(official))
        #expect(PluginMarketplacePresentation.isLitheRun(store))
        #expect(!PluginMarketplacePresentation.isLitheRun(userAdded))
    }

    /// Formatters are shared per locale; a second call, and a call in another
    /// locale between them, must still format in the locale asked for.
    @Test
    func sharedFormatterKeepsEachLocaleSeparate() {
        let fetchedAt = Self.now.addingTimeInterval(-5 * 60)
        let chinese = Locale(identifier: "zh_Hans")

        let first = PluginMarketplacePresentation.refreshedTime(fetchedAt, now: Self.now, locale: Self.locale)
        let other = PluginMarketplacePresentation.refreshedTime(fetchedAt, now: Self.now, locale: chinese)
        let again = PluginMarketplacePresentation.refreshedTime(fetchedAt, now: Self.now, locale: Self.locale)

        #expect(first == "5 minutes ago")
        #expect(again == first)
        #expect(other != first)
        #expect(other.contains("5"))
    }
}
