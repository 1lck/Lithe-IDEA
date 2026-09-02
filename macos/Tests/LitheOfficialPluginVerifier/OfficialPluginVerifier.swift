import Foundation
import LitheApplicationKernel
import LitheCoreContracts
import LitheModuleAPI

@main
struct OfficialPluginVerifier {
    @MainActor
    static func main() async throws {
        _ = LanguageExecutionProcessRequest.self
        guard CommandLine.arguments.count == 2 else {
            throw VerificationError.usage
        }
        let packageURL = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        )
        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(contentsOf: packageURL.appendingPathComponent("plugin.json"))
        )
        guard OfficialPluginCatalog.manifests.contains(manifest) else {
            throw VerificationError.manifestMismatch
        }

        guard let bundlePath = manifest.entrypoint.bundlePath,
              let bundle = Bundle(
                  url: packageURL.appendingPathComponent(bundlePath, isDirectory: true)
              ) else {
            throw VerificationError.invalidBundle
        }
        try bundle.loadAndReturnError()
        guard let principalClass: AnyClass = bundle.principalClass,
              let entrypointType = principalClass as? LithePluginEntrypoint.Type else {
            throw VerificationError.invalidEntrypoint
        }

        let factories = try entrypointType.init().moduleFactories(
            context: .empty
        )
        guard factories.count == manifest.modules.count,
              zip(factories, manifest.modules).allSatisfy({ pair in
                  pair.0.manifest == pair.1.manifest
                      && pair.0.contributions == pair.1.contributions
              }) else {
            throw VerificationError.factoryMismatch
        }

        _ = try ValidatedPluginCatalog(
            manifests: BuiltInPluginCatalog.manifests + [manifest],
            hostVersion: BuiltInPluginCatalog.hostVersion
        )
        let runtime = ModuleRuntime()
        for declaration in BuiltInPluginCatalog.manifests.flatMap(\.modules) {
            try runtime.register(ModuleFactory(
                manifest: declaration.manifest,
                contributions: declaration.contributions
            ) {
                throw VerificationError.factoryMustNotBeInvoked
            })
        }
        for factory in factories {
            try runtime.register(factory)
        }
        try runtime.validateGraph()
        await runtime.shutdownAll()
        print("Verified \(manifest.id) through the native Bundle boundary")
    }
}

private enum VerificationError: Error {
    case usage
    case manifestMismatch
    case invalidBundle
    case invalidEntrypoint
    case factoryMismatch
    case factoryMustNotBeInvoked
}
