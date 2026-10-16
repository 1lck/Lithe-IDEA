import Foundation
import LitheCoreContracts
import LitheExecutionModule
import Testing
@testable import Lithe

@MainActor
@Suite("Real test JVM profiling", .serialized)
struct TestJFRIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_TEST_JAVA_EXECUTABLE"] != nil))
    func ownedWorkerReportsRealHeapAndProducesJFRAnalysis() async throws {
        let java = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LITHE_TEST_JAVA_EXECUTABLE"]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ConsoleLauncher.java")
        try """
        package org.junit.platform.console;
        public class ConsoleLauncher {
          static volatile Object sink;
          static final byte[] retained = new byte[16 * 1024 * 1024];
          public static void main(String[] args) {
            System.out.println("READY");
            long end = System.nanoTime() + 25000000000L;
            long count = 0;
            while (System.nanoTime() < end) {
              sink = new byte[128 * 1024];
              retained[(int)(count++ % retained.length)]++;
            }
          }
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compile = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: MacProcessRunner().run(ProcessRequest(
                    executablePath: java.deletingLastPathComponent().appendingPathComponent("javac").path,
                    arguments: ["-d", directory.path, source.path], timeoutMilliseconds: 8000)))
            }
        }
        #expect(compile.succeeded, "\(compile.output)")
        let process = MacStreamingProcess()
        defer { process.stop() }
        let probe = JFRWorkerProbe()
        process.onOutput = { probe.receive($0) }
        process.onStateChange = { if $0.state == .running { probe.processID = $0.processID } }
        try process.start(ProcessRequest(executablePath: java.path,
            arguments: ["-Xmx128m", "-cp", directory.path, "org.junit.platform.console.ConsoleLauncher"], timeoutMilliseconds: 30_000))
        let provider = MacTestJVMPerformance(processRegistry: nil)
        var recording: TestJVMRecording?
        var collector: Task<Void, Never>?
        do {
            #expect(await probe.ready.waitUntilOpen(timeout: .seconds(5)))
            let root = try #require(probe.processID)
            var worker: TestJVMProcess?
            let discovered = TestGate()
            let discovery = Task { @MainActor in
                for try await workers in provider.processes(rootProcessID: root) {
                    if let first = workers.first { worker = first; discovered.open(); break }
                }
            }
            defer { discovery.cancel() }
            #expect(await discovered.waitUntilOpen())
            let target = try #require(worker)
            #expect(target.processID == root)
            let value = try await provider.startRecording(target)
            recording = value
            let received = TestGate()
            var samples: [DebugPerformanceSample] = []
            var failure: String?
            collector = Task { @MainActor in
                do {
                    for try await sample in MacDebugPerformanceSampler(processRegistry: nil).samples(for: target.target) {
                        samples.append(sample)
                        if samples.count >= 3 { received.open() }
                    }
                } catch { failure = error.localizedDescription; received.open() }
            }
            #expect(await received.waitUntilOpen(timeout: .seconds(6)))
            #expect(failure == nil)
            #expect(samples.count >= 3)
            #expect(samples.allSatisfy { $0.memoryUsedBytes > 8 * 1024 * 1024 })
            collector?.cancel(); await collector?.value
            try await provider.stopRecording(value)
            let report = try await provider.report(value)
            #expect(report.contains("JDK Flight Recorder"))
            #expect(report.contains("ExecutionSample"))
            #expect(report.contains("ConsoleLauncher"))
            #expect(report.contains("allocation-by-site"))
            #expect(!report.contains("Unknown command"))
            await provider.discard(value)
            #expect(!FileManager.default.fileExists(atPath: value.fileURL.deletingLastPathComponent().path))
            #expect(await process.stopAndWait())
        } catch {
            collector?.cancel(); await collector?.value
            if let recording { await provider.discard(recording) }
            _ = await process.stopAndWait()
            throw error
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_TEST_GRADLE_EXECUTABLE"] != nil))
    func gradleTestWorkerIsOwnedEvenWithAnExistingDaemon() async throws {
        let environment = ProcessInfo.processInfo.environment
        let gradle = try #require(environment["LITHE_TEST_GRADLE_EXECUTABLE"])
        let java = try #require(environment["LITHE_TEST_JAVA_EXECUTABLE"])
        let junit = try #require(environment["LITHE_TEST_JUNIT_JAR"])
        let hamcrest = try #require(environment["LITHE_TEST_HAMCREST_JAR"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-gradle-\(UUID().uuidString)")
        let source = directory.appendingPathComponent("src/test/java/OwnedWorkerTest.java")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(atPath: junit, toPath: directory.appendingPathComponent("junit.jar").path)
        try FileManager.default.copyItem(atPath: hamcrest, toPath: directory.appendingPathComponent("hamcrest.jar").path)
        let build = directory.appendingPathComponent("build.gradle")
        try """
        plugins { id 'java' }
        dependencies { testImplementation files('junit.jar', 'hamcrest.jar') }
        tasks.withType(JavaCompile).configureEach { options.fork = true }
        test { useJUnit(); testLogging.showStandardStreams = true }
        tasks.register('probeDaemon') { doLast { println('DAEMON:' + ProcessHandle.current().pid()) } }
        """.write(to: build, atomically: true, encoding: .utf8)
        try """
        import org.junit.Test;
        import java.nio.file.*;
        public class OwnedWorkerTest {
          @Test public void holdsWorker() throws Exception {
            System.out.println("READY");
            long deadline = System.nanoTime() + 30000000000L;
            while (!Files.exists(Paths.get("release")) && System.nanoTime() < deadline) { Thread.onSpinWait(); }
          }
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let mainSource = directory.appendingPathComponent("src/main/java/ForkedCompile.java")
        try FileManager.default.createDirectory(at: mainSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "public class ForkedCompile {}".write(to: mainSource, atomically: true, encoding: .utf8)
        let home = directory.appendingPathComponent("gradle-home").path
        let options = ["--offline", "--console=plain", "--gradle-user-home", home]
        let processEnvironment = ["JAVA_HOME": URL(fileURLWithPath: java).deletingLastPathComponent().deletingLastPathComponent().path]
        func runGradle(_ arguments: [String]) async -> ProcessResult {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: MacProcessRunner().run(ProcessRequest(
                        executablePath: gradle, arguments: options + arguments, workingDirectory: directory.path,
                        environment: processEnvironment, timeoutMilliseconds: 60_000)))
                }
            }
        }
        let process = MacStreamingProcess()
        defer { process.stop() }
        do {
            let warmup = await runGradle(["--daemon", "probeDaemon"])
            try #require(warmup.succeeded, "\(warmup.output)")
            let daemonPID = try #require(warmup.output.split(separator: "\n")
                .first(where: { $0.hasPrefix("DAEMON:") }).flatMap { Int32($0.dropFirst(7)) })
            #expect(MacProcessMemorySampler().cpuSnapshot(for: daemonPID) != nil)
            let descriptor = LanguageProviderDescriptor(id: "java", displayName: "Java", fileExtensions: ["java"],
                capabilities: [.testing], activationPolicy: .onDemand)
            let plan = try StandardLanguageTestProvider(descriptor: descriptor).testPlan(scope: .workspace,
                context: LanguageTestContext(workspaceURL: directory, projectFiles: [build, source]))
            let probe = JFRWorkerProbe()
            process.onOutput = { probe.receive($0) }
            process.onStateChange = { if $0.state == .running { probe.processID = $0.processID } }
            try process.start(ProcessRequest(executablePath: gradle, arguments: options + plan.launchPlan.arguments,
                workingDirectory: directory.path, environment: processEnvironment, timeoutMilliseconds: 60_000))
            #expect(await probe.ready.waitUntilOpen(timeout: .seconds(40)))
            let root = try #require(probe.processID)
            let discovered = TestGate()
            var target: TestJVMProcess?
            let discovery = Task { @MainActor in
                for try await workers in MacTestJVMPerformance(processRegistry: nil).processes(rootProcessID: root) {
                    if let worker = workers.first { target = worker; discovered.open(); break }
                }
            }
            defer { discovery.cancel() }
            #expect(await discovered.waitUntilOpen(timeout: .seconds(5)))
            let worker = try #require(target)
            let listing = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: MacProcessRunner().run(ProcessRequest(
                        executablePath: URL(fileURLWithPath: java).deletingLastPathComponent().appendingPathComponent("jps").path,
                        arguments: ["-lm"], timeoutMilliseconds: 10_000)))
                }
            }
            try #require(listing.succeeded, "\(listing.output)")
            let owned = MacProcessMemorySampler().descendantProcessIDs(of: [root])
            let compilerWorkers = listing.output.split(separator: "\n").filter { $0.contains("Gradle Worker Daemon ") }
                .compactMap { Int32($0.split(separator: " ").first ?? "") }.filter { owned.contains($0) }
            #expect(!compilerWorkers.isEmpty, "Forked compilation must coexist with the test executor: \(listing.output)")
            #expect(!compilerWorkers.contains(worker.processID))
            #expect(worker.processID != daemonPID)
            #expect(MacProcessMemorySampler().descendantProcessIDs(of: [root]).contains(worker.processID))
            #expect(MacProcessMemorySampler().cpuSnapshot(for: daemonPID) != nil,
                    "The pre-existing daemon must be left running and untouched")
            try Data().write(to: directory.appendingPathComponent("release"))
            #expect(await process.stopAndWait())
            let stopped = await runGradle(["--stop"])
            #expect(stopped.succeeded, "\(stopped.output)")
        } catch {
            _ = await process.stopAndWait()
            _ = await runGradle(["--stop"])
            throw error
        }
    }

}

private final class JFRWorkerProbe: @unchecked Sendable {
    let ready = TestGate()
    private let lock = NSLock()
    private var pid: Int32?
    private var text = ""
    var processID: Int32? {
        get { lock.withLock { pid } }
        set { lock.withLock { pid = newValue } }
    }
    func receive(_ chunk: String) {
        if lock.withLock({ text = String((text + chunk).suffix(128)); return text.contains("READY\n") }) { ready.open() }
    }
}
