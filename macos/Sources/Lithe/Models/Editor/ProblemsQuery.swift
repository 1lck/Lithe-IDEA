import Foundation
import LitheModuleAPI

/// Problems tool-window order and grouping returned by Rust Core
/// (`lsp.problems.query`). Core owns filtering, severity order, natural file
/// order, and counts; the view only renders the returned groups.
struct ProblemsQueryResult: Equatable, Sendable {
    struct FileGroup: Equatable, Sendable {
        let fileURL: URL
        let diagnostics: [EditorDiagnostic]
    }

    let groups: [FileGroup]
    let errorCount: Int
    let warningCount: Int

    static let empty = ProblemsQueryResult(groups: [], errorCount: 0, warningCount: 0)

    var diagnostics: [EditorDiagnostic] { groups.flatMap(\.diagnostics) }
}

enum ProblemsQuery {
    /// Runs the shared query off the main actor. `displayPaths` maps each
    /// diagnostic file to its workspace-relative path, which decides file order.
    static func run(
        diagnostics: [EditorDiagnostic],
        severities: Set<DiagnosticSeverity>,
        displayPaths: [URL: String],
        logSink: (any LogSink)?
    ) -> ProblemsQueryResult {
        guard !diagnostics.isEmpty else { return .empty }
        struct Facts: Encodable {
            let fileKey: String
            let displayPath: String
            let line: Int
            let column: Int
            let severity: Int
            let message: String
            let source: String?
            let code: String?
        }
        struct Filter: Encodable { let severities: [Int] }
        struct Request: Encodable {
            let diagnostics: [Facts]
            let groupBy = "file"
            let sortBy = "severity"
            let filter: Filter
        }
        struct Counts: Decodable { let error: Int; let warning: Int }
        struct Group: Decodable { let indices: [Int] }
        struct Response: Decodable {
            let groups: [Group]
            let visibleCounts: Counts
        }
        let request = Request(
            diagnostics: diagnostics.map {
                Facts(fileKey: $0.fileURL.absoluteString,
                      displayPath: displayPaths[$0.fileURL] ?? $0.fileURL.path,
                      line: $0.line, column: $0.utf16Column, severity: $0.severity.rawValue,
                      message: $0.message, source: $0.source, code: $0.code)
            },
            filter: Filter(severities: severities.map(\.rawValue).sorted())
        )
        let result: Result<Response, RustCoreBridge.CoreCallError> = RustCoreBridge().executeResult(
            command: "lsp.problems.query", payload: request)
        switch result {
        case .success(let response):
            let groups = response.groups.compactMap { group -> ProblemsQueryResult.FileGroup? in
                let members = group.indices.compactMap { diagnostics.indices.contains($0) ? diagnostics[$0] : nil }
                guard let first = members.first else { return nil }
                return ProblemsQueryResult.FileGroup(fileURL: first.fileURL, diagnostics: members)
            }
            return ProblemsQueryResult(groups: groups, errorCount: response.visibleCounts.error,
                                       warningCount: response.visibleCounts.warning)
        case .failure(let error):
            logSink?.emit(AppCoreFallbackSelected(error: LogFailure(domain: "RustCore", code: error.code),
                                                  stage: "lsp.problems.query"))
            return .empty
        }
    }
}
