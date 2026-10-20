import Foundation

/// Opens Lithe again after this process exits, for "Restart Lithe" after
/// plugin changes. The request goes through the normal quit flow first, so
/// unsaved documents and running processes are confirmed as on any quit.
enum MacApplicationRelauncher {
    struct Command: Equatable {
        let executableURL: URL
        let arguments: [String]
    }

    /// Waits at most this long for the old process to exit. If it is still
    /// running, `open` only activates it instead of starting a second copy.
    static let exitWaitTenths = 300

    /// The helper polls the old process and then opens the app bundle, or
    /// starts the executable directly for an unbundled development build.
    static func command(bundleURL: URL, executableURL: URL?, processID: Int32) -> Command? {
        let target: String
        let mode: String
        if bundleURL.pathExtension == "app" {
            target = bundleURL.path
            mode = "bundle"
        } else if let executableURL {
            target = executableURL.path
            mode = "executable"
        } else {
            return nil
        }
        let script = """
        pid="$1"; target="$2"; mode="$3"; limit="$4"; i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$limit" ]; do sleep 0.1; i=$((i + 1)); done
        if [ "$mode" = bundle ]; then exec /usr/bin/open "$target"; fi
        "$target" </dev/null >/dev/null 2>&1 &
        """
        return Command(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "lithe-relaunch", "\(processID)", target, mode, "\(exitWaitTenths)"]
        )
    }

    /// Call as the last step of termination, after child processes have been
    /// ended, so the helper is not one of the processes Lithe cleans up.
    static func scheduleRelaunch(bundle: Bundle = .main) {
        guard let command = command(
            bundleURL: bundle.bundleURL,
            executableURL: bundle.executableURL,
            processID: ProcessInfo.processInfo.processIdentifier
        ) else { return }
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
