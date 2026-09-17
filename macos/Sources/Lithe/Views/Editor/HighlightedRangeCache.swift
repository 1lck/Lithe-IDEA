import Foundation

struct HighlightedRangeCache {
    private(set) var ranges: [NSRange] = []

    init(ranges: [NSRange] = []) {
        for range in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if let last = self.ranges.last, NSMaxRange(last) >= range.location {
                self.ranges[self.ranges.count - 1] = NSUnionRange(last, range)
            } else {
                self.ranges.append(range)
            }
        }
    }

    func contains(_ location: Int) -> Bool {
        let index = firstRangeEnding(after: location)
        return index < ranges.count && NSLocationInRange(location, ranges[index])
    }

    func intersects(_ range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        let index = firstRangeEnding(after: range.location)
        return index < ranges.count && ranges[index].location < NSMaxRange(range)
    }

    private func firstRangeEnding(after location: Int) -> Int {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if NSMaxRange(ranges[middle]) <= location { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }

    mutating func insert(_ range: NSRange) {
        guard range.length > 0 else { return }
        var merged = range
        var result: [NSRange] = []
        var didInsert = false

        for existing in ranges {
            if NSMaxRange(existing) < merged.location {
                result.append(existing)
            } else if NSMaxRange(merged) < existing.location {
                if !didInsert {
                    result.append(merged)
                    didInsert = true
                }
                result.append(existing)
            } else {
                merged = NSUnionRange(merged, existing)
            }
        }
        if !didInsert {
            result.append(merged)
        }
        ranges = result
    }

    func uncoveredRanges(in target: NSRange) -> [NSRange] {
        guard target.length > 0 else { return [] }
        let targetEnd = NSMaxRange(target)
        var cursor = target.location
        var uncovered: [NSRange] = []

        for existing in ranges {
            if NSMaxRange(existing) <= cursor { continue }
            if existing.location >= targetEnd { break }
            if existing.location > cursor {
                uncovered.append(NSRange(
                    location: cursor,
                    length: min(existing.location, targetEnd) - cursor
                ))
            }
            cursor = max(cursor, min(NSMaxRange(existing), targetEnd))
            if cursor >= targetEnd { break }
        }
        if cursor < targetEnd {
            uncovered.append(NSRange(location: cursor, length: targetEnd - cursor))
        }
        return uncovered
    }

    mutating func removeAll() {
        ranges.removeAll(keepingCapacity: true)
    }

    /// Keeps cached ranges valid after NSTextStorage applies an edit. Ranges
    /// crossing the edit are discarded; ranges after it are shifted by the
    /// UTF-16 length delta.
    mutating func applyEdit(replacedRange: NSRange, replacementLength: Int) {
        guard replacedRange.location != NSNotFound,
              replacedRange.location >= 0,
              replacedRange.length >= 0,
              replacementLength >= 0 else {
            removeAll()
            return
        }

        let editEnd = NSMaxRange(replacedRange)
        let delta = replacementLength - replacedRange.length
        ranges = ranges.compactMap { range in
            if NSMaxRange(range) > replacedRange.location && range.location < editEnd {
                return nil
            }
            if range.location >= editEnd {
                return NSRange(location: range.location + delta, length: range.length)
            }
            return range
        }
    }
}
