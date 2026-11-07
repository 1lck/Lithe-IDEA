import Foundation
import LitheRustCore
@testable import LitheGitModule

/// Runs a pure Core planner in the real linked Core, so lifecycle tests with
/// scripted Git I/O never mirror the shared Update or history-window rules.
enum GitCorePlanTestSupport {
    private struct Envelope<Payload: Encodable>: Encodable {
        let id = "plan"
        let command: String
        let payload: Payload
    }
    private struct Reply<Data: Decodable>: Decodable { let ok: Bool; let data: Data? }

    static func run<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        _ command: GitCorePlanCommand,
        _ payload: Request
    ) -> Response? {
        guard let data = try? JSONEncoder().encode(Envelope(command: command.rawValue, payload: payload)),
              let json = String(data: data, encoding: .utf8),
              let result = json.withCString({ lithe_bridge_execute_json($0) }) else { return nil }
        defer { lithe_bridge_free_string(result) }
        guard let reply = try? JSONDecoder().decode(Reply<Response>.self, from: Data(String(cString: result).utf8)),
              reply.ok else { return nil }
        return reply.data
    }
}
