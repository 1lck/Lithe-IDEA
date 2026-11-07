import Combine
import Foundation
import Testing
@testable import Lithe

@MainActor
@Suite("Debug performance sampling", .serialized)
struct DebugPerformanceSamplingTests {
    @Test func collapseSwitchAndStopCancelTheirStreamsAndRejectStaleSamples() async throws {
        let sampler = ControlledPerformanceSampler()
        defer { sampler.finishAll() }
        let feature = DebugPerformanceFeatureModel(sampler: sampler)
        defer { feature.setVisible(false) }
        let first = UUID(), second = UUID()
        for (id, pid) in [(first, Int32(101)), (second, 102)] {
            feature.register(DebugPerformanceTarget(processID: pid), sessionID: id)
        }
        feature.select(sessionID: first, isActive: true)
        feature.setVisible(true)
        #expect(await sampler.started[0].waitUntilOpen())
        let received = TestGate()
        let subscription = feature.$samples.sink { if $0.last?.timestamp == 1 { received.open() } }
        defer { subscription.cancel() }
        sampler.yield(sample(1), at: 0)
        #expect(await received.waitUntilOpen())
        feature.setVisible(false)
        #expect(await sampler.terminated[0].waitUntilOpen())
        #expect(!feature.isSampling)
        feature.setVisible(true)
        #expect(await sampler.started[1].waitUntilOpen())
        feature.select(sessionID: second, isActive: true)
        #expect(await sampler.terminated[1].waitUntilOpen())
        #expect(await sampler.started[2].waitUntilOpen())
        let switched = TestGate()
        let nextSubscription = feature.$samples.sink { if $0.last?.timestamp == 3 { switched.open() } }
        defer { nextSubscription.cancel() }
        sampler.yield(sample(99), at: 1)
        sampler.yield(sample(3), at: 2)
        #expect(await switched.waitUntilOpen())
        #expect(feature.samples.map(\.timestamp) == [3])
        feature.select(sessionID: second, isActive: false)
        #expect(await sampler.terminated[2].waitUntilOpen())
        #expect(feature.samples.map(\.timestamp) == [3])
    }

    @Test func historyIsBoundedAndSamplingErrorsBecomeVisible() async throws {
        let sampler = ControlledPerformanceSampler()
        defer { sampler.finishAll() }
        let feature = DebugPerformanceFeatureModel(sampler: sampler)
        defer { feature.setVisible(false) }
        let id = UUID()
        feature.register(DebugPerformanceTarget(processID: 101), sessionID: id)
        feature.select(sessionID: id, isActive: true)
        feature.setVisible(true)
        #expect(await sampler.started[0].waitUntilOpen())
        let received = TestGate()
        let subscription = feature.$samples.sink { if $0.last?.timestamp == 604 { received.open() } }
        defer { subscription.cancel() }
        for value in 0...604 { sampler.yield(sample(Double(value)), at: 0) }
        #expect(await received.waitUntilOpen())
        #expect(feature.samples.count == 600)
        #expect(feature.samples.first?.timestamp == 5)
        let failed = TestGate()
        let errorSubscription = feature.$errorMessage.sink { if $0 == "fixture failure" { failed.open() } }
        defer { errorSubscription.cancel() }
        sampler.fail(at: 0)
        #expect(await failed.waitUntilOpen())
        #expect(!feature.isSampling)
    }

    @Test func replacingTheProcessInTheSameDAPSessionClearsItsOldTimeline() async {
        let sampler = ControlledPerformanceSampler()
        defer { sampler.finishAll() }
        let feature = DebugPerformanceFeatureModel(sampler: sampler)
        defer { feature.setVisible(false) }
        let id = UUID()
        let first = DebugPerformanceTarget(processID: 101)
        feature.register(first, sessionID: id)
        feature.select(sessionID: id, isActive: true)
        feature.setVisible(true)
        #expect(await sampler.started[0].waitUntilOpen())
        let received = TestGate()
        let subscription = feature.$samples.sink { if $0.last?.timestamp == 100 { received.open() } }
        defer { subscription.cancel() }
        sampler.yield(sample(100), at: 0)
        #expect(await received.waitUntilOpen())
        feature.register(first, sessionID: id)
        #expect(sampler.streamCount == 1)
        feature.register(DebugPerformanceTarget(processID: 102), sessionID: id)
        #expect(feature.samples.isEmpty)
        #expect(await sampler.terminated[0].waitUntilOpen())
        #expect(await sampler.started[1].waitUntilOpen())
        let restarted = TestGate()
        let nextSubscription = feature.$samples.sink { if $0.last?.timestamp == 1 { restarted.open() } }
        defer { nextSubscription.cancel() }
        sampler.yield(sample(1), at: 1)
        #expect(await restarted.waitUntilOpen())
        #expect(feature.samples.map(\.timestamp) == [1])
    }

    @Test func destroyingTheFeatureCancelsItsOwnedSampler() async {
        let sampler = ControlledPerformanceSampler()
        defer { sampler.finishAll() }
        var feature: DebugPerformanceFeatureModel? = DebugPerformanceFeatureModel(sampler: sampler)
        let id = UUID()
        feature?.register(DebugPerformanceTarget(processID: 101), sessionID: id)
        feature?.select(sessionID: id, isActive: true)
        feature?.setVisible(true)
        #expect(await sampler.started[0].waitUntilOpen())
        weak var released = feature
        feature = nil
        #expect(released == nil)
        #expect(await sampler.terminated[0].waitUntilOpen())
    }

    @Test func anUnknownTargetDoesNotPretendToSample() {
        let feature = DebugPerformanceFeatureModel(sampler: nil)
        feature.select(sessionID: UUID(), isActive: true)
        feature.setVisible(true)
        #expect(!feature.isSampling)
        #expect(feature.errorMessage == nil)
        #expect(feature.samples.isEmpty)
    }

    @Test func nativeCPUConvertsMachTicksBeforeCalculatingPercentages() {
        #expect(MacProcessMemorySampler.nanoseconds(ticks: 24_000_000, numerator: 125, denominator: 3) == 1_000_000_000)
        #expect(MacProcessMemorySampler.nanoseconds(ticks: 1_000_000_000, numerator: 1, denominator: 1) == 1_000_000_000)
        #expect(MacProcessMemorySampler.nanoseconds(ticks: UInt64.max, numerator: 125, denominator: 3) == UInt64.max)
    }

    @Test func testProcessTreeCPUHandlesForksExitAndPIDReuse() {
        typealias CPU = MacProcessTreePerformanceSampler.CPU
        let previous: [Int32: CPU] = [1: CPU(nanoseconds: 500, startedSeconds: 1, startedMicroseconds: 0),
            2: CPU(nanoseconds: 900, startedSeconds: 2, startedMicroseconds: 0)]
        let current: [Int32: CPU] = [1: CPU(nanoseconds: 700, startedSeconds: 1, startedMicroseconds: 0),
            2: CPU(nanoseconds: 100, startedSeconds: 3, startedMicroseconds: 0),
            3: CPU(nanoseconds: 200, startedSeconds: 3, startedMicroseconds: 0)]
        #expect(MacProcessTreePerformanceSampler.cpuPercent(previous: previous, current: current,
            elapsed: 1000, processors: 2) == 25)
        #expect(MacProcessTreePerformanceSampler.cpuPercent(previous: current, current: [:],
            elapsed: 1000, processors: 2) == 0)
        #expect(MacProcessTreePerformanceSampler.cpuPercent(previous: [:], current: current,
            elapsed: 0, processors: 2) == nil)
    }

    private func sample(_ timestamp: Double) -> DebugPerformanceSample {
        DebugPerformanceSample(timestamp: timestamp, cpuPercent: 1, memoryUsedBytes: 10, memoryCapacityBytes: 20)
    }
}

private final class ControlledPerformanceSampler: DebugPerformanceSampling, @unchecked Sendable {
    let started = (0..<3).map { _ in TestGate() }
    let terminated = (0..<3).map { _ in TestGate() }
    private let lock = NSLock()
    private var streams: [AsyncThrowingStream<DebugPerformanceSample, Error>.Continuation] = []

    func samples(for target: DebugPerformanceTarget) -> AsyncThrowingStream<DebugPerformanceSample, Error> {
        let pair = AsyncThrowingStream<DebugPerformanceSample, Error>.makeStream()
        let index = lock.withLock { let index = streams.count; streams.append(pair.continuation); return index }
        pair.continuation.onTermination = { [gate = terminated[index]] _ in gate.open() }
        started[index].open()
        return pair.stream
    }
    var streamCount: Int { lock.withLock { streams.count } }
    func yield(_ sample: DebugPerformanceSample, at index: Int) { lock.withLock { streams[index] }.yield(sample) }
    func fail(at index: Int) { lock.withLock { streams[index] }.finish(throwing: DebugPerformanceError.unavailable("fixture failure")) }
    func finishAll() { lock.withLock { streams }.forEach { $0.finish() } }
}
