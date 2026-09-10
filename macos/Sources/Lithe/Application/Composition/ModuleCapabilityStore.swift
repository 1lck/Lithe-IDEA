import Combine
import Foundation
import LitheModuleAPI

/// Owns the application-scoped bindings between module capability IDs and
/// their active capability instances.
///
/// The store deliberately knows nothing about a capability's feature type or
/// teardown behavior. ModuleSessionCoordinator invokes the composed
/// product-specific cleanup when a module is released.
@MainActor
final class ModuleCapabilityStore {
    private struct CachedCapability {
        let moduleID: ModuleID
        let value: AnyObject
    }

    private var capabilities: [ModuleCapabilityID: CachedCapability] = [:]
    private var featureObservations: [ModuleID: [AnyCancellable]] = [:]

    func activate<Capability: AnyObject>(
        _ id: ModuleCapabilityID,
        as type: Capability.Type = Capability.self,
        moduleID: ModuleID,
        using activate: @escaping @MainActor (ModuleCapabilityID) async throws -> AnyObject
    ) async throws -> Capability {
        if let cached = capability(id, as: type) {
            return cached
        }
        let value = try await activate(id)
        guard let capability = value as? Capability else {
            throw ModuleCapabilityStoreError.invalidCapabilityType(
                id: id,
                expected: String(reflecting: type),
                actual: String(reflecting: Swift.type(of: value))
            )
        }
        cache(capability, id: id, moduleID: moduleID)
        return capability
    }

    func capability<Capability: AnyObject>(
        _ id: ModuleCapabilityID,
        as type: Capability.Type = Capability.self
    ) -> Capability? {
        capabilities[id]?.value as? Capability
    }

    func cache(
        _ capability: AnyObject,
        id: ModuleCapabilityID,
        moduleID: ModuleID
    ) {
        capabilities[id] = CachedCapability(moduleID: moduleID, value: capability)
    }

    func observe(
        _ moduleID: ModuleID,
        observation: AnyCancellable
    ) {
        featureObservations[moduleID, default: []].append(observation)
    }

    func clear(for moduleID: ModuleID) {
        featureObservations[moduleID] = nil
        capabilities = capabilities.filter { $0.value.moduleID != moduleID }
    }
}

enum ModuleCapabilityStoreError: Error, Equatable, LocalizedError {
    case invalidCapabilityType(id: ModuleCapabilityID, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidCapabilityType(let id, let expected, let actual):
            "Capability \(id.rawValue) returned \(actual), expected \(expected)"
        }
    }
}
