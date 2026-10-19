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
        try readText(at: resolvedConfigurationTarget(file.url), reportedAs: file.url.path)
    }

    /// Reads one configuration file with the same bounds `write` validates.
    private func readText(at url: URL, reportedAs path: String) throws -> String? {
        guard storage.fileExists(at: url) else { return nil }
        guard let metadata = storage.metadata(for: url), metadata.isRegularFile else {
            throw McpConfigurationError.unreadable(path)
        }
        if let byteCount = metadata.byteCount, byteCount > Self.maximumBytes {
            throw McpConfigurationError.tooLarge
        }
        let data: Data
        do {
            data = try storage.readData(from: url, options: [])
        } catch {
            throw McpConfigurationError.unreadable(path)
        }
        guard data.count <= Self.maximumBytes, let content = String(data: data, encoding: .utf8) else {
            throw data.count > Self.maximumBytes
                ? McpConfigurationError.tooLarge
                : McpConfigurationError.unreadable(path)
        }
        return content
    }

    func write(
        _ content: String, to file: McpConfigurationFile, replacing expected: String?
    ) throws -> McpWriteReceipt {
        let data = Data(content.utf8)
        guard data.count <= Self.maximumBytes else { throw McpConfigurationError.tooLarge }
        // Atomic replacement renames over the path, which would replace a
        // dotfile symlink with a regular file; write through to its target.
        let target = resolvedConfigurationTarget(file.url)
        // Re-read immediately before replacing. Atomic rename prevents a
        // half-written file, but not losing a save another Agent, editor or
        // Lithe instance made after this plan was computed.
        if let expected {
            guard let current = try readText(at: target, reportedAs: file.url.path),
                  current == expected else {
                throw McpConfigurationError.changedOnDisk
            }
        } else if storage.fileExists(at: target) {
            // The plan assumed a new file; creating it now would discard the
            // entry another process just added.
            throw McpConfigurationError.changedOnDisk
        }
        let exists = storage.fileExists(at: target)
        let permissions = exists ? posixPermissions(of: target) : 0o600
        let backupURL = try backup(target)
        do {
            try storage.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // The snapshot check above runs before the backup. Publish through
            // the platform's conditional replacement so a save another Agent,
            // editor or Lithe instance makes between that check and the final
            // write is preserved and reported instead of overwritten.
            guard try storage.replaceData(
                data, at: target, expecting: expected.map { Data($0.utf8) }
            ) else {
                throw McpConfigurationError.changedOnDisk
            }
        } catch let error as FileStorageRetainedCopyError {
            restorePermissions(permissions, to: target, ifHolding: data)
            throw McpConfigurationError.retainedCopy(
                destination: error.destinationPath, retained: error.retainedPath
            )
        } catch let error as McpConfigurationError {
            throw error
        } catch {
            // A failed exchange can leave the prepared file (created with the
            // default mode) at the destination; restore the original mode so a
            // secret-bearing config is not left 0644.
            restorePermissions(permissions, to: target, ifHolding: data)
            throw McpConfigurationError.notWritable(file.url.path)
        }
        applyPermissions(permissions, to: target)
        return McpWriteReceipt(backupURL: backupURL)
    }

    /// Only rewrites the mode while the failed publish left this call's bytes
    /// at the destination; an external file keeps the mode its writer chose.
    private func restorePermissions(_ permissions: Int, to target: URL, ifHolding data: Data) {
        // A special or oversized file must not be read back just to restore a
        // mode; only this call's own regular-file bytes justify touching it.
        guard let metadata = storage.metadata(for: target),
              metadata.isRegularFile,
              metadata.byteCount == data.count,
              let current = try? storage.readData(from: target, options: []),
              current == data else { return }
        applyPermissions(permissions, to: target)
    }

    private func applyPermissions(_ permissions: Int, to target: URL) {
        try? fileManager.setAttributes(
            [.posixPermissions: permissions], ofItemAtPath: target.path
        )
    }

    func restore(_ change: McpConfigurationChange) throws {
        let target = resolvedConfigurationTarget(change.file.url)
        guard try readText(at: target, reportedAs: change.file.url.path) == change.content else {
            throw McpConfigurationError.changedOnDisk
        }
        if let source = change.source {
            // The forward path also checks the snapshot and replaces atomically.
            // Backups retain the original and the attempted output.
            _ = try write(source, to: change.file, replacing: change.content)
        } else {
            do {
                // The rollback must not delete a file another process wrote
                // after our batch created this one; remove only the bytes this
                // batch published.
                guard try storage.removeData(
                    at: target, expecting: Data(change.content.utf8)
                ) else {
                    throw McpConfigurationError.changedOnDisk
                }
            } catch let error as FileStorageRetainedCopyError {
                throw McpConfigurationError.retainedCopy(
                    destination: error.destinationPath, retained: error.retainedPath
                )
            } catch let error as McpConfigurationError {
                throw error
            } catch {
                throw McpConfigurationError.notWritable(change.file.url.path)
            }
        }
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
        // Another editor can append a rule between our read and the write.
        // Publish conditionally and merge once with the fresh snapshot instead
        // of overwriting that rule with our stale bytes.
        for _ in 0..<2 {
            let exists = storage.fileExists(at: excludeURL)
            let existing: Data
            if exists {
                do {
                    existing = try storage.readData(from: excludeURL, options: [])
                } catch {
                    throw McpConfigurationError.unreadable(excludeURL.path)
                }
            } else {
                existing = Data()
            }
            // Decode individual rules only; unrelated bytes may use another encoding.
            let alreadyListed = existing
                .split(separator: 0x0A, omittingEmptySubsequences: false)
                .contains { line in
                    let rule = line.last == 0x0D ? line.dropLast() : line
                    guard let text = String(data: rule, encoding: .utf8) else { return false }
                    // Leading spaces and tabs are literal Git pattern characters.
                    return text == relativePath || text == "/" + relativePath
                }
            guard !alreadyListed else { return }
            var updated = existing
            if !updated.isEmpty && updated.last != 0x0A { updated.append(0x0A) }
            updated.append(contentsOf: relativePath.utf8)
            updated.append(0x0A)
            do {
                try storage.createDirectory(
                    at: excludeURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                if try storage.replaceData(
                    updated, at: excludeURL, expecting: exists ? existing : nil
                ) {
                    return
                }
            } catch {
                throw McpConfigurationError.notWritable(excludeURL.path)
            }
        }
        throw McpConfigurationError.changedOnDisk
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
                : dotGit.deletingLastPathComponent().appendingPathComponent(path)
        } else {
            return nil
        }
        // Linked worktrees keep the exclude list in the repository's common
        // directory, not under `.git/worktrees/<name>`.
        return commonGitDirectory(gitDirectory)
            .appendingPathComponent("info/exclude")
    }

    /// Resolves `commondir` for linked worktrees; Git records the shared
    /// repository directory there as a path relative to the worktree's gitdir.
    private func commonGitDirectory(_ gitDirectory: URL) -> URL {
        let commonFile = gitDirectory.appendingPathComponent("commondir")
        guard let data = try? storage.readPrefix(from: commonFile, byteCount: 4096),
              let text = String(data: data, encoding: .utf8) else {
            return gitDirectory.standardizedFileURL
        }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return gitDirectory.standardizedFileURL }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return gitDirectory.appendingPathComponent(path).standardizedFileURL
    }

    /// Reads, writes and rollback validate the same dotfiles target, while
    /// diagnostics continue to identify the user-facing configuration path.
    private func resolvedConfigurationTarget(_ url: URL) -> URL {
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
