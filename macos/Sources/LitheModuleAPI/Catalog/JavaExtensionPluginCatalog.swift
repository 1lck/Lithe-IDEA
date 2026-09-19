import Foundation

/// The migration provider is independently selectable in the existing plugin manager.
/// Its disabled default is temporary until the extension workflow passes M1–M4.
public enum JavaExtensionPluginCatalog {
    public static let moduleID = ModuleID("dev.lithe.extension.java")
    public static let capabilityID = ModuleCapabilityID("dev.lithe.extension.java.host")
    public static let moduleManifest = ModuleManifest(
        id: moduleID,
        displayName: "Java Extension Host",
        scope: .workspace,
        defaultState: .disabled,
        activationPolicy: .onDemand,
        sleepPolicy: .whenIdle(afterSeconds: 10 * 60),
        dependencies: [.module(.workspace), .module(.languageIntelligence)],
        providedCapabilities: [capabilityID]
    )
    public static let manifest = PluginManifest(
        id: PluginID("dev.lithe.plugin.java-extension-support"),
        displayName: "Java Support (Extension Preview)",
        version: BuiltInPluginCatalog.hostVersion,
        hostCompatibility: PluginHostCompatibility(minimum: BuiltInPluginCatalog.hostVersion),
        vendor: BuiltInPluginCatalog.vendor,
        entrypoint: .builtIn(targetName: "LitheLanguageIntelligenceModule"),
        modules: [PluginModuleDeclaration(manifest: moduleManifest)]
    )
}
