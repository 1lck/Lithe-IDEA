import Foundation
import LitheCoreContracts

/// Rechecks native filesystem and current package ownership at the debug handoff.
/// Provider facts never replace the adapter's own registered process or permissions.
@MainActor
struct MacBuildDebugLaunchResolver {
    let planner: any DeclarativeLanguageServerLaunchPlanning
    let entry: (String) -> PluginDebugAdapterEntry?
    let generation: () -> Int

    func resolve(source: BuildSystemPluginSource, preparation: BuildDebugPreparation,
                 workspaceURL: URL, title: String) throws -> DebugLaunchConfiguration {
        let identity = "\(source.pluginID)/\(preparation.adapter)"
        guard let entry = entry(identity),
              entry.plugin.descriptor.normalizedManifest == source.manifest,
              entry.plugin.packageURL.standardizedFileURL == source.packageURL.standardizedFileURL else {
            throw DebugLaunchConfigurationResolutionError.providerDebugUnavailable
        }
        // Recheck canonical containment at the platform handoff, since
        // a workspace symlink may change after Core decoded the result.
        let workspace = workspaceURL.resolvingSymlinksInPath().standardizedFileURL
        let program = workspace.appendingPathComponent(preparation.program).resolvingSymlinksInPath().standardizedFileURL
        let cwd = workspace.appendingPathComponent(preparation.workingDirectory).resolvingSymlinksInPath().standardizedFileURL
        let instance = workspace.appendingPathComponent(preparation.root).resolvingSymlinksInPath().standardizedFileURL
        let prefix = instance.path.hasSuffix("/") ? instance.path : instance.path + "/"
        let workspacePrefix = workspace.path.hasSuffix("/") ? workspace.path : workspace.path + "/"
        var isDirectory: ObjCBool = false
        guard instance == workspace || instance.path.hasPrefix(workspacePrefix),
              program.path.hasPrefix(prefix), cwd == instance || cwd.path.hasPrefix(prefix),
              MacPluginDebugExecutableResolver.isRunnableFile(program.path),
              FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory) && isDirectory.boolValue else {
            throw DebugLaunchConfigurationResolutionError.providerDebugUnavailable
        }
        let generation = generation()
        let arguments = try planner.debugStartArguments(
            manifest: source.manifest, adapterID: preparation.adapter,
            request: DeclarativeDebugStartRequest(request: .launch, targetKind: "executable", path: program.path,
                workingDirectory: cwd.path, registrationGeneration: generation, currentRegistrationGeneration: generation,
                arguments: preparation.arguments, environment: preparation.environment))
        return DebugLaunchConfiguration(name: title, request: .launch, arguments: arguments, adapterProviderID: identity)
    }
}
