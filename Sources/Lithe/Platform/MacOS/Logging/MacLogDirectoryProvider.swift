import Foundation

struct MacLogDirectoryProvider: LogDirectoryProviding {
    var defaultLogDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Lithe", isDirectory: true)
    }
}
