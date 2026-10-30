import Testing
@testable import Lithe

@Suite("Settings latency input correlation")
@MainActor
struct SettingsPageLatencyTraceTests {
    @Test func mouseDownAndUpCanSelectOnlyOnce() {
        var inputs = SettingsPageLatencyTrace.InputCorrelation()
        #expect(inputs.receive(id: 7, input: 10, at: 20)?.id == 7)
        #expect(inputs.take(eventID: 7, isMouse: true, at: 30)?.id == 7)
        // The mouse-up is the same tagged click, not a second correlation.
        #expect(inputs.receive(id: 7, input: 10, at: 40) == nil)
        #expect(inputs.take(eventID: 7, isMouse: true, at: 50) == nil)
    }

    @Test func keyboardNavigationCannotReuseAPreviousClick() {
        var inputs = SettingsPageLatencyTrace.InputCorrelation()
        _ = inputs.receive(id: 7, input: 10, at: 20)
        #expect(inputs.take(eventID: 7, isMouse: false, at: 30) == nil)
        #expect(inputs.take(eventID: 7, isMouse: true, at: 40) == nil)
    }

    @Test func unrelatedUnmarkedAndExpiredInputsAreRejected() {
        var inputs = SettingsPageLatencyTrace.InputCorrelation()
        _ = inputs.receive(id: 7, input: 10, at: 20)
        #expect(inputs.take(eventID: 8, isMouse: true, at: 30) == nil)
        _ = inputs.receive(id: 8, input: 40, at: 50)
        _ = inputs.receive(id: 0, input: 60, at: 70)
        #expect(inputs.take(eventID: 8, isMouse: true, at: 80) == nil)
        _ = inputs.receive(id: 9, input: 90, at: 100)
        #expect(inputs.take(eventID: 9, isMouse: true, at: 1_000_000_100) == nil)
    }
}
