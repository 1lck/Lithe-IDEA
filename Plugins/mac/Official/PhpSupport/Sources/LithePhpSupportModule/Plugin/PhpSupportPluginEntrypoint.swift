import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
@objc(LithePhpSupportPluginEntrypoint)
public final class PhpSupportPluginEntrypoint: NSObject, LithePluginEntrypoint {
    public override init() { super.init() }

    public func moduleFactories(context: PluginHostContext) throws -> [ModuleFactory] {
        let executionHost = context.service(.languageExecution) as? any LanguageExecutionHostProviding
        return [
            ModuleFactory(manifest: PhpExecutionModule.moduleManifest) {
                PhpExecutionModule(executionHost: executionHost)
            },
            ModuleFactory(manifest: PhpLanguageServerModule.moduleManifest) {
                PhpLanguageServerModule()
            }
        ]
    }
}
