import LitheModuleAPI

/// Native opt-in machine protocol output for the existing performance tools.
/// Typed facts still enter LogSink; markers contain only controlled names and numeric measurements.
protocol PerformanceMarkerWriting: LogSink {
    func writePerformanceMarker(_ marker: String)
}
