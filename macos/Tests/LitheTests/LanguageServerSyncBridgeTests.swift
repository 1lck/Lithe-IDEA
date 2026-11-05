import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

@Suite("Language server sync bridge")
struct LanguageServerSyncBridgeTests {
    @Test(.enabled(if: RustCoreBridge().isAvailable, "Requires the linked Rust Core integration library"))
    func filePathsUseSharedURIContractInsideSyncRequests() throws {
        struct Request: Encodable { let path: String; let platform = "posix" }
        struct Response: Decodable { let uri: String }
        let core = RustCoreBridge()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/lsp/document-uri-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try #require(fixture["cases"] as? [[String: Any]])
        for item in cases where item["platform"] as? String == "posix" {
            guard let path = item["path"] as? String, let expected = item["uri"] as? String else { continue }
            let response: Response = try core.executeResult(command: "lsp.documentUri", payload: Request(path: path)).get()
            #expect(response.uri == expected)
        }
        let result = core.lspSyncDocument(
            sessionID: "uri-bridge-test-missing-session",
            fileURL: URL(fileURLWithPath: "/work/A#B?.java"), languageID: "java", text: ""
        )
        switch result {
        case .success: Issue.record("A nonexistent session must not accept a document")
        case .failure(let error): #expect(error.message == "Unknown language-server session.")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_RUN_JAVA_DEBUG_INTEGRATION"] == "1"))
    func incrementalPositionsReachCoreSessionLookup() throws {
        let core = RustCoreBridge()
        try #require(core.isAvailable)
        // A missing session avoids launching a process while exercising the real
        // Swift encoder and Rust decoder. Bad position keys fail before lookup.
        let result = core.lspSyncDocument(
            sessionID: "sync-bridge-test-missing-session",
            fileURL: URL(fileURLWithPath: "/in-memory/Probe.java"),
            languageID: "java", text: "class Probe {}",
            changes: [.init(start: .init(line: 1, utf16Column: 4),
                            end: .init(line: 2, utf16Column: 7), text: "😀")]
        )
        switch result {
        case .success:
            Issue.record("A nonexistent session must not accept document edits")
        case .failure(let error):
            #expect(error.message == "Unknown language-server session.")
        }
    }
}
