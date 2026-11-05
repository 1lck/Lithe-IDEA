import Foundation
import LitheCoreContracts

/// One Core decision for a coalesced watcher path; native event flags and
/// workspace visibility remain owned by the platform watcher.
struct GitMetadataClassification: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable { case context, ignoreRule, metadata, ignored, other }
    let kind: Kind
    let indexOnly: Bool
}

struct RustGitMetadataClassifier: Sendable {
    private static let pageSize = 256
    let core: RustCoreBridge

    private struct Context: Encodable {
        let workspaceRoot: String
        let repositoryRoot: String
        let gitDirectory: String
        let gitCommonDirectory: String
        let ruleDirectories: [String] = []
    }
    private struct Request: Encodable { let context: Context; let paths: [String] }
    private struct Response: Decodable { let events: [GitMetadataClassification] }

    /// Before Git is discovered, keep watching the workspace marker so a
    /// newly initialized repository can rebuild its watch roots.
    func classify(paths: [String], configuration: DirectoryWatchConfiguration) -> Result<[GitMetadataClassification], RustCoreBridge.CoreCallError> {
        let repository = configuration.repositoryRoot ?? configuration.workspaceRoot
        let directory = configuration.gitDirectory ?? repository.appendingPathComponent(".git")
        let common = configuration.gitCommonDirectory ?? directory
        let context = Context(workspaceRoot: configuration.workspaceRoot.path,
            repositoryRoot: repository.path, gitDirectory: directory.path, gitCommonDirectory: common.path)
        var events: [GitMetadataClassification] = []
        events.reserveCapacity(paths.count)
        for offset in stride(from: 0, to: paths.count, by: Self.pageSize) {
            let page = Array(paths[offset..<min(offset + Self.pageSize, paths.count)])
            let result: Result<Response, RustCoreBridge.CoreCallError> = core.executeResult(
                command: "git.classifyMetadataChanges", payload: Request(context: context, paths: page))
            switch result {
            case .success(let response) where response.events.count == page.count:
                events.append(contentsOf: response.events)
            case .success:
                return .failure(.init(code: "invalid_response", message: "Invalid Git metadata classification response", details: nil))
            case .failure(let error):
                return .failure(error)
            }
        }
        return .success(events)
    }
}
