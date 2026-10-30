import Foundation
import Testing
@testable import Lithe

@MainActor
struct PluginHostMessageServiceTests {
    private typealias Outcome = Task<PluginHostMessageOutcome, any Error>

    private func request(
        _ fixture: PluginHostFixture, _ text: String = "Build finished",
        severity: PluginHostMessageSeverity = .information, actions: [String] = [],
        caller: PluginHostCaller? = nil, windowID: UUID? = nil
    ) -> PluginHostMessageRequest {
        PluginHostMessageRequest(
            context: fixture.context(windowID: windowID, caller: caller),
            severity: severity, text: text, actions: actions
        )
    }

    private func start(_ service: PluginHostMessageService, _ request: PluginHostMessageRequest) -> Outcome {
        Task { @MainActor in try await service.show(request) }
    }

    private func waitForPending(
        _ messages: PluginHostMessageFeatureModel, _ count: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let reached = await waitForPluginHostMessages(messages) { messages.pendingCount == count }
        #expect(reached, "Pending messages were \(messages.pendingCount), expected \(count)", sourceLocation: sourceLocation)
    }

    // MARK: Answers

    @Test func theUsersChoiceComesBackAsTheIndexOfTheButton() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let service = fixture.messageService()
        let messages = fixture.window.messages

        let outcome = start(service, request(fixture, actions: ["Open", "Later"]))
        await waitForPending(messages, 1)
        let shown = try #require(messages.visible.first)
        messages.choose(shown.id, index: 1)

        #expect(try await outcome.value == .selected(index: 1))
        #expect(messages.pendingCount == 0)
    }

    @Test func closingAMessageIsAnAnswerOfItsOwn() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let service = fixture.messageService()
        let messages = fixture.window.messages

        let outcome = start(service, request(fixture, severity: .error, actions: ["Retry"]))
        await waitForPending(messages, 1)
        messages.dismiss(try #require(messages.visible.first).id)

        #expect(try await outcome.value == .dismissed(.user))
    }

    @Test func textAndButtonsAreShownExactlyAsThePluginWroteThem() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let service = fixture.messageService()
        let messages = fixture.window.messages
        let text = "Deploy 100% done\n  next: %@ {arg1} \"quoted\" 部署完成"
        let actions = ["View %@", "了解"]

        let outcome = start(service, request(fixture, text, severity: .warning, actions: actions))
        await waitForPending(messages, 1)
        let shown = try #require(messages.visible.first)

        #expect(shown.text == text)
        #expect(shown.actions == actions)
        #expect(shown.severity == .warning)
        #expect(shown.pluginID == fixture.caller.pluginID)
        #expect(shown.pluginName == fixture.caller.pluginName)
        #expect(shown.workspaceGeneration == PluginHostFixture.defaultGeneration)
        messages.dismiss(shown.id)
        _ = try await outcome.value
    }

    @Test func aMessageWithoutButtonsIsAccepted() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let service = fixture.messageService()
        let messages = fixture.window.messages

        let outcome = start(service, request(fixture))
        await waitForPending(messages, 1)
        messages.dismiss(try #require(messages.visible.first).id)

        #expect(try await outcome.value == .dismissed(.user))
    }

    // MARK: Queue

    @Test func messagesBeyondTheVisibleLimitWaitAndAppearOnceRoomIsMade() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let messages = fixture.window.messages
        var limits = PluginHostMessageLimits()
        limits.maxPendingPerPlugin = 10
        let crowded = fixture.messageService(limits: limits)

        var outcomes: [Outcome] = []
        for index in 0...PluginHostMessageFeatureModel.visibleLimit {
            outcomes.append(start(crowded, request(fixture, "message \(index)", actions: ["OK"])))
            await waitForPending(messages, index + 1)
        }
        #expect(messages.visible.map(\.text) == ["message 0", "message 1", "message 2"])
        #expect(messages.queued.map(\.text) == ["message 3"])

        messages.choose(try #require(messages.visible.first).id, index: 0)
        #expect(try await outcomes[0].value == .selected(index: 0))

        // The waiting message took the freed place, in order.
        #expect(messages.visible.map(\.text) == ["message 1", "message 2", "message 3"])
        #expect(messages.queued.isEmpty)
    }

    @Test func aPluginCannotHaveMoreThanItsShareOfMessagesPending() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let service = fixture.messageService()
        let messages = fixture.window.messages
        let other = PluginHostCaller(pluginID: "com.example.other", pluginName: "Other")

        var outcomes: [Outcome] = []
        for index in 0..<PluginHostMessageLimits().maxPendingPerPlugin {
            outcomes.append(start(service, request(fixture, "m\(index)")))
            await waitForPending(messages, index + 1)
        }

        await #expect(throws: PluginHostError.messageQueueFull) {
            try await service.show(request(fixture, "one too many"))
        }
        // The cap is per plugin: another plugin still gets through.
        let otherOutcome = start(service, request(fixture, "from other", caller: other))
        await waitForPending(messages, outcomes.count + 1)
        #expect(messages.pendingCount(forPlugin: other.pluginID) == 1)

        messages.dismissAll(.windowClosed)
        for outcome in outcomes + [otherOutcome] { #expect(try await outcome.value == .dismissed(.windowClosed)) }
    }

    @Test func aWindowCannotHoldMoreThanItsOwnCapOfMessages() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        var limits = PluginHostMessageLimits()
        limits.maxPendingPerWindow = 2
        let service = fixture.messageService(limits: limits)
        let messages = fixture.window.messages
        let first = PluginHostCaller(pluginID: "com.example.one", pluginName: "One")
        let second = PluginHostCaller(pluginID: "com.example.two", pluginName: "Two")
        let third = PluginHostCaller(pluginID: "com.example.three", pluginName: "Three")

        let a = start(service, request(fixture, "a", caller: first))
        await waitForPending(messages, 1)
        let b = start(service, request(fixture, "b", caller: second))
        await waitForPending(messages, 2)

        await #expect(throws: PluginHostError.messageQueueFull) {
            try await service.show(request(fixture, "c", caller: third))
        }
        messages.dismissAll(.workspaceChanged)
        #expect(try await a.value == .dismissed(.workspaceChanged))
        #expect(try await b.value == .dismissed(.workspaceChanged))
    }

    // MARK: Rate limit

    @Test func aFloodIsRefusedAndTheUserIsToldOnceUntilTheWindowOfTimePasses() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        var limits = PluginHostMessageLimits()
        limits.maxRequestsPerInterval = 2
        limits.interval = 10
        let service = fixture.messageService(limits: limits)
        let messages = fixture.window.messages
        let other = PluginHostCaller(pluginID: "com.example.other", pluginName: "Other")

        for index in 0..<2 {
            let outcome = start(service, request(fixture, "m\(index)"))
            await waitForPending(messages, 1)
            messages.dismiss(try #require(messages.visible.first).id)
            #expect(try await outcome.value == .dismissed(.user))
        }

        for _ in 0..<3 {
            await #expect(throws: PluginHostError.rateLimited) {
                try await service.show(request(fixture, "flood"))
            }
        }
        #expect(fixture.window.limitNotices == [fixture.caller.pluginName])
        #expect(messages.pendingCount == 0)

        // Another plugin has its own allowance.
        let otherOutcome = start(service, request(fixture, "unaffected", caller: other))
        await waitForPending(messages, 1)
        messages.dismiss(try #require(messages.visible.first).id)
        #expect(try await otherOutcome.value == .dismissed(.user))

        // Time moves on without waiting: the plugin is admitted again.
        fixture.clock.now += limits.interval + 1
        let again = start(service, request(fixture, "back"))
        await waitForPending(messages, 1)
        messages.dismiss(try #require(messages.visible.first).id)
        #expect(try await again.value == .dismissed(.user))
    }

    @Test func theRateLimitIsKeptPerWindow() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        var limits = PluginHostMessageLimits()
        limits.maxRequestsPerInterval = 1
        let service = fixture.messageService(limits: limits)
        let second = fixture.addWindow(isForeground: false)

        let first = start(service, request(fixture, "one"))
        await waitForPending(fixture.window.messages, 1)
        await #expect(throws: PluginHostError.rateLimited) {
            try await service.show(request(fixture, "two"))
        }

        // The other window has not been spoken to yet.
        let elsewhere = start(service, request(fixture, "three", windowID: second.id))
        await waitForPending(second.window.messages, 1)
        #expect(fixture.window.limitNotices.count == 1)
        #expect(second.window.limitNotices.isEmpty)

        fixture.window.messages.dismissAll(.cancelled)
        second.window.messages.dismissAll(.cancelled)
        _ = try await first.value
        _ = try await elsewhere.value
    }

    // MARK: Validation

    @Test func malformedMessagesAreRefusedBeforeAnythingShows() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let service = fixture.messageService()
        let limits = PluginHostMessageLimits()
        let malformed: [PluginHostMessageRequest] = [
            request(fixture, ""),
            request(fixture, "   \n\t "),
            request(fixture, String(repeating: "x", count: limits.maxTextLength + 1)),
            request(fixture, "bell\u{7}"),
            request(fixture, "escape\u{1B}[31m"),
            request(fixture, "ok", actions: ["a", "b", "c", "d"]),
            request(fixture, "ok", actions: [""]),
            request(fixture, "ok", actions: ["   "]),
            request(fixture, "ok", actions: [String(repeating: "y", count: limits.maxActionLength + 1)]),
            request(fixture, "ok", actions: ["multi\nline"])
        ]

        for message in malformed {
            await #expect(throws: PluginHostError.invalidMessage, "text: \(message.text.debugDescription)") {
                try await service.show(message)
            }
        }
        #expect(fixture.window.messages.pendingCount == 0)
        // A refused message does not count against the plugin's allowance.
        #expect(fixture.window.limitNotices.isEmpty)
    }

    @Test func textAtTheLimitsAndMultilineTextAreAccepted() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let service = fixture.messageService()
        let messages = fixture.window.messages
        let limits = PluginHostMessageLimits()
        let text = String(repeating: "x", count: limits.maxTextLength - 3) + "\na\t"
        let actions = [String(repeating: "y", count: limits.maxActionLength), "b", "c"]

        let outcome = start(service, request(fixture, text, actions: actions))
        await waitForPending(messages, 1)
        #expect(messages.visible.first?.text == text)
        messages.dismissAll(.cancelled)
        _ = try await outcome.value
    }

    // MARK: Window scope

    @Test func aMessageShowsInTheNamedWindowAndNotInTheOneInFront() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let service = fixture.messageService()
        let background = fixture.addWindow(isForeground: false)

        let outcome = start(service, request(fixture, "for the back window", windowID: background.id))
        await waitForPending(background.window.messages, 1)

        #expect(fixture.window.messages.pendingCount == 0)
        background.window.messages.dismissAll(.windowClosed)
        #expect(try await outcome.value == .dismissed(.windowClosed))
    }

    @Test func closingTheWindowEndsShowingAndWaitingMessages() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        var limits = PluginHostMessageLimits()
        limits.maxPendingPerPlugin = 10
        let service = fixture.messageService(limits: limits)
        let messages = fixture.window.messages

        var outcomes: [Outcome] = []
        for index in 0...PluginHostMessageFeatureModel.visibleLimit {
            outcomes.append(start(service, request(fixture, "m\(index)")))
            await waitForPending(messages, index + 1)
        }
        messages.dismissAll(.windowClosed)

        for outcome in outcomes { #expect(try await outcome.value == .dismissed(.windowClosed)) }
        #expect(messages.pendingCount == 0)
    }

    @Test func aCancelledCallRemovesItsOwnMessage() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let service = fixture.messageService()
        let messages = fixture.window.messages

        let outcome = start(service, request(fixture, "will be cancelled"))
        await waitForPending(messages, 1)
        outcome.cancel()

        #expect(try await outcome.value == .dismissed(.cancelled))
        await waitForPending(messages, 0)
    }

    @Test func remoteMissingAndReplacedWindowsAreRefused() async {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let service = fixture.messageService()

        await #expect(throws: PluginHostError.windowUnavailable) {
            try await service.show(request(fixture, windowID: UUID()))
        }
        await #expect(throws: PluginHostError.workspaceChanged) {
            try await service.show(PluginHostMessageRequest(
                context: fixture.context(generation: PluginHostFixture.defaultGeneration + 1),
                severity: .information, text: "stale"
            ))
        }
        fixture.updateSnapshot(isRemote: true)
        await #expect(throws: PluginHostError.remoteWorkspaceUnsupported) {
            try await service.show(request(fixture))
        }
        #expect(fixture.window.messages.pendingCount == 0)
    }

    // MARK: Entry model

    @Test func answeringAnUnknownMessageOrButtonChangesNothing() async throws {
        let fixture = PluginHostFixture()
        defer { fixture.tearDown() }
        let service = fixture.messageService()
        let messages = fixture.window.messages

        let outcome = start(service, request(fixture, actions: ["Only"]))
        await waitForPending(messages, 1)
        let shown = try #require(messages.visible.first)

        messages.choose(UUID(), index: 0)
        messages.choose(shown.id, index: 1)
        messages.choose(shown.id, index: -1)
        messages.dismiss(UUID())
        #expect(messages.pendingCount == 1)

        messages.choose(shown.id, index: 0)
        #expect(try await outcome.value == .selected(index: 0))
        // A second answer to a finished message is ignored.
        messages.choose(shown.id, index: 0)
        #expect(messages.pendingCount == 0)
    }
}

struct PluginHostRateLimiterTests {
    @Test func admitsUpToTheLimitThenDeniesAndNoticesOncePerInterval() {
        var limiter = PluginHostRateLimiter(maxRequests: 2, interval: 10)

        #expect(limiter.admit(key: "a", now: 0) == .allowed)
        #expect(limiter.admit(key: "a", now: 1) == .allowed)
        #expect(limiter.admit(key: "a", now: 2) == .denied(shouldNotify: true))
        #expect(limiter.admit(key: "a", now: 3) == .denied(shouldNotify: false))
        #expect(limiter.admit(key: "b", now: 3) == .allowed)
        // The first request expires at 10, which frees one place.
        #expect(limiter.admit(key: "a", now: 10) == .allowed)
        // Still within ten seconds of the notice at 2, so the user is not told again.
        #expect(limiter.admit(key: "a", now: 10.5) == .denied(shouldNotify: false))
        #expect(limiter.admit(key: "a", now: 11) == .allowed)
        // The notice at 2 is now ten seconds old, so a new flood is announced again.
        #expect(limiter.admit(key: "a", now: 12) == .denied(shouldNotify: true))
    }

    @Test func aDeniedRequestDoesNotExtendThePenalty() {
        var limiter = PluginHostRateLimiter(maxRequests: 1, interval: 5)

        #expect(limiter.admit(key: "a", now: 0) == .allowed)
        for second in 1..<5 { #expect(limiter.admit(key: "a", now: Double(second)) != .allowed) }

        #expect(limiter.admit(key: "a", now: 5) == .allowed)
    }
}

/// A timeout that never fires by itself: it waits until the flush cancels it,
/// so these tests neither sleep nor depend on the clock.
private func parkUntilCancelled(_ duration: Duration) async throws {
    while !Task.isCancelled { await Task.yield() }
    throw CancellationError()
}

@MainActor
struct PluginHostEditorFlushTests {
    @Test func anImmediateAnswerWinsOverALongTimeout() async {
        let confirmed = await PluginHostEditorFlush.run(
            timeout: .seconds(3600),
            sleep: parkUntilCancelled,
            request: { $0(true) }
        )

        #expect(confirmed)
    }

    @Test func anAnswerThatIsFalseIsFalse() async {
        let confirmed = await PluginHostEditorFlush.run(
            timeout: .seconds(3600), sleep: parkUntilCancelled, request: { $0(false) }
        )

        #expect(!confirmed)
    }

    @Test func aTimeoutThatFiresFirstGivesFalseAndTheLateAnswerIsIgnored() async {
        var late: (@MainActor (Bool) -> Void)?

        let confirmed = await PluginHostEditorFlush.run(
            timeout: .seconds(1), sleep: { _ in }, request: { late = $0 }
        )
        // The editor answering after the bound must not resume anything twice.
        late?(true)

        #expect(!confirmed)
    }

    @Test func anAnswerThatArrivesLaterBeforeTheTimeoutIsUsed() async {
        let confirmed = await PluginHostEditorFlush.run(
            timeout: .seconds(3600),
            sleep: parkUntilCancelled,
            request: { answer in Task { @MainActor in answer(true) } }
        )

        #expect(confirmed)
    }

    @Test func aRepeatedAnswerIsIgnored() async {
        let confirmed = await PluginHostEditorFlush.run(
            timeout: .seconds(3600),
            sleep: parkUntilCancelled,
            request: { answer in
                answer(true)
                answer(false)
            }
        )

        #expect(confirmed)
    }
}
