import Foundation
import LitheModuleAPI

final class MacModuleConfigurationStore: ModuleConfigurationStore, ModuleRecoveryStore, @unchecked Sendable {
    private let store: any KeyValueStore
    private let lock = NSLock()

    init(store: any KeyValueStore) {
        self.store = store
    }

    func enabledState(for moduleID: ModuleID) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return store.object(forKey: key(for: moduleID)) as? Bool
    }

    func setEnabledState(_ enabled: Bool, for moduleID: ModuleID) {
        lock.lock(); defer { lock.unlock() }
        store.set(enabled, forKey: key(for: moduleID))
    }

    func pendingActivation() -> ModuleID? {
        lock.lock(); defer { lock.unlock() }
        return pendingActivationsLocked().first
    }

    func setPendingActivation(_ moduleID: ModuleID?) {
        lock.lock(); defer { lock.unlock() }
        setPendingActivationsLocked(moduleID.map { [$0] } ?? [])
    }

    func pendingActivations() -> [ModuleID] {
        lock.lock(); defer { lock.unlock() }
        return pendingActivationsLocked()
    }

    func setPendingActivations(_ moduleIDs: [ModuleID]) {
        lock.lock(); defer { lock.unlock() }
        setPendingActivationsLocked(moduleIDs)
    }

    func isQuarantined(_ moduleID: ModuleID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return store.object(forKey: quarantineKey(for: moduleID)) as? Bool ?? false
    }

    func setQuarantined(_ quarantined: Bool, for moduleID: ModuleID) {
        lock.lock(); defer { lock.unlock() }
        store.set(quarantined ? true : nil, forKey: quarantineKey(for: moduleID))
    }

    func pendingPluginLoadModules() -> [ModuleID] {
        lock.lock(); defer { lock.unlock() }
        let values = store.object(forKey: Self.pendingPluginLoadKey) as? [String] ?? []
        return values.map { ModuleID($0) }.sorted()
    }

    func setPendingPluginLoadModules(_ moduleIDs: [ModuleID]) {
        lock.lock(); defer { lock.unlock() }
        let values = moduleIDs.map(\.rawValue).sorted()
        store.set(values.isEmpty ? nil : values, forKey: Self.pendingPluginLoadKey)
    }

    private func key(for moduleID: ModuleID) -> String {
        "lithe.modules.\(moduleID.rawValue).enabled"
    }

    private func quarantineKey(for moduleID: ModuleID) -> String {
        "lithe.modules.\(moduleID.rawValue).quarantined"
    }

    private func pendingActivationsLocked() -> [ModuleID] {
        var values = store.object(forKey: Self.pendingActivationsKey) as? [String] ?? []
        if let legacy = store.string(forKey: Self.pendingActivationKey), !legacy.isEmpty {
            values.append(legacy)
        }
        return Set(values.map { ModuleID($0) }).sorted()
    }

    private func setPendingActivationsLocked(_ moduleIDs: [ModuleID]) {
        let values = Set(moduleIDs).sorted().map(\.rawValue)
        store.set(values.isEmpty ? nil : values, forKey: Self.pendingActivationsKey)
        store.set(nil, forKey: Self.pendingActivationKey)
    }

    private static let pendingActivationKey = "lithe.modules.pending-activation"
    private static let pendingActivationsKey = "lithe.modules.pending-activations"
    private static let pendingPluginLoadKey = "lithe.plugins.pending-code-load"
}
