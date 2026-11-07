import Foundation
import LitheRustCore
import LitheGitModule

/// Runs `git.graphProjection` in the real linked Core, so graph tests assert Core's
/// answer and never mirror its layout rules.
package enum GitGraphCoreTestSupport {
    private struct Envelope: Encodable {
        let id = "graph"
        let command = "git.graphProjection"
        let payload: GitGraphProjectionRequest
    }
    private struct Reply: Decodable { let ok: Bool; let data: GitGraphProjectionResponse? }

    package static func response(_ request: GitGraphProjectionRequest) -> GitGraphProjectionResponse? {
        guard let data = try? JSONEncoder().encode(Envelope(payload: request)),
              let json = String(data: data, encoding: .utf8),
              let result = json.withCString({ lithe_bridge_execute_json($0) }) else { return nil }
        defer { lithe_bridge_free_string(result) }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(String(cString: result).utf8)),
              reply.ok else { return nil }
        return reply.data
    }

    /// The layout Core projects for one loaded window.
    package static func layout(
        commits: [GitCommit],
        references: [GitReference] = [],
        repositoryCommits: [GitCommit] = [],
        visibleHashes: Set<String>? = nil,
        options: GitGraphDisplayOptions = .compact,
        currentBranch: String? = nil
    ) -> GitGraphLayout {
        guard !commits.isEmpty else { return GitGraphLayout(rows: [], laneCount: 0, hasMissingParents: false) }
        let request = GitGraphLayoutService.request(
            commits: commits, references: references, repositoryCommits: repositoryCommits,
            visibleHashes: visibleHashes, options: options, currentBranch: currentBranch)
        guard let response = response(request),
              let layout = GitGraphLayoutService.layout(commits: commits, response: response)
        else { preconditionFailure("Core rejected the graph projection request") }
        return layout
    }
}
