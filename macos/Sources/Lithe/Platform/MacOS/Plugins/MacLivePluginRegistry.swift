import Combine
import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI

extension Notification.Name {
    /// One window changed which live plugins are installed or enabled. The
    /// other windows' registries rescan; the sender is the notification object.
    static let litheLivePluginsDidChange = Notification.Name("LitheLivePluginsDidChange")
}

/// A debug adapter and the package that declares it.
struct PluginDebugAdapterEntry {
    let plugin: InstalledPluginPackage
    let adapter: DeclarativeDebugAdapter

    var providerID: String { "\(plugin.descriptor.id.rawValue)/\(adapter.id)" }

    /// Every declared adapter has an explicit identity, independently of the
    /// default debugger of its language or the presence of a source file.
    static func qualifiedIndex(of packages: [InstalledPluginPackage]) -> [String: PluginDebugAdapterEntry] {
        var entries: [String: PluginDebugAdapterEntry] = [:]
        for plugin in packages.sorted(by: { $0.manifest.id < $1.manifest.id }) {
            for adapter in plugin.descriptor.debugAdapters {
                let entry = PluginDebugAdapterEntry(plugin: plugin, adapter: adapter)
                entries[entry.providerID] = entry
            }
        }
        return entries
    }

    func provider(languages: [DebugProviderDescriptor]) -> DebugProviderDescriptor {
        let supported = languages.filter { adapter.languageIDs.contains($0.id) }
        return DebugProviderDescriptor(
            id: providerID,
            displayName: adapter.displayName,
            fileExtensions: Set(supported.flatMap(\.fileExtensions)),
            fileNames: Set(supported.flatMap(\.fileNames)),
            fileNamePrefixes: Set(supported.flatMap(\.fileNamePrefixes)),
            selectsByFile: false,
            matchesAllSources: adapter.languageIDs.isEmpty,
            requests: adapter.requests
        )
    }

    /// The adapter that launches a debug session for a language's open file,
    /// first package in ID order first. An adapter that only attaches, or only
    /// debugs executables and processes, is not chosen for a file.
    /// Java keeps the host's own adapter.
    static func index(of packages: [InstalledPluginPackage]) -> [String: PluginDebugAdapterEntry] {
        var entries: [String: PluginDebugAdapterEntry] = [:]
        for plugin in packages.sorted(by: { $0.manifest.id < $1.manifest.id }) {
            for adapter in plugin.descriptor.debugAdapters {
                let languageIDs = adapter.fileLaunchLanguageIDs
                for languageID in languageIDs where languageID != "java" && entries[languageID] == nil {
                    entries[languageID] = PluginDebugAdapterEntry(plugin: plugin, adapter: adapter)
                }
            }
        }
        return entries
    }
}

/// What the registry holds for one live plugin.
struct LivePluginEntry: Equatable {
    let package: InstalledPluginPackage
    /// Whether the user's enablement lets the plugin contribute right now.
    /// A disabled plugin stays registered so enabling it needs no scan.
    let isEnabled: Bool
}

/// The registry's content at one generation.
struct LivePluginSnapshot: Equatable {
    var entries: [PluginID: LivePluginEntry] = [:]
    /// Increases whenever `entries` changes. A start prepared against an
    /// older generation was prepared against registrations that no longer exist.
    var generation = 0

    var activePackages: [InstalledPluginPackage] {
        entries.values.filter(\.isEnabled).map(\.package).sorted { $0.manifest.id < $1.manifest.id }
    }

    /// Languages the active live plugins declare; a debug-only declaration
    /// adds a debugger without taking the language's other features.
    var languageSupports: [LanguageSupportDeclaration] {
        activePackages.flatMap { $0.manifest.languageSupports ?? [] }
    }

    var debugAdapters: [String: PluginDebugAdapterEntry] {
        PluginDebugAdapterEntry.index(of: activePackages)
    }
}

/// Lock-protected so the debug session factory and the catalog source read the
/// registry from whichever isolation they run on.
final class LivePluginSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = LivePluginSnapshot()

    var snapshot: LivePluginSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func replace(_ newValue: LivePluginSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}

// Note: 免重启插件的内存注册表见 .agents/notes/implemented/architecture/2026-10-26-plugin-live-activation.md
/// In-memory registry of the plugins that take effect without a restart.
///
/// Whether a plugin may live here is the host backend's call
/// (`DeclarativePluginDescriptor.canActivateWithoutRestart`), not the manifest's.
/// A live plugin never joins `ModuleRuntime`: it contributes only data the host
/// reads when it needs it, so installing, updating, enabling or removing one
/// only replaces this registry's snapshot. A background thread scans the
/// installed packages and the registry adopts the result on the main actor.
@MainActor
final class MacLivePluginRegistry {
    typealias Acceptor = @MainActor (
        _ packages: [InstalledPluginPackage],
        _ registered: [PluginManifest]
    ) -> MacPluginAcceptance

    private let box = LivePluginSnapshotBox()
    private let makeScanStore: @Sendable () -> MacPluginPackageStore
    private let accept: Acceptor
    /// Manifests registered with the module graph at launch, so a live package
    /// cannot take ownership they already hold.
    private let registeredManifests: [PluginManifest]
    private let isEnabled: @MainActor (InstalledPluginPackage) -> Bool
    /// Called with the package a running feature may still be using, after the
    /// registry replaced, removed or disabled it.
    private let didWithdraw: @MainActor (InstalledPluginPackage) -> Void
    private var pendingScan: Task<Void, Never>?
    private var peerObservation: AnyCancellable?
    private let changeSubject = PassthroughSubject<Void, Never>()
    private let notificationCenter: NotificationCenter

    /// Fires after the registry's content changed.
    var changes: AnyPublisher<Void, Never> { changeSubject.eraseToAnyPublisher() }

    var snapshot: LivePluginSnapshot { box.snapshot }
    /// Readable from any isolation.
    nonisolated var snapshotBox: LivePluginSnapshotBox { box }

    init(
        initial: [InstalledPluginPackage],
        registeredManifests: [PluginManifest],
        makeScanStore: @escaping @Sendable () -> MacPluginPackageStore,
        accept: @escaping Acceptor,
        isEnabled: @escaping @MainActor (InstalledPluginPackage) -> Bool,
        didWithdraw: @escaping @MainActor (InstalledPluginPackage) -> Void = { _ in },
        notificationCenter: NotificationCenter = .default
    ) {
        self.notificationCenter = notificationCenter
        self.registeredManifests = registeredManifests
        self.makeScanStore = makeScanStore
        self.accept = accept
        self.isEnabled = isEnabled
        self.didWithdraw = didWithdraw
        // Startup already scanned and accepted these, so adopting them costs
        // no second scan.
        var snapshot = LivePluginSnapshot()
        for package in initial {
            snapshot.entries[package.manifest.id] = LivePluginEntry(package: package, isEnabled: isEnabled(package))
        }
        box.replace(snapshot)
        peerObservation = notificationCenter
            .publisher(for: .litheLivePluginsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, notification.object as AnyObject? !== self else { return }
                    self.scheduleScan()
                }
            }
    }

    /// Rescans the installed packages on a background thread, and tells the
    /// other windows to do the same. Call it after the packages or their
    /// enablement changed.
    @discardableResult
    func packagesDidChange() -> Task<Void, Never> {
        let task = scheduleScan()
        notificationCenter.post(name: .litheLivePluginsDidChange, object: self)
        return task
    }

    /// Scans are serialized so the last one always reflects the latest change
    /// on disk.
    @discardableResult
    func scheduleScan() -> Task<Void, Never> {
        let previous = pendingScan
        let task = Task { [weak self] in
            await previous?.value
            await self?.scan()
        }
        pendingScan = task
        return task
    }

    /// A package this registry holds is about to be replaced or removed on disk,
    /// so whatever still runs from it must stop first.
    func willReplacePackage(of pluginID: PluginID) {
        guard let entry = box.snapshot.entries[pluginID] else { return }
        didWithdraw(entry.package)
    }

    /// The user turned a plugin on or off. This window follows at once; the
    /// other windows rescan.
    func enablementDidChange() {
        refreshEnablement()
        notificationCenter.post(name: .litheLivePluginsDidChange, object: self)
    }

    /// Recomputes enablement for the packages already registered, after the
    /// user's module settings changed and no package did.
    func refreshEnablement() {
        var next = box.snapshot
        for (id, entry) in next.entries {
            next.entries[id] = LivePluginEntry(package: entry.package, isEnabled: isEnabled(entry.package))
        }
        publish(next)
    }

    private func scan() async {
        let makeScanStore = makeScanStore
        let outcome = await Task.detached(priority: .utility) { () -> ScanOutcome in
            do {
                return ScanOutcome(result: try makeScanStore().scanInstalledPlugins(), error: nil)
            } catch {
                return ScanOutcome(result: nil, error: error.localizedDescription)
            }
        }.value
        guard let result = outcome.result else {
            // Keep the last known registrations rather than dropping them all
            // on a transient read failure.
            NSLog("Lithe live plugin scan failed: %@", outcome.error ?? "")
            return
        }
        apply(result.packages)
    }

    /// Adopts the live-capable subset of `packages`.
    func apply(_ packages: [InstalledPluginPackage]) {
        // A staged update or pending removal is not active until restart.
        let candidates = packages.filter {
            $0.installation.status == .installed && $0.descriptor.canActivateWithoutRestart
        }
        let acceptance = accept(candidates, registeredManifests)
        MacPluginStartupLoader.log(acceptance.issues)
        var next = LivePluginSnapshot(generation: box.snapshot.generation)
        for package in acceptance.accepted {
            next.entries[package.manifest.id] = LivePluginEntry(package: package, isEnabled: isEnabled(package))
        }
        publish(next)
    }

    private func publish(_ next: LivePluginSnapshot) {
        let previous = box.snapshot
        guard previous.entries != next.entries else { return }
        var published = next
        published.generation = previous.generation + 1
        box.replace(published)
        for (id, entry) in previous.entries where published.entries[id] != entry {
            didWithdraw(entry.package)
        }
        changeSubject.send()
    }
}

private struct ScanOutcome: @unchecked Sendable {
    let result: PluginPackageScanResult?
    let error: String?
}
