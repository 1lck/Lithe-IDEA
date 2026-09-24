import Foundation

/// Coalesces chatty process reads before they cross into observable feature state.
///
/// Run and build processes can wake `FileHandle` for every small write. Forwarding
/// every wake-up makes the main actor publish and lay out the growing console once
/// per chunk. A bounded delay keeps interactive output responsive while the high
/// water mark prevents the native side from retaining an unbounded burst.
final class MacProcessOutputBatcher: @unchecked Sendable {
    static let defaultFlushDelay: TimeInterval = 0.1
    static let defaultHighWaterMarkBytes = 1_048_576

    private let queue = DispatchQueue(
        label: "com.openres.Lithe.process-output-batcher",
        qos: .userInitiated
    )
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let flushDelay: TimeInterval
    private let highWaterMarkBytes: Int
    private let deliver: @Sendable (String) -> Void

    private var pendingChunks: [String] = []
    private var pendingByteCount = 0
    private var scheduledFlush: DispatchWorkItem?
    private var scheduledFlushGeneration: UInt64 = 0
    private var acceptsOutput = true

    init(
        flushDelay: TimeInterval = MacProcessOutputBatcher.defaultFlushDelay,
        highWaterMarkBytes: Int = MacProcessOutputBatcher.defaultHighWaterMarkBytes,
        deliver: @escaping @Sendable (String) -> Void
    ) {
        self.flushDelay = flushDelay
        self.highWaterMarkBytes = max(1, highWaterMarkBytes)
        self.deliver = deliver
        queue.setSpecific(key: queueKey, value: 1)
    }

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, acceptsOutput else { return }
            pendingChunks.append(chunk)
            pendingByteCount += chunk.utf8.count
            if pendingByteCount >= highWaterMarkBytes {
                cancelScheduledFlush()
                flushOnQueue()
            } else {
                scheduleFlushIfNeeded()
            }
        }
    }

    /// Delivers everything accepted before this call and keeps the batcher open.
    func flush() {
        syncOnQueue {
            cancelScheduledFlush()
            flushOnQueue()
        }
    }

    /// Delivers the final batch and rejects callbacks racing with process teardown.
    func finish() {
        syncOnQueue {
            acceptsOutput = false
            cancelScheduledFlush()
            flushOnQueue()
        }
    }

    private func scheduleFlushIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard scheduledFlush == nil else { return }
        scheduledFlushGeneration &+= 1
        let generation = scheduledFlushGeneration
        let work = DispatchWorkItem { [weak self] in
            self?.runScheduledFlush(generation: generation)
        }
        scheduledFlush = work
        queue.asyncAfter(deadline: .now() + flushDelay, execute: work)
    }

    private func runScheduledFlush(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard generation == scheduledFlushGeneration else { return }
        scheduledFlush = nil
        flushOnQueue()
    }

    private func cancelScheduledFlush() {
        dispatchPrecondition(condition: .onQueue(queue))
        scheduledFlushGeneration &+= 1
        scheduledFlush?.cancel()
        scheduledFlush = nil
    }

    private func flushOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !pendingChunks.isEmpty else { return }
        let batch = pendingChunks.joined()
        pendingChunks.removeAll(keepingCapacity: true)
        pendingByteCount = 0
        deliver(batch)
    }

    private func syncOnQueue(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            operation()
        } else {
            queue.sync(execute: operation)
        }
    }
}
