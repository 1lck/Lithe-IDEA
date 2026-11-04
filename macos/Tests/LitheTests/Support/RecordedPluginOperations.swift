import LitheModuleAPI

/// Records what a `PluginOperationReporter` delivers, on a clock that advances
/// `tick` milliseconds per reading, so an attempt that is begun and ended with
/// no other reading in between lasts exactly one tick.
@MainActor
final class RecordedPluginOperations {
    static let tick: UInt64 = 7
    private(set) var observations: [PluginOperationObservation] = []
    private var now: UInt64 = 0

    var reporter: PluginOperationReporter {
        PluginOperationReporter(
            record: { [self] in observations.append($0) },
            clock: { [self] in now += Self.tick; return now }
        )
    }

    /// A declarative language server start that failed at `stage` after one tick.
    static func languageServerStart(
        pluginID: String, failure stage: PluginOperationStage?, operationID: String
    ) -> PluginOperationObservation {
        PluginOperationObservation(
            pluginID: pluginID, operation: .languageServerStart, failure: stage,
            durationMs: tick, operationID: operationID
        )
    }
}
