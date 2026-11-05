import Foundation
import LitheRustCore
@testable import LitheGitModule

/// The module's lifecycle tests use the real linked reducer; scripted Git I/O
/// remains independent from the shared membership and scope rules.
enum GitChangelistCoreTestSupport {
    static func project(_ payload: GitChangelistCoreRequest) -> GitChangelistCoreProjection? {
        struct Request: Encodable { let command = "git.changelists"; let payload: GitChangelistCoreRequest }
        struct Response: Decodable { let ok: Bool; let data: GitChangelistCoreProjection? }
        guard let data = try? JSONEncoder().encode(Request(payload: payload)),
              let json = String(data: data, encoding: .utf8),
              let result = json.withCString({ lithe_bridge_execute_json($0) }) else { return nil }
        defer { lithe_bridge_free_string(result) }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: Data(String(cString: result).utf8)), decoded.ok else { return nil }
        return decoded.data
    }
}
