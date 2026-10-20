import Foundation

/// Search vocabulary for the settings sidebar.
///
/// `SettingsView.filteredCategories` decides which settings page a query opens by
/// matching the query against these English keys and against each key's localized
/// value. A page whose vocabulary drifts from its own controls becomes
/// unreachable from settings search without any visible error, which is how the
/// Editor page lost its tabs entry while it gained the programming-font row.
///
/// The vocabulary therefore lives outside the view so it can be asserted
/// directly, including the localized half of the match.
enum SettingsSearchVocabulary {
    /// English keys that describe a settings page, in reviewer-friendly order.
    /// Every page must list the words a user can actually read on that page.
    static func terms(for category: SettingsCategory) -> [String] {
        switch category {
        case .general:
            ["General", "Appearance", "Color theme", "Appearance mode", "Language", "Projects", "Files", "Version control", "Hidden paths"]
        case .editor:
            ["Editor", "Display", "Editor tabs", "tabs", "Font", "Font size", "Search fonts", "File tree row height", "Show minimap", "Minimap", "Indentation", "Tab width"]
        case .keymap:
            ["Keymap", "Keyboard shortcuts", "Shortcuts", "Actions"]
        case .project:
            ["Project", "Java SDK", "JDK", "Project JDK", "Maven", "Maven Home", "Maven Wrapper", "Maven JDK"]
        case .run:
            ["Run configurations", "Program arguments", "VM options", "Environment variables", "Working directory", "Services"]
        case .terminal:
            ["Terminal", "Shell", "Default shell", "Scrollback", "Terminal scrollback", "Scrollback lines"]
        case .lsp:
            ["LSP", "Language server"]
        case .ai:
            ["AI & Commit", "Commit message", "Pull request"]
        case .agents:
            ["Agents", "Agent conversation", "Codex", "Claude", "ACP adapter", "Preflight", "Providers"]
        case .providers:
            ["AI Providers", "AI provider", "Model", "API key", "Endpoint", "Responses", "Anthropic"]
        case .git:
            ["Git", "Fetch", "Tags", "Submodules", "Prune", "Commit identity", "Committer name", "Committer email", "Configuration scope", "user.name", "user.email"]
        case .updates:
            ["Updates", "Application version", "Update status", "Check for Updates", "Update channel", "Stable (Recommended)", "AutoBuild Rolling"]
        case .processTermination:
            ["Process Termination Policy", "Process", "Quit", "Terminals with running programs", "Agent tasks", "Background services", "Closing a terminal tab", "After Lithe closes unexpectedly", "Time to exit", "Remembered choices", "Daemon"]
        case .diagnostics:
            ["Logs and Diagnostics", "Logs", "Log directory", "Log timeline", "Diagnostics", "Diagnostic bundle", "Export logs", "Bug report", "Detailed diagnostics", "Module", "Session", "Minimum level", "Filter log messages", "From (UTC ISO 8601)", "Until (UTC ISO 8601)", "Retention and cleanup"]
        case .plugins:
            ["Plugins", "Installed", "Marketplace", "Language support"]
        case .mcp:
            ["MCP Configuration", "MCP", "MCP servers", "Server library", "Add server", "Codex", "Claude Code", "Agent", "AI tool connections (MCP)", "Copy agent configuration", "Permissions", "Environment variables", "Lithe IDE access"]
        }
    }

    /// True when `query` matches a page either through an English key or through
    /// that key's localized value. `localize` is injected so the localized half of
    /// the match can be asserted against the shipped translation table.
    static func matches(
        query: String,
        category: SettingsCategory,
        localize: (String) -> String = { $0 }
    ) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        return terms(for: category).contains { term in
            localize(term).localizedCaseInsensitiveContains(trimmed)
                || term.localizedCaseInsensitiveContains(trimmed)
        }
    }
}
