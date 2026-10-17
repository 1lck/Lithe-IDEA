import Darwin
import Foundation

// Note: 保留后代与 macOS 边界见 .agents/notes/proposed/architecture/2026-10-16-unified-child-process-lifecycle.md

/// Watches only retained identities, and persists descendants while their
/// ancestry is still observable. The owner keeps this alive through finalSweep.
///
/// Darwin does not support NOTE_TRACK/NOTE_CHILD (since macOS 10.5), and a
/// NOTE_FORK event does not expose the child PID. Consequently this is an
/// event-driven snapshot supplement, not a kernel containment boundary: a
/// double fork that reparents before observation still needs an inherited task
/// identity supplied at launch. Never compensate by retaining a whole Agent.
final class MacRetainedProcessTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var retained: Set<MacProcessIdentity> = []
    private var registered: Set<MacProcessIdentity> = []
    private let descriptor: Int32
    private let source: DispatchSourceRead?
    private let discovered: @Sendable ([MacProcessIdentity]) -> Void

    init(discovered: @escaping @Sendable ([MacProcessIdentity]) -> Void) {
        self.discovered = discovered
        descriptor = kqueue()
        if descriptor >= 0 {
            let descriptor = descriptor
            let source = DispatchSource.makeReadSource(
                fileDescriptor: descriptor,
                queue: DispatchQueue(label: "lithe.retained-process-tracker")
            )
            self.source = source
            source.setEventHandler { [weak self] in self?.consumeEvents() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
        } else {
            source = nil
            FileHandle.standardError.write(Data("Could not watch retained processes: \(errno)\n".utf8))
        }
    }

    deinit { source?.cancel() }

    /// Register roots before taking the snapshot, closing the ordinary
    /// snapshot-to-registration fork gap. Calling again also refreshes ancestry.
    @discardableResult
    func refresh(adding identities: [MacProcessIdentity] = []) -> Set<MacProcessIdentity> {
        let update: (Set<MacProcessIdentity>, [MacProcessIdentity]) = lock.withLock {
            let previous = retained
            retained.formUnion(identities)
            guard !retained.isEmpty else { return (retained, []) }
            registerLiveProcesses()
            retained = MacProcessScopeScanner.retainedIdentities(Array(retained), snapshot: MacProcessTable.snapshot())
            registerLiveProcesses()
            return (retained, Array(retained.subtracting(previous)))
        }
        if !update.1.isEmpty { discovered(update.1) }
        return update.0
    }

    private func registerLiveProcesses() {
        guard descriptor >= 0 else { return }
        for identity in retained where !registered.contains(identity) && MacProcessTable.isAlive(identity) {
            var change = kevent(
                ident: UInt(identity.processID), filter: Int16(EVFILT_PROC),
                flags: UInt16(EV_ADD | EV_CLEAR),
                fflags: UInt32(truncatingIfNeeded: NOTE_FORK) | UInt32(truncatingIfNeeded: NOTE_EXIT)
                    | UInt32(truncatingIfNeeded: NOTE_EXEC),
                data: 0, udata: nil
            )
            if kevent(descriptor, &change, 1, nil, 0, nil) == 0 {
                registered.insert(identity)
            } else if errno != ESRCH {
                FileHandle.standardError.write(Data("Could not watch retained PID \(identity.processID): \(errno)\n".utf8))
            }
        }
    }

    private func consumeEvents() {
        var events: [kevent] = Array(repeating: kevent(), count: 32)
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        let count = events.withUnsafeMutableBufferPointer {
            kevent(descriptor, nil, 0, $0.baseAddress, Int32($0.count), &timeout)
        }
        if count < 0, errno != EINTR {
            FileHandle.standardError.write(Data("Could not read retained process events: \(errno)\n".utf8))
        }
        refresh()
    }
}
