import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("macOS GitHub HTTP transport")
struct MacGitHubHTTPTransportTests {
    @Test
    func preservesCoreEncodedComparePathWithoutDoubleEncoding() throws {
        let plan = GitHubRequestPlan(
            host: .api,
            method: "GET",
            path: "/repos/openai/codex/compare/release%2F2026.08...feature%2F%E4%B8%AD%E6%96%87",
            query: [:],
            body: nil,
            requiresAuthentication: true
        )

        let url = try MacGitHubHTTPTransport.requestURL(
            baseURL: #require(URL(string: "https://api.github.com")),
            plan: plan
        )

        #expect(
            url.absoluteString
                == "https://api.github.com/repos/openai/codex/compare/release%2F2026.08...feature%2F%E4%B8%AD%E6%96%87"
        )
        #expect(!url.absoluteString.contains("%252F"))
    }
}
