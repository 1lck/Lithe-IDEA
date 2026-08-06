import Foundation

struct MarkdownScrollPosition: Equatable {
    enum Source: Equatable {
        case editor
        case preview
    }

    private(set) var ratio = 0.0
    private(set) var source: Source?
    private(set) var revision: UInt64 = 0

    @discardableResult
    mutating func update(ratio: Double, source: Source) -> Bool {
        let normalizedRatio = min(1, max(0, ratio.isFinite ? ratio : 0))
        guard self.source != source || abs(self.ratio - normalizedRatio) > 0.0005 else {
            return false
        }

        self.ratio = normalizedRatio
        self.source = source
        revision &+= 1
        return true
    }
}

enum MarkdownScrollMetrics {
    static func ratio(offset: Double, contentHeight: Double, viewportHeight: Double) -> Double {
        let extent = max(0, contentHeight - viewportHeight)
        guard extent > 0 else { return 0 }
        return min(1, max(0, offset / extent))
    }

    static func offset(ratio: Double, contentHeight: Double, viewportHeight: Double) -> Double {
        let extent = max(0, contentHeight - viewportHeight)
        return min(1, max(0, ratio.isFinite ? ratio : 0)) * extent
    }
}
