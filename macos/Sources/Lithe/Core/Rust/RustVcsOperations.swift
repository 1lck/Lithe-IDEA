import Foundation
import LitheCoreContracts

// Note: 统一 VCS 模型见 .agents/notes/proposed/architecture/2026-10-22-unified-vcs-provider-model.md

/// Typed `vcs.*` operations. Rust Core owns root detection, ownership, and
/// reply validation for both products; this adapter only translates
/// payloads and outcomes.
struct RustVcsOperations: VcsRootPlanning {
    let core: RustCoreBridge

    func detectRoots(
        workspaceURL: URL,
        manifests: [Data],
        mappings: [VcsRootMapping]
    ) throws -> VcsDetection {
        let outcome: Outcome<DetectionResult> = try execute(
            "vcs.detectRoots",
            payload: DetectPayload(
                workspaceRoot: workspaceURL.standardizedFileURL.path,
                plugins: try manifests.map { DetectPayload.Plugin(manifest: try Self.json($0)) },
                mappings: mappings
            )
        )
        return outcome.value.detection
    }

    func owners(roots: [String], ambiguous: [String], paths: [String]) throws -> [String?] {
        guard !paths.isEmpty else { return [] }
        let outcome: Outcome<OwnersResult> = try execute(
            "vcs.ownerOf",
            payload: OwnerPayload(roots: roots, ambiguous: ambiguous, paths: paths)
        )
        return outcome.value.owners.map(\.root)
    }

    func decodeReply<Value: Decodable>(
        _ operation: VcsOperation,
        capabilities: [String: Int],
        reply: ToolingJSONValue,
        as type: Value.Type
    ) throws -> Value {
        let outcome: Outcome<DecodedReply<Value>> = try execute(
            "vcs.decodeReply",
            payload: DecodePayload(
                operation: operation.name,
                capabilities: capabilities,
                request: operation.arguments,
                reply: reply
            )
        )
        return outcome.value.result
    }

    private func execute<Payload: Encodable, Value: Decodable>(
        _ command: String,
        payload: Payload
    ) throws -> Outcome<Value> {
        let outcome: Outcome<Value>
        do {
            outcome = try core.executeResult(command: command, payload: payload).get()
        } catch {
            throw DeclarativePluginRejection(
                code: "vcs.provider.failed",
                message: String(localized: "Lithe could not evaluate the version control data: \(error.localizedDescription)")
            )
        }
        if let rejection = outcome.error {
            throw VcsProviderFailure(code: rejection.code, message: rejection.message)
        }
        return outcome
    }

    private static func json(_ data: Data) throws -> ToolingJSONValue {
        do {
            return try JSONDecoder().decode(ToolingJSONValue.self, from: data)
        } catch {
            throw DeclarativePluginRejection(code: "plugin.manifest.invalid", message: "plugin.json is not valid JSON.")
        }
    }

    // MARK: Wire types

    private struct DetectPayload: Encodable {
        struct Plugin: Encodable {
            let manifest: ToolingJSONValue
        }

        let workspaceRoot: String
        let plugins: [Plugin]
        let mappings: [VcsRootMapping]
    }

    private struct DetectionResult: Decodable {
        let detection: VcsDetection
    }

    private struct OwnerPayload: Encodable {
        let roots: [String]
        let ambiguous: [String]
        let paths: [String]
    }

    private struct OwnersResult: Decodable {
        struct Owner: Decodable {
            let root: String?
        }

        let owners: [Owner]
    }

    private struct DecodePayload: Encodable {
        let operation: String
        let capabilities: [String: Int]
        let request: ToolingJSONValue
        let reply: ToolingJSONValue
    }

    private struct DecodedReply<Value: Decodable>: Decodable {
        let result: Value
    }

    private struct Rejection: Decodable {
        let code: String
        let message: String
    }

    /// `{status: "ok", …}` with the value at the top level, or
    /// `{status: "rejected", error}`.
    private struct Outcome<Value: Decodable>: Decodable {
        let error: Rejection?
        private let decodedValue: Value?

        var value: Value { decodedValue! }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if try container.decode(String.self, forKey: .status) == "rejected" {
                error = try container.decode(Rejection.self, forKey: .error)
                decodedValue = nil
            } else {
                error = nil
                decodedValue = try Value(from: decoder)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case status, error
        }
    }
}
