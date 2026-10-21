import Foundation

protocol LogDirectoryProviding {
    var defaultLogDirectory: URL { get }
}

extension LogDirectoryProviding {
    /// Legacy application log retained for compatibility with older releases.
    /// Production module collection resolves the writer's effective directory
    /// through ApplicationLogging, including runtime fallback.
    var applicationLogFileURL: URL {
        defaultLogDirectory.appendingPathComponent("lithe.log", isDirectory: false)
    }
}
