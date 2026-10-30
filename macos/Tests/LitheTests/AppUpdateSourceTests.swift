import Foundation
import Testing
@testable import Lithe

@Suite("App update source")
struct AppUpdateSourceTests {
    private let defaultFeed = URL(string: "https://github.com/1lck/Lithe-IDEA/releases/latest/download/appcast-arm64.xml")!

    @Test(arguments: [
        ("https://mirror.example.com/lithe", "https://mirror.example.com/lithe/"),
        ("  https://mirror.example.com/lithe/  ", "https://mirror.example.com/lithe/"),
        ("https://mirror.example.com/lithe/appcast-arm64.xml", "https://mirror.example.com/lithe/"),
        ("HTTPS://mirror.example.com", "https://mirror.example.com/"),
        ("http://127.0.0.1:8080/feed", "http://127.0.0.1:8080/feed/"),
        ("http://localhost/feed/", "http://localhost/feed/")
    ])
    func normalizesTypedSourcesToAFolder(input: String, expected: String) throws {
        #expect(try AppUpdateSource.parseBase(input).get().absoluteString == expected)
    }

    @Test(arguments: [
        ("http://mirror.example.com/lithe/", AppUpdateSource.InputError.insecure),
        ("mirror.example.com/lithe", .invalid),
        ("ftp://mirror.example.com/", .invalid),
        ("https://user:secret@mirror.example.com/", .invalid),
        ("https://mirror.example.com/?token=1", .invalid),
        ("https://mirror.example.com/#top", .invalid),
        ("", .invalid)
    ])
    func rejectsUnsafeOrIncompleteSources(input: String, expected: AppUpdateSource.InputError) {
        guard case .failure(let error) = AppUpdateSource.parseBase(input) else {
            Issue.record("accepted \(input)")
            return
        }
        #expect(error == expected)
    }

    @Test
    func defaultSourceKeepsTheOfficialFeedAndDownloads() {
        let source = AppUpdateSource(defaultFeed: defaultFeed, customBase: nil)
        let archive = URL(string: "https://github.com/1lck/Lithe-IDEA/releases/download/v1.2.0/Lithe-1.2.0-arm64.zip")!
        #expect(!source.isCustom)
        #expect(source.feedURL == defaultFeed)
        #expect(source.baseURL.absoluteString == "https://github.com/1lck/Lithe-IDEA/releases/latest/download/")
        #expect(source.downloadURL(for: archive) == archive)
    }

    @Test
    func customSourceServesFeedAndArchivesFromItsFolder() {
        let source = AppUpdateSource(defaultFeed: defaultFeed, customBase: URL(string: "https://mirror.example.com/lithe/")!)
        let archive = URL(string: "https://github.com/1lck/Lithe-IDEA/releases/download/v1.2.0/Lithe-1.2.0-arm64.zip")!
        #expect(source.isCustom)
        #expect(source.host == "mirror.example.com")
        #expect(source.feedURL.absoluteString == "https://mirror.example.com/lithe/appcast-arm64.xml")
        #expect(source.downloadURL(for: archive).absoluteString == "https://mirror.example.com/lithe/Lithe-1.2.0-arm64.zip")
    }

    @Test
    func savedValueEqualToTheDefaultOrUnusableMeansDefault() throws {
        let suite = "AppUpdateSourceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AppUpdateSource.saved(in: defaults, defaultFeed: defaultFeed).customBase == nil)
        defaults.set("https://github.com/1lck/Lithe-IDEA/releases/latest/download", forKey: AppUpdateSource.preferenceKey)
        #expect(AppUpdateSource.saved(in: defaults, defaultFeed: defaultFeed).customBase == nil)
        defaults.set("http://mirror.example.com/", forKey: AppUpdateSource.preferenceKey)
        #expect(AppUpdateSource.saved(in: defaults, defaultFeed: defaultFeed).customBase == nil)
        defaults.set("https://mirror.example.com/lithe", forKey: AppUpdateSource.preferenceKey)
        #expect(AppUpdateSource.saved(in: defaults, defaultFeed: defaultFeed).customBase?.absoluteString
            == "https://mirror.example.com/lithe/")
    }

    @Test
    func appcastParserPicksTheNewestFullArchiveAndIgnoresDeltas() throws {
        let item = try #require(AppcastLatestItem.parse(Data(Self.appcast.utf8)))
        #expect(item.version == "1.10.0")
        #expect(item.build == "110")
        #expect(item.archive.lastPathComponent == "Lithe-1.10.0.zip")
    }

    @Test
    func nonAppcastDocumentsAreNotParsed() {
        #expect(AppcastLatestItem.parse(Data("<html><body>Not found</body></html>".utf8)) == nil)
        #expect(AppcastLatestItem.parse(Data("not xml".utf8)) == nil)
    }

    @Test
    func mirrorFailuresNameTheMirrorHost() {
        #expect(UpdateDownloadFailure.httpStatus(503).message(host: "mirror.example.com").contains("mirror.example.com"))
        #expect(UpdateDownloadFailure.httpStatus(503).message(host: "mirror.example.com").contains("503"))
        #expect(UpdateDownloadFailure.timedOut.message(host: "mirror.example.com").contains("mirror.example.com"))
        #expect(UpdateDownloadFailure.timedOut.message(host: nil) == UpdateDownloadFailure.timedOut.checkError.userMessage)
    }

    @Test
    func probeReportsTheNewestVersionWhenTheArchiveIsPresent() async {
        let session = ProbeStub.session { request in
            switch request.url?.lastPathComponent {
            case "appcast-arm64.xml": (200, Self.appcast)
            case "Lithe-1.10.0.zip" where request.httpMethod == "HEAD": (200, "")
            default: (404, "")
            }
        }
        let source = AppUpdateSource(defaultFeed: defaultFeed, customBase: URL(string: "https://mirror.example.com/lithe/")!)
        #expect(await UpdateSourceProbe.run(source, session: session) == .reachable(version: "1.10.0"))
    }

    @Test
    func probeExplainsAMissingFeedOrArchive() async {
        let source = AppUpdateSource(defaultFeed: defaultFeed, customBase: URL(string: "https://mirror.example.com/lithe/")!)
        let missingArchive = ProbeStub.session { request in
            request.url?.lastPathComponent == "appcast-arm64.xml" ? (200, Self.appcast) : (404, "")
        }
        guard case .failed(let archiveMessage) = await UpdateSourceProbe.run(source, session: missingArchive) else {
            Issue.record("missing archive was accepted")
            return
        }
        #expect(archiveMessage.contains("Lithe-1.10.0.zip"))

        let notAFeed = ProbeStub.session { _ in (200, "<html></html>") }
        guard case .failed(let feedMessage) = await UpdateSourceProbe.run(source, session: notAFeed) else {
            Issue.record("non-appcast page was accepted")
            return
        }
        #expect(feedMessage.contains("appcast-arm64.xml"))
    }

    private static let appcast = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item>
          <title>1.9.0</title>
          <sparkle:version>90</sparkle:version>
          <sparkle:shortVersionString>1.9.0</sparkle:shortVersionString>
          <enclosure url="https://github.com/1lck/Lithe-IDEA/releases/download/v1.9.0/Lithe-1.9.0.zip" length="1" type="application/octet-stream" sparkle:edSignature="x"/>
        </item>
        <item>
          <title>1.10.0</title>
          <sparkle:version>110</sparkle:version>
          <sparkle:shortVersionString>1.10.0</sparkle:shortVersionString>
          <sparkle:deltas>
            <enclosure url="https://github.com/1lck/Lithe-IDEA/releases/download/v1.10.0/Lithe110-90.delta" sparkle:deltaFrom="90" length="1" type="application/octet-stream" sparkle:edSignature="y"/>
          </sparkle:deltas>
          <enclosure url="https://github.com/1lck/Lithe-IDEA/releases/download/v1.10.0/Lithe-1.10.0.zip" length="1" type="application/octet-stream" sparkle:edSignature="z"/>
        </item>
      </channel>
    </rss>
    """
}

/// Answers probe requests from a closure instead of the network.
private final class ProbeStub: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (Int, String)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func session(_ handler: @escaping Handler) -> URLSession {
        let id = UUID().uuidString
        lock.withLock { handlers[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeStub.self]
        configuration.httpAdditionalHeaders = ["X-Probe-Stub": id]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Probe-Stub") ?? ""
        guard let handler = Self.lock.withLock({ Self.handlers[id] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Update source in the update checker", .serialized)
@MainActor
struct UpdateCheckerSourceTests {
    @Test
    func stableBuildUsesAndClearsTheSavedMirror() throws {
        let fixture = try CheckerFixture(channel: "stable")
        defer { fixture.cleanUp() }
        fixture.defaults.set("https://mirror.example.com/lithe/", forKey: AppUpdateSource.preferenceKey)
        let checker = fixture.makeChecker()
        #expect(checker.canCustomizeUpdateSource)
        #expect(checker.effectiveUpdateSource?.feedURL.absoluteString
            == "https://mirror.example.com/lithe/\(CheckerFixture.feedName)")

        #expect(checker.applyUpdateSource(nil))
        #expect(fixture.defaults.string(forKey: AppUpdateSource.preferenceKey) == nil)
        #expect(checker.effectiveUpdateSource?.isCustom == false)

        #expect(checker.applyUpdateSource(URL(string: "https://other.example.com/")!))
        #expect(fixture.defaults.string(forKey: AppUpdateSource.preferenceKey) == "https://other.example.com/")
        #expect(checker.customUpdateSourceBase?.absoluteString == "https://other.example.com/")
    }

    @Test
    func autoBuildIgnoresAndCannotChangeTheMirror() throws {
        let fixture = try CheckerFixture(channel: "autobuild")
        defer { fixture.cleanUp() }
        fixture.defaults.set("https://mirror.example.com/lithe/", forKey: AppUpdateSource.preferenceKey)
        let checker = fixture.makeChecker()
        #expect(!checker.canCustomizeUpdateSource)
        #expect(checker.effectiveUpdateSource?.isCustom == false)
        #expect(!checker.applyUpdateSource(URL(string: "https://other.example.com/")!))
        #expect(fixture.defaults.string(forKey: AppUpdateSource.preferenceKey) == "https://mirror.example.com/lithe/")
    }

    @Test
    func choosingAutoBuildOnAStableBuildFallsBackToTheOfficialSource() throws {
        let fixture = try CheckerFixture(channel: "stable")
        defer { fixture.cleanUp() }
        fixture.defaults.set("https://mirror.example.com/lithe/", forKey: AppUpdateSource.preferenceKey)
        fixture.defaults.set(AppUpdateChannel.autobuild.rawValue, forKey: AppUpdateChannel.preferenceKey)
        let checker = fixture.makeChecker()
        #expect(!checker.canCustomizeUpdateSource)
        #expect(checker.effectiveUpdateSource?.isCustom == false)
    }
}

/// A throwaway bundle with the stable feed keys and private preferences.
private struct CheckerFixture {
    static let feedName = "appcast-arm64.xml"
    let directory: URL
    let suite: String
    let defaults: UserDefaults

    init(channel: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateCheckerSourceTests-\(UUID().uuidString).bundle", isDirectory: true)
        let contents = directory.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "app.lithe.tests.update-source",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "100",
            "LitheUpdateChannel": channel,
            "LitheStableFeedURL": "https://github.com/1lck/Lithe-IDEA/releases/latest/download/\(Self.feedName)",
            "LitheAutoBuildFeedURL": "https://github.com/1lck/Lithe-IDEA/releases/download/AutoBuild/\(Self.feedName)"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        suite = "UpdateCheckerSourceTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    @MainActor
    func makeChecker() -> UpdateChecker {
        UpdateChecker(bundle: Bundle(url: directory)!, preferences: defaults, diagnosticSink: { _ in })
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
