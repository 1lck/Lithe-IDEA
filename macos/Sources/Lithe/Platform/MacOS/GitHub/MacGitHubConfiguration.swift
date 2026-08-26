import Foundation

struct MacGitHubConfiguration: GitHubConfiguration, Sendable {
    let oauthClientID: String?

    init(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let bundleValue = bundle.object(forInfoDictionaryKey: "LitheGitHubOAuthClientID") as? String
        let environmentValue = environment["LITHE_GITHUB_CLIENT_ID"]
        oauthClientID = [environmentValue, bundleValue]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
