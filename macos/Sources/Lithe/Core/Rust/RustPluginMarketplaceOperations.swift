import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Typed `plugins.marketplace.*` operations. Rust Core owns index validation,
/// availability, source resolution, and install reviews for both products;
/// this adapter only translates payloads and outcomes.
struct RustPluginMarketplaceOperations: PluginMarketplaceEvaluating {
    let core: RustCoreBridge

    func validateIndex(
        _ index: Data,
        sourceKind: PluginMarketplaceSourceKind,
        platform: String
    ) throws -> PluginMarketplaceIndex {
        let outcome: Outcome<IndexResult> = try execute(
            "plugins.marketplace.validateIndex",
            payload: ValidateIndexPayload(
                index: try Self.json(index, invalidCode: "plugin.index.invalid", what: "The plugin index"),
                sourceKind: sourceKind,
                platform: platform,
                hostCapabilities: PluginManifest.hostCapabilities
            )
        )
        return outcome.value.index
    }

    func resolveSource(_ input: String) throws -> PluginMarketplaceSourceResolution {
        let outcome: Outcome<SourceResult> = try execute(
            "plugins.marketplace.resolveSource",
            payload: ResolveSourcePayload(url: input)
        )
        return outcome.value.source
    }

    func installReview(
        manifest: Data,
        expectedID: String?,
        expectedVersion: String?,
        approvedPrograms: [PluginProgram]?
    ) throws -> PluginInstallReview {
        let outcome: Outcome<ReviewResult> = try execute(
            "plugins.marketplace.installReview",
            payload: InstallReviewPayload(
                manifest: try Self.json(manifest, invalidCode: "plugin.manifest.invalid", what: "plugin.json"),
                expectedID: expectedID,
                expectedVersion: expectedVersion,
                approvedPrograms: approvedPrograms?.map(\.json),
                hostCapabilities: PluginManifest.hostCapabilities
            )
        )
        let review = outcome.value.review
        return PluginInstallReview(
            pluginID: review.id,
            version: review.version,
            permissions: review.permissions,
            programs: review.programs.map(PluginProgram.init(json:)),
            newPrograms: review.newPrograms.map(PluginProgram.init(json:))
        )
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
                code: "plugin.index.invalid",
                message: "Lithe could not evaluate the plugin marketplace data: \(error.localizedDescription)"
            )
        }
        if let rejection = outcome.error {
            throw rejection.rejection
        }
        return outcome
    }

    private static func json(_ data: Data, invalidCode: String, what: String) throws -> ToolingJSONValue {
        do {
            return try JSONDecoder().decode(ToolingJSONValue.self, from: data)
        } catch {
            throw DeclarativePluginRejection(code: invalidCode, message: "\(what) is not valid JSON.")
        }
    }

    // MARK: Wire types

    private struct ValidateIndexPayload: Encodable {
        let index: ToolingJSONValue
        let sourceKind: PluginMarketplaceSourceKind
        let platform: String
        /// Level 3 versions are offered only for capabilities this host runs.
        let hostCapabilities: [String: [Int]]
    }

    private struct ResolveSourcePayload: Encodable {
        let url: String
    }

    private struct InstallReviewPayload: Encodable {
        let manifest: ToolingJSONValue
        let expectedID: String?
        let expectedVersion: String?
        let approvedPrograms: [ToolingJSONValue]?
        let hostCapabilities: [String: [Int]]
    }

    private struct Outcome<Value: Decodable>: Decodable {
        let error: DeclarativePluginRejectionPayload?
        private let decodedValue: Value?

        var value: Value { decodedValue! }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if try container.decode(String.self, forKey: .status) == "rejected" {
                error = try container.decode(DeclarativePluginRejectionPayload.self, forKey: .error)
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

    private struct IndexResult: Decodable {
        let index: PluginMarketplaceIndex
    }

    private struct SourceResult: Decodable {
        let source: PluginMarketplaceSourceResolution
    }

    private struct ReviewResult: Decodable {
        struct Review: Decodable {
            let id: String
            let version: String
            let permissions: [String]
            let programs: [ToolingJSONValue]
            let newPrograms: [ToolingJSONValue]
        }
        let review: Review
    }
}
