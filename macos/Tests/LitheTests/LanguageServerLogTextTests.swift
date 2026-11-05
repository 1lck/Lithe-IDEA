import Foundation
import Testing
@testable import Lithe

@Suite("LSP Logs console text")
@MainActor
struct LanguageServerLogTextTests {
    private typealias Record = RustCoreBridge.LogQueryRecord

    private func record(_ seq: UInt64, path: String = "lsp/a.jsonl", msg: String? = nil,
                        fields: [String: String] = [:]) -> Record {
        Record(line: "", channel: "lsp/example", lineNumber: Int(seq), foldKey: "", epochMs: 1_700_000_000_000,
               opOffsetMs: nil, relativePath: path, ts: "2026-11-04T00:00:00.\(seq)Z", level: "INFO", seq: seq,
               event: "lsp.server.stderr", op: nil, msg: msg ?? "line \(seq)", fields: fields)
    }

    /// Counts formatter calls; the count stands in for the work a publish costs.
    private final class Formatter {
        var calls = 0
        @MainActor func line(_ record: Record) -> String {
            calls += 1
            return Self.expected([record])
        }
        static func expected(_ records: [Record]) -> String {
            records.map { "\($0.relativePath)#\($0.seq) \($0.msg)\n" }.joined()
        }
    }

    @Test func liveBatchesFormatOnlyTheRecordsTheyAppend() {
        let formatter = Formatter()
        let text = LanguageServerLogText(format: formatter.line)
        let cap = UInt64(LogWindowModel.maximumRecords)
        let full = (1...cap).map { record($0) }
        #expect(text.update(full) == Formatter.expected(full))
        #expect(formatter.calls == full.count)

        // Status, summary and selection publishes carry the same records.
        formatter.calls = 0
        #expect(text.update(full) == Formatter.expected(full))
        #expect(formatter.calls == 0)

        // A full buffer evicts from the front as a batch appends at the end.
        let next = Array(full.dropFirst(10)) + (1...10).map { record(cap + $0) }
        #expect(text.update(next) == Formatter.expected(next))
        #expect(formatter.calls == 10)

        // A batch below the cap only appends.
        formatter.calls = 0
        let grown = next + [record(cap + 11)]
        #expect(text.update(grown) == Formatter.expected(grown))
        #expect(formatter.calls == 1)
    }

    @Test func anyOtherChangeRebuildsTheText() {
        let text = LanguageServerLogText(format: Formatter().line)
        _ = text.update((1...5).map { record($0) })

        // A new query with the same count but other records.
        let replaced = (1...5).map { record($0, path: "lsp/b.jsonl") }
        #expect(text.update(replaced) == Formatter.expected(replaced))

        // A record dropped from the middle is not an eviction.
        let gapped = [replaced[0]] + replaced[2...]
        #expect(text.update(gapped) == Formatter.expected(gapped))

        // A new query that shares the first record but not the rest.
        let diverged = [gapped[0], record(99, path: "lsp/b.jsonl")]
        #expect(text.update(diverged) == Formatter.expected(diverged))

        // "Clear View" empties the buffer; the next batch starts a fresh text.
        #expect(text.update([]) == "")
        let after = [record(100)]
        #expect(text.update(after) == Formatter.expected(after))
    }

    @Test func evictionKeepsMultiByteLinesIntact() {
        let text = LanguageServerLogText()
        let records = [record(1, msg: "服务器已启动 🚀"), record(2, msg: "e\u{301}"), record(3, msg: "done")]
        _ = text.update(records)
        let next = Array(records.dropFirst(2)) + [record(4, msg: "第四行")]
        #expect(text.update(next) == next.map(LanguageServerLogText.line).joined())
    }

    @Test func defaultLineShowsLevelTimeMessageAndSortedFields() {
        let value = record(7, msg: "exited", fields: ["status": "1", "pid": "42"])
        let time = Date(timeIntervalSince1970: 1_700_000_000).formatted(date: .omitted, time: .standard)
        #expect(LanguageServerLogText.line(value) == "[INFO] \(time) exited\npid=42 status=1\n")
        #expect(LanguageServerLogText.line(record(8, msg: "ready")) == "[INFO] \(time) ready\n")
    }
}
