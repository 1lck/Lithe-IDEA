import Foundation

struct LanguageServerInstallPlan: Equatable, Sendable {
    let homebrewFormula: String?
    let officialDownloadURL: URL?

    static func plan(for descriptor: LanguageProviderDescriptor) -> Self {
        let installation = descriptor.languageServerInstallation
        return Self(
            homebrewFormula: installation?.homebrewFormula.flatMap {
                isSafeHomebrewFormula($0) ? $0 : nil
            },
            officialDownloadURL: installation?.officialDownloadURL.flatMap {
                $0.scheme?.lowercased() == "https" && $0.host != nil ? $0 : nil
            }
        )
    }

    private static func isSafeHomebrewFormula(_ formula: String) -> Bool {
        guard !formula.isEmpty,
              formula.count <= 200,
              !formula.hasPrefix("/"),
              !formula.hasSuffix("/"),
              !formula.contains("//"),
              !formula.contains("..") else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "@+._-/")
        )
        return formula.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

enum LanguageServerInstallationState: Equatable, Sendable {
    case idle
    case installing
    case installed(String)
    case failed(String)
}

enum LanguageServerExecutableVerificationState: Equatable, Sendable {
    case unavailable
    case foundUnverified
    case executableVerified
}

enum LanguageServerToolConfigurationError: LocalizedError, Equatable {
    case executableRequired
    case executableInvalid(String)
    case executableValidationFailed(path: String, message: String)
    case homebrewUnavailable
    case homebrewUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .executableRequired:
            "Choose a language-server executable."
        case .executableInvalid(let path):
            "The selected language-server path is not executable: \(path)"
        case .executableValidationFailed(let path, let message):
            "The selected language server could not run: \(path)\n\(message)"
        case .homebrewUnavailable:
            "Homebrew is not installed or is not available to Lithe."
        case .homebrewUnsupported(let provider):
            "No verified Homebrew formula is configured for \(provider)."
        }
    }
}

@MainActor
final class LanguageServerToolService: ObservableObject {
    @Published private(set) var customExecutablePaths: [String: String]
    @Published private(set) var installationStates: [String: LanguageServerInstallationState] = [:]

    private let runtimeService: ProjectRuntimeService
    private let processRunner: any ProcessRunner
    private let settingsStore: LanguageServerToolSettingsStore
    private var validationCache: [ExecutableValidationKey: ExecutableValidationResult] = [:]

    init(
        runtimeService: ProjectRuntimeService,
        processRunner: any ProcessRunner,
        store: any KeyValueStore
    ) {
        self.runtimeService = runtimeService
        self.processRunner = processRunner
        settingsStore = LanguageServerToolSettingsStore(store: store)
        customExecutablePaths = settingsStore.load()
    }

    func installPlan(for descriptor: LanguageProviderDescriptor) -> LanguageServerInstallPlan {
        LanguageServerInstallPlan.plan(for: descriptor)
    }

    func customExecutablePath(for providerID: String) -> String? {
        customExecutablePaths[providerID]
    }

    func installationState(for providerID: String) -> LanguageServerInstallationState {
        installationStates[providerID] ?? .idle
    }

    func isHomebrewAvailable() -> Bool {
        runtimeService.executableOnPath("brew") != nil
    }

    func candidates(for descriptor: LanguageProviderDescriptor) -> [RuntimeToolCandidate] {
        var result: [RuntimeToolCandidate] = []
        var seen = Set<String>()

        if let path = customExecutablePath(for: descriptor.id),
           let executableURL = runtimeService.executableURL(at: path) {
            let candidate = RuntimeToolCandidate(
                command: descriptor.languageServerLaunch?.executableNames.first ?? descriptor.id,
                executableURL: executableURL,
                source: .custom,
                detail: "Lithe override"
            )
            if validate(candidate, for: descriptor).isUsable {
                result.append(candidate)
                seen.insert(executableURL.path)
            }
        }

        for command in descriptor.languageServerLaunch?.executableNames ?? [] {
            for candidate in runtimeService.executableCandidates(command) {
                guard seen.insert(candidate.executableURL.path).inserted else { continue }
                guard validate(candidate, for: descriptor).isUsable else { continue }
                result.append(candidate)
            }
        }
        return result
    }

    func executableURL(for descriptor: LanguageProviderDescriptor) -> URL? {
        candidates(for: descriptor).first?.executableURL
    }

    func executableVerificationState(
        for descriptor: LanguageProviderDescriptor
    ) -> LanguageServerExecutableVerificationState {
        guard let candidate = candidates(for: descriptor).first else {
            return .unavailable
        }
        return validate(candidate, for: descriptor).didExecute
            ? .executableVerified
            : .foundUnverified
    }

    func setCustomExecutablePath(
        _ path: String,
        for descriptor: LanguageProviderDescriptor
    ) throws {
        let normalized = (path as NSString)
            .expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw LanguageServerToolConfigurationError.executableRequired
        }
        guard let executableURL = runtimeService.executableURL(at: normalized) else {
            throw LanguageServerToolConfigurationError.executableInvalid(normalized)
        }
        validationCache.removeAll()
        let candidate = RuntimeToolCandidate(
            command: descriptor.languageServerLaunch?.executableNames.first ?? descriptor.id,
            executableURL: executableURL,
            source: .custom,
            detail: "Lithe override"
        )
        let validation = validate(candidate, for: descriptor)
        guard validation.isUsable else {
            throw LanguageServerToolConfigurationError.executableValidationFailed(
                path: executableURL.path,
                message: validation.message
            )
        }
        customExecutablePaths[descriptor.id] = executableURL.path
        settingsStore.save(customExecutablePaths)
    }

    func clearCustomExecutablePath(for providerID: String) {
        customExecutablePaths[providerID] = nil
        settingsStore.save(customExecutablePaths)
    }

    func installWithHomebrew(_ descriptor: LanguageProviderDescriptor) async {
        let plan = installPlan(for: descriptor)
        guard let formula = plan.homebrewFormula else {
            installationStates[descriptor.id] = .failed(
                LanguageServerToolConfigurationError.homebrewUnsupported(descriptor.displayName)
                    .localizedDescription
            )
            return
        }
        guard let brewURL = runtimeService.executableOnPath("brew") else {
            installationStates[descriptor.id] = .failed(
                LanguageServerToolConfigurationError.homebrewUnavailable.localizedDescription
            )
            return
        }

        installationStates[descriptor.id] = .installing
        let runner = processRunner
        let request = ProcessRequest(
            operationID: "lsp-install-\(descriptor.id)-\(UUID().uuidString)",
            executablePath: brewURL.path,
            arguments: ["install", formula],
            environment: runtimeService.processEnvironment(),
            timeoutMilliseconds: 10 * 60 * 1_000
        )
        let result = await Task.detached(priority: .userInitiated) {
            runner.run(request)
        }.value

        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.succeeded {
            validationCache.removeAll()
            installationStates[descriptor.id] = .installed(
                output.isEmpty ? "brew install \(formula) completed." : output
            )
        } else {
            installationStates[descriptor.id] = .failed(
                output.isEmpty ? "brew install \(formula) failed with exit code \(result.exitCode)." : output
            )
        }
    }

    private func validate(
        _ candidate: RuntimeToolCandidate,
        for descriptor: LanguageProviderDescriptor
    ) -> ExecutableValidationResult {
        let arguments = descriptor.languageServerLaunch?.validationArguments ?? []
        guard !arguments.isEmpty else { return .unverifiedUsable }
        let key = ExecutableValidationKey(
            executablePath: candidate.executableURL.standardizedFileURL.path,
            arguments: arguments
        )
        if let cached = validationCache[key],
           Date().timeIntervalSince(cached.checkedAt) < 30 {
            return cached
        }
        let result = processRunner.run(ProcessRequest(
            operationID: "lsp-validate-\(descriptor.id)-\(UUID().uuidString)",
            executablePath: key.executablePath,
            arguments: arguments,
            environment: runtimeService.processEnvironment(),
            timeoutMilliseconds: 5_000
        ))
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let validation = ExecutableValidationResult(
            isUsable: result.succeeded,
            message: output.isEmpty ? "Exited with code \(result.exitCode)." : output,
            didExecute: true,
            checkedAt: Date()
        )
        validationCache[key] = validation
        return validation
    }
}

private struct ExecutableValidationKey: Hashable {
    let executablePath: String
    let arguments: [String]
}

private struct ExecutableValidationResult {
    let isUsable: Bool
    let message: String
    let didExecute: Bool
    let checkedAt: Date

    static let unverifiedUsable = Self(
        isUsable: true,
        message: "",
        didExecute: false,
        checkedAt: .distantFuture
    )
}

private struct LanguageServerToolSettingsStore {
    private static let key = "lithe.language-server-tools.executable-paths"
    private let store: any KeyValueStore

    init(store: any KeyValueStore) {
        self.store = store
    }

    func load() -> [String: String] {
        guard let data = store.data(forKey: Self.key),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return value
    }

    func save(_ paths: [String: String]) {
        guard let data = try? JSONEncoder().encode(paths) else { return }
        store.set(data, forKey: Self.key)
    }
}
