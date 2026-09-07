import Foundation
import Testing
@testable import Lithe

@Suite("Document language coordination")
@MainActor
struct DocumentLanguageCoordinatorTests {
    @Test
    func repeatedChangesCancelThePreviousDelayAndRefreshOnlyTheLatestDocument() async {
        let delay = ControlledHintDelay(count: 2)
        let refreshed = TestGate()
        var activations = 0
        var reloads = 0
        var refreshedURLs: [URL] = []
        let document = makeDocument()
        let coordinator = DocumentLanguageCoordinator(
            activate: { _ in activations += 1 },
            reloadProject: { _ in reloads += 1 },
            close: { _ in }, supportsHints: { _ in true },
            refreshHints: { refreshedURLs.append($0); refreshed.open() },
            delay: { try await delay.wait($0) }
        )
        defer {
            coordinator.stop()
            delay.releaseAll()
        }
        coordinator.documentChanged(document)
        #expect(await delay.started[0].waitUntilOpen())
        coordinator.documentChanged(document)
        #expect(await delay.finished[0].waitUntilOpen())
        #expect(await delay.started[1].waitUntilOpen())
        #expect(refreshedURLs.isEmpty)

        delay.releases[1].open()
        #expect(await refreshed.waitUntilOpen())
        #expect(activations == 2)
        #expect(reloads == 2)
        #expect(refreshedURLs == [document.url])
        #expect(await delay.durations == [.milliseconds(450), .milliseconds(450)])
    }

    @Test(arguments: [Cancellation.closeDocument, .stopSession, .releaseCoordinator])
    func cancellationEndsPendingHintsWithoutRefreshing(_ cancellation: Cancellation) async {
        let delay = ControlledHintDelay(count: 1)
        var closed = 0
        var refreshCount = 0
        let document = makeDocument()
        var coordinator: DocumentLanguageCoordinator? = DocumentLanguageCoordinator(
            activate: { _ in }, reloadProject: { _ in },
            close: { _ in closed += 1 }, supportsHints: { _ in true },
            refreshHints: { _ in refreshCount += 1 },
            delay: { try await delay.wait($0) }
        )
        defer {
            coordinator?.stop()
            delay.releaseAll()
        }
        coordinator?.documentChanged(document)
        #expect(await delay.started[0].waitUntilOpen())

        switch cancellation {
        case .closeDocument: coordinator?.documentClosed(document)
        case .stopSession: coordinator?.stop()
        case .releaseCoordinator: coordinator = nil
        }

        #expect(await delay.finished[0].waitUntilOpen())
        #expect(refreshCount == 0)
        #expect(closed == (cancellation == .closeDocument ? 1 : 0))
    }

    @Test
    func unsupportedDocumentsStillActivateReloadAndCloseWithoutSchedulingHints() {
        var events: [String] = []
        let coordinator = DocumentLanguageCoordinator(
            activate: { _ in events.append("activate") },
            reloadProject: { _ in events.append("reload") },
            close: { _ in events.append("close") }, supportsHints: { _ in false },
            refreshHints: { _ in Issue.record("Unexpected hints") },
            delay: { _ in Issue.record("Unexpected delay") }
        )
        defer { coordinator.stop() }
        let document = makeDocument()
        coordinator.documentOpened(document)
        coordinator.documentChanged(document)
        coordinator.documentClosed(document)
        #expect(events == ["activate", "activate", "reload", "close"])
    }

    enum Cancellation: Sendable {
        case closeDocument, stopSession, releaseCoordinator
    }

    private func makeDocument() -> EditorDocument {
        EditorDocument(
            url: URL(fileURLWithPath: "/in-memory/Main.java"),
            text: "class Main {}", modificationDate: nil
        )
    }
}

private actor ControlledHintDelay {
    nonisolated let started: [TestGate]
    nonisolated let releases: [TestGate]
    nonisolated let finished: [TestGate]
    private(set) var durations: [Duration] = []

    init(count: Int) {
        started = (0..<count).map { _ in TestGate() }
        releases = (0..<count).map { _ in TestGate() }
        finished = (0..<count).map { _ in TestGate() }
    }

    func wait(_ duration: Duration) async throws {
        let index = durations.count
        durations.append(duration)
        guard started.indices.contains(index) else {
            Issue.record("Unexpected hint refresh delay")
            throw CancellationError()
        }
        started[index].open()
        defer { finished[index].open() }
        guard await releases[index].waitUntilOpen() else { throw CancellationError() }
        try Task.checkCancellation()
    }

    nonisolated func releaseAll() {
        releases.forEach { $0.open() }
    }
}
