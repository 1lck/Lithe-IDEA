import Foundation
import LitheModuleAPI
import Testing
@testable import Lithe

struct MacPluginPackageDownloaderTests {
    @Test
    func officialPHPArchiveURLUsesTheAppReleaseVersionAndChannel() throws {
        let configuration = MacPluginDistributionConfiguration(
            releaseBaseURL: URL(string: "https://downloads.example.test/releases")!,
            channel: .stable,
            architecture: "arm64",
            releaseVersion: PluginVersion(major: 0, minor: 5, patch: 8)
        )

        let url = try configuration.archiveURL(pluginID: OfficialPluginCatalog.phpPluginID)

        #expect(url.absoluteString == "https://downloads.example.test/releases/v0.5.8/Lithe-PHP-Support-0.5.8-arm64.zip")
    }

    @Test
    func previewPHPArchiveURLUsesTheRollingPreviewTag() throws {
        let configuration = MacPluginDistributionConfiguration(
            releaseBaseURL: URL(string: "https://downloads.example.test/releases")!,
            channel: .preview,
            architecture: "x86_64",
            releaseVersion: PluginVersion(major: 0, minor: 3, patch: 0)
        )

        let url = try configuration.archiveURL(pluginID: OfficialPluginCatalog.phpPluginID)

        #expect(url.absoluteString == "https://downloads.example.test/releases/preview-0.3.0/Lithe-PHP-Support-0.3.0-x86_64.zip")
    }

    @Test
    func unsupportedPluginCannotBeMappedToThePHPArchive() {
        let configuration = MacPluginDistributionConfiguration(architecture: "arm64")

        #expect(throws: MacPluginPackageDownloadError.unsupportedPlugin(PluginID("dev.example.plugin"))) {
            _ = try configuration.archiveURL(pluginID: PluginID("dev.example.plugin"))
        }
    }
}
