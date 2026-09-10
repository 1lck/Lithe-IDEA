import Foundation
import Testing
@testable import Lithe

private final class StubLogDirectoryProviding: LogDirectoryProviding {
    let defaultLogDirectory: URL

    init(defaultLogDirectory: URL) {
        self.defaultLogDirectory = defaultLogDirectory
    }
}

private struct StubSystemDiagnosticsProvider: SystemDiagnosticsProviding {
    func currentSnapshot(volumeURL: URL) -> SystemDiagnosticsSnapshot {
        SystemDiagnosticsSnapshot(
            appVersion: "1.2.3",
            osName: "macOS",
            osVersion: "Test OS 1.0",
            cpuCoreCount: 8,
            memoryRSSBytes: 123_456,
            diskFreeBytes: 987_654_321
        )
    }
}

private final class RecordingArchiver: DiagnosticsArchiving, @unchecked Sendable {
    private(set) var archivedDirectoryURL: URL?
    private(set) var archivedDestinationURL: URL?
    var errorToThrow: (any Error)?

    func archive(directoryURL: URL, toZipURL destinationURL: URL) throws {
        if let errorToThrow {
            throw errorToThrow
        }
        archivedDirectoryURL = directoryURL
        archivedDestinationURL = destinationURL
    }
}

private struct ArchiverStubError: Error {}

private final class InMemoryDiagnosticsFileStorage: FileStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var directories: Set<String> = []
    private let root = URL(fileURLWithPath: "/in-memory-diagnostics-storage", isDirectory: true)

    /// Invoked at the top of `readData` (on the caller's thread) so a test can
    /// pause the detached staging task and interleave a `cancel()`.
    var beforeReadData: (@Sendable () -> Void)?

    func seed(_ data: Data, at url: URL) {
        lock.lock()
        files[url.path] = data
        lock.unlock()
    }

    /// Every file path currently stored, for asserting staging cleanup.
    var allFilePaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(files.keys)
    }

    func homeDirectory() -> URL { root }
    func cacheDirectory() -> URL { root }
    func applicationSupportDirectory() -> URL { root }
    func temporaryDirectory() -> URL { root }

    func metadata(for url: URL) -> FileMetadata? {
        lock.lock()
        defer { lock.unlock() }
        if let data = files[url.path] {
            return FileMetadata(byteCount: data.count, modificationDate: nil, isRegularFile: true, isDirectory: false)
        }
        if directories.contains(url.path) {
            return FileMetadata(byteCount: nil, modificationDate: nil, isRegularFile: false, isDirectory: true)
        }
        return nil
    }

    func fileExists(at url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return files[url.path] != nil || directories.contains(url.path)
    }

    func isExecutable(at url: URL) -> Bool { false }

    func listDirectory(at url: URL) -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return files.keys
            .filter { URL(fileURLWithPath: $0).deletingLastPathComponent().path == url.path }
            .map { URL(fileURLWithPath: $0) }
    }

    func readPrefix(from url: URL, byteCount: Int) throws -> Data {
        Data(try readData(from: url, options: []).prefix(byteCount))
    }

    func readData(from url: URL, options: Data.ReadingOptions = []) throws -> Data {
        beforeReadData?()
        lock.lock()
        defer { lock.unlock() }
        guard let data = files[url.path] else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return data
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions = []) throws {
        lock.lock()
        files[url.path] = data
        directories.insert(url.deletingLastPathComponent().path)
        lock.unlock()
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        lock.lock()
        directories.insert(url.path)
        lock.unlock()
    }

    func removeItem(at url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        let prefix = url.path
        files = files.filter { !$0.key.hasPrefix(prefix) }
        directories = directories.filter { !$0.hasPrefix(prefix) }
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        files[destinationURL.path] = files[sourceURL.path]
        files[sourceURL.path] = nil
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        files[destinationURL.path] = files[sourceURL.path]
    }
}

@Suite("Diagnostics export service")
@MainActor
struct DiagnosticsExportServiceTests {
    private func makeLogDirectoryProviding() -> StubLogDirectoryProviding {
        StubLogDirectoryProviding(
            defaultLogDirectory: URL(fileURLWithPath: "/in-memory-diagnostics-storage/logs", isDirectory: true)
        )
    }

    @Test
    func prepareStagesRedactedLogAndAwaitsConfirmation() async {
        // `swift test` does not force-load the Rust Core static library by
        // default (see scripts/test-macos.sh); skip gracefully rather than
        // asserting on the "unavailable" failure path, mirroring
        // RealJavaDebugIntegrationTests's guard.
        guard RustCoreBridge().isAvailable else { return }

        let storage = InMemoryDiagnosticsFileStorage()
        let logDirectoryProviding = makeLogDirectoryProviding()
        storage.seed(
            Data("token=super-secret-value\nsomething happened\n".utf8),
            at: logDirectoryProviding.applicationLogFileURL
        )
        let service = DiagnosticsExportService(
            logDirectoryProviding: logDirectoryProviding,
            fileStorage: storage,
            systemDiagnostics: StubSystemDiagnosticsProvider(),
            archiver: RecordingArchiver(),
            core: RustCoreBridge()
        )

        guard case .idle = service.state else {
            Issue.record("Expected idle before prepare()")
            return
        }

        await service.prepare()

        guard case .awaitingConfirmation(let manifest) = service.state else {
            Issue.record("Expected awaitingConfirmation after prepare(), got \(service.state)")
            return
        }
        #expect(manifest.files.map(\.relativePath).sorted() == ["environment.json", "lithe.log"])
        #expect(manifest.environment.appVersion == "1.2.3")
        #expect(manifest.environment.cpuCoreCount == 8)
    }

    @Test
    func exportWritesManifestArchivesAndCompletes() async {
        guard RustCoreBridge().isAvailable else { return }

        let storage = InMemoryDiagnosticsFileStorage()
        let logDirectoryProviding = makeLogDirectoryProviding()
        storage.seed(Data("a log line\n".utf8), at: logDirectoryProviding.applicationLogFileURL)
        let archiver = RecordingArchiver()
        let service = DiagnosticsExportService(
            logDirectoryProviding: logDirectoryProviding,
            fileStorage: storage,
            systemDiagnostics: StubSystemDiagnosticsProvider(),
            archiver: archiver,
            core: RustCoreBridge()
        )

        await service.prepare()
        guard case .awaitingConfirmation = service.state else {
            Issue.record("Expected awaitingConfirmation before export()")
            return
        }

        let destinationURL = URL(fileURLWithPath: "/in-memory-diagnostics-storage/out/Lithe-Diagnostics.zip")
        await service.export(to: destinationURL)

        guard case .completed(let completedURL) = service.state else {
            Issue.record("Expected completed after export(), got \(service.state)")
            return
        }
        #expect(completedURL == destinationURL)
        #expect(archiver.archivedDestinationURL == destinationURL)
        #expect(archiver.archivedDirectoryURL != nil)
    }

    @Test
    func exportFailureSurfacesFailedState() async {
        guard RustCoreBridge().isAvailable else { return }

        let storage = InMemoryDiagnosticsFileStorage()
        let logDirectoryProviding = makeLogDirectoryProviding()
        storage.seed(Data("a log line\n".utf8), at: logDirectoryProviding.applicationLogFileURL)
        let archiver = RecordingArchiver()
        archiver.errorToThrow = ArchiverStubError()
        let service = DiagnosticsExportService(
            logDirectoryProviding: logDirectoryProviding,
            fileStorage: storage,
            systemDiagnostics: StubSystemDiagnosticsProvider(),
            archiver: archiver,
            core: RustCoreBridge()
        )

        await service.prepare()
        await service.export(to: URL(fileURLWithPath: "/in-memory-diagnostics-storage/out/Lithe-Diagnostics.zip"))

        guard case .failed = service.state else {
            Issue.record("Expected failed after archiver throws, got \(service.state)")
            return
        }
    }

    @Test
    func cancelResetsToIdle() async {
        let storage = InMemoryDiagnosticsFileStorage()
        let logDirectoryProviding = makeLogDirectoryProviding()
        storage.seed(Data("a log line\n".utf8), at: logDirectoryProviding.applicationLogFileURL)
        let service = DiagnosticsExportService(
            logDirectoryProviding: logDirectoryProviding,
            fileStorage: storage,
            systemDiagnostics: StubSystemDiagnosticsProvider(),
            archiver: RecordingArchiver(),
            core: RustCoreBridge()
        )

        await service.prepare()
        service.cancel()

        guard case .idle = service.state else {
            Issue.record("Expected idle after cancel(), got \(service.state)")
            return
        }
    }

    @Test
    func cancelDuringPrepareDiscardsStaleResultAndCleansStaging() async {
        // Regression: cancelling while the detached staging task is in flight
        // must not resurrect .awaitingConfirmation when the task later
        // succeeds, and must not leave an orphaned staging directory behind.
        guard RustCoreBridge().isAvailable else { return }

        let storage = InMemoryDiagnosticsFileStorage()
        let logDirectoryProviding = makeLogDirectoryProviding()
        storage.seed(Data("token=secret\n".utf8), at: logDirectoryProviding.applicationLogFileURL)

        // Gate the log read so prepare() is provably mid-flight when we cancel.
        let readEntered = DispatchSemaphore(value: 0)
        let readRelease = DispatchSemaphore(value: 0)
        storage.beforeReadData = {
            readEntered.signal()
            // Bounded so a missed handshake fails fast instead of hanging CI;
            // the happy path releases within milliseconds.
            _ = readRelease.wait(timeout: .now() + 10)
        }

        let service = DiagnosticsExportService(
            logDirectoryProviding: logDirectoryProviding,
            fileStorage: storage,
            systemDiagnostics: StubSystemDiagnosticsProvider(),
            archiver: RecordingArchiver(),
            core: RustCoreBridge()
        )

        let prepareTask = Task { await service.prepare() }
        // Wait off the main actor (bounded) so prepare() and its detached task
        // can run, then assert the read was actually reached before cancelling.
        let entered: DispatchTimeoutResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: readEntered.wait(timeout: .now() + 10))
            }
        }
        #expect(entered == .success)

        service.cancel()
        guard case .idle = service.state else {
            Issue.record("Expected idle immediately after cancel(), got \(service.state)")
            readRelease.signal()
            return
        }

        // Let the now-stale detached staging task complete.
        readRelease.signal()
        await prepareTask.value

        guard case .idle = service.state else {
            Issue.record("Expected state to stay idle after stale prepare completed, got \(service.state)")
            return
        }
        #expect(!storage.allFilePaths.contains { $0.contains("diagnostics-export") })
    }
}
