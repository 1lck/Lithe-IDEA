import Foundation
import Testing
import LitheModuleAPI
@testable import Lithe

private final class LogTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_792_454_400)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

@Suite("macOS application log writer")
struct MacLogStoreTests {
    @Test
    func collectionAndCleanupPreserveUnrelatedLogFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LogTestClock()
        let writer = MacLogStore(now: clock.now)
        try writer.redirect(to: root)
        let unrelated = [root.appendingPathComponent("lithe.backup.log"),
            root.appendingPathComponent("language/lithe.notes.log")]
        try FileManager.default.createDirectory(at: root.appendingPathComponent("language"), withIntermediateDirectories: true)
        for file in unrelated {
            try Data("unrelated evidence".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: clock.now().addingTimeInterval(-31 * 86400)], ofItemAtPath: file.path)
        }
        let legacy = root.appendingPathComponent("lithe.log")
        try Data("2026-10-20T00:00:00.000Z INFO legacy evidence\n".utf8).write(to: legacy)
        writer.emit(AppSessionStarted())
        let collection = try await writer.collect(query: ApplicationLogQuery(session: "all"))
        #expect(!collection.content.contains("legacy evidence"))
        #expect(!collection.files.contains { String(decoding: $0.data, as: UTF8.self).contains("legacy evidence") })
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(collection.content.contains("event=app.session.started"))
        #expect(!collection.content.contains("unrelated evidence"))
        clock.advance(31 * 86400)
        try FileManager.default.setAttributes([.modificationDate: clock.now().addingTimeInterval(-31 * 86400)], ofItemAtPath: legacy.path)
        _ = try await writer.collect(query: .init(session: "all"))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        for file in unrelated { #expect(try String(contentsOf: file, encoding: .utf8) == "unrelated evidence") }
    }

    @Test
    func filtersBeforeFileLimitAndReportsOmittedMatchingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MacLogStore()
        try writer.redirect(to: root)
        let session = "2026-11-03T00-00-00_abcdef12"
        for category in ["app", "vcs"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions/" + session + "/" + category), withIntermediateDirectories: true)
        }
        let timestamp = "2026-11-03T00:00:00.000Z"
        try Data("\(timestamp) INFO seq=1 event=app.session.started msg=\"git evidence\"\n".utf8)
            .write(to: root.appendingPathComponent("sessions/\(session)/vcs/git.log"))
        for index in 1...201 {
            try Data("\(timestamp) INFO seq=\(index) event=app.session.started msg=\"application evidence\"\n".utf8)
                .write(to: root.appendingPathComponent("sessions/\(session)/app/file-\(index).log"))
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
        let writer = MacLogStore()
        let original = root.appendingPathComponent("original")
        let selected = root.appendingPathComponent("selected")
        try writer.redirect(to: original)
        writer.emit(AppSessionStarted())
        let first = try await writer.collect(query: ApplicationLogQuery())
        #expect(first.content.contains("app.session.started"))
        try writer.redirect(to: selected)
        writer.emit(EditorTextClassificationFailed())
        let second = try await writer.collect(query: ApplicationLogQuery())
        #expect(second.effectiveDirectory == selected)
        #expect(second.content.contains("editor.text.classification_failed"))
        #expect(!second.content.contains("app.session.started"))
        #expect(second.files.contains { $0.relativePath.contains("/editor.log") })
    }

    @Test
    func routesRedactsAndFiltersWithoutLeakingSourceContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MacLogStore()
        try writer.redirect(to: root)
        writer.emit(AppSessionStarted(operationID: "operation-a"))
        writer.emit(EditorDocumentOpenFailed(error: NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "password=fake-secret failed"]), reason: "unavailable", operationID: "operation-b"))
        let all = try await writer.collect(query: ApplicationLogQuery())
        #expect(all.content.contains("app.session.started"))
        #expect(all.content.contains("operation-b"))
        #expect(!all.content.contains("fake-secret"))
        #expect(!all.content.contains("private editor text"))
        let filtered = try await writer.collect(query: ApplicationLogQuery(category: "language", minimumLevel: "error"))
        #expect(!filtered.content.contains("app.session.started"))
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
        let writer = MacLogStore(fileLimit: 700, totalLimit: 3000, diagnosticNow: { clock.now().timeIntervalSince1970 }, now: clock.now)
        try writer.redirect(to: root)
        await writer.configureDiagnostic(category: "language", enabled: true)
        writer.emit(EditorSyncUnlockFinished(document: LogSegment("document-1")!))
        writer.emit(PerfGitCacheHit(duration: .zero, operation: "other"))
        let enabled = try await writer.collect(query: ApplicationLogQuery())
        #expect(enabled.diagnosticEnabled)
        #expect(enabled.content.contains("editor.sync.unlock_finished"))
        #expect(!enabled.content.contains("perf.git.cache_hit"))
        clock.advance(901)
        writer.emit(EditorSyncUnlockFinished(document: LogSegment("expired")!))
        for index in 0..<12 {
            writer.emit(EditorDocumentOpenFailed(error: NSError(domain: "fixture", code: index), reason: "unavailable"))
        }
        let expired = try await writer.collect(query: ApplicationLogQuery())
        #expect(!expired.diagnosticEnabled)
        #expect(!expired.content.contains("document=expired"))
        #expect(expired.content.contains("error_code=11"))
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        let sizes = (enumerator?.allObjects as? [URL] ?? []).compactMap { url -> Int? in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true ? values?.fileSize : nil
        }
        #expect(sizes.count <= 3)
        #expect(sizes.allSatisfy { $0 <= 700 })
        let languageOnly = try await writer.collect(query: .init(category: "language"))
        #expect(languageOnly.content.contains("error_code=11"))
    }

    @Test
    func runtimeDirectoryFailureFallsBackToTheCollectedDefaultDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("custom")
        let fallback = root.appendingPathComponent("default")
        let notified = TestGate()
        let writer = MacLogStore(defaultDirectory: fallback, onDirectoryFallback: { notified.open() })
        try writer.redirect(to: selected)
        try FileManager.default.removeItem(at: selected)
        try Data("unavailable directory".utf8).write(to: selected)
        writer.emit(EditorTextClassificationFailed())
        let snapshot = try await writer.collect(query: ApplicationLogQuery())
        #expect(snapshot.effectiveDirectory == fallback)
        #expect(snapshot.content.contains("editor.text.classification_failed"))
        #expect(await notified.waitUntilOpen())
        #expect(snapshot.writeFailures == 1)
    }

    @Test
    func repeatedErrorsAreAggregatedBeforeCollection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MacLogStore()
        try writer.redirect(to: root)
        for _ in 0..<3 { writer.emit(EditorTextClassificationFailed()) }
        let snapshot = try await writer.collect(query: ApplicationLogQuery())
        #expect(snapshot.content.components(separatedBy: "event=editor.text.classification_failed").count == 2)
        #expect(snapshot.content.contains("count=2"))
        #expect(snapshot.content.contains("first="))
        #expect(snapshot.content.contains("last="))
    }

    @Test
    func defaultDirectoryProviderUsesTheMacUserLogsDirectory() {
        #expect(MacLogDirectoryProvider().defaultLogDirectory.path.hasSuffix("/Library/Logs/Lithe"))
    }
}

extension MacLogStoreTests {
    @Test
    func typedEventsUseCatalogHeadersAndCorePathRedaction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MacLogStore()
        try writer.redirect(to: root)
        let scope = LogScope(sink: writer, operationID: "operation-1")
        scope.emit(AppLoggingRedirectFailed(directory: URL(fileURLWithPath: "/private/sensitive/location"),
            error: NSError(domain: "fixture", code: 7)))
        let snapshot = try await writer.collect(query: .init())
        #expect(snapshot.content.contains("event=app.logging.redirect_failed"))
        #expect(snapshot.content.contains("op=operation-1"))
        #expect(!snapshot.content.contains("/private/sensitive"))
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL])
        let file = try #require(files.first { $0.lastPathComponent == "app.log" })
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("#lithe-log v2 session="))
        #expect(file.path.contains("/sessions/"))
        await writer.finishSession()
    }

    @Test
    func reservedCapacityCountsDropsAndBroadcastsOnlyEncodedEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "test.log-store.reservation")
        let writer = MacLogStore(capacity: 4, reserved: 2, queue: queue)
        try writer.redirect(to: root)
        queue.suspend()
        writer.emit(AppSessionStarted(operationID: "accepted-1"))
        writer.emit(AppSessionStarted(operationID: "accepted-2"))
        writer.emit(AppSessionStarted(operationID: "dropped-info"))
        writer.emit(AppFontMissing(font: "first"))
        writer.emit(AppFontMissing(font: "second"))
        writer.emit(AppFontMissing(font: "dropped-warning"))
        queue.resume()
        let snapshot = try await writer.collect(query: .init())
        #expect(snapshot.droppedEvents == 2)
        #expect(snapshot.content.contains("event=log.dropped"))
        #expect(snapshot.content.contains("count=2"))
        #expect(!snapshot.content.contains("dropped-warning"))
        let stream = try await writer.subscribe()
        let observed = TestGate()
        let consumer = Task {
            for await batch in stream {
                #expect(batch.contains { $0.line.contains("event=log.dropped") })
                observed.open()
                break
            }
        }
        defer { consumer.cancel() }
        #expect(await observed.waitUntilOpen())
        await writer.finishSession()
        await consumer.value
    }

    @Test
    func expiredControlDoesNotDrainQueuedEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MacLogStore()
        try writer.redirect(to: root)
        do {
            try await writer.flush(timeout: 0)
            Issue.record("Expired control unexpectedly ran")
        } catch { #expect((error as NSError).code == CocoaError.userCancelled.rawValue) }
        let empty = try await writer.collect(query: .init())
        #expect(empty.content.isEmpty)
        writer.emit(AppFontMissing(font: "after-timeout"))
        let snapshot = try await writer.collect(query: .init())
        #expect(snapshot.content.contains("after-timeout"))
        await writer.finishSession()
    }

    @Test
    func retentionDeletesExpiredSessionsAndHandleEvictionPreservesHeaders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LogTestClock()
        let writer = MacLogStore(handleLimit: 2, now: clock.now)
        try writer.redirect(to: root)
        let expired = root.appendingPathComponent("sessions/2020-01-01T00-00-00_abcdef12")
        try FileManager.default.createDirectory(at: expired, withIntermediateDirectories: true)
        try Data("old evidence".utf8).write(to: expired.appendingPathComponent("app.log"))
        for index in 0..<35 {
            let server = try #require(LogSegment("server-\(index)"))
            writer.emit(LspStderrReceived(diagnostic: "upstream warning", server: server))
        }
        let snapshot = try await writer.collect(query: .init())
        #expect(!FileManager.default.fileExists(atPath: expired.path))
        #expect(snapshot.writeFailures == 0)
        #expect(snapshot.files.filter { $0.relativePath.hasSuffix(".log") }.count == 35)
        await writer.finishSession()
    }
}

extension MacLogStoreTests {
    @Test
    func fullBatchWritesBeforeTheExplicitFlushBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "test.log-store.batch")
        let writer = MacLogStore(queue: queue)
        try writer.redirect(to: root)
        queue.suspend()
        for index in 0..<256 { writer.emit(AppFontMissing(font: "font-\(index)")) }
        let written = TestGate()
        queue.async {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            let text = files.first { $0.lastPathComponent == "app.log" }.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            #expect(text?.contains("font-255") == true)
            written.open()
        }
        queue.resume()
        #expect(await written.waitUntilOpen())
        await writer.finishSession()
    }
}

private struct ClockAdvancingLogEvent: LogEvent {
    let clock: LogTestClock
    static let id = AppFontMissing.id
    static let level = AppFontMissing.level
    static let messageTemplate = AppFontMissing.messageTemplate
    static let ratePerMinute = AppFontMissing.ratePerMinute
    static let owner = AppFontMissing.owner
    static let debugOnly = false
    let operationID: String? = nil
    var channel: LogChannel { AppFontMissing(font: "clock-boundary").channel }
    var fields: [String: LogFieldValue] {
        clock.advance(20)
        return AppFontMissing(font: "clock-boundary").fields
    }
}

extension MacLogStoreTests {
    @Test func controlExpiryDuringDrainPreservesAcceptedSuffixAndDropSummary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LogTestClock()
        let queue = DispatchQueue(label: "test.log.expiry")
        let admitted = TestGate()
        let writer = MacLogStore(capacity: 600, reserved: 0, queue: queue,
            diagnosticNow: { admitted.open(); return clock.now().timeIntervalSince1970 })
        try writer.redirect(to: root)
        queue.suspend()
        let control = Task { try? await writer.flush(timeout: 10) }
        #expect(await admitted.waitUntilOpen())
        writer.emit(ClockAdvancingLogEvent(clock: clock))
        for index in 1..<600 { writer.emit(AppFontMissing(font: "accepted-\(index)")) }
        writer.emit(AppFontMissing(font: "dropped"))
        queue.resume()
        await control.value
        let snapshot = try await writer.collect(query: .init())
        #expect(snapshot.content.contains("accepted-599"))
        #expect(snapshot.content.contains("clock-boundary"))
        #expect(snapshot.content.contains("event=log.dropped"))
        #expect(snapshot.droppedEvents == 1)
        #expect(snapshot.writeFailures == 0)
        await writer.finishSession()
    }

    @Test func coreNormalizesMultilineErrorsAndPreservesStringFailureCodes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MacLogStore()
        try writer.redirect(to: root)
        writer.emit(EditorDocumentOpenFailed(error: NSError(domain: "fixture", code: 42,
            userInfo: [NSLocalizedDescriptionKey: "password=fixture-secret\n" + String(repeating: "界", count: 600)]), reason: "unavailable"))
        var span = VcsGitRequestSpan.begin(command: "fetch", provider: LogSegment("git")!, emit: writer.emit)
        span.fail(LogFailure(domain: "git.core", code: "cancelled"), failureCode: "cancelled")
        let snapshot = try await writer.collect(query: .init())
        #expect(snapshot.writeFailures == 0)
        #expect(snapshot.content.contains("error_code=42"))
        #expect(snapshot.content.contains("error_code=cancelled"))
        #expect(!snapshot.content.contains("fixture-secret"))
        await writer.finishSession()
    }

    @Test func rotatingDottedChannelNeverMovesAnotherOpenChannel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = MacLogStore(fileLimit: 550)
        try writer.redirect(to: root)
        let foo = LogSegment("foo")!, dotted = LogSegment("foo.1")!
        writer.emit(LspStderrReceived(diagnostic: "dotted-before", server: dotted))
        for index in 0..<4 { writer.emit(LspStderrReceived(diagnostic: "foo-\(index)", server: foo)) }
        writer.emit(LspStderrReceived(diagnostic: "dotted-after", server: dotted))
        let snapshot = try await writer.collect(query: .init())
        #expect(snapshot.writeFailures == 0)
        #expect(snapshot.content.contains("dotted-before"))
        #expect(snapshot.content.contains("dotted-after"))
        for index in 0..<4 { #expect(snapshot.content.contains("foo-\(index)")) }
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL])
        #expect(files.contains { $0.lastPathComponent == "foo~1.log" })
        for file in files where file.pathExtension == "log" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let expected = file.lastPathComponent == "foo.1.log" ? "lsp/foo.1" : "lsp/foo"
            #expect(text.components(separatedBy: "\n").first?.contains("channel=" + expected + " ") == true)
        }
        await writer.finishSession()
    }

    @Test func finishBypassesSaturatedControlsAndClosesEvenWhenDrainFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected"), fallback = root.appendingPathComponent("fallback")
        let queue = DispatchQueue(label: "test.log.finish.saturated")
        let admission = LogControlAdmission()
        let writer = MacLogStore(defaultDirectory: fallback, queue: queue, diagnosticNow: admission.now)
        try writer.redirect(to: selected)
        writer.emit(AppFontMissing(font: "opened-handle"))
        try await writer.flush()
        let stream = try await writer.subscribe()
        let ended = TestGate()
        let consumer = Task { for await _ in stream {}; ended.open() }
        defer { consumer.cancel() }
        // Keep an existing open handle, then make both destinations unavailable.
        try FileManager.default.removeItem(at: selected)
        try Data().write(to: selected)
        try Data().write(to: fallback)
        queue.suspend()
        admission.arm()
        let controls = (0..<4).map { _ in Task { try? await writer.flush(timeout: 0) } }
        let accepted = await admission.allAccepted.waitUntilOpen()
        #expect(accepted)
        writer.emit(EditorTextClassificationFailed())
        let finish = Task { await writer.finishSession() }
        defer { for control in controls { control.cancel() }; finish.cancel() }
        queue.resume()
        for control in controls { await control.value }
        await finish.value
        let terminated = await ended.waitUntilOpen()
        #expect(terminated)
        if !terminated { consumer.cancel() }
        await consumer.value
    }

    @Test func cancelledFinishStillClosesSubscriptionsAndHandles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "test.log.finish")
        let writer = MacLogStore(queue: queue)
        try writer.redirect(to: root)
        writer.emit(AppFontMissing(font: "before-close"))
        try await writer.flush()
        let stream = try await writer.subscribe()
        let ended = TestGate()
        let consumer = Task { for await _ in stream {}; ended.open() }
        defer { consumer.cancel() }
        queue.suspend()
        let finish = Task { await writer.finishSession() }
        finish.cancel()
        queue.resume()
        await finish.value
        let terminated = await ended.waitUntilOpen()
        #expect(terminated)
        if !terminated { consumer.cancel() }
        await consumer.value
        // A finished store must not create a new live subscription.
        let after = try await writer.subscribe()
        let afterEnded = TestGate()
        let afterConsumer = Task { for await _ in after {}; afterEnded.open() }
        defer { afterConsumer.cancel() }
        #expect(await afterEnded.waitUntilOpen())
        afterConsumer.cancel()
        await afterConsumer.value
    }
}

private final class LogControlAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 0
    let allAccepted = TestGate()
    func arm() { lock.withLock { remaining = 4 } }
    func now() -> TimeInterval {
        let complete = lock.withLock { () -> Bool in
            guard remaining > 0 else { return false }
            remaining -= 1
            return remaining == 0
        }
        if complete { allAccepted.open() }
        return 100
    }
}
