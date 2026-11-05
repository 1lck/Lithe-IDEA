import Foundation
import LitheGitModule
import LitheModuleAPI

/// Side-by-side rows for two texts the caller already holds, produced by the
/// shared Rust Core comparison so every Lithe diff pane pairs lines the same way.
enum TextComparisonRows {
    /// Returns nil when Core rejects the comparison (for example an oversized side).
    static func rows(old oldText: String, current currentText: String, logSink: (any LogSink)? = nil) -> [DiffRow]? {
        var core = RustCoreBridge()
        core.coreLogSink = logSink
        return core.compareTexts(old: oldText, current: currentText)?.map(DiffRow.init)
    }
}
