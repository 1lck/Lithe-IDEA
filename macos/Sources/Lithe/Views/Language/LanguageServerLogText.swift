import Foundation

/// Console text for the editor-area "LSP Logs" tab, kept in step with the
/// record buffer one record at a time.
///
/// A live batch appends records to the end of `LogWindowModel.state.records`
/// and, once the buffer holds `LogWindowModel.maximumRecords`, evicts as many
/// from the front. Other publishes (status, live summary, selection) leave the
/// records as they are. Formatting only the appended records and cutting the
/// evicted lines off the front keeps a batch's cost proportional to the batch,
/// not to the buffer. Any other change, such as a new query or a clear,
/// rebuilds the text once.
@MainActor
final class LanguageServerLogText: ObservableObject {
    typealias Record = RustCoreBridge.LogQueryRecord

    /// The identity `LogWindowModel.recordID` uses, and the UTF-8 length of the
    /// record's line in `text`. The line itself lives only in `text`.
    private struct Line {
        let relativePath: String
        let seq: UInt64
        let ts: String
        let bytes: Int

        func shows(_ record: Record) -> Bool {
            seq == record.seq && ts == record.ts && relativePath == record.relativePath
        }
    }

    private static let time = Date.FormatStyle(date: .omitted, time: .standard)
    private let format: @MainActor (Record) -> String
    private var lines: [Line] = []
    private(set) var text = ""

    init(format: @escaping @MainActor (Record) -> String = LanguageServerLogText.line) {
        self.format = format
    }

    /// One record as the console shows it. Level, time and field keys are
    /// structured identifiers (the shared console colors the level prefix);
    /// upstream messages and field values are shown unchanged.
    static func line(_ record: Record) -> String {
        let time = Date(timeIntervalSince1970: TimeInterval(record.epochMs) / 1000).formatted(Self.time)
        let fields = record.fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return "[\(record.level)] \(time) \(record.msg)\(fields.isEmpty ? "" : "\n" + fields)\n"
    }

    /// Returns the text for `records`, reusing the lines of records it already shows.
    func update(_ records: [Record]) -> String {
        // The records already shown must survive as one run at the front, after
        // the evicted ones; anything else is a new buffer.
        guard let first = records.first,
              let evicted = lines.firstIndex(where: { $0.shows(first) }),
              records.count >= lines.count - evicted,
              zip(lines[evicted...], records).allSatisfy({ $0.shows($1) })
        else { return rebuild(records) }
        if evicted > 0 {
            // Every line ends with a newline, so the cut lands on a character boundary.
            let bytes = lines[..<evicted].reduce(0) { $0 + $1.bytes }
            text.removeSubrange(text.startIndex..<text.utf8.index(text.startIndex, offsetBy: bytes))
            lines.removeFirst(evicted)
        }
        for record in records[lines.count...] { append(record) }
        return text
    }

    private func rebuild(_ records: [Record]) -> String {
        lines.removeAll(keepingCapacity: true)
        text = ""
        for record in records { append(record) }
        return text
    }

    private func append(_ record: Record) {
        let line = format(record)
        lines.append(Line(relativePath: record.relativePath, seq: record.seq, ts: record.ts, bytes: line.utf8.count))
        text += line
    }
}
