import Combine
import CoreVideo
import Foundation
import QuartzCore

/// Counts vsync callbacks that reach the main thread so a hitch shows up as a
/// lower FPS. The workbench must not observe this object; only the status-bar
/// label should subscribe.
@MainActor
final class FrameRateMonitor: ObservableObject {
    private(set) var framesPerSecond = 0

    var framesPerSecondText: String {
        "\(framesPerSecond) FPS"
    }

    private var displayLink: CVDisplayLink?
    private var framesInWindow: UInt64 = 0
    private var windowStartedAt: CFTimeInterval?
    private var lastAcceptedFrameAt: CFTimeInterval?
    private var displayedFramesPerSecond = -1
    private let sampleWindow: CFTimeInterval

    init(sampleWindow: TimeInterval = 0.5) {
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
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context in
            guard let context else { return kCVReturnSuccess }
            Task { @MainActor in
                Unmanaged<FrameRateMonitor>.fromOpaque(context).takeUnretainedValue()
                    .recordFrame(at: CACurrentMediaTime())
            }
            return kCVReturnSuccess
        }, context)
        CVDisplayLinkStart(link)
    }

    #if DEBUG
    func recordFrameForTesting(at mediaTime: TimeInterval) {
        recordFrame(at: mediaTime)
    }
    #endif

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
        guard fps != displayedFramesPerSecond else { return }
        displayedFramesPerSecond = fps
        framesPerSecond = fps
        objectWillChange.send()
    }
}
