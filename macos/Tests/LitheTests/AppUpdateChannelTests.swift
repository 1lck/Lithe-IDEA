import Foundation
import Sparkle
import Testing
@testable import Lithe

@MainActor
struct AppUpdateChannelTests {
    @Test
    func defaultAndInvalidPreferenceUseStableRegardlessOfInstalledIdentity() {
        withPreferences { preferences in
            #expect(AppUpdateChannel.saved(in: preferences) == .stable)
            preferences.set("preview", forKey: AppUpdateChannel.preferenceKey)
            #expect(AppUpdateChannel.saved(in: preferences) == .stable)
            for channel in ["preview", "autobuild"] {
                #expect(AppUpdateChannel.installed(info: ["LitheUpdateChannel": channel]) == .autobuild)
                #expect(UpdateBuildIdentity(info: ["LitheUpdateChannel": channel]).isPreview)
            }
            #expect(AppUpdateChannel.installed(info: ["LitheBuildGitBranch": "preview"]) == .stable)
        }
    }

    @Test
    func isolatedDevelopmentDefaultNeverOverridesAnExplicitChoice() {
        withPreferences { preferences in
            #expect(AppUpdateChannel.saved(in: preferences, defaultChannel: .autobuild) == .autobuild)
            preferences.set("stable", forKey: AppUpdateChannel.preferenceKey)
            #expect(AppUpdateChannel.saved(in: preferences, defaultChannel: .autobuild) == .stable)
            preferences.set("invalid", forKey: AppUpdateChannel.preferenceKey)
            #expect(AppUpdateChannel.saved(in: preferences, defaultChannel: .autobuild) == .stable)
        }
    }

    @Test
    func malformedPreferenceTypesNeverUseTheDevelopmentDefault() {
        withPreferences { preferences in
            let malformedValues: [Any] = [["bad": "value"], ["autobuild"], 1, true]
            for value in malformedValues {
                preferences.set(value, forKey: AppUpdateChannel.preferenceKey)
                #expect(AppUpdateChannel.saved(in: preferences) == .stable)
                #expect(AppUpdateChannel.saved(in: preferences, defaultChannel: .autobuild) == .stable)
            }
        }
    }

    @Test
    func rollingRequiresConsentAndPersistsAcrossCheckerReplacement() {
        withPreferences { preferences in
            let checker = UpdateChecker(preferences: preferences)
            #expect(!checker.selectChannel(.autobuild))
            #expect(checker.selectedChannel == .stable)
            #expect(preferences.string(forKey: AppUpdateChannel.preferenceKey) == nil)
            #expect(checker.selectChannel(.autobuild, acknowledgingRisk: true))
            #expect(UpdateChecker(preferences: preferences).selectedChannel == .autobuild)
            #expect(checker.selectChannel(.stable))
            #expect(UpdateChecker(preferences: preferences).selectedChannel == .stable)
        }
    }

    @Test
    func channelChangeClearsOldOfferAndCannotInterruptCheckingOrInstallation() throws {
        try withPreferences { preferences in
            let checker = UpdateChecker(preferences: preferences)
            let controller = SPUStandardUpdaterController(startingUpdater: false,
                updaterDelegate: nil, userDriverDelegate: nil)
            try checker.updater(controller.updater, mayPerform: .updates)
            #expect(!checker.selectChannel(.autobuild, acknowledgingRisk: true))
            checker.updater(controller.updater, didFinishUpdateCycleFor: .updates, error: nil)
            checker.receiveOffer(SUAppcastItem.empty())
            #expect(checker.updateInfo != nil)
            #expect(checker.selectChannel(.autobuild, acknowledgingRisk: true))
            #expect(checker.updateInfo == nil)
            #expect(checker.status == .idle)
            checker.installationWaitingForTermination(true)
            #expect(!checker.canChangeChannel)
            #expect(!checker.selectChannel(.stable))
        }
    }

    @Test
    func switchingToRollingOffersFullInstallerWithoutStartingSparkleOrClaimingFreshness() async {
        let name = "AppUpdateChannelTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        let checker = UpdateChecker(preferences: preferences)
        #expect(checker.selectChannel(.autobuild, acknowledgingRisk: true))
        await checker.checkForUpdates(manual: false)
        #expect(checker.notice == nil)
        await checker.checkForUpdates(manual: true)
        guard case .open(let url) = checker.notice?.action else {
            Issue.record("Switching channels must offer a full installer")
            return
        }
        #expect(url == AppUpdateChannel.autoBuildReleaseURL)
        #expect(checker.status == .idle)
        #expect(!checker.isBusy)
        let controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: nil, userDriverDelegate: nil)
        #expect(throws: (any Error).self) {
            try checker.updater(controller.updater, mayPerform: .updatesInBackground)
        }
    }

    @Test
    func feedsUseFixedTagAndCorrectArchitectureWithoutCrossingStableFeed() {
        let info: [String: Any] = ["SUFeedURL": "https://example.com/stable.xml"]
        #expect(AppUpdateChannel.stable.feedURL(info: info, architecture: "arm64") == "https://example.com/stable.xml")
        #expect(AppUpdateChannel.stable.feedURL(info: ["LitheUpdateChannel": "autobuild",
            "SUFeedURL": "https://example.com/rolling.xml"], architecture: "arm64") == nil)
        #expect(AppUpdateChannel.stable.feedURL(info: ["LitheUpdateChannel": "autobuild",
            "LitheStableFeedURL": "https://example.com/stable.xml"], architecture: "arm64") == "https://example.com/stable.xml")
        for architecture in ["arm64", "x86_64"] {
            #expect(AppUpdateChannel.autobuild.feedURL(info: info, architecture: architecture)
                == "https://github.com/1lck/Lithe-IDEA/releases/download/AutoBuild/appcast-preview-\(architecture).xml")
        }
    }

    @Test
    func sharedChannelSelectionContract() throws {
        struct Fixture: Decodable {
            struct Route: Decodable { let installed: AppUpdateChannel; let selected: AppUpdateChannel; let fullInstallation: Bool }
            let defaultChannel: AppUpdateChannel
            let developmentDefaultChannel: AppUpdateChannel
            let rollingReleaseURL: URL
            let cases: [Route]
            let invalidPreferences: [String?]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            root.appendingPathComponent("shared/fixtures/updates/channel-selection-v1.json")))
        #expect(fixture.defaultChannel == .stable)
        #expect(fixture.developmentDefaultChannel == .autobuild)
        #expect(fixture.rollingReleaseURL == AppUpdateChannel.autoBuildReleaseURL)
        for route in fixture.cases {
            #expect(route.selected.requiresFullInstallation(from: route.installed) == route.fullInstallation)
        }
        withPreferences { preferences in
            for value in fixture.invalidPreferences {
                preferences.set(value, forKey: AppUpdateChannel.preferenceKey)
                #expect(AppUpdateChannel.saved(in: preferences) == fixture.defaultChannel)
            }
        }
    }

    @Test
    func rollingBuildTimeUsesSharedStrictUTCFormat() throws {
        struct Fixture: Decodable {
            struct Sample: Decodable { let timestamp: String; let build: String; let display: String }
            let cases: [Sample]
            let invalidTimestamps: [String]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            root.appendingPathComponent("shared/fixtures/updates/build-time-v1.json")))
        for sample in fixture.cases {
            #expect(AutoBuildTimestamp.display(timestamp: sample.timestamp) == sample.display)
            #expect(AutoBuildTimestamp.display(build: sample.build) == sample.display)
            #expect(AutoBuildTimestamp.label(timestamp: sample.timestamp).contains(sample.display))
            let identity = UpdateBuildIdentity(info: ["LitheUpdateChannel": "autobuild",
                "CFBundleVersion": sample.build, "LitheBuildTimestamp": sample.timestamp])
            #expect(identity.updateInfo(version: "0.3.0", targetVersion: "0.3.0", targetBuild: sample.build,
                date: nil, notes: nil).currentBuildDate == sample.timestamp)
        }
        for invalid in fixture.invalidTimestamps {
            #expect(AutoBuildTimestamp.display(timestamp: invalid) == nil)
        }
        #expect(AutoBuildTimestamp.label(build: "58.1") == "AutoBuild")
        #expect(AutoBuildTimestamp.display(build: "20260229.120000") == nil)
        #expect(AutoBuildTimestamp.display(build: "20261015.240000") == nil)
    }

    private func withPreferences(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "AppUpdateChannelTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        try body(preferences)
    }
}
