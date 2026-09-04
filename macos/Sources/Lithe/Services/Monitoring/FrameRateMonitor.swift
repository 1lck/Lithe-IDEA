import Combine
import CoreVideo
import Foundation
import QuartzCore

/// Counts vsync callbacks that reach the main thread so a hitch shows up as a
/// lower FPS. The workbench must not observe this object; only the status-bar
/// label should subscribe.
@MainActor
final class FrameRateMonitor: ObservableObject {
    private final class CallbackState: @unchecked Sendable {
        private let lock = NSLock()
        private var pendingTime: CFTimeInterval?
        private var drainScheduled = false

        func enqueue(_ time: CFTimeInterval) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            pendingTime = time
            guard !drainScheduled else { return false }
            drainScheduled = true
            return true
        }

        func drain() -> CFTimeInterval? {
            lock.lock()
            defer { lock.unlock() }
            let time = pendingTime
            pendingTime = nil
            drainScheduled = false
            return time
        }
    }

    private(set) var framesPerSecond = 0

    var framesPerSecondText: String {
        "\(framesPerSecond) FPS"
    }

    private var displayLink: CVDisplayLink?
    private var framesInWindow: UInt64 = 0
    private var windowStartedAt: CFTimeInterval?
    private var lastAcceptedFrameAt: CFTimeInterval?
    private var displayedFramesPerSecond = -1
    private var pendingDisplayedFramesPerSecond: Int?
    private var pendingDisplayedSampleCount = 0
    private let sampleWindow: CFTimeInterval
    private let callbackState = CallbackState()

    init(sampleWindow: TimeInterval = 1.0) {
        self.sampleWindow = sampleWindow
    }

    deinit {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }

    func start() {
        guard displayLink == nil else { return }
        windowStartedAt = CACurrentMediaTime()
        lastAcceptedFrameAt = nil
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        displayLink = link
        let context = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { _, _, outputTime, _, _, context in
            guard let context else { return kCVReturnSuccess }
            // CVDisplayLink invokes the callback off-main. Keep the display's
            // host timestamp only as the coalescing token; the final metric is
            // timestamped when the main actor consumes the tick below.
            let hostTime = outputTime.pointee.hostTime
            let frequency = CVGetHostClockFrequency()
            let mediaTime = frequency > 0
                ? CFTimeInterval(Double(hostTime) / Double(frequency))
                : CACurrentMediaTime()
            Unmanaged<FrameRateMonitor>.fromOpaque(context).takeUnretainedValue()
                .enqueueCallback(at: mediaTime)
            return kCVReturnSuccess
        }, context)
        CVDisplayLinkStart(link)
    }

    #if DEBUG
    func recordFrameForTesting(at mediaTime: TimeInterval) {
        recordFrame(at: mediaTime)
    }
    #endif

    /// Collapse callbacks while the main actor is busy. Counting every queued
    /// callback would turn a hitch into a burst and incorrectly report the
    /// panel's nominal refresh rate.
    nonisolated private func enqueueCallback(at mediaTime: CFTimeInterval) {
        guard callbackState.enqueue(mediaTime) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.callbackState.drain() != nil else { return }
            // The metric is main-thread responsiveness: measure when this
            // tick is actually consumed, not when the display generated it.
            // A blocked UI therefore produces a real gap instead of a burst
            // of queued host timestamps that falsely reads as 60 FPS.
            self.recordFrame(at: CACurrentMediaTime())
        }
    }

    /// Display-link callbacks can pile up behind a hitch. Collapse ticks that
    /// land in the same frame so a stall is not hidden by a later burst.
    private func recordFrame(at mediaTime: CFTimeInterval) {
        if let lastAcceptedFrameAt, mediaTime - lastAcceptedFrameAt < 0.008 {
            return
        }
        lastAcceptedFrameAt = mediaTime
        let windowStart = windowStartedAt ?? mediaTime
        windowStartedAt = windowStart
        framesInWindow += 1
        let elapsed = mediaTime - windowStart
        guard elapsed >= sampleWindow else { return }

        let fps = Int((Double(framesInWindow) / elapsed).rounded())
        framesInWindow = 0
        windowStartedAt = mediaTime
        guard fps != displayedFramesPerSecond else {
            pendingDisplayedFramesPerSecond = nil
            pendingDisplayedSampleCount = 0
            return
        }
        // Near-refresh-rate values are especially sensitive to a single tick
        // crossing the sample-window boundary; low values should surface on
        // the first window so a real hitch is visible immediately.
        let requiresHysteresis = fps >= 50 && displayedFramesPerSecond >= 0
        if !requiresHysteresis {
            displayedFramesPerSecond = fps
            pendingDisplayedFramesPerSecond = nil
            pendingDisplayedSampleCount = 0
            framesPerSecond = fps
            objectWillChange.send()
            return
        }
        if pendingDisplayedFramesPerSecond == fps {
            pendingDisplayedSampleCount += 1
        } else {
            pendingDisplayedFramesPerSecond = fps
            pendingDisplayedSampleCount = 1
        }
        // Require two consecutive windows before changing the status label.
        // This filters single-tick boundary jitter without hiding sustained
        // stalls caused by a busy main thread.
        guard pendingDisplayedSampleCount >= 2 else { return }
        displayedFramesPerSecond = fps
        pendingDisplayedFramesPerSecond = nil
        pendingDisplayedSampleCount = 0
        framesPerSecond = fps
        objectWillChange.send()
    }
}
