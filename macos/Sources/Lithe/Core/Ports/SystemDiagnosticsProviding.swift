import Foundation

/// Environment and performance facts gathered natively at diagnostic-bundle
/// export time. This is the native input to `RustCoreBridge.buildDiagnosticsManifest`;
/// the Rust Core never reads the filesystem or process table itself.
struct SystemDiagnosticsSnapshot: Codable, Sendable {
    let appVersion: String
    let osName: String
    let osVersion: String
    let cpuCoreCount: Int
    let memoryRSSBytes: Int64
    let diskFreeBytes: Int64

    private enum CodingKeys: String, CodingKey {
        case appVersion
        case osName
        case osVersion
        case cpuCoreCount
        case memoryRSSBytes = "memoryRssBytes"
        case diskFreeBytes
    }
}

protocol SystemDiagnosticsProviding: Sendable {
    /// `volumeURL` identifies the volume free space is reported for; callers
    /// pass the log directory so the figure matches where the bundle stages.
    func currentSnapshot(volumeURL: URL) -> SystemDiagnosticsSnapshot
}
