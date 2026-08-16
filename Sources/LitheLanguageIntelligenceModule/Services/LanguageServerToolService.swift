import Combine
import Foundation
import LitheCoreContracts

package struct LanguageServerInstallPlan: Equatable, Sendable {
    package let homebrewFormula: String?
    package let officialDownloadURL: URL?

    package static func plan(for descriptor: LanguageProviderDescriptor) -> Self {
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

package enum LanguageServerInstallationState: Equatable, Sendable {
    case idle
    case installing
    case installed(String)
    case failed(String)
}

package enum LanguageServerExecutableVerificationState: Equatable, Sendable {
    case unavailable
    case foundUnverified
    case executableVerified
}

package enum LanguageServerToolConfigurationError: LocalizedError, Equatable {
    case executableRequired
    case executableInvalid(String)
    case executableValidationFailed(path: String, message: String)
    case homebrewUnavailable
    case homebrewUnsupported(String)

    package var errorDescription: String? {
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
package final class LanguageServerToolService: ObservableObject {
    @Published package private(set) var customExecutablePaths: [String: String]
    @Published package private(set) var installationStates: [String: LanguageServerInstallationState] = [:]
    @Published private var validatedCandidates: [String: [RuntimeToolCandidate]] = [:]
    package var onCandidatesChanged: ((String) -> Void)?

    private let runtimeService: any LanguageToolRuntimePort
    private let commandRunner: any LanguageToolCommandRunning
    private let settingsStore: any LanguageToolSettingsStoring
    private var validationCache: [ExecutableValidationKey: ExecutableValidationResult] = [:]

    package init(
        runtimeService: any LanguageToolRuntimePort,
        commandRunner: any LanguageToolCommandRunning,
        settingsStore: any LanguageToolSettingsStoring
    ) {
        self.runtimeService = runtimeService
        self.commandRunner = commandRunner
        self.settingsStore = settingsStore
        customExecutablePaths = settingsStore.loadLanguageToolExecutablePaths()
    }

    package func installPlan(for descriptor: LanguageProviderDescriptor) -> LanguageServerInstallPlan {
        LanguageServerInstallPlan.plan(for: descriptor)
    }

    package func customExecutablePath(for providerID: String) -> String? {
        customExecutablePaths[providerID]
    }

    package func installationState(for providerID: String) -> LanguageServerInstallationState {
        installationStates[providerID] ?? .idle
    }

    package func isHomebrewAvailable() -> Bool {
        runtimeService.executableOnPath("brew") != nil
    }

    package func candidates(for descriptor: LanguageProviderDescriptor) -> [RuntimeToolCandidate] {
        if let cached = validatedCandidates[descriptor.id] {
            return cached
        }
        guard descriptor.languageServerLaunch?.validationArguments.isEmpty != false else {
            return []
        }
        return discoveredCandidates(for: descriptor)
    }

    @discardableResult
    package func refreshCandidates(
        for descriptor: LanguageProviderDescriptor
    ) async -> [RuntimeToolCandidate] {
        let discovered = discoveredCandidates(for: descriptor)
        let arguments = descriptor.languageServerLaunch?.validationArguments ?? []
        guard !arguments.isEmpty else {
            validatedCandidates[descriptor.id] = discovered
            onCandidatesChanged?(descriptor.id)
            return discovered
        }
        var usable: [RuntimeToolCandidate] = []
        for candidate in discovered {
            if await validate(candidate, for: descriptor).isUsable {
                usable.append(candidate)
            }
        }
        validatedCandidates[descriptor.id] = usable
        onCandidatesChanged?(descriptor.id)
        return usable
    }

    private func discoveredCandidates(
        for descriptor: LanguageProviderDescriptor
    ) -> [RuntimeToolCandidate] {
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
            result.append(candidate)
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

    package func executableURL(for descriptor: LanguageProviderDescriptor) -> URL? {
        candidates(for: descriptor).first?.executableURL
    }

    package func executableVerificationState(
        for descriptor: LanguageProviderDescriptor
    ) -> LanguageServerExecutableVerificationState {
        guard let candidate = candidates(for: descriptor).first else {
            return .unavailable
        }
        let arguments = descriptor.languageServerLaunch?.validationArguments ?? []
        guard !arguments.isEmpty else { return .foundUnverified }
        let key = ExecutableValidationKey(
            executablePath: candidate.executableURL.standardizedFileURL.path,
            arguments: arguments
        )
        return validationCache[key]?.didExecute == true ? .executableVerified : .unavailable
    }

    package func setCustomExecutablePath(
        _ path: String,
        for descriptor: LanguageProviderDescriptor
    ) async throws {
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
        validatedCandidates[descriptor.id] = nil
        let candidate = RuntimeToolCandidate(
            command: descriptor.languageServerLaunch?.executableNames.first ?? descriptor.id,
            executableURL: executableURL,
            source: .custom,
            detail: "Lithe override"
        )
        let validation = await validate(candidate, for: descriptor)
        guard validation.isUsable else {
            throw LanguageServerToolConfigurationError.executableValidationFailed(
                path: executableURL.path,
                message: validation.message
            )
        }
        customExecutablePaths[descriptor.id] = executableURL.path
        settingsStore.saveLanguageToolExecutablePaths(customExecutablePaths)
        await refreshCandidates(for: descriptor)
    }

    package func clearCustomExecutablePath(for providerID: String) {
        customExecutablePaths[providerID] = nil
        validatedCandidates[providerID] = nil
        settingsStore.saveLanguageToolExecutablePaths(customExecutablePaths)
    }

    package func installWithHomebrew(_ descriptor: LanguageProviderDescriptor) async {
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
        let runner = commandRunner
        let operationID = "lsp-install-\(descriptor.id)-\(UUID().uuidString)"
        let environment = runtimeService.languageToolProcessEnvironment()
        let result = await Task.detached(priority: .userInitiated) {
            runner.runLanguageToolCommand(
                operationID: operationID,
                executableURL: brewURL,
                arguments: ["install", formula],
                environment: environment,
                timeoutMilliseconds: 10 * 60 * 1_000
            )
        }.value

        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.succeeded {
            validationCache.removeAll()
            validatedCandidates[descriptor.id] = nil
            installationStates[descriptor.id] = .installed(
                output.isEmpty ? "brew install \(formula) completed." : output
            )
            await refreshCandidates(for: descriptor)
        } else {
            installationStates[descriptor.id] = .failed(
                output.isEmpty ? "brew install \(formula) failed with exit code \(result.exitCode)." : output
            )
        }
    }

    private func validate(
        _ candidate: RuntimeToolCandidate,
        for descriptor: LanguageProviderDescriptor
    ) async -> ExecutableValidationResult {
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
        let operationID = "lsp-validate-\(descriptor.id)-\(UUID().uuidString)"
        let runner = commandRunner
        let executableURL = candidate.executableURL
        let environment = runtimeService.languageToolProcessEnvironment()
        let result = await Task.detached(priority: .userInitiated) {
            runner.runLanguageToolCommand(
                operationID: operationID,
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                timeoutMilliseconds: 5_000
            )
        }.value
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
