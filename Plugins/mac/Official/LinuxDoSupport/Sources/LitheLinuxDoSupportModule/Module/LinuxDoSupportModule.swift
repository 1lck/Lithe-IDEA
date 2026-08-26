import LitheModuleAPI

@MainActor
public final class LinuxDoSupportModule: LitheModule {
    public static let declaration = OfficialPluginCatalog
        .manifest(forModule: OfficialPluginCatalog.linuxDoSupportModuleID)!
        .modules.first { $0.manifest.id == OfficialPluginCatalog.linuxDoSupportModuleID }!

    public let manifest = declaration.manifest

    public init() {}

    public func activate(context: ModuleContext) async throws {}
    public func prepareForSleep() async throws {}
    public func sleep() async {}
    public func shutdown() async {}
    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
    public func contributions() -> [ModuleContribution] { Self.declaration.contributions }
}
