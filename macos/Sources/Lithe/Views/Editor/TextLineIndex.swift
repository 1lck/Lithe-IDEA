import Foundation

struct TextLineIndex {
    var textLength: Int
    var starts: [Int]

    init(source: NSString) {
        textLength = source.length
        var starts = [0]
        if source.length > 0 {
            for index in 0..<source.length {
                let character = source.character(at: index)
                if character == 10 {
                    starts.append(index + 1)
                } else if character == 13,
                          (index + 1 == source.length || source.character(at: index + 1) != 10) {
                    starts.append(index + 1)
                }
            }
        }
        self.starts = starts
    }

    /// Shift line starts after a single-line insert/delete. Returns false when
    /// the replaced range crossed a line break and the index must be rebuilt.
    mutating func applySingleLineEdit(replacedRange: NSRange, insertedLength: Int) -> Bool {
        let replacedEnd = NSMaxRange(replacedRange)
        if starts.contains(where: { $0 > replacedRange.location && $0 <= replacedEnd }) {
            return false
        }
        let delta = insertedLength - replacedRange.length
        guard delta != 0 else { return true }
        textLength = max(0, textLength + delta)
        for index in starts.indices where starts[index] > replacedRange.location {
            starts[index] += delta
        }
        return true
    }

    var lineCount: Int {
        guard textLength > 0, starts.last == textLength else { return starts.count }
        return max(1, starts.count - 1)
    }

    func characterOffset(forLine line: Int) -> Int {
        starts[min(max(0, line), starts.count - 1)]
    }

    func lineNumber(at location: Int) -> Int {
        let safeLocation = min(max(0, location), textLength)
        var lowerBound = 0
        var upperBound = starts.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if starts[midpoint] <= safeLocation {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return max(0, lowerBound - 1)
    }

    func lineRange(forLine line: Int) -> NSRange {
        let safeLine = min(max(0, line), starts.count - 1)
        let start = starts[safeLine]
        let end = safeLine + 1 < starts.count ? starts[safeLine + 1] : textLength
        return NSRange(location: start, length: max(0, end - start))
    }
}
