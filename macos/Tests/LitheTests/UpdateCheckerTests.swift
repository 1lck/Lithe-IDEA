import Foundation
import Testing
@testable import Lithe

@Suite("macOS update manifest")
struct UpdateManifestTests {
    @Test
    func productionUpdateEndpointUsesStaticHTTPSManifest() {
        #expect(UpdateEndpointConfiguration.production.manifestURL == UpdateEndpointConfiguration.productionManifestURL)
        #expect(UpdateEndpointConfiguration.production.manifestURL.scheme == "https")
        #expect(UpdateEndpointConfiguration.production.allowsLocalHTTP == false)
    }

    @Test
    func localUpdateModeAllowsOnlyLoopbackHTTPManifestAssets() throws {
        let localManifest = try JSONDecoder().decode(
            UpdateManifest.self,
            from: manifestData(
                armURL: "http://127.0.0.1:8765/Lithe-0.3.1-arm64.dmg",
                intelURL: "http://localhost:8765/Lithe-0.3.1-x86_64.dmg"
            )
        )

        #expect(throws: UpdateCheckError.invalidManifest) {
            try localManifest.validated()
        }
        #expect(throws: Never.self) {
            try localManifest.validated(allowingLocalHTTP: true)
        }
    }

    @Test
    func decodesAndSelectsArchitectureSpecificChecksumMetadata() throws {
        let manifest = try JSONDecoder().decode(
            UpdateManifest.self,
            from: manifestData(version: "0.3.1")
        ).validated()

        let armAsset = try manifest.asset(for: .arm64)
        let intelAsset = try manifest.asset(for: .x86_64)

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.version == "0.3.1")
        #expect(armAsset.url.lastPathComponent == "Lithe-0.3.1-arm64.dmg")
        #expect(armAsset.normalizedSHA256 == String(repeating: "a", count: 64))
        #expect(intelAsset.url.lastPathComponent == "Lithe-0.3.1-x86_64.dmg")
        #expect(intelAsset.normalizedSHA256 == String(repeating: "b", count: 64))
    }

    @Test
    func rejectsUnsupportedSchemaInvalidChecksumAndInsecureURL() throws {
        let unsupported = try JSONDecoder().decode(
            UpdateManifest.self,
            from: manifestData(schemaVersion: 2)
        )
        #expect(throws: UpdateCheckError.unsupportedSchema(2)) {
            try unsupported.validated()
        }

        let invalidChecksum = try JSONDecoder().decode(
            UpdateManifest.self,
            from: manifestData(armChecksum: "not-a-checksum")
        )
        #expect(throws: UpdateCheckError.invalidManifest) {
            try invalidChecksum.validated()
        }

        let insecure = try JSONDecoder().decode(
            UpdateManifest.self,
            from: manifestData(releaseURL: "http://example.com/releases/v0.3.1")
        )
        #expect(throws: UpdateCheckError.invalidManifest) {
            try insecure.validated()
        }

        let incompleteVersion = try JSONDecoder().decode(
            UpdateManifest.self,
            from: manifestData(version: "0.3")
        )
        #expect(throws: UpdateCheckError.invalidManifest) {
            try incompleteVersion.validated()
        }
    }

    @Test
    func reportsMissingCompatibleAssetSeparately() throws {
        let manifest = try JSONDecoder().decode(
            UpdateManifest.self,
            from: manifestData(includeIntel: false)
        ).validated()

        #expect(throws: UpdateCheckError.noCompatibleAsset) {
            try manifest.asset(for: .x86_64)
        }
    }

    @Test(arguments: [
        ("0.3.1", "0.3.0", true),
        ("0.3.0", "0.3.0", false),
        ("0.3", "0.3.0", false),
        ("1.0.0", "0.99.99", true),
        ("v0.4.0-preview", "0.3.9", true),
        ("invalid", "0.3.0", false)
    ])
    func comparesVersions(candidate: String, current: String, expected: Bool) {
        #expect(UpdateVersion.isNewer(candidate, than: current) == expected)
    }
}

@Suite("macOS update checker")
@MainActor
struct UpdateCheckerTests {
    @Test
    func fetchesStaticManifestAndRecordsOnlySuccessfulAutomaticCheck() async throws {
        let recorder = UpdateRequestRecorder()
        let transport = StubUpdateNetworkTransport(fetch: { request in
            await recorder.record(request)
            return UpdateHTTPResponse(statusCode: 200, headers: [:], body: manifestData())
        })
        let preferences = makePreferences()
        defer { clear(preferences) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let checker = UpdateChecker(
            currentVersion: "0.3.0",
            transport: transport,
            preferences: preferences,
            now: { now },
            architecture: .arm64
        )

        await checker.checkForUpdates()
        await checker.checkForUpdates()

        let requests = await recorder.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.absoluteString == "https://github.com/1lck/Lithe-IDEA/releases/latest/download/latest-macos.json")
        #expect(requests.first?.url?.host == "github.com")
        #expect(checker.status == .available(
            version: "0.3.1",
            url: URL(string: "https://github.com/1lck/Lithe-IDEA/releases/tag/v0.3.1")!
        ))
    }

    @Test
    func failedAutomaticCheckIsNotSuppressedForTwentyFourHours() async {
        let recorder = UpdateRequestRecorder()
        let transport = StubUpdateNetworkTransport(fetch: { request in
            await recorder.record(request)
            throw URLError(.notConnectedToInternet)
        })
        let preferences = makePreferences()
        defer { clear(preferences) }
        let checker = UpdateChecker(
            currentVersion: "0.3.0",
            transport: transport,
            preferences: preferences,
            architecture: .arm64
        )

        await checker.checkForUpdates()
        await checker.checkForUpdates()

        #expect(await recorder.requests.count == 2)
        guard case .failed(let message) = checker.status else {
            Issue.record("Expected a failed update status")
            return
        }
        #expect(message.contains("proxy"))
    }

    @Test(arguments: [
        FailureScenario(
            response: UpdateHTTPResponse(
                statusCode: 403,
                headers: ["X-RateLimit-Remaining": "0"],
                body: Data(#"{"message":"API rate limit exceeded"}"#.utf8)
            ),
            error: nil,
            expectedMessageFragment: "shared API limit"
        ),
        FailureScenario(
            response: UpdateHTTPResponse(statusCode: 503, headers: [:], body: Data()),
            error: nil,
            expectedMessageFragment: "HTTP 503"
        ),
        FailureScenario(
            response: nil,
            error: URLError(.serverCertificateUntrusted),
            expectedMessageFragment: "TLS inspection"
        ),
        FailureScenario(
            response: nil,
            error: UpdateTransportError.invalidResponse,
            expectedMessageFragment: "unexpected response"
        ),
        FailureScenario(
            response: UpdateHTTPResponse(statusCode: 200, headers: [:], body: Data("not json".utf8)),
            error: nil,
            expectedMessageFragment: "manifest is invalid"
        )
    ])
    func presentsActionableManualCheckFailures(scenario: FailureScenario) async {
        let transport = StubUpdateNetworkTransport(fetch: { _ in
            if let error = scenario.error { throw error }
            return scenario.response!
        })
        let preferences = makePreferences()
        defer { clear(preferences) }
        let checker = UpdateChecker(
            currentVersion: "0.3.0",
            transport: transport,
            preferences: preferences,
            architecture: .arm64
        )

        await checker.checkForUpdates(manual: true)

        #expect(checker.notice?.message.contains(scenario.expectedMessageFragment) == true)
        guard case .open(let url) = checker.notice?.action else {
            Issue.record("Expected the Release page fallback action")
            return
        }
        #expect(url.absoluteString == "https://github.com/1lck/Lithe-IDEA/releases/latest")
    }

    @Test
    func rejectsDownloadedAssetWhenManifestChecksumDoesNotMatch() async throws {
        let downloadedFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-update-test-\(UUID().uuidString).dmg")
        try Data("unexpected disk image".utf8).write(to: downloadedFile)
        defer { try? FileManager.default.removeItem(at: downloadedFile) }

        let transport = StubUpdateNetworkTransport(
            fetch: { _ in
                UpdateHTTPResponse(statusCode: 200, headers: [:], body: manifestData())
            },
            download: { request, progress in
                #expect(request.url?.lastPathComponent == "Lithe-0.3.1-arm64.dmg")
                await progress(UpdateDownloadProgress(downloadedBytes: 21, totalBytes: 21))
                return downloadedFile
            }
        )
        let preferences = makePreferences()
        defer { clear(preferences) }
        let checker = UpdateChecker(
            currentVersion: "0.3.0",
            transport: transport,
            preferences: preferences,
            architecture: .arm64
        )

        await checker.checkForUpdates(manual: true)
        await checker.installAvailableUpdate()

        #expect(checker.notice?.message.contains("SHA-256") == true)
        #expect(!FileManager.default.fileExists(atPath: downloadedFile.path))
    }

    private func makePreferences() -> UserDefaults {
        let suiteName = "lithe.update-tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    private func clear(_ preferences: UserDefaults) {
        for key in preferences.dictionaryRepresentation().keys {
            preferences.removeObject(forKey: key)
        }
    }
}

struct FailureScenario: Sendable, CustomTestStringConvertible {
    let response: UpdateHTTPResponse?
    let error: (any Error & Sendable)?
    let expectedMessageFragment: String

    var testDescription: String { expectedMessageFragment }
}

private final class StubUpdateNetworkTransport: UpdateNetworkTransport, @unchecked Sendable {
    private let fetchHandler: @Sendable (URLRequest) async throws -> UpdateHTTPResponse
    private let downloadHandler: @Sendable (
        URLRequest,
        @escaping @Sendable (UpdateDownloadProgress) async -> Void
    ) async throws -> URL

    init(
        fetch: @escaping @Sendable (URLRequest) async throws -> UpdateHTTPResponse,
        download: @escaping @Sendable (
            URLRequest,
            @escaping @Sendable (UpdateDownloadProgress) async -> Void
        ) async throws -> URL = { _, _ in throw UpdateCheckError.downloadFailed }
    ) {
        fetchHandler = fetch
        downloadHandler = download
    }

    func fetch(_ request: URLRequest) async throws -> UpdateHTTPResponse {
        try await fetchHandler(request)
    }

    func download(
        _ request: URLRequest,
        progress: @escaping @Sendable (UpdateDownloadProgress) async -> Void
    ) async throws -> URL {
        try await downloadHandler(request, progress)
    }
}

private actor UpdateRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}

private func manifestData(
    schemaVersion: Int = 1,
    version: String = "0.3.1",
    releaseURL: String = "https://github.com/1lck/Lithe-IDEA/releases/tag/v0.3.1",
    armChecksum: String = String(repeating: "a", count: 64),
    armURL: String = "https://github.com/1lck/Lithe-IDEA/releases/download/v0.3.1/Lithe-0.3.1-arm64.dmg",
    intelURL: String = "https://github.com/1lck/Lithe-IDEA/releases/download/v0.3.1/Lithe-0.3.1-x86_64.dmg",
    includeIntel: Bool = true
) -> Data {
    let intelEntry = includeIntel
        ? #", "x86_64": {"url":"\#(intelURL)","sha256":"\#(String(repeating: "b", count: 64))"}"#
        : ""
    return Data(#"{"schemaVersion":\#(schemaVersion),"version":"\#(version)","releaseURL":"\#(releaseURL)","assets":{"arm64":{"url":"\#(armURL)","sha256":"\#(armChecksum)"}\#(intelEntry)}}"#.utf8)
}
