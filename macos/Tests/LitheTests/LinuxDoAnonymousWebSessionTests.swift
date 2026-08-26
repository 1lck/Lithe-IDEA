@testable import Lithe
import Testing

@MainActor
struct LinuxDoIdleRetainerTests {
    @Test
    func shortPanelAbsenceKeepsTheCurrentObject() async {
        let retainer = LinuxDoIdleRetainer<TestRetainedObject>(
            idleLifetimeNanoseconds: 50_000_000,
            prepareForRelease: { _ in }
        )
        let retainedObject = TestRetainedObject()
        retainer.value = retainedObject

        let releaseTask = retainer.releaseAfterInactivity()
        retainer.resume()
        await releaseTask.value

        #expect(retainer.value === retainedObject)
    }

    @Test
    func inactiveSessionReleasesItsObject() async {
        var releasedObject: TestRetainedObject?
        let retainer = LinuxDoIdleRetainer<TestRetainedObject>(
            idleLifetimeNanoseconds: 20_000_000
        ) { value in
            releasedObject = value
        }
        let retainedObject = TestRetainedObject()
        retainer.value = retainedObject

        let releaseTask = retainer.releaseAfterInactivity()
        await releaseTask.value

        #expect(releasedObject === retainedObject)
        #expect(retainer.value == nil)
    }
}

private final class TestRetainedObject {}
