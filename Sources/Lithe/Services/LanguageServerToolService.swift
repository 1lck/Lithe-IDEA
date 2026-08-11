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

enum LanguageServerToolConfigurationError: LocalizedError, Equatable {
    case executableRequired
    case executableInvalid(String)
    case homebrewUnavailable
    case homebrewUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .executableRequired:
            "Choose a language-server executable."
        case .executableInvalid(let path):
            "The selected language-server path is not executable: \(path)"
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
            result.append(RuntimeToolCandidate(
                command: descriptor.languageServerLaunch?.executableNames.first ?? descriptor.id,
                executableURL: executableURL,
                source: .custom,
                detail: "Lithe override"
            ))
            seen.insert(executableURL.path)
        }

        for command in descriptor.languageServerLaunch?.executableNames ?? [] {
            for candidate in runtimeService.executableCandidates(command) {
                guard seen.insert(candidate.executableURL.path).inserted else { continue }
                result.append(candidate)
            }
        }
        return result
    }

    func executableURL(for descriptor: LanguageProviderDescriptor) -> URL? {
        candidates(for: descriptor).first?.executableURL
    }

    func setCustomExecutablePath(_ path: String, for providerID: String) throws {
        let normalized = (path as NSString)
            .expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw LanguageServerToolConfigurationError.executableRequired
        }
        guard let executableURL = runtimeService.executableURL(at: normalized) else {
            throw LanguageServerToolConfigurationError.executableInvalid(normalized)
        }
        customExecutablePaths[providerID] = executableURL.path
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
            installationStates[descriptor.id] = .installed(
                output.isEmpty ? "brew install \(formula) completed." : output
            )
        } else {
            installationStates[descriptor.id] = .failed(
                output.isEmpty ? "brew install \(formula) failed with exit code \(result.exitCode)." : output
            )
        }
    }
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
