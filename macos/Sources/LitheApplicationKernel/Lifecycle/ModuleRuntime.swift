import Foundation
import LitheModuleAPI

@MainActor
public final class ModuleRuntime: ModuleCapabilityResolver, ModuleEventPublishing, ModuleContributionPublishing {
    private struct Entry {
        let factory: ModuleFactory
        let resources: ModuleResourceScope
        var isEnabled: Bool
        var isQuarantined: Bool
        let isSuppressedBySafeMode: Bool
        var state: ModuleState
        var instance: (any LitheModule)?
    }

    private var entries: [ModuleID: Entry] = [:]
    private var capabilities: [ModuleCapabilityID: (provider: ModuleID, value: AnyObject)] = [:]
    private var eventObservers: [UUID: @MainActor (ModuleEvent) -> Void] = [:]
    private var moduleContributions: [ModuleID: [ModuleContribution]] = [:]
    private let workspaceURL: URL?
    private let configurationStore: (any ModuleConfigurationStore)?
    private let recoveryStore: (any ModuleRecoveryStore)?
    private let launchMode: ModuleLaunchMode

    public init(
        workspaceURL: URL? = nil,
        configurationStore: (any ModuleConfigurationStore)? = nil,
        recoveryStore: (any ModuleRecoveryStore)? = nil,
        launchMode: ModuleLaunchMode = .normal
    ) {
        self.workspaceURL = workspaceURL
        self.configurationStore = configurationStore
        self.recoveryStore = recoveryStore
        self.launchMode = launchMode
        let pendingActivations = recoveryStore?.pendingActivations() ?? []
        for pending in pendingActivations {
            recoveryStore?.setQuarantined(true, for: pending)
        }
        if !pendingActivations.isEmpty {
            recoveryStore?.setPendingActivations([])
        }
    }

    public func register(_ factory: ModuleFactory, enabled: Bool? = nil) throws {
        let id = factory.manifest.id
        guard entries[id] == nil else { throw ModuleRuntimeError.duplicateModule(id) }
        let configuredEnabled = enabled
            ?? configurationStore?.enabledState(for: id)
            ?? (factory.manifest.defaultState == .enabled)
        let isQuarantined = !factory.manifest.isRequired
            && (recoveryStore?.isQuarantined(id) ?? false)
        if factory.manifest.isRequired, recoveryStore?.isQuarantined(id) == true {
            recoveryStore?.setQuarantined(false, for: id)
        }
        let isSuppressedBySafeMode = launchMode == .safeMode && !factory.manifest.isRequired
        let isEnabled = configuredEnabled && !isQuarantined && !isSuppressedBySafeMode
        entries[id] = Entry(
            factory: factory,
            resources: ModuleResourceScope(moduleID: id),
            isEnabled: isEnabled,
            isQuarantined: isQuarantined,
            isSuppressedBySafeMode: isSuppressedBySafeMode,
            state: isEnabled ? .inactive : .disabled,
            instance: nil
        )
        publishStateChanged(id)
    }

    public func validateGraph() throws {
        let capabilityProviders = Dictionary(grouping: entries.values.flatMap { entry in
            entry.factory.manifest.providedCapabilities.map { ($0, entry.factory.manifest.id) }
        }, by: \.0)

        for (capability, values) in capabilityProviders where values.count > 1 {
            throw ModuleRuntimeError.capabilityCollision(
                capability: capability,
                providers: values.map(\.1).sorted()
            )
        }

        for entry in entries.values {
            for dependency in entry.factory.manifest.dependencies {
                switch dependency {
                case .module(let dependencyID):
                    guard entries[dependencyID] != nil else {
                        throw ModuleRuntimeError.missingModuleDependency(
                            module: entry.factory.manifest.id,
                            dependency: dependencyID
                        )
                    }
                case .capability(let capability):
                    guard capabilityProviders[capability] != nil else {
                        throw ModuleRuntimeError.missingCapabilityDependency(
                            module: entry.factory.manifest.id,
                            capability: capability
                        )
                    }
                }
            }
        }

        var visited: Set<ModuleID> = []
        var visiting: [ModuleID] = []
        for id in entries.keys.sorted() {
            try visit(id, visited: &visited, visiting: &visiting)
        }
    }

    public func startEagerModules() async throws {
        try validateGraph()
        let eagerModuleIDs = entries.values
            .filter { $0.isEnabled && $0.factory.manifest.activationPolicy == .eager }
            .map { $0.factory.manifest.id }
            .sorted()
        for id in eagerModuleIDs {
            try await activate(id)
        }
    }

    @discardableResult
    public func activate(_ id: ModuleID) async throws -> any LitheModule {
        guard var entry = entries[id] else { throw ModuleRuntimeError.unknownModule(id) }
        guard !entry.isQuarantined else { throw ModuleRuntimeError.moduleQuarantined(id) }
        guard !entry.isSuppressedBySafeMode else {
            throw ModuleRuntimeError.optionalModuleUnavailableInSafeMode(id)
        }
        guard entry.isEnabled else { throw ModuleRuntimeError.moduleDisabled(id) }
        if let instance = entry.instance, entry.state == .active || entry.state == .idle {
            return instance
        }

        for dependency in entry.factory.manifest.dependencies.sorted(by: dependencyOrder) {
            switch dependency {
            case .module(let dependencyID):
                _ = try await activate(dependencyID)
            case .capability(let capabilityID):
                guard let provider = providerID(for: capabilityID) else {
                    throw ModuleRuntimeError.missingCapabilityDependency(module: id, capability: capabilityID)
                }
                _ = try await activate(provider)
            }
        }

        if !entry.factory.manifest.isRequired {
            addPendingActivation(id)
        }
        entry.state = .activating
        entries[id] = entry
        publishStateChanged(id)
        var activatingInstance: (any LitheModule)?
        do {
            let instance = try entry.instance ?? entry.factory.makeModule()
            activatingInstance = instance
            let context = ModuleContext(
                moduleID: id,
                workspaceURL: workspaceURL,
                capabilities: self,
                events: self,
                resources: entry.resources,
                leases: entry.resources,
                contributions: self
            )
            try await instance.activate(context: context)
            entry.resources.recordActivity()
            entry.instance = instance
            entry.state = .active
            entries[id] = entry
            try publishCapabilities(of: instance, manifest: entry.factory.manifest)
            let instanceContributions = instance.contributions().sorted(by: contributionOrder)
            guard instanceContributions == entry.factory.contributions else {
                throw ModuleRuntimeError.contributionCatalogMismatch(id)
            }
            for contribution in entry.factory.contributions {
                register(contribution, for: id)
            }
            publish(ModuleEvent(source: id, name: "module.activated"))
            publishStateChanged(id)
            removePendingActivation(id)
            return instance
        } catch {
            removePendingActivation(id)
            if let activatingInstance {
                await activatingInstance.shutdown()
            }
            await entry.resources.stopAllResources()
            let activeKinds = entry.resources.resourceSnapshots().filter(\.isActive).map(\.kind)
            entry.resources.releaseStoppedResources()
            removeCapabilities(providedBy: id)
            removeContributions(for: id)
            entry.instance = nil
            if !activeKinds.isEmpty {
                entry.state = .failed(message: "Resources remain active after failed activation")
                entries[id] = entry
                publishStateChanged(id)
                throw ModuleRuntimeError.activeResourcesRemain(module: id, kinds: activeKinds)
            }
            entry.state = .failed(message: error.localizedDescription)
            entries[id] = entry
            publishStateChanged(id)
            throw error
        }
    }

    public func setEnabled(_ enabled: Bool, for id: ModuleID) async throws {
        guard var entry = entries[id] else { throw ModuleRuntimeError.unknownModule(id) }
        if enabled, entry.isSuppressedBySafeMode {
            throw ModuleRuntimeError.optionalModuleUnavailableInSafeMode(id)
        }
        if enabled, entry.isQuarantined {
            entry.isQuarantined = false
            recoveryStore?.setQuarantined(false, for: id)
        }
        guard entry.isEnabled != enabled else {
            entries[id] = entry
            return
        }
        if enabled {
            entry.isEnabled = true
            entry.state = .inactive
            entries[id] = entry
            if entry.factory.manifest.activationPolicy == .eager {
                _ = try await activate(id)
            }
        } else {
            guard !entry.factory.manifest.isRequired else {
                throw ModuleRuntimeError.requiredModuleCannotBeDisabled(id)
            }
            let dependents = enabledDependents(of: id)
            guard dependents.isEmpty else {
                throw ModuleRuntimeError.enabledDependentsPreventDisable(module: id, dependents: dependents)
            }
            entries[id] = entry
            try await shutdown(id)
            guard var stopped = entries[id] else { return }
            stopped.isEnabled = false
            stopped.state = .disabled
            entries[id] = stopped
        }
        configurationStore?.setEnabledState(enabled, for: id)
        publishStateChanged(id)
    }

    private func enabledDependents(of moduleID: ModuleID) -> [ModuleID] {
        let provided = entries[moduleID]?.factory.manifest.providedCapabilities ?? []
        return entries.values.compactMap { candidate in
            guard candidate.isEnabled, candidate.factory.manifest.id != moduleID else { return nil }
            let depends = candidate.factory.manifest.dependencies.contains { dependency in
                switch dependency {
                case .module(let id): id == moduleID
                case .capability(let capability): provided.contains(capability)
                }
            }
            return depends ? candidate.factory.manifest.id : nil
        }.sorted()
    }

    private func instantiatedDependents(of moduleID: ModuleID) -> [ModuleID] {
        let provided = entries[moduleID]?.factory.manifest.providedCapabilities ?? []
        return entries.values.compactMap { candidate in
            guard candidate.instance != nil, candidate.factory.manifest.id != moduleID else { return nil }
            let depends = candidate.factory.manifest.dependencies.contains { dependency in
                switch dependency {
                case .module(let id): id == moduleID
                case .capability(let capability): provided.contains(capability)
                }
            }
            return depends ? candidate.factory.manifest.id : nil
        }.sorted()
    }

    public func markIdle(_ id: ModuleID) throws {
        guard var entry = entries[id] else { throw ModuleRuntimeError.unknownModule(id) }
        guard entry.instance != nil else { return }
        entry.state = .idle
        entry.resources.recordActivity()
        entries[id] = entry
        publishStateChanged(id)
    }

    public func sleep(_ id: ModuleID) async throws {
        guard var entry = entries[id] else { throw ModuleRuntimeError.unknownModule(id) }
        let dependents = instantiatedDependents(of: id)
        guard dependents.isEmpty else {
            let reason = "Active dependents: \(dependents.map(\.rawValue).joined(separator: ", "))"
            entry.state = .sleepBlocked(reason: reason)
            entries[id] = entry
            publishStateChanged(id)
            throw ModuleRuntimeError.activeDependentsPreventSleep(module: id, dependents: dependents)
        }
        guard let instance = entry.instance else {
            if entry.isEnabled { entry.state = .sleeping }
            entries[id] = entry
            publishStateChanged(id)
            return
        }
        let reasons = entry.resources.activeLeaseReasons
        guard reasons.isEmpty else {
            entry.state = .sleepBlocked(reason: reasons.joined(separator: ", "))
            entries[id] = entry
            publishStateChanged(id)
            throw ModuleRuntimeError.activeLeasesPreventSleep(module: id, reasons: reasons)
        }

        entry.state = .preparingToSleep
        entries[id] = entry
        publishStateChanged(id)
        do {
            try await instance.prepareForSleep()
            await instance.sleep()
            await entry.resources.stopAllResources()
            let activeKinds = entry.resources.resourceSnapshots().filter(\.isActive).map(\.kind)
            guard activeKinds.isEmpty else {
                entry.state = .sleepBlocked(reason: "Resources remain active")
                entries[id] = entry
                publishStateChanged(id)
                throw ModuleRuntimeError.activeResourcesRemain(module: id, kinds: activeKinds)
            }
            entry.resources.releaseStoppedResources()
            removeCapabilities(providedBy: id)
            removeContributions(for: id)
            entry.instance = nil
            entry.state = .sleeping
            entries[id] = entry
            publish(ModuleEvent(source: id, name: "module.sleeping"))
            publishStateChanged(id)
        } catch {
            if case ModuleRuntimeError.activeResourcesRemain = error { throw error }
            entry.state = .sleepBlocked(reason: error.localizedDescription)
            entries[id] = entry
            publishStateChanged(id)
            throw error
        }
    }

    public func shutdown(_ id: ModuleID) async throws {
        guard var entry = entries[id] else { throw ModuleRuntimeError.unknownModule(id) }
        if let instance = entry.instance {
            await instance.shutdown()
        }
        await entry.resources.stopAllResources()
        let activeKinds = entry.resources.resourceSnapshots().filter(\.isActive).map(\.kind)
        guard activeKinds.isEmpty else {
            entry.state = .failed(message: "Resources remain active after shutdown")
            entries[id] = entry
            publishStateChanged(id)
            throw ModuleRuntimeError.activeResourcesRemain(module: id, kinds: activeKinds)
        }
        entry.resources.releaseStoppedResources()
        removeCapabilities(providedBy: id)
        removeContributions(for: id)
        entry.instance = nil
        entry.state = entry.isEnabled ? .inactive : .disabled
        entries[id] = entry
        publish(ModuleEvent(source: id, name: "module.shutdown"))
        publishStateChanged(id)
    }

    public func shutdownAll() async {
        for id in entries.keys.sorted().reversed() {
            try? await shutdown(id)
        }
    }

    public func evaluateIdleModules(now: Date = Date()) async {
        for id in entries.keys.sorted() {
            guard let entry = entries[id],
                  entry.state == .idle,
                  let interval = entry.factory.manifest.sleepPolicy.idleInterval,
                  entry.resources.activeLeaseReasons.isEmpty,
                  let lastActivity = entry.resources.lastActivityAt,
                  now.timeIntervalSince(lastActivity) >= interval else { continue }
            try? await sleep(id)
        }
    }

    public func snapshot(for id: ModuleID) throws -> ModuleSnapshot {
        guard let entry = entries[id] else { throw ModuleRuntimeError.unknownModule(id) }
        return ModuleSnapshot(
            manifest: entry.factory.manifest,
            state: entry.state,
            activity: entry.resources.activity,
            isInstantiated: entry.instance != nil,
            resources: entry.resources.resourceSnapshots(),
            activeLeaseReasons: entry.resources.activeLeaseReasons,
            isQuarantined: entry.isQuarantined,
            isSuppressedBySafeMode: entry.isSuppressedBySafeMode
        )
    }

    public func snapshots() -> [ModuleSnapshot] {
        entries.keys.sorted().compactMap { try? snapshot(for: $0) }
    }

    public func capability(_ id: ModuleCapabilityID) -> AnyObject? {
        capabilities[id]?.value
    }

    public func activateCapability(_ id: ModuleCapabilityID) async throws -> AnyObject {
        guard let provider = providerID(for: id) else {
            throw ModuleRuntimeError.missingCapabilityDependency(
                module: ModuleID("dev.lithe.capability-client"),
                capability: id
            )
        }
        _ = try await activate(provider)
        guard let value = capability(id) else {
            throw ModuleRuntimeError.missingCapabilityDependency(module: provider, capability: id)
        }
        return value
    }

    @discardableResult
    public func observeEvents(_ observer: @escaping @MainActor (ModuleEvent) -> Void) -> UUID {
        let id = UUID()
        eventObservers[id] = observer
        return id
    }

    public func removeEventObserver(_ id: UUID) {
        eventObservers.removeValue(forKey: id)
    }

    public func publish(_ event: ModuleEvent) {
        applyActivityEvent(event)
        for observer in eventObservers.values { observer(event) }
    }

    private func applyActivityEvent(_ event: ModuleEvent) {
        guard event.name == ModuleEvent.activityStartedName
                || event.name == ModuleEvent.activityEndedName,
              var entry = entries[event.source],
              entry.instance != nil else { return }
        entry.resources.recordActivity()
        entry.state = event.name == ModuleEvent.activityStartedName ? .active : .idle
        entries[event.source] = entry
        publishStateChanged(event.source)
    }

    public func register(_ contribution: ModuleContribution, for moduleID: ModuleID) {
        moduleContributions[moduleID, default: []].append(contribution)
        moduleContributions[moduleID]?.sort { $0.id < $1.id }
    }

    public func removeContributions(for moduleID: ModuleID) {
        moduleContributions.removeValue(forKey: moduleID)
    }

    public func contributions() -> [ModuleID: [ModuleContribution]] { moduleContributions }

    /// Declarative UI metadata for enabled modules. Reading this catalog never
    /// invokes a module factory, so an inactive module can expose the action
    /// that activates it without constructing any service or resource.
    public func availableContributions() -> [ModuleID: [ModuleContribution]] {
        Dictionary(uniqueKeysWithValues: entries.values.compactMap { entry in
            guard entry.isEnabled, !entry.factory.contributions.isEmpty else { return nil }
            return (entry.factory.manifest.id, entry.factory.contributions)
        })
    }

    private func providerID(for capability: ModuleCapabilityID) -> ModuleID? {
        entries.values.first { $0.factory.manifest.providedCapabilities.contains(capability) }?
            .factory.manifest.id
    }

    private func publishCapabilities(of module: any LitheModule, manifest: ModuleManifest) throws {
        let values = module.exportedCapabilities()
        if let missing = manifest.providedCapabilities.subtracting(values.keys).sorted().first {
            throw ModuleRuntimeError.missingExportedCapability(
                module: manifest.id,
                capability: missing
            )
        }
        if let undeclared = Set(values.keys).subtracting(manifest.providedCapabilities).sorted().first {
            throw ModuleRuntimeError.undeclaredExportedCapability(
                module: manifest.id,
                capability: undeclared
            )
        }
        for capabilityID in manifest.providedCapabilities {
            if let existing = capabilities[capabilityID], existing.provider != manifest.id {
                throw ModuleRuntimeError.capabilityCollision(
                    capability: capabilityID,
                    providers: [existing.provider, manifest.id].sorted()
                )
            }
        }
        for capabilityID in manifest.providedCapabilities {
            capabilities[capabilityID] = (manifest.id, values[capabilityID]!)
        }
    }

    private func removeCapabilities(providedBy id: ModuleID) {
        capabilities = capabilities.filter { $0.value.provider != id }
    }

    private func visit(
        _ id: ModuleID,
        visited: inout Set<ModuleID>,
        visiting: inout [ModuleID]
    ) throws {
        if visited.contains(id) { return }
        if let cycleStart = visiting.firstIndex(of: id) {
            throw ModuleRuntimeError.dependencyCycle(Array(visiting[cycleStart...]) + [id])
        }
        visiting.append(id)
        let dependencies = entries[id]?.factory.manifest.dependencies.compactMap { dependency -> ModuleID? in
            switch dependency {
            case .module(let dependencyID): dependencyID
            case .capability(let capability): providerID(for: capability)
            }
        }.sorted() ?? []
        for dependency in dependencies {
            try visit(dependency, visited: &visited, visiting: &visiting)
        }
        _ = visiting.popLast()
        visited.insert(id)
    }

    private func dependencyOrder(_ lhs: ModuleDependency, _ rhs: ModuleDependency) -> Bool {
        String(describing: lhs) < String(describing: rhs)
    }

    private func publishStateChanged(_ id: ModuleID) {
        publish(ModuleEvent(source: id, name: ModuleEvent.stateChangedName))
    }

    private func addPendingActivation(_ id: ModuleID) {
        guard let recoveryStore else { return }
        var pending = Set(recoveryStore.pendingActivations())
        pending.insert(id)
        recoveryStore.setPendingActivations(pending.sorted())
    }

    private func removePendingActivation(_ id: ModuleID) {
        guard let recoveryStore else { return }
        var pending = Set(recoveryStore.pendingActivations())
        pending.remove(id)
        recoveryStore.setPendingActivations(pending.sorted())
    }

    private func contributionOrder(_ lhs: ModuleContribution, _ rhs: ModuleContribution) -> Bool {
        (lhs.placement.rawValue, lhs.order, lhs.id)
            < (rhs.placement.rawValue, rhs.order, rhs.id)
    }
}
