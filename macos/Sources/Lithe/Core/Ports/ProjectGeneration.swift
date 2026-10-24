import Foundation
import LitheCoreContracts

// Note: 新建项目向导与项目生成器见 .agents/notes/implemented/feature/2026-10-23-plugin-project-generators.md

/// The deterministic half of creating a project: Rust Core lists the
/// generators, evaluates their forms, and plans every step. Hosts never
/// interpret a generator's fields or templates themselves.
protocol ProjectGeneratorPlanning: Sendable {
    func catalog(_ plugins: [ProjectGeneratorPluginSource]) throws -> ProjectGeneratorCatalog
    func form(_ target: ProjectGeneratorTarget, input: ProjectGeneratorFormInput) throws -> ProjectGeneratorFormState
    func plan(_ target: ProjectGeneratorTarget, input: ProjectGeneratorFormInput) throws -> ProjectGenerationPlan
    func nameProblem(_ projectName: String) throws -> ProjectFieldProblem?
    /// Extracts a downloaded archive into the staging directory, refusing
    /// entries outside it, links, and existing files.
    func extractArchive(at archiveURL: URL, into directory: URL) throws
}

/// What the platform does for a generation plan. Everything happens inside
/// a staging directory next to the destination, so a failure or
/// cancellation never leaves half a project behind.
protocol ProjectGenerationPlatform: Sendable {
    /// Creates an empty, hidden staging directory in `parent`, which must
    /// exist and be writable.
    func makeStagingDirectory(in parent: URL, for projectName: String) throws -> URL
    func writeFile(_ contents: String, to url: URL, executable: Bool) throws
    func createDirectory(at url: URL) throws
    /// Runs a scaffolding tool resolved by bare name, with `directory` as
    /// its working directory. Output is passed on as it arrives.
    func runCommand(
        _ command: ProjectGenerationPlan.Command,
        in directory: URL,
        environment: [String: String],
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws
    /// Downloads an archive to a temporary file the caller removes.
    func download(_ url: URL) async throws -> URL
    /// Moves the contents of `subdirectory` up into `root` and removes it.
    func collect(_ subdirectory: URL, into root: URL) throws
    /// Moves the finished project into place; refuses an existing target.
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL)
    func itemExists(at url: URL) -> Bool
}

/// Why creating a project stopped. The message is shown as is.
struct ProjectGenerationError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}
