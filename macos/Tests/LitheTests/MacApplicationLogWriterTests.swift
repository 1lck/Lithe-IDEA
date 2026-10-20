import Foundation
import Testing
@testable import Lithe

private final class LogTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_792_454_400)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

@Suite("macOS application log writer")
struct MacApplicationLogWriterTests {
    @Test
    func collectionAndCleanupPreserveUnrelatedLogFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LogTestClock()
        let writer = MacApplicationLogWriter(now: clock.now)
        try writer.redirect(to: root)
        let unrelated = [root.appendingPathComponent("lithe.backup.log"),
            root.appendingPathComponent("language/lithe.notes.log")]
        try FileManager.default.createDirectory(at: root.appendingPathComponent("language"), withIntermediateDirectories: true)
        for file in unrelated {
            try Data("unrelated evidence".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: clock.now().addingTimeInterval(-31 * 86400)], ofItemAtPath: file.path)
        }
        let legacy = root.appendingPathComponent("lithe.log")
        try Data("legacy evidence\n".utf8).write(to: legacy)
        writer.record(level: "info", scope: "application", message: "managed evidence")
        let collection = try await writer.collect(query: ApplicationLogQuery(session: "all"))
        #expect(collection.content.contains("legacy evidence"))
        #expect(collection.content.contains("managed evidence"))
        #expect(!collection.content.contains("unrelated evidence"))
        try await writer.clear()
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        for file in unrelated { #expect(try String(contentsOf: file, encoding: .utf8) == "unrelated evidence") }
    }

    @Test
    func filtersBeforeFileLimitAndReportsOmittedMatchingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MacApplicationLogWriter()
        try writer.redirect(to: root)
        let session = String(repeating: "a", count: 32)
        for category in ["application", "git"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(category), withIntermediateDirectories: true)
        }
        let old = "lithe.2026-10-19T00-00-00.000Z.\(session).00000000000000000001.log"
        try Data("2026-10-19T00:00:00.000Z INFO [session=\(session)] git evidence\n".utf8)
            .write(to: root.appendingPathComponent("git/\(old)"))
        for index in 1...201 {
            let name = "lithe.2026-10-20T00-00-00.000Z.\(session).\(String(format: "%020d", index)).log"
            try Data("2026-10-20T00:00:00.000Z INFO [session=\(session)] application evidence\n".utf8)
                .write(to: root.appendingPathComponent("application/\(name)"))
        }
        let git = try await writer.collect(query: ApplicationLogQuery(category: "git", session: "all"))
        #expect(git.content.contains("git evidence"))
        #expect(!git.truncated)
        let previous = try await writer.collect(query: ApplicationLogQuery(category: "git", session: "previous"))
        #expect(previous.content.contains("git evidence"))
        let application = try await writer.collect(query: ApplicationLogQuery(category: "application", session: "all"))
        #expect(application.truncated)
        #expect(application.files.contains { $0.relativePath == "collection-status.txt" && String(decoding: $0.data, as: UTF8.self).contains("truncated=true") })
    }

    @Test
    func changingDirectoryMovesCollectionToTheSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MacApplicationLogWriter()
        let original = root.appendingPathComponent("original")
        let selected = root.appendingPathComponent("selected")
        try writer.redirect(to: original)
        writer.record(level: "info", scope: "application", message: "original line", fields: [:])
        let first = try await writer.collect(query: ApplicationLogQuery())
        #expect(first.content.contains("original line"))
        try writer.redirect(to: selected)
        writer.record(level: "error", scope: "language.java", message: "selected line", fields: [:])
        let second = try await writer.collect(query: ApplicationLogQuery())
        #expect(second.effectiveDirectory == selected)
        #expect(second.content.contains("selected line"))
        #expect(!second.content.contains("original line"))
        #expect(second.files.contains { $0.relativePath.hasPrefix("logs/language/") })
    }

    @Test
    func routesRedactsAndFiltersWithoutLeakingSourceContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MacApplicationLogWriter()
        try writer.redirect(to: root)
        writer.record(level: "info", scope: "git.fetch", message: "fetch finished", fields: ["operation_id": "operation-a"])
        writer.record(level: "error", scope: "language.java", message: "password=fake-secret failed",
            fields: ["sourceContent": "private editor text", "operation_id": "operation-b"])
        let all = try await writer.collect(query: ApplicationLogQuery())
        #expect(all.content.contains("fetch finished"))
        #expect(all.content.contains("operation-b"))
        #expect(!all.content.contains("fake-secret"))
        #expect(!all.content.contains("private editor text"))
        let filtered = try await writer.collect(query: ApplicationLogQuery(category: "language", minimumLevel: "error"))
        #expect(!filtered.content.contains("fetch finished"))
        #expect(filtered.content.contains("ERROR"))
        try await writer.clear()
        let cleared = try await writer.collect(query: ApplicationLogQuery())
        #expect(cleared.content.isEmpty)
    }

    @Test
    func rotatesAndExpiresDiagnosticModeUsingAnInjectedClock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LogTestClock()
        let writer = MacApplicationLogWriter(fileLimit: 700, totalLimit: 3000, diagnosticNow: { clock.now().timeIntervalSince1970 }, now: clock.now)
        try writer.redirect(to: root)
        await writer.configureDiagnostic(category: "language", enabled: true)
        writer.record(level: "debug", scope: "language.java", message: "diagnostic visible", fields: [:])
        writer.record(level: "debug", scope: "git.fetch", message: "other domain hidden", fields: [:])
        let enabled = try await writer.collect(query: ApplicationLogQuery())
        #expect(enabled.diagnosticEnabled)
        #expect(enabled.content.contains("diagnostic visible"))
        #expect(!enabled.content.contains("other domain hidden"))
        clock.advance(901)
        writer.record(level: "debug", scope: "language.java", message: "expired hidden", fields: [:])
        for index in 0..<12 {
            writer.record(level: "error", scope: "language.java", message: "event-\(index) " + String(repeating: "x", count: 200), fields: [:])
        }
        let expired = try await writer.collect(query: ApplicationLogQuery())
        #expect(!expired.diagnosticEnabled)
        #expect(!expired.content.contains("expired hidden"))
        #expect(expired.content.contains("event-11"))
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        let sizes = (enumerator?.allObjects as? [URL] ?? []).compactMap { url -> Int? in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true ? values?.fileSize : nil
        }
        #expect(sizes.reduce(0, +) <= 3000)
    }

    @Test
    func runtimeDirectoryFailureFallsBackToTheCollectedDefaultDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("custom")
        let fallback = root.appendingPathComponent("default")
        let notified = TestGate()
        let writer = MacApplicationLogWriter(defaultDirectory: fallback, onDirectoryFallback: { notified.open() })
        try writer.redirect(to: selected)
        try FileManager.default.removeItem(at: selected)
        try Data("unavailable directory".utf8).write(to: selected)
        writer.record(level: "error", scope: "language.java", message: "recovered evidence", fields: [:])
        let snapshot = try await writer.collect(query: ApplicationLogQuery())
        #expect(snapshot.effectiveDirectory == fallback)
        #expect(snapshot.content.contains("recovered evidence"))
        #expect(await notified.waitUntilOpen())
        #expect(snapshot.writeFailures == 1)
    }

    @Test
    func repeatedErrorsAreAggregatedBeforeCollection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MacApplicationLogWriter()
        try writer.redirect(to: root)
        for _ in 0..<3 { writer.record(level: "error", scope: "language.java", message: "same failure", fields: [:]) }
        let snapshot = try await writer.collect(query: ApplicationLogQuery())
        #expect(snapshot.content.components(separatedBy: "same failure").count == 2)
        #expect(snapshot.content.contains("count=\"2\""))
        #expect(snapshot.content.contains("first_timestamp="))
        #expect(snapshot.content.contains("last_timestamp="))
    }

    @Test
    func defaultDirectoryProviderUsesTheMacUserLogsDirectory() {
        #expect(MacLogDirectoryProvider().defaultLogDirectory.path.hasSuffix("/Library/Logs/Lithe"))
    }
}
