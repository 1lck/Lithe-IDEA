import Foundation
import LitheGitModule

// Legacy fixture parser remains test-only; production receives Core documents.
package enum DiffParser {
    private struct Entry {
        let number: Int
        let text: String
    }

    package static func parse(_ patch: String) -> [DiffRow] {
        parseDocument(patch).rows
    }

    package static func parseDocument(_ patch: String) -> DiffDocument {
        var rows: [DiffRow] = []
        var oldLine = 0
        var newLine = 0
        var removed: [Entry] = []
        var added: [Entry] = []
        var currentHunkID: String?
        var currentHunkHeader = ""
        var currentHunkLines: [String] = []
        var fileHeaderLines: [String] = []
        var hunkRecords: [(id: String, header: String, lines: [String])] = []
        var hunkIndex = 0
        // Monotonic per-document counter that keeps DiffRowID unique even when
        // rows share a hunk and line numbers.
        var rowSequence = 0
        let hasTrailingNewline = patch.hasSuffix("\n")
        var patchLines = patch.components(separatedBy: "\n")
        if hasTrailingNewline {
            patchLines.removeLast()
        }

        func flushChanges() {
            let count = max(removed.count, added.count)
            guard count > 0 else { return }
            for index in 0..<count {
                let left = index < removed.count ? removed[index] : nil
                let right = index < added.count ? added[index] : nil
                let kind: DiffRowKind
                if left != nil && right != nil {
                    kind = .changed
                } else if left != nil {
                    kind = .removal
                } else {
                    kind = .addition
                }
                rows.append(DiffRow(
                    oldLine: left?.number,
                    newLine: right?.number,
                    left: left?.text,
                    right: right?.text,
                    kind: kind,
                    hunkID: currentHunkID,
                    sequence: rowSequence
                ))
                rowSequence += 1
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }

        func finishHunk() {
            guard let hunkID = currentHunkID else { return }
            flushChanges()
            hunkRecords.append((
                id: hunkID,
                header: currentHunkHeader,
                lines: currentHunkLines
            ))
            currentHunkID = nil
            currentHunkHeader = ""
            currentHunkLines.removeAll(keepingCapacity: true)
        }

        for line in patchLines {
            if line.hasPrefix("@@") {
                finishHunk()
                let hunkID = "hunk-\(hunkIndex)"
                hunkIndex += 1
                currentHunkID = hunkID
                currentHunkHeader = line
                currentHunkLines = fileHeaderLines + [line]
                if let ranges = parseHunkHeader(line) {
                    oldLine = ranges.old
                    newLine = ranges.new
                }
                rows.append(DiffRow(
                    oldLine: nil,
                    newLine: nil,
                    left: line,
                    right: nil,
                    kind: .information,
                    hunkID: hunkID,
                    sequence: rowSequence
                ))
                rowSequence += 1
            } else if line.hasPrefix("diff --git"), currentHunkID != nil {
                finishHunk()
                fileHeaderLines = [line]
            } else if currentHunkID == nil {
                fileHeaderLines.append(line)
            } else if line.hasPrefix("-") {
                currentHunkLines.append(line)
                removed.append(Entry(number: oldLine, text: String(line.dropFirst())))
                oldLine += 1
            } else if line.hasPrefix("+") {
                currentHunkLines.append(line)
                added.append(Entry(number: newLine, text: String(line.dropFirst())))
                newLine += 1
            } else if line.hasPrefix(" ") {
                flushChanges()
                currentHunkLines.append(line)
                rows.append(DiffRow(
                    oldLine: oldLine,
                    newLine: newLine,
                    left: String(line.dropFirst()),
                    right: nil,
                    kind: .context,
                    hunkID: currentHunkID,
                    sequence: rowSequence
                ))
                rowSequence += 1
                oldLine += 1
                newLine += 1
            } else if line.hasPrefix("\\ No newline") {
                currentHunkLines.append(line)
            } else {
                currentHunkLines.append(line)
            }
        }
        finishHunk()

        let hunks = hunkRecords.map { record in
            let patchText = record.lines.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
            return DiffHunk(
                id: record.id,
                header: record.header,
                patch: patchText
            )
        }
        return DiffDocument(rows: rows, hunks: hunks)
    }

    private static func parseHunkHeader(_ header: String) -> (old: Int, new: Int)? {
        let pattern = #"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let oldRange = Range(match.range(at: 1), in: header),
              let newRange = Range(match.range(at: 2), in: header),
              let old = Int(header[oldRange]),
              let new = Int(header[newRange]) else { return nil }
        return (old, new)
    }
}


package extension GitSavedPatchFile {
    init(file: GitCommitFile, version: String, base: String, patch: String) {
        self.init(file: file, version: version, base: base, patch: patch,
                  document: DiffParser.parseDocument(patch))
    }
}
