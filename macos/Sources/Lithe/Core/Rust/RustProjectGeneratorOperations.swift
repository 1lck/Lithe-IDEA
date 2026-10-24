import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Typed `project.*` operations. Rust Core owns the catalog, form rules,
/// plans, and archive extraction for both products; this adapter only
/// translates payloads and outcomes.
struct RustProjectGeneratorOperations: ProjectGeneratorPlanning {
    let core: RustCoreBridge

    func catalog(_ plugins: [ProjectGeneratorPluginSource]) throws -> ProjectGeneratorCatalog {
        let result: CatalogResult = try execute(
            "project.generatorCatalog",
            payload: CatalogPayload(
                plugins: try plugins.map {
                    CatalogPayload.Plugin(manifest: try Self.json($0.manifest), enabled: $0.isEnabled)
                },
                hostCapabilities: PluginManifest.hostCapabilities
            )
        )
        return result.catalog
    }

    func form(_ target: ProjectGeneratorTarget, input: ProjectGeneratorFormInput) throws -> ProjectGeneratorFormState {
        let result: FormResult = try execute(
            "project.generatorForm",
            payload: FormPayload(manifest: try Self.json(target.manifest), generatorID: target.generatorID, form: input)
        )
        return result.form
    }

    func plan(_ target: ProjectGeneratorTarget, input: ProjectGeneratorFormInput) throws -> ProjectGenerationPlan {
        let result: PlanResult = try execute(
            "project.generationPlan",
            payload: PlanPayload(
                manifest: try Self.json(target.manifest),
                generatorID: target.generatorID,
                packagePath: target.packageURL.path,
                form: input
            )
        )
        return result.plan
    }

    func nameProblem(_ projectName: String) throws -> ProjectFieldProblem? {
        let result: NameResult = try execute("project.checkName", payload: ["projectName": projectName])
        return result.name.problem
    }

    func extractArchive(at archiveURL: URL, into directory: URL) throws {
        let _: ExtractResult = try execute(
            "project.extractArchive",
            payload: ["archivePath": archiveURL.path, "destination": directory.path]
        )
    }

    private func execute<Payload: Encodable, Value: Decodable>(_ command: String, payload: Payload) throws -> Value {
        let outcome: Outcome<Value>
        do {
            outcome = try core.executeResult(command: command, payload: payload).get()
        } catch {
            throw CoreRejection(
                code: "plugin.project.unavailable",
                message: "Lithe could not evaluate the project generator: \(error.localizedDescription)",
                field: nil
            )
        }
        if let rejection = outcome.error { throw rejection }
        return outcome.value
    }

    private static func json(_ data: Data) throws -> ToolingJSONValue {
        do {
            return try JSONDecoder().decode(ToolingJSONValue.self, from: data)
        } catch {
            throw CoreRejection(code: "plugin.manifest.invalid", message: "plugin.json is not valid JSON.", field: nil)
        }
    }

    // MARK: Wire types

    private struct CatalogPayload: Encodable {
        struct Plugin: Encodable {
            let manifest: ToolingJSONValue
            let enabled: Bool
        }

        let plugins: [Plugin]
        let hostCapabilities: [String: [Int]]
    }

    private struct FormPayload: Encodable {
        let manifest: ToolingJSONValue
        let generatorID: String
        let form: ProjectGeneratorFormInput
    }

    private struct PlanPayload: Encodable {
        let manifest: ToolingJSONValue
        let generatorID: String
        let packagePath: String
        let form: ProjectGeneratorFormInput
    }

    private struct CatalogResult: Decodable { let catalog: ProjectGeneratorCatalog }
    private struct FormResult: Decodable { let form: ProjectGeneratorFormState }
    private struct PlanResult: Decodable { let plan: ProjectGenerationPlan }
    private struct NameResult: Decodable {
        struct Name: Decodable { let problem: ProjectFieldProblem? }
        let name: Name
    }

    private struct ExtractResult: Decodable {}

    /// `{status: "ok", …}` with the operation's value at the top level, or
    /// `{status: "rejected", error}`.
    private struct Outcome<Value: Decodable>: Decodable {
        let error: CoreRejection?
        private let decodedValue: Value?

        var value: Value { decodedValue! }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if try container.decode(String.self, forKey: .status) == "rejected" {
                error = try container.decode(CoreRejection.self, forKey: .error)
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
