import Darwin
import Foundation

@_silgen_name("proc_pidpath")
private func lithePerformancePIDPath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32

/// Only known upstream test launchers descended from the exact owned root are
/// eligible. Maven/Gradle build daemons are not used as a substitute for tests.
struct MacTestJVMPerformance: TestJVMPerformanceProviding {
    let processRegistry: ManagedProcessRegistry?

    static func javaExecutable(processID: Int32) -> URL? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard lithePerformancePIDPath(processID, &path, UInt32(path.count)) > 0 else { return nil }
        let url = URL(fileURLWithPath: String(cString: path))
        return url.lastPathComponent == "java" ? url : nil
    }

    // ponytail: Only public JUnit/TestNG/Surefire/Gradle worker entry points are
    // recognized. Custom/in-process runners stay unavailable; replace this
    // classifier when execution providers expose exact worker identities.
    static func isTestWorker(arguments: [String]) -> Bool {
        // DefaultWorkerProcessBuilder appends a quoted display name as the final argument.
        let name = arguments.last?.trimmingCharacters(in: CharacterSet(charactersIn: "'")) ?? ""
        let gradleTest = name.hasPrefix("Gradle Test Executor ")
            && Int(name.dropFirst("Gradle Test Executor ".count)).map { $0 > 0 } == true
        return arguments.contains { argument in
            argument == "com.intellij.rt.junit.JUnitStarter"
                || argument == "org.junit.platform.console.ConsoleLauncher"
                || argument == "org.testng.TestNG"
                || argument == "com.intellij.rt.testng.RemoteTestNGStarter"
                || (URL(fileURLWithPath: argument).lastPathComponent.hasPrefix("junit-platform-console-standalone") && argument.hasSuffix(".jar"))
                || (argument.hasSuffix(".GradleWorkerMain") && gradleTest)
                || argument == "org.apache.maven.surefire.booter.ForkedBooter"
                || (URL(fileURLWithPath: argument).lastPathComponent.hasPrefix("surefirebooter") && argument.hasSuffix(".jar"))
        }
    }

    private static func arguments(processID: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
        var size = 1_048_576
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0, size > 4 else { return [] }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= 65_536 else { return [] }
        var index = 4
        while index < size && bytes[index] != 0 { index += 1 }
        while index < size && bytes[index] == 0 { index += 1 }
        var result: [String] = []
        for _ in 0..<count where index < size {
            let start = index
            while index < size && bytes[index] != 0 { index += 1 }
            result.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }

    func processes(rootProcessID: Int32) -> AsyncThrowingStream<[TestJVMProcess], Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached(priority: .utility) {
                let sampler = MacProcessMemorySampler()
                guard let root = sampler.cpuSnapshot(for: rootProcessID) else { continuation.finish(); return }
                while !Task.isCancelled {
                    guard let identity = sampler.cpuSnapshot(for: rootProcessID),
                          identity.startedSeconds == root.startedSeconds,
                          identity.startedMicroseconds == root.startedMicroseconds else { break }
                    let owned = sampler.descendantProcessIDs(of: [rootProcessID])
                    let all = owned.compactMap { pid -> TestJVMProcess? in
                        guard let java = Self.javaExecutable(processID: pid),
                              Self.isTestWorker(arguments: Self.arguments(processID: pid)),
                              let cpu = sampler.cpuSnapshot(for: pid) else { return nil }
                        return TestJVMProcess(processID: pid, javaExecutable: java,
                            startedSeconds: cpu.startedSeconds, startedMicroseconds: cpu.startedMicroseconds)
                    }.sorted { $0.processID < $1.processID }
                    continuation.yield(all)
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func validate(_ process: TestJVMProcess) throws {
        let cpu = MacProcessMemorySampler().cpuSnapshot(for: process.processID)
        guard cpu?.startedSeconds == process.startedSeconds,
              cpu?.startedMicroseconds == process.startedMicroseconds,
              Self.javaExecutable(processID: process.processID) == process.javaExecutable else {
            throw DebugPerformanceError.unavailable("The selected test JVM has exited or changed.")
        }
    }

    func startRecording(_ process: TestJVMProcess) async throws -> TestJVMRecording {
        try validate(process)
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-jfr-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let recording = TestJVMRecording(id: id, process: process,
            fileURL: directory.appendingPathComponent("recording.jfr"), startedAt: Date())
        do {
            _ = try await command(process.javaExecutable, tool: "jcmd", arguments: [String(process.processID), "JFR.start",
                "name=\(recording.name)", "settings=profile", "filename=\(Self.quoted(recording.fileURL.path))",
                "dumponexit=true", "maxsize=64m", "duration=120s"])
            try validate(process)
            try Task.checkCancellation()
            return recording
        } catch {
            // Cleanup must survive cancellation of the request that started JFR.
            await Task {
                // This unique recording name can only belong to this request,
                // including a start/exit race after the initial identity check.
                _ = try? await command(process.javaExecutable, tool: "jcmd",
                    arguments: [String(process.processID), "JFR.stop", "name=\(recording.name)"])
                await discard(recording)
            }.value
            throw error
        }
    }

    func stopRecording(_ recording: TestJVMRecording) async throws {
        // The JVM's dumponexit owns the final file if it has already exited.
        if (try? validate(recording.process)) != nil {
            _ = try await command(recording.process.javaExecutable, tool: "jcmd",
                arguments: [String(recording.process.processID), "JFR.stop", "name=\(recording.name)"])
        }
    }

    func report(_ recording: TestJVMRecording) async throws -> String {
        let size = try recording.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 80 * 1024 * 1024 else {
            throw DebugPerformanceError.unavailable("No completed JFR recording is available.")
        }
        let java = recording.process.javaExecutable
        let summary = try await command(java, tool: "jfr", arguments: ["summary", recording.fileURL.path])
        var result = "JDK Flight Recorder\n\n\(summary)\n"
        for view in ["hot-methods", "allocation-by-site"] {
            do {
                result += "\n\(view)\n\n" + (try await command(java, tool: "jfr",
                    arguments: ["view", "--width", "140", "--truncate", "end", view, recording.fileURL.path]))
            } catch {
                try Task.checkCancellation()
                // JDKs before 21 can record JFR but do not provide `jfr view`.
                result += "\n\(view): \(error.localizedDescription)\n"
            }
        }
        return result
    }

    func discard(_ recording: TestJVMRecording) async {
        try? await stopRecording(recording)
        let expected = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-jfr-\(recording.id.uuidString)")
        guard recording.fileURL.standardizedFileURL == expected.appendingPathComponent("recording.jfr").standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: expected)
    }

    /// jcmd parses a diagnostic command after OS argv; quote that grammar rather
    /// than introducing a shell. Paths containing apostrophes use double quotes.
    static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func command(_ java: URL, tool: String, arguments: [String]) async throws -> String {
        let executable = java.deletingLastPathComponent().appendingPathComponent(tool)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw DebugPerformanceError.unavailable("The selected JDK does not provide \(tool).")
        }
        let process = MacStreamingProcess(processRegistry: processRegistry, moduleID: .execution)
        let output = JVMToolOutput()
        let pair = AsyncThrowingStream<Int32, Error>.makeStream()
        process.onOutput = { output.append($0) }
        process.onTermination = { pair.continuation.yield($0); pair.continuation.finish() }
        pair.continuation.onTermination = { _ in process.stop() }
        defer { process.stop(); pair.continuation.finish() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try process.start(ProcessRequest(executablePath: executable.path, arguments: arguments,
                timeoutMilliseconds: 10_000))
            var iterator = pair.stream.makeAsyncIterator()
            guard let code = try await iterator.next() else { throw CancellationError() }
            try Task.checkCancellation()
            guard code == 0 else { throw DebugPerformanceError.unavailable(output.value) }
            return output.value
        } onCancel: { process.stop(); pair.continuation.finish() }
    }
}

private final class JVMToolOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    var value: String { lock.withLock { text } }
    func append(_ chunk: String) { lock.withLock { text = String((text + chunk).prefix(262_144)) } }
}
