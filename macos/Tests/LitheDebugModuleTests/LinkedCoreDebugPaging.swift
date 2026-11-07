import Foundation
import LitheCoreContracts
import LitheRustCore

/// Runs variable and disassembly paging through the Rust Core linked into the
/// test bundle, so feature-model tests exercise the shared rules instead of a Swift copy.
struct LinkedCoreDebugPaging: DebugPagingCoreCommandExecuting {
    struct CallError: Error { let message: String }

    func executeDebugPagingCommand<Payload: Encodable, Response: Decodable>(
        _ command: String,
        payload: Payload
    ) throws -> Response {
        let json = String(decoding: try JSONEncoder().encode(DebugPagingLinkedRequest(command: command, payload: payload)), as: UTF8.self)
        guard let result = json.withCString({ lithe_bridge_execute_json($0) }) else {
            throw CallError(message: "Rust Core is not linked into the test bundle")
        }
        defer { lithe_bridge_free_string(result) }
        let envelope = try JSONDecoder().decode(DebugPagingLinkedEnvelope<Response>.self, from: Data(String(cString: result).utf8))
        guard envelope.ok, let data = envelope.data else {
            throw CallError(message: envelope.error?.message ?? "Rust Core returned no data")
        }
        return data
    }
}

private struct DebugPagingLinkedRequest<Body: Encodable>: Encodable {
    let command: String
    let payload: Body
}

private struct DebugPagingLinkedEnvelope<Body: Decodable>: Decodable {
    struct Failure: Decodable { let message: String }
    let ok: Bool
    let data: Body?
    let error: Failure?
}
