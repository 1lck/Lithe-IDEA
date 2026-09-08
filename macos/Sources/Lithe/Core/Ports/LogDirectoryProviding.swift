import Foundation

protocol LogDirectoryProviding {
    var defaultLogDirectory: URL { get }
}

extension LogDirectoryProviding {
    /// The single application log file callers read, tail, or stage for
    /// export. Kept here so every layer resolves the same path instead of
    /// duplicating the "lithe.log" file name.
    var applicationLogFileURL: URL {
        defaultLogDirectory.appendingPathComponent("lithe.log", isDirectory: false)
    }
}
