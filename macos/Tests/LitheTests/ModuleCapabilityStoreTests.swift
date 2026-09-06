import Testing
@testable import Lithe

@Suite("Module capability store")
@MainActor
struct ModuleCapabilityStoreTests {
    @Test
    func cachesCapabilitiesByIDAndPreservesTypeSafety() {
        let store = ModuleCapabilityStore()
        let capability = TestCapability()

        store.cache(capability, id: .gitWorkspace, moduleID: .git)

        #expect(store.capability(.gitWorkspace) === capability)
        #expect(store.capability(.gitWorkspace, as: OtherCapability.self) == nil)
    }

    @Test
    func clearingAModuleRemovesOnlyItsCapabilities() {
        let store = ModuleCapabilityStore()
        let gitCapability = TestCapability()
        let searchCapability = OtherCapability()

        store.cache(gitCapability, id: .gitWorkspace, moduleID: .git)
        store.cache(searchCapability, id: .searchWorkspace, moduleID: .search)

        store.clear(for: .git)

        #expect(store.capability(.gitWorkspace, as: TestCapability.self) == nil)
        #expect(store.capability(.searchWorkspace) === searchCapability)
    }

    @Test
    func activationCachesAndTypeChecksTheReturnedCapability() async throws {
        let store = ModuleCapabilityStore()
        let capability = TestCapability()
        var activationCount = 0

        let first: TestCapability = try await store.activate(
            .gitWorkspace,
            moduleID: .git,
            using: { _ in
                activationCount += 1
                return capability
            }
        )
        let second: TestCapability = try await store.activate(
            .gitWorkspace,
            moduleID: .git,
            using: { _ in
                activationCount += 1
                return TestCapability()
            }
        )

        #expect(first === capability)
        #expect(second === capability)
        #expect(activationCount == 1)
    }
}

private final class TestCapability {}
private final class OtherCapability {}
