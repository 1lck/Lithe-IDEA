import Foundation

struct DiagnosticCrashReports: Sendable {
    var files: [ApplicationLogFile] = []
    var status: [String] = []
}

/// macOS owns DiagnosticReports discovery and native report metadata. Returned
/// bytes have already passed through Core redaction, never raw report contents.
protocol CrashReportCollecting: Sendable {
    func collect(since: Date, until: Date) throws -> DiagnosticCrashReports
}
