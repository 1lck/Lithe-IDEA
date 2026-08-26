import Combine
import Testing
@testable import Lithe

@MainActor
struct FrameRateMonitorTests {
    @Test
    func publishesWhenDisplayedIntegerChangesAndIgnoresRepeats() {
        let monitor = FrameRateMonitor(sampleWindow: 0.5)
        monitor.recordFrameForTesting(at: 0)
        monitor.recordFrameForTesting(at: 0.5)
        #expect(monitor.framesPerSecond == 4)
        #expect(monitor.framesPerSecondText == "4 FPS")

        var publishCount = 0
        let observation = monitor.objectWillChange.sink { _ in publishCount += 1 }
        defer { observation.cancel() }

        monitor.recordFrameForTesting(at: 1.0)
        #expect(monitor.framesPerSecond == 2)
        #expect(publishCount == 1)

        monitor.recordFrameForTesting(at: 1.5)
        #expect(monitor.framesPerSecond == 2)
        #expect(publishCount == 1)
    }

    @Test
    func coalescesBurstsAfterAHitch() {
        let monitor = FrameRateMonitor(sampleWindow: 0.5)
        monitor.recordFrameForTesting(at: 0)
        monitor.recordFrameForTesting(at: 0.001)
        monitor.recordFrameForTesting(at: 0.002)
        monitor.recordFrameForTesting(at: 0.5)
        #expect(monitor.framesPerSecond == 4)
    }
}
