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

    @Test
    func inheritedTagBehaviorResolvesWhatGitWillFetch() {
        let entry = { (key: String, value: String) in
            GitConfigurationEntry(key: key, value: value, scope: "local", origin: "file:.git/config", effective: true)
        }
        let origin = [
            entry("remote.origin.url", "https://example.com/team/repo.git"),
            entry("remote.origin.tagopt", "--no-tags")
        ]
        // Inherit must not read as "follow Git's rules"; it reports the concrete
        // transfer that the configured remotes produce.
        #expect(GitConfigurationFallback.value(for: "lithe.fetch.tags", fetchOptions: GitFetchOptions(), entries: origin) == "none")
        #expect(GitConfigurationFallback.value(for: "lithe.fetch.tags", fetchOptions: GitFetchOptions(), entries: []) == "reachable")
        #expect(GitConfigurationFallback.value(for: "lithe.fetch.tags", fetchOptions: GitFetchOptions(tags: .all), entries: origin) == "all")

        let pruning = origin + [entry("fetch.prunetags", "true")]
        #expect(GitConfigurationFallback.value(for: "lithe.fetch.tags", fetchOptions: GitFetchOptions(), entries: pruning) == "prune")
        #expect(GitConfigurationFallback.value(for: "lithe.fetch.tags", fetchOptions: GitFetchOptions(prune: false), entries: pruning) == "all")

        let mixed = origin + [
            entry("remote.upstream.url", "https://example.com/team/upstream.git"),
            entry("remote.upstream.tagopt", "--tags")
        ]
        let behavior = GitConfigurationFallback.inheritedTagBehavior(remote: nil, prune: true, entries: mixed)
        #expect(behavior.value == "remoteDependent")
        let explicit = GitConfigurationFallback.inheritedTagBehavior(remote: "upstream", prune: true, entries: mixed)
        #expect(explicit.value == "all")
        #expect(explicit.source?.key == "remote.upstream.tagopt")

        // Fetch ignores skipFetchAll remotes when fetching all remotes, so
        // their tagOpt must not make the inherited value look remote-dependent.
        let skipped = mixed + [entry("remote.upstream.skipfetchall", "true")]
        #expect(GitConfigurationFallback.inheritedTagBehavior(remote: nil, prune: true, entries: skipped).value == "none")
        #expect(GitConfigurationFallback.inheritedTagBehavior(remote: "upstream", prune: true, entries: skipped).value == "all")
    }

    @Test(arguments: [true, false])
    func inheritedTagPolicyUsesNormalizedCoreBoolean(prune: Bool) {
        let entries = [
            GitConfigurationEntry(key: "fetch.prunetags", value: "true", scope: "global", origin: "file:fixture.gitconfig", effective: true),
            GitConfigurationEntry(key: "remote.origin.tagopt", value: "--no-tags", scope: "local", origin: "file:.git/config", effective: true)
        ]
        let behavior = GitConfigurationFallback.inheritedTagBehavior(remote: "origin", prune: prune, entries: entries)
        #expect(behavior.value == (prune ? "prune" : "all"))
        #expect(behavior.source?.key == "fetch.prunetags")
        #expect(behavior.source?.scope == "global")
    }

    @Test(arguments: ["false", "invalid"])
    func remoteTagBooleanTakesPrecedenceOverFetchDefault(value: String) {
        let entry = { (key: String, value: String) in
            GitConfigurationEntry(key: key, value: value, scope: "local", origin: "file:.git/config", effective: true)
        }
        let entries = [
            entry("fetch.prunetags", "true"),
            entry("remote.origin.url", "https://example.com/team/repo.git"),
            entry("remote.origin.prunetags", value),
            entry("remote.origin.tagopt", "--no-tags"),
            entry("remote.upstream.url", "https://example.com/team/upstream.git")
        ]
        let origin = GitConfigurationFallback.inheritedTagBehavior(remote: "origin", prune: true, entries: entries)
        #expect(origin.value == "none")
        #expect(origin.source?.key == "remote.origin.tagopt")
        #expect(GitConfigurationFallback.inheritedTagBehavior(remote: "upstream", prune: true, entries: entries).value == "prune")
        #expect(GitConfigurationFallback.inheritedTagBehavior(remote: nil, prune: true, entries: entries).value == "remoteDependent")
    }

    @Test(arguments: ["false", "invalid"])
    func disabledOrInvalidFetchTagBooleanFallsBackToReachableTags(value: String) {
        let entries = [
            GitConfigurationEntry(key: "fetch.prunetags", value: value, scope: "local", origin: "file:.git/config", effective: true)
        ]
        let behavior = GitConfigurationFallback.inheritedTagBehavior(remote: "origin", prune: true, entries: entries)
        #expect(behavior.value == "reachable")
        #expect(behavior.source == nil)
    }
}
