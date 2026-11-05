import Testing
@testable import Lithe

struct RustDebugShortcutOperationsTests {
    @Test func combinedDebugShortcutUsesTheSharedSessionDecision() throws {
        let core = RustCoreBridge()
        #expect(try core.debugStartOrContinue(active: false, paused: false, requestPending: false) == .start)
        #expect(try core.debugStartOrContinue(active: true, paused: true, requestPending: false) == .continue)
        #expect(try core.debugStartOrContinue(active: true, paused: false, requestPending: false) == .none)
        #expect(try core.debugStartOrContinue(active: true, paused: true, requestPending: true) == .none)
    }
}
