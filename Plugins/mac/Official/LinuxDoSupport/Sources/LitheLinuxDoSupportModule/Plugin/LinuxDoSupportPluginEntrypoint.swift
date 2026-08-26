import Foundation
import LitheModuleAPI

@MainActor
@objc(LitheLinuxDoSupportPluginEntrypoint)
public final class LinuxDoSupportPluginEntrypoint: NSObject, LithePluginEntrypoint {
    public override init() { super.init() }

    public func moduleFactories(context: PluginHostContext) throws -> [ModuleFactory] {
        [ModuleFactory(
            manifest: LinuxDoSupportModule.declaration.manifest,
            contributions: LinuxDoSupportModule.declaration.contributions
        ) {
            LinuxDoSupportModule()
        }]
    }
}
