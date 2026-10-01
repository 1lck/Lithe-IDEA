import LitheModuleAPI

/// The PHP package owns its manifest and module declarations.
///
/// This is deliberately kept under `Plugins/mac/Official/PhpSupport`; the
/// application catalog only discovers the decoded package manifest. Keeping the
/// declaration here prevents the plugin from importing a host language catalog
/// or another language's implementation during an isolated package build.
public enum PhpSupportManifest {
    public static let pluginID = PluginID("dev.lithe.plugin.php-support")
    public static let version = PluginVersion(major: 0, minor: 3, patch: 0)
    public static let languageID = "php"

    public static let vendor = PluginVendor(
        id: "dev.lithe",
        displayName: "Lithe",
        signatureRequirement: .publisherPackage
    )

    public static let executionModule = ModuleManifest(
        id: .languageExecutionExtension(languageID),
        displayName: "PHP Execution",
        scope: .workspace,
        defaultState: .disabled,
        activationPolicy: .onDemand,
        sleepPolicy: .whenIdle(afterSeconds: 10 * 60),
        dependencies: [.module(.workspace)],
        providedCapabilities: [
            .languageExecutionExtension(languageID),
            .languageTestingExtension(languageID)
        ]
    )

    public static let languageServerModule = ModuleManifest(
        id: .languageServerExtension(languageID),
        displayName: "PHP Language Server",
        scope: .workspace,
        defaultState: .disabled,
        activationPolicy: .onDemand,
        sleepPolicy: .whenIdle(afterSeconds: 10 * 60),
        dependencies: [.module(.workspace)],
        providedCapabilities: [.languageServerExtension(languageID)]
    )

    public static let plugin = PluginManifest(
        id: pluginID,
        displayName: "PHP Support",
        version: version,
        hostCompatibility: PluginHostCompatibility(
            minimum: version,
            maximumExclusive: PluginVersion(major: 0, minor: 4, patch: 0)
        ),
        vendor: vendor,
        entrypoint: PluginEntrypoint(
            kind: .nativeBundle,
            bundleIdentifier: "dev.lithe.plugin.php-support.bundle",
            principalClass: "LithePhpSupportPluginEntrypoint",
            bundlePath: "PhpSupport.bundle"
        ),
        modules: [
            PluginModuleDeclaration(manifest: executionModule),
            PluginModuleDeclaration(manifest: languageServerModule)
        ],
        languageSupports: [LanguageSupportDeclaration(
            id: languageID,
            displayName: "PHP",
            fileExtensions: ["php", "phtml"],
            projectFileNames: ["composer.json"],
            languageServerModuleID: languageServerModule.id,
            executionModuleID: executionModule.id,
            testingModuleID: executionModule.id
        )]
    )
}
