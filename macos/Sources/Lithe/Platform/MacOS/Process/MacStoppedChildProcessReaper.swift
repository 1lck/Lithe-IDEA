import Darwin
import Foundation

/// Reaps direct child processes after a platform-owned stop operation.
///
/// Some native terminal libraries send the termination signal themselves but
/// can miss their eventual `waitpid` callback. Keeping a second process source
/// prevents an exited debuggee from remaining as a zombie under Lithe.
final class MacStoppedChildProcessReaper: @unchecked Sendable {
    typealias Completion = @Sendable () -> Void

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "app.lithe.stopped-child-process-reaper",
        qos: .utility
    )
    private var sources: [pid_t: DispatchSourceProcess] = [:]
    private var completions: [pid_t: [Completion]] = [:]

    func reapWhenExited(
        _ processID: pid_t,
        completion: @escaping Completion = {}
    ) {
        guard processID > 0 else {
            completion()
            return
        }

        var waitStatus: Int32 = 0
        errno = 0
        let immediateResult = Darwin.waitpid(processID, &waitStatus, WNOHANG)
        if immediateResult == processID || (immediateResult == -1 && errno == ECHILD) {
            completion()
            return
        }

        let processSource = lock.withLock { () -> DispatchSourceProcess? in
            completions[processID, default: []].append(completion)
            guard sources[processID] == nil else { return nil }
            // A second stop may register while the first source still waits.
            // Never create and discard an inactive dispatch source for it.
            let processSource = DispatchSource.makeProcessSource(
                identifier: processID, eventMask: .exit, queue: queue
            )
            sources[processID] = processSource
            return processSource
        }
        guard let processSource else { return }

        // Retaining self until the event fires keeps reaping alive even when a
        // terminal session is closed immediately after stop().
        processSource.setEventHandler { [self] in
            reap(processID)
        }
        processSource.activate()
    }

    private func reap(_ processID: pid_t) {
        var waitStatus: Int32 = 0
        var waitResult: pid_t
        repeat {
            waitResult = Darwin.waitpid(processID, &waitStatus, 0)
        } while waitResult == -1 && errno == EINTR

        let state = lock.withLock { () -> (DispatchSourceProcess?, [Completion]) in
            let source = sources.removeValue(forKey: processID)
            let callbacks = completions.removeValue(forKey: processID) ?? []
            return (source, callbacks)
        }
        state.0?.cancel()
        state.1.forEach { $0() }
    }
}
