import Foundation
import Testing
@testable import LitheGitModule

struct GitSettingsPresentationTests {
    @Test(arguments: [
        "https://user:FAKE_PASSWORD@example.com/team/repo.git?custom_secret=FAKE_TOKEN#FAKE_FRAGMENT",
        "http://user:FAKE_PASSWORD@example.com/team/repo.git?token=FAKE_TOKEN",
        "ssh://user:FAKE_PASSWORD@example.com:2222/team/repo.git?token=FAKE_TOKEN",
        "git://user:FAKE_PASSWORD@example.com/team/repo.git?token=FAKE_TOKEN",
        "git@example.com:team/repo.git?token=FAKE_TOKEN"
    ])
    func remoteCredentialsNeverReachEitherPresentationSurface(rawURL: String) throws {
        let presentation = try #require(GitRemoteURLPresentation(rawURL))
        for output in [presentation.displayURL, presentation.browserURL?.absoluteString].compactMap({ $0 }) {
            #expect(!output.contains("FAKE_"))
            let components = try #require(URLComponents(string: output))
            #expect(components.user == nil)
            #expect(components.password == nil)
            #expect(components.query == nil)
            #expect(components.fragment == nil)
            #expect(components.host == "example.com")
            #expect(components.path == "/team/repo.git")
        }
    }

    @Test
    func sshBrowserLinkUsesHTTPSWithoutTransportPort() throws {
        let presentation = try #require(GitRemoteURLPresentation("ssh://git@example.com:2222/team/repo.git"))
        #expect(presentation.displayURL == "ssh://example.com:2222/team/repo.git")
        #expect(presentation.browserURL?.absoluteString == "https://example.com/team/repo.git")
        let scp = try #require(GitRemoteURLPresentation("git@example.com:team/repo.git"))
        #expect(scp.browserURL?.absoluteString == "https://example.com/team/repo.git")
        #expect(GitRemoteURLPresentation("git://example.com/team/repo.git")?.browserURL == nil)
    }

    @Test(arguments: ["", "/fixture/repository", "file:///fixture/repository", "custom://user:FAKE_PASSWORD@example.com/repo", "https://", "https://example.com/\nFAKE_PASSWORD"])
    func unsupportedOrMalformedAddressesDoNotFallBackToRawText(rawURL: String) {
        #expect(GitRemoteURLPresentation(rawURL) == nil)
    }

    @Test
    func resetDefaultsAreIndependentOfRepositoryOverrides() {
        let defaults = GitFetchOptions(prune: true, submodules: .yes, tags: .all)
        let resolved = GitFetchOptions(prune: false, submodules: .no, tags: .none)
        let entries = [
            GitConfigurationEntry(key: "lithe.fetch.prune", value: "false", scope: "local", origin: "file:.git/config", effective: true),
            GitConfigurationEntry(key: "lithe.fetch.submodules", value: "no", scope: "local", origin: "file:.git/config", effective: true),
            GitConfigurationEntry(key: "lithe.fetch.tags", value: "none", scope: "local", origin: "file:.git/config", effective: true),
            GitConfigurationEntry(key: "fetch.recursesubmodules", value: "on-demand", scope: "global", origin: "file:fixture.gitconfig", effective: true)
        ]
        for (key, resetValue, currentValue) in [("lithe.fetch.prune", "true", "false"), ("lithe.fetch.submodules", "yes", "no"), ("lithe.fetch.tags", "all", "none")] {
            #expect(GitConfigurationFallback.value(for: key, fetchOptions: defaults, entries: entries) == resetValue)
            #expect(GitConfigurationFallback.value(for: key, fetchOptions: resolved, entries: entries) == currentValue)
        }
        // Only an explicit inherit policy follows Git's submodule setting.
        #expect(GitConfigurationFallback.value(for: "lithe.fetch.submodules", fetchOptions: GitFetchOptions(), entries: entries) == "on-demand")
        #expect(GitConfigurationFallback.value(for: "lithe.fetch.submodules", fetchOptions: GitFetchOptions(), entries: []) == "false")
        #expect(GitConfigurationFallback.value(for: "lithe.fetch.prune", fetchOptions: nil, entries: []) == nil)
    }
}
