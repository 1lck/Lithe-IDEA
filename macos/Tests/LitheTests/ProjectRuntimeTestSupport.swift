import Foundation
import LitheCoreContracts
@testable import Lithe

/// Tool lookup tests use an explicit, isolated locator. The runtime service
/// keeps no persisted settings, so the store argument only keeps older call
/// sites that still pass an isolated defaults store compiling.
@MainActor
extension ProjectRuntimeService {
    convenience init(runtimeLocator: any RuntimeLocator, store _: any KeyValueStore,
                     toolDiscovery: (any RuntimeToolDiscovery)? = nil) {
        self.init(runtimeLocator: runtimeLocator, toolDiscovery: toolDiscovery)
    }
}
