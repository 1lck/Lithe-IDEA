import LitheModuleAPI

/// Go's module declarations live with the Go plugin implementation. The host
/// validates the signed `plugin.json` package metadata separately; it does not
/// provide a second Swift source of truth for the plugin's module graph.
enum GoSupportManifest {
    static let execution = ModuleManifest(
        id: .languageExecutionExtension(goLanguageID),
        displayName: "Go Execution",
        scope: .workspace,
        defaultState: .disabled,
        activationPolicy: .onDemand,
        sleepPolicy: .whenIdle(afterSeconds: 600),
        dependencies: [.module(.workspace)],
        providedCapabilities: [
            .languageExecutionExtension(goLanguageID),
            .languageTestingExtension(goLanguageID)
        ]
    )

    static let languageServer = ModuleManifest(
        id: .languageServerExtension(goLanguageID),
        displayName: "Go Language Server",
        scope: .workspace,
        defaultState: .disabled,
        activationPolicy: .onDemand,
        sleepPolicy: .whenIdle(afterSeconds: 600),
        dependencies: [.module(.workspace)],
        providedCapabilities: [.languageServerExtension(goLanguageID)]
    )
}
