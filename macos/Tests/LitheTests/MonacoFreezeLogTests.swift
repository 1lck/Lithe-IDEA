import Testing
import LitheModuleAPI
@testable import Lithe

@Suite("Editor freeze diagnostic evidence")
@MainActor
struct MonacoFreezeLogTests {
    @Test(arguments: [false, true])
    func mismatchRetainsTheSameSnapshotCountersAsSuccess(matches: Bool) throws {
        let sink = TypedLogRecorder()
        var span = EditorSyncFreezeSpan.begin(document: LogSegment("document-1")!, revision: 5, emit: sink.emit)
        MonacoWorkbenchSession.completeFreezeLog(&span, matches: matches, barrierDrained: false,
            browserRevision: 6, inputPasses: 2, modelVersion: 9, nativeRevision: 7, nativeLength: 31,
            pendingEdits: 3, snapshotRevision: 5, snapshotLength: 29)
        let event = try #require(sink.events.last)
        #expect(type(of: event).id == (matches ? "editor.sync.freeze.finished" : "editor.sync.freeze.failed"))
        for (key, expected) in ["revision": 5, "browser_revision": 6, "input_passes": 2,
            "model_version": 9, "native_revision": 7, "native_utf16_length": 31,
            "pending_edits": 3, "snapshot_revision": 5, "snapshot_utf16_length": 29] {
            if case .int(let value) = event.fields[key] { #expect(value == expected) }
            else { Issue.record("Missing freeze counter: \(key)") }
        }
        if case .bool(let drained) = event.fields["barrier_drained"] { #expect(!drained) }
        else { Issue.record("Missing barrier state") }
    }
}
