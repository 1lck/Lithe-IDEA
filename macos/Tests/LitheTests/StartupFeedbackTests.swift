import Foundation
import Testing
@testable import Lithe

@Suite("Startup feedback")
@MainActor
struct StartupFeedbackTests {
    @Test
    func quickStartupIsSkippedWithoutShowingAnything() {
        let clock = FakeStartupFeedbackClock()
        let feedback = StartupFeedbackCoordinator(clock: clock)

        feedback.start()
        // The animation is scheduled, but the startup finishes before the
        // threshold elapses.
        #expect(clock.pendingActionCount == 1)
        clock.advance(by: 0.1)
        feedback.markReady()

        #expect(feedback.outcome == .ready)
        #expect(!feedback.isVisible)
        #expect(!feedback.isFading)
        // A skipped startup leaves no scheduled action behind.
        #expect(clock.pendingActionCount == 0)
    }

    @Test
    func slowStartupShowsTheCurrentPhaseAndFadesOut() {
        let clock = FakeStartupFeedbackClock()
        let feedback = StartupFeedbackCoordinator(clock: clock)

        feedback.start()
        clock.advance(by: 0.5)
        #expect(feedback.isVisible)
        #expect(feedback.stage == .preparing)

        feedback.setStage(.openingWorkspace)
        #expect(feedback.stage == .openingWorkspace)

        feedback.markReady()
        #expect(feedback.outcome == .ready)
        #expect(feedback.isVisible)
        #expect(feedback.isFading)

        clock.advance(by: 0.18)
        #expect(!feedback.isVisible)
        #expect(!feedback.isFading)
    }

    @Test
    func failedStartupStaysVisibleUntilTheUserDismissesIt() {
        let clock = FakeStartupFeedbackClock()
        let feedback = StartupFeedbackCoordinator(clock: clock)

        feedback.start()
        clock.advance(by: 0.5)
        feedback.markFailed(code: .workspaceOpenFailed, message: "Could not read the project folder.")

        #expect(feedback.outcome == .failed)
        #expect(feedback.isVisible)
        #expect(!feedback.isFading)
        #expect(feedback.failureCode == .workspaceOpenFailed)
        #expect(feedback.failureMessage == "Could not read the project folder.")

        // The failure reason stays readable; only the user can dismiss it.
        clock.advance(by: 5)
        #expect(feedback.isVisible)

        feedback.dismiss()
        #expect(!feedback.isVisible)
    }

    @Test
    func disabledAnimationNeverShowsAndNeverDelays() {
        let clock = FakeStartupFeedbackClock()
        let feedback = StartupFeedbackCoordinator(clock: clock)

        feedback.setEnabled(false)
        feedback.start()

        #expect(clock.pendingActionCount == 0)
        #expect(!feedback.isVisible)

        clock.advance(by: 1)
        #expect(!feedback.isVisible)

        feedback.markReady()
        #expect(!feedback.isVisible)
        #expect(clock.pendingActionCount == 0)
    }

    @Test
    func phasesOnlyAdvanceWhileTheStartupIsRunning() {
        let clock = FakeStartupFeedbackClock()
        let feedback = StartupFeedbackCoordinator(clock: clock)

        feedback.start()
        feedback.setStage(.openingWorkspace)
        #expect(feedback.stage == .openingWorkspace)

        feedback.markReady()
        feedback.setStage(.restoringSession)
        #expect(feedback.stage == .openingWorkspace)
    }

    @Test
    func aLaterFailureCannotReplayTheStartupAnimation() {
        let clock = FakeStartupFeedbackClock()
        let feedback = StartupFeedbackCoordinator(clock: clock)

        feedback.start()
        feedback.markReady()
        feedback.markFailed(code: .pluginLoadFailed, message: "later")

        #expect(feedback.outcome == .ready)
        #expect(!feedback.isVisible)
        #expect(feedback.failureCode == nil)
    }

    @Test
    func readinessReportedBeforeTheAnimationStartsSkipsTheAnimation() {
        let clock = FakeStartupFeedbackClock()
        let feedback = StartupFeedbackCoordinator(clock: clock)

        // The workspace can finish loading before the window becomes visible.
        feedback.markReady()
        feedback.start()

        #expect(feedback.outcome == .ready)
        #expect(!feedback.isVisible)
        #expect(!feedback.isFading)
        #expect(clock.pendingActionCount == 0)
    }

    @Test
    func failureReportedBeforeTheAnimationStartsIsShownImmediately() {
        let clock = FakeStartupFeedbackClock()
        let feedback = StartupFeedbackCoordinator(clock: clock)

        feedback.markFailed(code: .sessionRestoreFailed, message: "Could not restore the last session.")
        feedback.start()

        #expect(feedback.outcome == .failed)
        #expect(feedback.isVisible)
        #expect(feedback.failureCode == .sessionRestoreFailed)
        #expect(feedback.failureMessage == "Could not restore the last session.")
    }

    @Test
    func theSkipThresholdIsMeasuredFromTheApplicationLaunch() {
        let clock = FakeStartupFeedbackClock()
        let feedback = StartupFeedbackCoordinator(clock: clock)

        // The application was already busy for longer than the threshold
        // before the window became visible, so the animation starts at once.
        clock.advance(by: 0.5)
        feedback.start()

        #expect(feedback.outcome == .loading)
        #expect(feedback.isVisible)
        #expect(clock.pendingActionCount == 0)
    }

    @Test
    func startupStagesMatchTheSharedContract() throws {
        let fixture = try sharedStartupFeedbackFixture()

        #expect(fixture.version == 1)
        #expect(fixture.stages.map(\.id) == StartupStage.allCases.map(\.rawValue))
        #expect(fixture.stages.map(\.order) == Array(1...fixture.stages.count))
        #expect(fixture.outcomes == ["idle", "loading", "ready", "failed"])
        #expect(StartupFeedbackTiming.minimumVisibleDuration == .milliseconds(fixture.minimumVisibleDurationMs))
        #expect(StartupFeedbackTiming.fadeOutDuration == .milliseconds(fixture.fadeOutDurationMs))
        #expect(Set(fixture.failureCodes) == Set(StartupFailureCode.allCases.map(\.rawValue)))

        for stage in fixture.stages {
            #expect(StartupStage(rawValue: stage.id)?.englishLabel == stage.labels.en)
        }
    }

    @Test
    func simplifiedChineseResourcesCoverTheStartupFeedbackWording() throws {
        let translations = try simplifiedChineseTranslations()
        let fixture = try sharedStartupFeedbackFixture()

        for stage in fixture.stages {
            #expect(translations[stage.labels.en] == stage.labels.zhHans)
        }
        for message in fixture.messages.values {
            #expect(translations[message.labels.en] == message.labels.zhHans)
        }
    }

    @Test
    func startupAnimationSwitchIsEnabledByDefaultAndPersists() {
        let store = StartupFeedbackSettingsStore()
        let settings = AppSettings(store: store)

        #expect(settings.startupAnimationEnabled)

        settings.startupAnimationEnabled = false
        #expect(!(AppSettings(store: store).startupAnimationEnabled))

        settings.restoreDefaults()
        #expect(settings.startupAnimationEnabled)
    }

    private func sharedStartupFeedbackFixture() throws -> StartupFeedbackFixture {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: repositoryRoot.appendingPathComponent("shared/fixtures/settings/startup-feedback-v1.json")
        )
        return try JSONDecoder().decode(StartupFeedbackFixture.self, from: data)
    }

    private func simplifiedChineseTranslations() throws -> [String: String] {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourceURL = macosRoot
            .appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings")
        let data = try Data(contentsOf: resourceURL)
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try #require(propertyList as? [String: String])
    }
}

private struct StartupFeedbackFixture: Decodable {
    struct Labels: Decodable {
        let en: String
        let zhHans: String
    }

    struct Stage: Decodable {
        let id: String
        let order: Int
        let labelKey: String
        let labels: Labels
    }

    struct Message: Decodable {
        let labelKey: String
        let labels: Labels
    }

    let version: Int
    let minimumVisibleDurationMs: Int
    let fadeOutDurationMs: Int
    let outcomes: [String]
    let stages: [Stage]
    let failureCodes: [String]
    let messages: [String: Message]
}

/// A deterministic clock, so the skip threshold and the fade-out are verified
/// without waiting for real time to pass.
@MainActor
final class FakeStartupFeedbackClock: StartupFeedbackClock {
    private struct ScheduledAction {
        let token: StartupFeedbackTimerToken
        let dueTime: TimeInterval
        let action: @MainActor () -> Void
    }

    private var currentTime: TimeInterval = 0
    private var nextToken: UInt64 = 0
    private var scheduledActions: [ScheduledAction] = []

    var pendingActionCount: Int { scheduledActions.count }

    func now() -> TimeInterval { currentTime }

    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) -> StartupFeedbackTimerToken {
        nextToken += 1
        let token = StartupFeedbackTimerToken(id: nextToken)
        scheduledActions.append(
            ScheduledAction(token: token, dueTime: currentTime + delay.secondsValue, action: action)
        )
        return token
    }

    func cancel(_ token: StartupFeedbackTimerToken) {
        scheduledActions.removeAll { $0.token == token }
    }

    /// Advances the clock and runs every action that is due.
    func advance(by seconds: TimeInterval) {
        currentTime += seconds
        let due = scheduledActions.filter { $0.dueTime <= currentTime }.sorted { $0.dueTime < $1.dueTime }
        scheduledActions.removeAll { $0.dueTime <= currentTime }
        for item in due {
            item.action()
        }
    }
}

private final class StartupFeedbackSettingsStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
