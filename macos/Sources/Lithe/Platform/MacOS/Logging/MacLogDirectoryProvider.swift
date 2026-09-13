import Foundation

// Note: macOS 日志目录的默认路径、持久化与失败回退见 .agents/notes/implemented/feature/2026-08-17-macos-log-directory-configuration.md
struct MacLogDirectoryProvider: LogDirectoryProviding {
    var defaultLogDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Lithe", isDirectory: true)
    }
}
