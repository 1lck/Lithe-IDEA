import Foundation
import Darwin
import LitheModuleAPI

/// Reads only this application's reports in the user's DiagnosticReports store.
/// No data is written back to that store or to the application bundle.
struct MacCrashReportCollector: CrashReportCollecting {
    static let maximumReports = 5
    static let maximumReportBytes = 1024 * 1024
    let directory: URL
    let processName: String
    let bundleID: String
    let sink: (any LogSink)?
    private let core = RustCoreBridge()

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
         processName: String = ProcessInfo.processInfo.processName,
         bundleID: String = Bundle.main.bundleIdentifier ?? "", sink: (any LogSink)? = nil) {
        self.directory = directory; self.processName = processName
        self.bundleID = bundleID; self.sink = sink
    }

    func collect(since: Date, until: Date) throws -> DiagnosticCrashReports {
        var result = DiagnosticCrashReports()
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
            var candidates: [(URL, Date)] = []
            for url in urls where ["ips", "crash"].contains(url.pathExtension) {
                try Task.checkCancellation()
                // Apple's report filename is <process>_<timestamp> or <process>-<timestamp>.
                // Match the complete process/bundle prefix, never another app's substring.
                let name = url.deletingPathExtension().lastPathComponent
                let identities = [processName, bundleID].filter { !$0.isEmpty }
                guard identities.contains(where: { name.hasPrefix($0 + "_") || name.hasPrefix($0 + "-") }) else { continue }
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          let date = values.contentModificationDate, date >= since, date <= until else { continue }
                    candidates.append((url, date))
                } catch { skipped(error, status: "crash metadata unreadable", result: &result) }
            }
            candidates.sort { $0.1 == $1.1 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.1 > $1.1 }
            for (url, _) in candidates.prefix(Self.maximumReports) {
                try Task.checkCancellation()
                do {
                    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
                    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    defer { do { try handle.close() } catch { skipped(error, status: "crash close failed", result: &result) } }
                    let bytes = try handle.read(upToCount: Self.maximumReportBytes) ?? Data()
                    try Task.checkCancellation()
                    let redacted = try core.redactDiagnosticText(String(decoding: bytes, as: UTF8.self)).get().redacted
                    // Stable opaque filenames avoid leaking source report filenames.
                    result.files.append(.init(relativePath: "crash/report-\(result.files.count + 1).\(url.pathExtension)", data: Data(redacted.utf8)))
                    if try handle.seekToEnd() > UInt64(Self.maximumReportBytes) { result.status.append("crash report truncated at \(Self.maximumReportBytes) bytes") }
                } catch is CancellationError { throw CancellationError() }
                catch { skipped(error, status: "crash report unreadable", result: &result) }
            }
            if candidates.count > Self.maximumReports { result.status.append("crash reports limited to \(Self.maximumReports)") }
        } catch is CancellationError { throw CancellationError() }
        // log-exempt: 预期的缺失：从未崩溃过的账户没有 DiagnosticReports 目录
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return result }
        catch { skipped(error, status: "crash directory unreadable", result: &result) }
        return result
    }

    private func skipped(_ error: Error, status: String, result: inout DiagnosticCrashReports) {
        result.status.append(status)
        sink?.emit(AppDiagnosticsCrashSkipped(error: error))
    }
}
