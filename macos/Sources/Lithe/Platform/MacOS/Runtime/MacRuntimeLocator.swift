import Darwin
import Foundation

struct MacRuntimeLocator: RuntimeLocator {
    func environment() -> [String: String] {
        MacLoginShellEnvironment.shared.merged(ProcessInfo.processInfo.environment)
    }

    func defaultExecutableSearchPath() -> String? {
        let count = confstr(_CS_PATH, nil, 0)
        guard count > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: count)
        let written = confstr(_CS_PATH, &buffer, buffer.count)
        guard written > 0, written <= buffer.count else { return nil }
        return String(cString: buffer)
    }

    func isExecutable(at url: URL) -> Bool {
        // Directory execute permission allows traversal, not process launch.
        // Follow symlinks so linked toolchain homes are rejected as well.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }
}
