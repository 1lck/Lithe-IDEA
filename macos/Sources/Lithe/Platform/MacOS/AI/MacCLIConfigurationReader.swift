import Foundation
import LitheCoreContracts

/// Native file and environment access for CLI configuration discovery.
///
/// Rust Core decides which files a source reads and how their text becomes a
/// provider (`ai.configuration.sources` / `ai.configuration.parse`). This reader
/// only touches the file system and resolves the credential locator Core returns,
/// so the secret never appears in a Core response.
struct MacCLIConfigurationReader: Sendable {
    let core: RustCoreBridge
    var fileManager: FileManager
    var environment: [String: String]

    init(core: RustCoreBridge, fileManager: FileManager = .default,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.core = core
        self.fileManager = fileManager
        self.environment = environment
    }

    struct Result {
        let model: String
        let snapshot: AIConfigurationSnapshot?
    }

    private struct SourcesPayload: Encodable {
        let source: String
        let home: String
        let environment: [String: String]
    }
    private struct SourceFile: Decodable {
        let file: String
        let path: String
    }
    private struct SourcesResponse: Decodable { let files: [SourceFile] }
    private struct ParsePayload: Encodable {
        let source: String
        let files: [String: String]
        let environment: [String: String]
    }
    private struct Locator: Decodable {
        let kind: String
        let name: String?
        let file: String?
        let path: [String]?
    }
    private struct Parsed: Decodable {
        struct Provider: Decodable {
            let name: String
            let endpoint: String
            let model: String
            let apiProtocol: CommitMessageAPIProtocol
            let authentication: AIProviderAuthentication
            let requiresApiKey: Bool
        }
        let model: String
        let provider: Provider?
        let reasoningEffort: String?
        let credential: Locator?
    }

    /// `nil` when the CLI is not configured, the files are unreadable, or Core rejects them.
    func read(_ source: AIConfigurationSourceKind) -> Result? {
        // Only directory overrides influence file discovery; the full snapshot is passed to parsing.
        let overrides = environment.filter { ["CODEX_HOME", "CLAUDE_CONFIG_DIR"].contains($0.key) }
        guard let listing = try? core.executeResult(command: "ai.configuration.sources", payload: SourcesPayload(
            source: source.rawValue, home: fileManager.homeDirectoryForCurrentUser.path, environment: overrides
        )).get() as SourcesResponse else { return nil }
        var files: [String: String] = [:]
        for entry in listing.files {
            guard let data = fileManager.contents(atPath: entry.path),
                  let text = String(data: data, encoding: .utf8) else { continue }
            files[entry.file] = text
        }
        let bounded = environment.filter { $0.key.utf8.count + $0.value.utf8.count <= 32 * 1024 }
        guard let parsed = try? core.executeResult(command: "ai.configuration.parse", payload: ParsePayload(
            source: source.rawValue, files: files, environment: Dictionary(uniqueKeysWithValues: bounded.prefix(4096).map { ($0.key, $0.value) })
        )).get() as Parsed? else { return nil }
        guard let provider = parsed.provider else {
            return Result(model: parsed.model, snapshot: nil)
        }
        return Result(model: parsed.model, snapshot: AIConfigurationSnapshot(
            source: source, providerName: provider.name, endpoint: provider.endpoint, model: provider.model,
            apiProtocol: provider.apiProtocol, authentication: provider.authentication,
            reasoningEffort: parsed.reasoningEffort.flatMap(CommitMessageReasoningEffort.init(rawValue:)),
            requiresAPIKey: provider.requiresApiKey, apiKey: resolve(parsed.credential, files: files)))
    }

    /// Reads the value a locator names. A credential inside the TOML `config` file is not
    /// resolved: Lithe never parsed TOML credentials natively and the key is treated as absent.
    private func resolve(_ locator: Locator?, files: [String: String]) -> String? {
        guard let locator else { return nil }
        if locator.kind == "environment" { return locator.name.flatMap { environment[$0] } }
        guard locator.kind == "file", let file = locator.file, file != "config", let path = locator.path,
              let text = files[file], var value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        for key in path {
            guard let object = value as? [String: Any], let next = object[key] else { return nil }
            value = next
        }
        return value as? String
    }
}

/// Codex CLI configuration (`config.toml` plus `auth.json`) read through Rust Core.
final class MacCodexConfigurationSource: CodexConfigurationSource, @unchecked Sendable {
    private let reader: MacCLIConfigurationReader

    init(core: RustCoreBridge, fileManager: FileManager = .default,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        reader = MacCLIConfigurationReader(core: core, fileManager: fileManager, environment: environment)
    }

    func loadModel() -> AIConfigurationModel? {
        reader.read(.codex).map { AIConfigurationModel(source: .codex, model: $0.model) }
    }

    func load() -> CodexConfigurationSnapshot? { reader.read(.codex)?.snapshot }
}

/// Claude CLI configuration (settings, credentials and root JSON) read through Rust Core.
final class MacClaudeConfigurationSource: ClaudeConfigurationSource, @unchecked Sendable {
    private let reader: MacCLIConfigurationReader

    init(core: RustCoreBridge, fileManager: FileManager = .default,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        reader = MacCLIConfigurationReader(core: core, fileManager: fileManager, environment: environment)
    }

    func loadModel() -> AIConfigurationModel? {
        reader.read(.claude).map { AIConfigurationModel(source: .claude, model: $0.model) }
    }

    func load() -> AIConfigurationSnapshot? { reader.read(.claude)?.snapshot }
}
