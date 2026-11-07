import Foundation

struct TerminalLinkLocation: Equatable, Sendable {
    let url: URL
    let line: Int?
    let column: Int?
}

enum TerminalLinkTarget: Equatable, Sendable { case file(TerminalLinkLocation); case external(URL) }

extension RustCoreBridge {
    /// Core interprets the link text (location suffix, `file://`, `~`, relative paths).
    /// Whether the file exists is a native fact, checked here after Core has named the path.
    func terminalLinkTarget(
        _ rawLink: String,
        relativeTo directory: URL,
        homeDirectory: URL,
        fileExists: (URL) -> Bool
    ) -> TerminalLinkTarget? {
        struct Request: Encodable {
            let texts: [String]
            let baseDirectory: String
            let homeDirectory: String
        }
        struct Target: Decodable {
            let kind: String
            let path: String?
            let line: Int?
            let column: Int?
            let url: String?
        }
        struct Response: Decodable { let targets: [Target?] }
        let result: Result<Response, CoreCallError> = executeResult(
            command: "terminal.parseLinkTarget",
            payload: Request(
                texts: [rawLink],
                baseDirectory: directory.path,
                homeDirectory: homeDirectory.path
            )
        )
        guard case .success(let response) = result, let target = response.targets.first ?? nil else { return nil }
        switch target.kind {
        case "external":
            return target.url.flatMap(URL.init(string:)).map(TerminalLinkTarget.external)
        case "file":
            guard let path = target.path else { return nil }
            let url = URL(fileURLWithPath: path)
            guard fileExists(url) else { return nil }
            return .file(TerminalLinkLocation(url: url, line: target.line, column: target.column))
        default:
            return nil
        }
    }
}
