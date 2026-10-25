import Foundation
import LitheModuleAPI
import LitheCoreContracts

// Note: 新建项目向导与项目生成器见 .agents/notes/implemented/feature/2026-10-23-plugin-project-generators.md

/// macOS side of creating a project. Writes go only to the staging
/// directory inside the folder the user chose and to a temporary download;
/// nothing is written to the application bundle or a plugin package.
final class MacProjectGenerationPlatform: ProjectGenerationPlatform, @unchecked Sendable {
    /// Largest archive Lithe downloads for a new project.
    static let defaultMaximumDownloadBytes: Int64 = 256 * 1024 * 1024
    /// Largest error body read for the server's explanation.
    static let maximumErrorBodyBytes = 64 * 1024
    private static let writeChunkBytes = 256 * 1024
    /// Lines of tool output kept for an error message.
    private static let outputTailLines = 20

    /// The user's process environment with overrides applied.
    private let environment: @MainActor ([String: String]) -> [String: String]
    /// Resolves a bare tool name like a build tool, never to a copy inside a
    /// project.
    private let executable: @MainActor (String) -> URL?
    private let runner: any BuildCommandRunning
    private let session: URLSession
    private let maximumDownloadBytes: Int64
    private let fileManager: FileManager

    init(
        environment: @escaping @MainActor ([String: String]) -> [String: String],
        executable: @escaping @MainActor (String) -> URL?,
        runner: any BuildCommandRunning,
        session: URLSession = .shared,
        maximumDownloadBytes: Int64 = defaultMaximumDownloadBytes,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.executable = executable
        self.runner = runner
        self.session = session
        self.maximumDownloadBytes = maximumDownloadBytes
        self.fileManager = fileManager
    }

    /// Resolves tools and the environment through the user's runtime settings.
    @MainActor
    convenience init(runtime: ProjectRuntimeService, runner: any BuildCommandRunning) {
        self.init(
            environment: { runtime.processEnvironment(overrides: $0) },
            executable: { command in
                runtime.executableCandidates(command).first { $0.source != .project }?.executableURL
            },
            runner: runner
        )
    }

    func makeStagingDirectory(in parent: URL, for projectName: String) throws -> URL {
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let staging = parent.appendingPathComponent(".\(projectName).lithe-creating-\(suffix)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        return staging
    }

    func writeFile(_ contents: String, to url: URL, executable: Bool) throws {
        try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        if executable {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func runCommand(
        _ command: ProjectGenerationPlan.Command,
        in directory: URL,
        environment overrides: [String: String],
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        let (executable, environment) = await MainActor.run { () -> (URL?, [String: String]) in
            var environment = self.environment(overrides)
            // A JDK the generator selected also comes first on PATH, so the
            // tool and anything it starts use the same Java.
            if let javaHome = overrides["JAVA_HOME"], !javaHome.isEmpty {
                environment["PATH"] = javaHome + "/bin:" + (environment["PATH"] ?? "")
            }
            return (self.executable(command.command), environment)
        }
        guard let executable else {
            throw ProjectGenerationError(message: String(
                localized: "Lithe could not find \(command.command). Install it or add it to PATH, then try again."
            ))
        }
        let tail = OutputTail(limit: Self.outputTailLines)
        let result = try await runner.run(
            BuildCommandRequest(
                executableURL: executable,
                arguments: command.arguments,
                workingDirectory: directory,
                environment: environment,
                timeout: .seconds(command.timeoutSeconds)
            ),
            onOutput: { text in
                tail.append(text)
                onOutput(text)
            }
        )
        switch result.termination {
        case .exited(0):
            return
        case .exited(let status):
            throw ProjectGenerationError(message: String(
                localized: "\(command.command) exited with status \(status).\n\(tail.text)"
            ))
        case .timedOut:
            throw ProjectGenerationError(message: String(
                localized: "\(command.command) did not finish within \(command.timeoutSeconds) seconds."
            ))
        }
    }

    /// Streams the archive to a temporary file and stops as soon as it
    /// passes the download budget, so an oversized or endless response
    /// never fills the disk first. A refused request reads at most
    /// `maximumErrorBodyBytes` of the server's explanation.
    func download(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("application/zip", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = await Self.serverMessage(in: bytes)
            bytes.task.cancel()
            throw ProjectGenerationError(message: String(
                localized: "\(url.host ?? "The server") answered with status \(status). \(detail)"
            ))
        }
        let tooLarge = ProjectGenerationError(message: String(
            localized: "The project archive from \(url.host ?? "") is too large."
        ))
        // A declared length over the limit is refused before reading the body.
        guard response.expectedContentLength <= maximumDownloadBytes else {
            bytes.task.cancel()
            throw tooLarge
        }
        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("lithe-project-\(UUID().uuidString).zip")
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            bytes.task.cancel()
            throw ProjectGenerationError(message: L10n.string("Lithe could not create a temporary download file."))
        }
        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var buffer = Data()
            buffer.reserveCapacity(Self.writeChunkBytes)
            var received: Int64 = 0
            for try await byte in bytes {
                received += 1
                guard received <= maximumDownloadBytes else { throw tooLarge }
                buffer.append(byte)
                if buffer.count >= Self.writeChunkBytes {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try handle.write(contentsOf: buffer)
            return destination
        } catch {
            bytes.task.cancel()
            removeItem(at: destination)
            throw error
        }
    }

    func collect(_ subdirectory: URL, into root: URL) throws {
        // Renamed first, so an entry named like the subdirectory itself can
        // still move up.
        let holding = root.appendingPathComponent(".lithe-collect-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fileManager.moveItem(at: subdirectory, to: holding)
        for entry in try fileManager.contentsOfDirectory(at: holding, includingPropertiesForKeys: nil) {
            try fileManager.moveItem(at: entry, to: root.appendingPathComponent(entry.lastPathComponent))
        }
        try fileManager.removeItem(at: holding)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        guard !itemExists(at: destination) else {
            throw ProjectGenerationError(message: String(
                localized: "\(destination.path) already exists. Choose another name or location."
            ))
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    func itemExists(at url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    /// Spring Initializr and similar servers explain a refused request in a
    /// small JSON body; a longer or different body is not shown.
    private static func serverMessage(in bytes: URLSession.AsyncBytes) async -> String {
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < maximumErrorBodyBytes else { return "" }
                data.append(byte)
            }
        } catch {
            return ""
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String else { return "" }
        return message
    }
}

/// The last lines a tool printed, for an error message.
private final class OutputTail: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var lines: [Substring] = []

    init(limit: Int) { self.limit = limit }

    func append(_ text: String) {
        lock.withLock {
            lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true))
            if lines.count > limit { lines.removeFirst(lines.count - limit) }
        }
    }

    var text: String { lock.withLock { lines.joined(separator: "\n") } }
}
