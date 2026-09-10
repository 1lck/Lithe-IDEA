import Foundation
import Sparkle
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

        let invalidReleaseDate = try JSONDecoder().decode(
            UpdateManifest.self,
            from: manifestData(releaseDate: "not-a-date")
        )
        #expect(throws: UpdateCheckError.invalidManifest) {
            try invalidReleaseDate.validated()
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

@Suite("macOS Sparkle update checker")
@MainActor
struct UpdateCheckerTests {
    @Test
    func requiresHTTPSFeedAndEd25519PublicKey() throws {
        let valid: [String: Any] = [
            "SUFeedURL": "https://example.com/appcast-arm64.xml",
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()
        ]
        try UpdateChecker.validateConfiguration(valid)
        for invalid: [String: Any] in [
            [:],
            ["SUFeedURL": "http://example.com/feed", "SUPublicEDKey": valid["SUPublicEDKey"]!],
            ["SUFeedURL": valid["SUFeedURL"]!, "SUPublicEDKey": "invalid"],
            ["SUFeedURL": valid["SUFeedURL"]!, "SUPublicEDKey": Data(repeating: 1, count: 31).base64EncodedString()]
        ] {
            #expect(throws: (any Error).self) {
                try UpdateChecker.validateConfiguration(invalid)
            }
        }
    }

    @Test
    func unconfiguredBuildProvidesReleaseFallbackWithoutStartingUpdater() async {
        let checker = UpdateChecker(bundle: Bundle(for: BundleMarker.self))
        await checker.checkForUpdates(manual: true)
        guard case .failed = checker.status, case .open(let url) = checker.notice?.action else {
            Issue.record("Unconfigured builds must offer the published release")
            return
        }
        #expect(url == UpdateChecker.releasePageURL)
        #expect(!checker.isBusy)
    }

    @Test
    func completedCyclesClearBusyStateAndSurfaceFailures() throws {
        let checker = UpdateChecker()
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        let updater = controller.updater
        var relaunches = 0
        var completedCycles = 0
        checker.willRelaunchForUpdate = { relaunches += 1 }
        checker.didFinishUpdateCycle = { completedCycles += 1 }
        checker.updaterWillRelaunchApplication(updater)
        #expect(relaunches == 1)
        try checker.updater(updater, mayPerform: .updates)
        #expect(checker.isChecking)
        checker.updater(updater, didFinishUpdateCycleFor: .updates,
            error: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.signatureError.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "Invalid update signature"]))
        #expect(checker.status == .failed(code: .installFailed, message: "Invalid update signature"))
        #expect(!checker.isBusy)
        checker.updater(updater, didFinishUpdateCycleFor: .updates,
            error: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue)))
        #expect(checker.status == .idle)
        checker.updater(updater, didFinishUpdateCycleFor: .updates,
            error: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
        #expect(checker.status == .upToDate(version: checker.currentVersion))
        #expect(completedCycles == 3)
    }

    private final class BundleMarker: NSObject {}
}

private func manifestData(
    schemaVersion: Int = 1,
    version: String = "0.3.1",
    releaseDate: String = "2026-01-02T00:00:00Z",
    releaseURL: String = "https://github.com/1lck/Lithe-IDEA/releases/tag/v0.3.1",
    armChecksum: String = String(repeating: "a", count: 64),
    armURL: String = "https://github.com/1lck/Lithe-IDEA/releases/download/v0.3.1/Lithe-0.3.1-arm64.dmg",
    intelURL: String = "https://github.com/1lck/Lithe-IDEA/releases/download/v0.3.1/Lithe-0.3.1-x86_64.dmg",
    includeIntel: Bool = true
) -> Data {
    let intelEntry = includeIntel
        ? #", "x86_64": {"url":"\#(intelURL)","sha256":"\#(String(repeating: "b", count: 64))"}"#
        : ""
    return Data(#"{"schemaVersion":\#(schemaVersion),"version":"\#(version)","releaseDate":"\#(releaseDate)","releaseNotes":"Bug fixes and improvements.","releaseURL":"\#(releaseURL)","assets":{"arm64":{"url":"\#(armURL)","sha256":"\#(armChecksum)"}\#(intelEntry)}}"#.utf8)
}
