import Foundation
import Testing
import LitheCoreContracts
@testable import Lithe

@Suite("Language server sync bridge")
struct LanguageServerSyncBridgeTests {
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
