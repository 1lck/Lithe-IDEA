import LitheModuleAPI

/// A data-only plugin's UI lifecycle. Host adapters render the catalog;
/// activation never loads plugin code or creates a platform resource.
@MainActor
public final class DeclarativeWorkbenchModule: LitheModule {
    private let declaration: PluginModuleDeclaration
    public var manifest: ModuleManifest { declaration.manifest }

    public init(declaration: PluginModuleDeclaration) { self.declaration = declaration }
    public func contributions() -> [ModuleContribution] { declaration.contributions }
    public func activate(context: ModuleContext) async throws {}
    public func prepareForSleep() async throws {}
    public func sleep() async {}
    public func shutdown() async {}
    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}
