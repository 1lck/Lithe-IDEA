import Foundation

struct ResolvedRunExecutable: Sendable {
    let executableURL: URL
    let environment: [String: String]
}

struct RunExecutableResolutionError: LocalizedError, Equatable, Sendable {
    let message: String

    var errorDescription: String? { message }
}

struct RunToolchainMetadata: Equatable, Sendable {
    let version: String
    let vendor: String
}

protocol RunToolchainMetadataResolving: Sendable {
    func metadata(for executableURL: URL, toolchainType: String) -> RunToolchainMetadata
}

/// Application boundary for resolving a launch plan. Toolchain ids are an
/// open registry, but every id must have an explicit resolver; an unknown id
/// must never silently acquire Maven semantics.
@MainActor
protocol RunExecutableResolving: AnyObject {
    func resolve(
        _ plan: SharedLaunchPlan,
        projectURL: URL,
        options: RunOptions
    ) throws -> ResolvedRunExecutable
    func refreshCandidates(projectURL: URL) async
    func candidates(projectURL: URL) -> [ProjectToolchainCandidate]
}

extension RunExecutableResolving {
    func refreshCandidates(projectURL: URL) async {}
    func candidates(projectURL: URL) -> [ProjectToolchainCandidate] { [] }
}
