import Combine
import Foundation
import Testing
@testable import Lithe

@MainActor
@Suite("Test JVM performance lifecycle", .serialized)
struct TestJVMPerformanceFeatureTests {
    @Test func workerExitStopsRecordingAndSelectsTheNextWorkerWithoutMixingRuns() async throws {
        let provider = ControlledTestJVMPerformance()
        let feature = TestJVMPerformanceFeatureModel(sampler: nil, provider: provider)
        defer { feature.update(runID: nil, processID: nil, isRunning: false, isJava: true); provider.finish() }
        feature.setVisible(true)
        let run = UUID()
        feature.update(runID: run, processID: 10, isRunning: true, isJava: true)
        #expect(await provider.started.waitUntilOpen())
        let first = provider.worker(11), second = provider.worker(12)
        let selected = TestGate()
        let selection = feature.$selectedProcess.sink { if $0 == first { selected.open() } }
        defer { selection.cancel() }
        provider.yield([first])
        #expect(await selected.waitUntilOpen())
        #expect(feature.canStartRecording)
        let recording = TestGate()
        let subscription = feature.$isRecording.sink { if $0 { recording.open() } }
        defer { subscription.cancel() }
        feature.startRecording()
        #expect(await recording.waitUntilOpen())
        feature.setVisible(false)
        #expect(!provider.terminated.isOpen, "An explicit recording keeps discovery alive while hidden")
        provider.yield([second])
        #expect(await provider.stopping.waitUntilOpen())
        #expect(!feature.canStartRecording)
        let stopped = TestGate()
        let stopSubscription = feature.$isBusy.sink { if !$0 { stopped.open() } }
        defer { stopSubscription.cancel() }
        provider.allowStop.open()
        #expect(await stopped.waitUntilOpen())
        #expect(!feature.isRecording)
        #expect(feature.selectedProcess == second)
        #expect(await provider.terminated.waitUntilOpen())
        feature.showResults()
        let reported = TestGate()
        let reportSubscription = feature.$report.sink { if $0 != nil { reported.open() } }
        defer { reportSubscription.cancel() }
        #expect(await reported.waitUntilOpen())
        #expect(feature.report == "JFR fixture report")
        feature.update(runID: UUID(), processID: 20, isRunning: true, isJava: true)
        #expect(feature.recording == nil)
        #expect(feature.report == nil)
        #expect(feature.selectedProcess == nil)
        #expect(await provider.discarded.waitUntilOpen())
    }

    @Test func closingTheRunDisposesARecordingThatFinishesStartingLate() async throws {
        let provider = ControlledTestJVMPerformance(delayedStart: true)
        let feature = TestJVMPerformanceFeatureModel(sampler: nil, provider: provider)
        defer { feature.update(runID: nil, processID: nil, isRunning: false, isJava: true); provider.finish() }
        feature.setVisible(true)
        feature.update(runID: UUID(), processID: 10, isRunning: true, isJava: true)
        #expect(await provider.started.waitUntilOpen())
        let selected = TestGate()
        let selection = feature.$selectedProcess.sink { if $0 != nil { selected.open() } }
        defer { selection.cancel() }
        provider.yield([provider.worker(11)])
        #expect(await selected.waitUntilOpen())
        feature.startRecording()
        #expect(await provider.starting.waitUntilOpen())
        feature.update(runID: nil, processID: nil, isRunning: false, isJava: true)
        // The provider deliberately returns a created resource after cancellation.
        provider.allowStart.open()
        #expect(await provider.discarded.waitUntilOpen())
        #expect(feature.recording == nil)
        #expect(!feature.isRecording)
        #expect(!feature.isBusy)
    }

    @Test func anExitedWorkerKeepsTheLastChartTargetUntilTheRunIsClosed() async throws {
        let provider = ControlledTestJVMPerformance()
        let feature = TestJVMPerformanceFeatureModel(sampler: nil, provider: provider)
        defer { feature.update(runID: nil, processID: nil, isRunning: false, isJava: true); provider.finish() }
        feature.setVisible(true)
        let id = UUID()
        feature.update(runID: id, processID: 10, isRunning: true, isJava: true)
        #expect(await provider.started.waitUntilOpen())
        let first = provider.worker(11)
        let selected = TestGate()
        let selection = feature.$selectedProcess.sink { if $0 == first { selected.open() } }
        defer { selection.cancel() }
        provider.yield([first])
        #expect(await selected.waitUntilOpen())
        let exited = TestGate()
        let exitSubscription = feature.$processes.sink { if $0.isEmpty { exited.open() } }
        defer { exitSubscription.cancel() }
        provider.yield([])
        #expect(await exited.waitUntilOpen())
        #expect(feature.selectedProcess == first)
        #expect(!feature.isProcessRunning)
        #expect(!feature.canStartRecording)
        feature.update(runID: id, processID: nil, isRunning: false, isJava: true)
        #expect(feature.selectedProcess == first)
        feature.update(runID: nil, processID: nil, isRunning: false, isJava: true)
        #expect(feature.selectedProcess == nil)
    }

    @Test func upstreamWorkerMarkersExcludeBuildLaunchers() {
        for arguments in [["java", "-jar", "/tmp/module/target/surefire/surefirebooter-1.jar"],
                          ["java", "com.intellij.rt.junit.JUnitStarter"],
                          ["java", "worker.org.gradle.process.internal.worker.GradleWorkerMain"],
                          ["java", "org.junit.platform.console.ConsoleLauncher"]] {
            #expect(MacTestJVMPerformance.isTestWorker(arguments: arguments))
        }
        #expect(!MacTestJVMPerformance.isTestWorker(arguments: ["java", "org.codehaus.plexus.classworlds.launcher.Launcher"]))
        #expect(!MacTestJVMPerformance.isTestWorker(arguments: ["java", "org.gradle.launcher.daemon.bootstrap.GradleDaemon"]))
        #expect(!MacTestJVMPerformance.isTestWorker(arguments: ["java", "demo.Main"]))
        #expect(MacTestJVMPerformance.quoted("/tmp/a b/\"x\".jfr") == "\"/tmp/a b/\\\"x\\\".jfr\"")
    }
}

private final class ControlledTestJVMPerformance: TestJVMPerformanceProviding, @unchecked Sendable {
    let starting = TestGate(), allowStart = TestGate()
    private let delayedStart: Bool
    init(delayedStart: Bool = false) { self.delayedStart = delayedStart }
    let started = TestGate(), terminated = TestGate(), stopping = TestGate(), allowStop = TestGate(), discarded = TestGate()
    private let pair = AsyncThrowingStream<[TestJVMProcess], Error>.makeStream()
    func worker(_ pid: Int32) -> TestJVMProcess {
        TestJVMProcess(processID: pid, javaExecutable: URL(fileURLWithPath: "/fixture/bin/java"),
            startedSeconds: UInt64(pid), startedMicroseconds: 0)
    }
    func processes(rootProcessID: Int32) -> AsyncThrowingStream<[TestJVMProcess], Error> {
        pair.continuation.onTermination = { [terminated] _ in terminated.open() }
        started.open()
        return pair.stream
    }
    func startRecording(_ process: TestJVMProcess) async throws -> TestJVMRecording {
        starting.open()
        if delayedStart { _ = await allowStart.waitUntilOpen() }
        return TestJVMRecording(id: UUID(), process: process, fileURL: URL(fileURLWithPath: "/fixture/recording.jfr"), startedAt: Date())
    }
    func stopRecording(_ recording: TestJVMRecording) async throws {
        stopping.open()
        guard await allowStop.waitUntilOpen() else { throw CancellationError() }
    }
    func report(_ recording: TestJVMRecording) async throws -> String { "JFR fixture report" }
    func discard(_ recording: TestJVMRecording) async { discarded.open() }
    func yield(_ workers: [TestJVMProcess]) { pair.continuation.yield(workers) }
    func finish() { allowStart.open(); allowStop.open(); pair.continuation.finish() }
}
