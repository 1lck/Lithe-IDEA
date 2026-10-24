import Foundation
import LitheCoreContracts

// Note: 新建项目向导与项目生成器见 .agents/notes/implemented/feature/2026-10-23-plugin-project-generators.md

/// A project that now exists on disk.
struct CreatedProject: Equatable, Sendable {
    let url: URL
    /// Files to open after the project opens, inside `url`.
    let openFiles: [URL]
    /// Set when the project exists but its Git repository could not be
    /// created; the project is still opened.
    let gitWarning: String?
}

/// Runs what Rust Core planned for the New Project window. Every step
/// happens in a staging directory next to the destination; only a complete
/// project is moved into place, and a failure or cancellation removes the
/// staging directory. The service never interprets a generator: files,
/// argv, and URLs come from the plan.
final class ProjectGenerationService: Sendable {
    let planner: any ProjectGeneratorPlanning
    private let platform: any ProjectGenerationPlatform
    private let initializeGitRepository: @Sendable (URL) -> String?
    private let recordJavaHome: @Sendable (URL, String) async -> Void

    /// - Parameters:
    ///   - initializeGitRepository: Creates a repository at the URL and
    ///     returns an error message, or nil on success.
    ///   - recordJavaHome: Stores a JDK as the new project's runtime.
    init(
        planner: any ProjectGeneratorPlanning,
        platform: any ProjectGenerationPlatform,
        initializeGitRepository: @escaping @Sendable (URL) -> String?,
        recordJavaHome: @escaping @Sendable (URL, String) async -> Void
    ) {
        self.planner = planner
        self.platform = platform
        self.initializeGitRepository = initializeGitRepository
        self.recordJavaHome = recordJavaHome
    }

    /// The host's own empty project: a directory, optionally with Git.
    func createEmptyProject(named name: String, in parent: URL, createGitRepository: Bool) async throws
        -> CreatedProject {
        if let problem = try planner.nameProblem(name) {
            throw ProjectGenerationError(message: Self.message(for: problem))
        }
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        try refuseExisting(destination)
        let staging = try platform.makeStagingDirectory(in: parent, for: name)
        do {
            try platform.moveItem(at: staging, to: destination)
        } catch {
            platform.removeItem(at: staging)
            throw error
        }
        return CreatedProject(
            url: destination,
            openFiles: [],
            gitWarning: createGitRepository ? initializeGitRepository(destination) : nil
        )
    }

    /// Plans and runs a plugin generator.
    func create(
        _ target: ProjectGeneratorTarget,
        input: ProjectGeneratorFormInput,
        in parent: URL,
        createGitRepository: Bool,
        onOutput: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> CreatedProject {
        let plan: ProjectGenerationPlan
        do {
            plan = try planner.plan(target, input: input)
        } catch let rejection as CoreRejection {
            throw ProjectGenerationError(message: rejection.message)
        }
        let destination = parent.appendingPathComponent(plan.projectName, isDirectory: true)
        try refuseExisting(destination)
        let staging = try platform.makeStagingDirectory(in: parent, for: plan.projectName)
        do {
            for step in plan.steps {
                try Task.checkCancellation()
                try await run(step, in: staging, onOutput: onOutput)
            }
            try Task.checkCancellation()
            try platform.moveItem(at: staging, to: destination)
        } catch {
            platform.removeItem(at: staging)
            // A cancelled download fails with URLError(.cancelled), not
            // CancellationError; either way the user asked to stop.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let error = error as? ProjectGenerationError { throw error }
            if let rejection = error as? CoreRejection { throw ProjectGenerationError(message: rejection.message) }
            throw ProjectGenerationError(message: error.localizedDescription)
        }

        for runtime in plan.runtimes where runtime.runtime == "java" {
            await recordJavaHome(destination, runtime.home)
        }
        return CreatedProject(
            url: destination,
            openFiles: plan.openFiles.map { destination.appendingPathComponent($0) },
            gitWarning: createGitRepository ? initializeGitRepository(destination) : nil
        )
    }

    private func run(
        _ step: ProjectGenerationPlan.Step,
        in staging: URL,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        switch step {
        case .writeFiles(let files):
            for file in files {
                let url = staging.appendingPathComponent(file.path)
                try platform.createDirectory(at: url.deletingLastPathComponent())
                try platform.writeFile(file.contents, to: url, executable: file.executable)
            }
        case .command(let command):
            try await platform.runCommand(command, in: staging, environment: command.environment, onOutput: onOutput)
            if let collect = command.collect {
                let subdirectory = staging.appendingPathComponent(collect, isDirectory: true)
                guard platform.itemExists(at: subdirectory) else {
                    throw ProjectGenerationError(message: String(
                        localized: "\(command.command) finished without creating \(collect)."
                    ))
                }
                try platform.collect(subdirectory, into: staging)
            }
        case .archive(let url, _):
            let archive = try await platform.download(url)
            defer { platform.removeItem(at: archive) }
            try planner.extractArchive(at: archive, into: staging)
        }
    }

    private func refuseExisting(_ destination: URL) throws {
        if platform.itemExists(at: destination) {
            throw ProjectGenerationError(message: String(
                localized: "\(destination.path) already exists. Choose another name or location."
            ))
        }
    }

    static func message(for problem: ProjectFieldProblem) -> String {
        switch problem {
        case .required: String(localized: "Enter a value.")
        case .tooLong: String(localized: "The value is too long.")
        case .invalidFormat: String(localized: "The value is not in the expected format.")
        case .unsupportedValue: String(localized: "Choose one of the offered values.")
        case .runtimeTooOld: String(localized: "This runtime is older than the generator requires.")
        case .versionTooHigh: String(localized: "This version is newer than the selected runtime supports.")
        }
    }
}
