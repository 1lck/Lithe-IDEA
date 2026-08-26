import Foundation
import LitheModuleAPI

@MainActor
public final class ModuleResourceScope: ModuleResourceManaging, ModuleLeaseManaging {
    private struct RegisteredResource {
        let value: any ModuleResource
        let kind: String
    }

    public let moduleID: ModuleID
    private var resources: [UUID: RegisteredResource] = [:]
    private var leases: [UUID: String] = [:]
    public private(set) var lastActivityAt: Date?

    public init(moduleID: ModuleID) {
        self.moduleID = moduleID
    }

    @discardableResult
    public func register(_ resource: any ModuleResource) -> UUID {
        let id = UUID()
        resources[id] = RegisteredResource(value: resource, kind: resource.moduleResourceKind)
        touch()
        return id
    }

    public func unregisterResource(id: UUID) {
        guard let resource = resources[id] else { return }
        guard !resource.value.isModuleResourceActive else {
            touch()
            return
        }
        resources.removeValue(forKey: id)
        touch()
    }

    public func resourceSnapshots() -> [ModuleResourceSnapshot] {
        return resources.map { id, resource in
            ModuleResourceSnapshot(
                id: id,
                kind: resource.kind,
                isActive: resource.value.isModuleResourceActive
            )
        }.sorted { lhs, rhs in
            if lhs.kind == rhs.kind { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.kind < rhs.kind
        }
    }

    public func acquireLease(reason: String) -> ModuleLease {
        let leaseID = UUID()
        leases[leaseID] = reason
        touch()
        return ModuleLease(id: leaseID, reason: reason) { [weak self] id in
            self?.releaseLease(id: id)
        }
    }

    public var activeLeaseReasons: [String] {
        leases.values.sorted()
    }

    public var activity: ModuleActivity {
        ModuleActivity(
            activeLeaseCount: leases.count,
            activeResourceCount: resourceSnapshots().filter(\.isActive).count,
            lastActivityAt: lastActivityAt
        )
    }

    public func recordActivity(at date: Date = Date()) {
        lastActivityAt = date
    }

    public func stopAllResources() async {
        let activeResources = resources.values.map(\.value).filter(\.isModuleResourceActive)
        for resource in activeResources {
            await resource.stopModuleResource()
        }
        touch()
    }

    public func releaseStoppedResources() {
        resources = resources.filter { $0.value.value.isModuleResourceActive }
        touch()
    }

    private func releaseLease(id: UUID) {
        leases.removeValue(forKey: id)
        touch()
    }

    private func touch() {
        recordActivity()
    }
}
