import Testing
@testable import Lithe

/// A settings page left open across module idle sleep must show the
/// re-activated feature, never the released one.
@MainActor
struct ModuleFeatureSelectionTests {
    @Test
    func activationResultShowsBeforeTheCapabilityCacheFills() {
        var selection = ModuleFeatureSelection<FeatureStub>()
        let first = FeatureStub()

        selection.beginActivation(current: nil)
        #expect(selection.feature(current: nil) == nil)
        #expect(selection.isActivating)
        selection.finishActivation(first)

        #expect(selection.feature(current: nil) === first)
        #expect(selection.feature(current: first) === first)
    }

    @Test
    func sleepThenReactivationReplacesTheReleasedFeature() {
        var selection = ModuleFeatureSelection<FeatureStub>()
        let released = FeatureStub()
        selection.beginActivation(current: nil)
        selection.finishActivation(released)

        // The module sleeps: the capability cache is cleared and the page's
        // activation task runs again with no current capability.
        selection.beginActivation(current: nil)
        #expect(selection.feature(current: nil) == nil)
        #expect(selection.activated == nil)

        let reactivated = FeatureStub()
        selection.finishActivation(reactivated)
        #expect(selection.feature(current: nil) === reactivated)
        #expect(selection.feature(current: reactivated) === reactivated)
    }

    @Test
    func currentCapabilityWinsOverAStaleActivation() {
        var selection = ModuleFeatureSelection<FeatureStub>()
        let stale = FeatureStub()
        let current = FeatureStub()
        selection.beginActivation(current: nil)
        selection.finishActivation(stale)

        #expect(selection.feature(current: current) === current)
        selection.beginActivation(current: current)
        #expect(selection.activated == nil)
    }

    @Test
    func failedReactivationShowsNothing() {
        var selection = ModuleFeatureSelection<FeatureStub>()
        selection.beginActivation(current: nil)
        selection.finishActivation(FeatureStub())

        selection.beginActivation(current: nil)
        selection.finishActivation(nil)

        #expect(selection.feature(current: nil) == nil)
        #expect(!selection.isActivating)
    }
}

private final class FeatureStub {}
