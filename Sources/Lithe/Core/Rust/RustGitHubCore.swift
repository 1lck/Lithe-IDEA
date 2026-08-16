import Foundation
import LitheCoreContracts

struct RustGitHubCore: GitHubCorePlanning, Sendable {
    let bridge: RustCoreBridge

    func parseRemote(_ remoteURL: String) throws -> GitHubRepository {
        try bridge.githubParseRemote(remoteURL).get()
    }

    func requestPlan(_ request: GitHubRequest) throws -> GitHubRequestPlan {
        try bridge.githubRequestPlan(request).get()
    }

    func normalizeResponse(
        operation: String,
        status: Int,
        body: String
    ) throws -> GitHubNormalizedResponse {
        try bridge.githubNormalizeResponse(operation: operation, status: status, body: body).get()
    }
}
