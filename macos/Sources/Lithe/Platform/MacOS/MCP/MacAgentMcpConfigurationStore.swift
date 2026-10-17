import Foundation

/// macOS file access for Codex and Claude Code MCP configuration.
///
/// Core owns parsing and formatting; this adapter owns path resolution, bounded
/// reads, backups and atomic replacement. Writes never re-serialize the whole
/// document, so unrelated settings survive byte for byte.
@MainActor
final class MacAgentMcpConfigurationStore: McpConfigurationStore {
    private static let maximumBytes = 1024 * 1024

    private let core: RustCoreBridge
    private let storage: any FileStorage
    private let environment: [String: String]
    private let fileManager = FileManager.default

    init(
        core: RustCoreBridge,
        storage: any FileStorage,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.core = core
        self.storage = storage
        self.environment = environment
    }

    func configurationFiles(workspace: URL?) -> [McpConfigurationFile] {
        let claudeURL = claudeConfigurationURL
        var files = [
            McpConfigurationFile(
                agent: .codex, scope: .global, url: codexConfigurationURL, projectPath: nil
            ),
            McpConfigurationFile(
                agent: .claudeCode, scope: .global, url: claudeURL, projectPath: nil
            )
        ]
        if let workspace {
            let projectPath = workspace.standardizedFileURL.path
            files.append(McpConfigurationFile(
                agent: .claudeCode, scope: .project, url: claudeURL, projectPath: projectPath
            ))
            files.append(McpConfigurationFile(
                agent: .codex,
                scope: .project,
                url: workspace.appendingPathComponent(".codex/config.toml"),
                projectPath: projectPath
            ))
        }
        return files
    }

    /// `$CODEX_HOME/config.toml`, else `~/.codex/config.toml`.
    private var codexConfigurationURL: URL {
        if let home = environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("config.toml")
        }
        return storage.homeDirectory().appendingPathComponent(".codex/config.toml")
    }

    /// `$CLAUDE_CONFIG_DIR/.claude.json`, else `~/.claude.json`.
    private var claudeConfigurationURL: URL {
        if let directory = environment["CLAUDE_CONFIG_DIR"], !directory.isEmpty {
            return URL(fileURLWithPath: directory).appendingPathComponent(".claude.json")
        }
        return storage.homeDirectory().appendingPathComponent(".claude.json")
    }

    func read(_ file: McpConfigurationFile) throws -> String? {
        guard storage.fileExists(at: file.url) else { return nil }
        guard let metadata = storage.metadata(for: file.url), metadata.isRegularFile else {
            throw McpConfigurationError.unreadable(file.url.path)
        }
        if let byteCount = metadata.byteCount, byteCount > Self.maximumBytes {
            throw McpConfigurationError.tooLarge
        }
        let data: Data
        do {
            data = try storage.readData(from: file.url, options: [])
        } catch {
            throw McpConfigurationError.unreadable(file.url.path)
        }
        guard data.count <= Self.maximumBytes, let content = String(data: data, encoding: .utf8) else {
            throw data.count > Self.maximumBytes
                ? McpConfigurationError.tooLarge
                : McpConfigurationError.unreadable(file.url.path)
        }
        return content
    }

    func write(_ content: String, to file: McpConfigurationFile) throws -> McpWriteReceipt {
        let data = Data(content.utf8)
        guard data.count <= Self.maximumBytes else { throw McpConfigurationError.tooLarge }
        // Atomic replacement renames over the path, which would replace a
        // dotfile symlink with a regular file; write through to its target.
        let target = resolvedWriteTarget(file.url)
        let exists = storage.fileExists(at: target)
        let permissions = exists ? posixPermissions(of: target) : 0o600
        let backupURL = try backup(target)
        do {
            try storage.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try storage.writeData(data, to: target, options: .atomic)
        } catch {
            throw McpConfigurationError.notWritable(file.url.path)
        }
        try? fileManager.setAttributes(
            [.posixPermissions: permissions], ofItemAtPath: target.path
        )
        return McpWriteReceipt(backupURL: backupURL)
    }

    func parse(_ file: McpConfigurationFile, content: String) throws -> [McpServerDefinition] {
        struct Payload: Encodable {
            let source: String
            let scope: String
            let content: String
            let projectPath: String?
        }
        struct Response: Decodable {
            let servers: [McpServerDefinition]
        }
        let payload = Payload(
            source: file.agent.sourceName,
            scope: file.scope.rawValue,
            content: content,
            projectPath: file.projectPath
        )
        do {
            let response: Response = try core.executeResult(
                command: "mcp.parseConfiguration", payload: payload
            ).get()
            return response.servers
        } catch let error {
            throw McpConfigurationError.core(error.message)
        }
    }

    func planWrite(_ request: McpWriteRequest, for file: McpConfigurationFile) throws -> McpWritePlan {
        do {
            return try core.executeResult(command: "mcp.planWrite", payload: request).get()
        } catch let error {
            throw McpConfigurationError.core(error.message)
        }
    }

    /// Appends to `.git/info/exclude` instead of the tracked `.gitignore` so the
    /// project's own version-control policy stays untouched.
    func excludeFromVersionControl(_ relativePath: String, workspace: URL) throws {
        guard let excludeURL = gitExcludeURL(workspace: workspace) else { return }
        let existing = (try? storage.readData(from: excludeURL, options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let alreadyListed = existing
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed == relativePath || trimmed == "/" + relativePath
            }
        guard !alreadyListed else { return }
        var updated = existing
        if !updated.isEmpty && !updated.hasSuffix("\n") { updated += "\n" }
        updated += relativePath + "\n"
        do {
            try storage.createDirectory(
                at: excludeURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try storage.writeData(Data(updated.utf8), to: excludeURL, options: .atomic)
        } catch {
            throw McpConfigurationError.notWritable(excludeURL.path)
        }
    }

    /// Resolves the worktree's Git directory, including linked worktrees where
    /// `.git` is a file pointing at the real directory.
    private func gitExcludeURL(workspace: URL) -> URL? {
        let dotGit = workspace.appendingPathComponent(".git")
        guard let metadata = storage.metadata(for: dotGit) else { return nil }
        let gitDirectory: URL
        if metadata.isDirectory {
            gitDirectory = dotGit
        } else if metadata.isRegularFile {
            guard let data = try? storage.readData(from: dotGit, options: []),
                  let text = String(data: data, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: {
                      String($0).trimmingCharacters(in: .whitespaces).hasPrefix("gitdir:")
                  }) else { return nil }
            let path = String(line)
                .trimmingCharacters(in: .whitespaces)
                .dropFirst("gitdir:".count)
                .trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            gitDirectory = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : URL(fileURLWithPath: path, relativeTo: dotGit.deletingLastPathComponent()).absoluteURL
        } else {
            return nil
        }
        return gitDirectory.standardizedFileURL.appendingPathComponent("info/exclude")
    }

    private func resolvedWriteTarget(_ url: URL) -> URL {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
            return url
        }
        return url.resolvingSymlinksInPath()
    }

    private func posixPermissions(of url: URL) -> Int {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
    }

    /// Copies the current bytes to Application Support before any overwrite.
    /// Failing to create the backup aborts the write rather than risking
    /// unrecoverable user configuration.
    private func backup(_ target: URL) throws -> URL? {
        guard storage.fileExists(at: target) else { return nil }
        let stamp = Self.backupStamp()
        let directory = storage.applicationSupportDirectory()
            .appendingPathComponent("MCP Backups")
            .appendingPathComponent(stamp)
        do {
            try storage.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(target.lastPathComponent)
            try storage.copyItem(at: target, to: destination)
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: destination.path
            )
            return destination
        } catch {
            throw McpConfigurationError.notWritable(target.path)
        }
    }

    private static func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(8)
    }
}
