import Foundation
import LitheCoreContracts
import LitheRustCore

/// Runs the test-run verdict through the Rust Core linked into the test
/// bundle, so service tests exercise the shared rule instead of a Swift copy.
struct LinkedCoreTestRunOutcome: TestRunOutcomeCoreCommandExecuting {
    struct CallError: Error { let message: String }

    func executeTestRunOutcomeCommand<Payload: Encodable, Response: Decodable>(
        _ command: String,
        payload: Payload
    ) throws -> Response {
        let json = String(decoding: try JSONEncoder().encode(TestRunLinkedRequest(command: command, payload: payload)), as: UTF8.self)
        guard let result = json.withCString({ lithe_bridge_execute_json($0) }) else {
            throw CallError(message: "Rust Core is not linked into the test bundle")
        }
        defer { lithe_bridge_free_string(result) }
        let envelope = try JSONDecoder().decode(TestRunLinkedEnvelope<Response>.self, from: Data(String(cString: result).utf8))
        guard envelope.ok, let data = envelope.data else {
            throw CallError(message: envelope.error?.message ?? "Rust Core returned no data")
        }
        return data
    }
}

private struct TestRunLinkedRequest<Body: Encodable>: Encodable {
    let command: String
    let payload: Body
}

private struct TestRunLinkedEnvelope<Body: Decodable>: Decodable {
    struct Failure: Decodable { let message: String }
    let ok: Bool
    let data: Body?
    let error: Failure?
}
