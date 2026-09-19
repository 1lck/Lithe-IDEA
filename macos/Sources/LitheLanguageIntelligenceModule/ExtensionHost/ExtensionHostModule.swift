import Foundation
import LitheCoreContracts
import LitheModuleAPI

package struct ExtensionHostStartupConfiguration: Sendable {
    package let launch: ExtensionHostLaunchConfiguration
    package let initialize: ToolingJSONValue

    package init(launch: ExtensionHostLaunchConfiguration, initialize: ToolingJSONValue) {
        self.launch = launch
        self.initialize = initialize
    }
}

/// Owns the process resource through the same runtime used by native plugins.
@MainActor
package final class ExtensionHostModule: LitheModule {
    package let manifest: ModuleManifest
    private let capabilityID: ModuleCapabilityID
    private let makeSession: @MainActor () -> ExtensionHostSession
    private let startup: (@MainActor (ModuleContext) async throws -> ExtensionHostStartupConfiguration)?
    private let onSessionCreated: (@MainActor (ModuleContext, ExtensionHostSession) async throws -> Void)?
    private let onSessionReleased: (@MainActor (ExtensionHostSession) -> Void)?
    private var capability: ExtensionHostCapability?

    package init(manifest: ModuleManifest, capabilityID: ModuleCapabilityID,
                 makeSession: @escaping @MainActor () -> ExtensionHostSession,
                 startup: (@MainActor (ModuleContext) async throws -> ExtensionHostStartupConfiguration)? = nil,
                 onSessionCreated: (@MainActor (ModuleContext, ExtensionHostSession) async throws -> Void)? = nil,
                 onSessionReleased: (@MainActor (ExtensionHostSession) -> Void)? = nil) {
        self.manifest = manifest
        self.capabilityID = capabilityID
        self.makeSession = makeSession
        self.startup = startup
        self.onSessionCreated = onSessionCreated
        self.onSessionReleased = onSessionReleased
    }

    package func activate(context: ModuleContext) async throws {
        guard capability == nil else { return }
        // Missing packaged resources must not stop an otherwise healthy legacy provider.
        let preparation = ExtensionHostStartupResource { [startup] in try await startup?(context) }
        let preparationID = context.resources.register(preparation)
        defer { context.resources.unregisterResource(id: preparationID) }
        let configuration = try await preparation.result()
        try Task.checkCancellation()
        let session = makeSession()
        context.resources.register(session)
        do {
            try await onSessionCreated?(context, session)
            if let configuration {
                _ = try await session.start(configuration.launch, initialize: configuration.initialize)
            }
        } catch {
            await session.stopModuleResource()
            throw error
        }
        capability = ExtensionHostCapability(session: session)
    }

    package func prepareForSleep() async throws {}
    package func sleep() async { await release() }
    package func shutdown() async { await release() }
    package func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        guard let capability else { return [:] }
        return [capabilityID: capability]
    }

    private func release() async {
        guard let session = capability?.session else { return }
        await session.stopModuleResource()
        onSessionReleased?(session)
        capability = nil
    }
}

/// Owns prompts and runtime probes before a process exists. Workspace shutdown
/// can cancel this stage through the same resource scope as the running host.
@MainActor
private final class ExtensionHostStartupResource: ModuleResource {
    let moduleResourceKind = "vscode-extension-host-startup"
    private var task: Task<ExtensionHostStartupConfiguration?, Error>?
    private var stopped = false

    init(prepare: @escaping @MainActor () async throws -> ExtensionHostStartupConfiguration?) {
        task = Task {
            let configuration = try await prepare()
            try Task.checkCancellation()
            return configuration
        }
    }

    var isModuleResourceActive: Bool { task != nil }

    func result() async throws -> ExtensionHostStartupConfiguration? {
        guard let task, !stopped else { throw CancellationError() }
        defer { self.task = nil }
        let configuration = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        guard !stopped else { throw CancellationError() }
        return configuration
    }

    func stopModuleResource() async {
        stopped = true
        guard let task else { return }
        task.cancel()
        _ = await task.result
        self.task = nil
    }
}

@MainActor
package final class ExtensionHostCapability: NSObject {
    package let session: ExtensionHostSession
    package init(session: ExtensionHostSession) { self.session = session }
}
