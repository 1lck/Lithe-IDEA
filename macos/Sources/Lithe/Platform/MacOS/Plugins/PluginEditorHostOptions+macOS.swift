import LitheCoreContracts

// Note: 编辑器扩展点的契约与宿主声明见 .agents/notes/implemented/architecture/2026-10-31-plugin-editor-extension-apis.md

extension PluginEditorHostOptions {
    /// What the macOS editor draws and routes. The icon names are the keys of
    /// `editorActionIcons` in `macos/EditorFrontend/main.ts`; each maps to an
    /// IDEA icon resource bundled with the web editor, so a name declared
    /// here without a resource there would draw nothing.
    ///
    /// Core relays this to a plugin backend through `getCapabilities` and
    /// validates registrations and results against it.
    static let macOS = PluginEditorHostOptions(
        actionIcons: [
            "run", "run-all", "debug", "test", "test-passed", "test-failed", "test-skipped",
            "navigate-super", "navigate-implementations",
        ],
        actionSourceBytes: 1024 * 1024,
        providerTypes: [
            "definition", "hover", "completion", "codeLens", "foldingRange", "semanticTokens", "documentLink",
        ]
    )
}
