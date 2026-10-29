import Foundation
import LitheCoreContracts
import LitheModuleAPI

// Note: 插件设置注册面与生效方式见 .agents/notes/implemented/architecture/2026-10-21-plugin-settings-surfaces.md

/// A settings page that exists only because enabled plugins registered
/// something for it. The host draws every page the same way; what a page
/// holds (options, buttons, which language or build system it is about)
/// comes entirely from the plugins' declarations.
struct ContributedSettingsPage: Identifiable, Equatable, Sendable {
    enum Placement: Hashable, Sendable {
        /// Languages & Frameworks › <language>.
        case language(String)
        /// Build, Execution, Deployment › <build system>.
        case buildSystem(String)
    }

    /// What one plugin put on the page.
    struct Contribution: Identifiable, Equatable, Sendable {
        let pluginID: PluginID
        let pluginName: String
        let settings: [PluginSettingState]
        let actions: [DeclarativePluginSettingAction]
        /// The plugin runs a language server for this page's language.
        let providesLanguageServer: Bool

        var id: PluginID { pluginID }
    }

    let placement: Placement
    let title: String
    let contributions: [Contribution]

    var id: String {
        switch placement {
        case .language(let id): "language:\(id)"
        case .buildSystem(let id): "buildSystem:\(id)"
        }
    }

    var group: SettingsGroup {
        switch placement {
        case .language: .languages
        case .buildSystem: .build
        }
    }

    var languageID: String? {
        if case .language(let id) = placement { id } else { nil }
    }

    /// Titles of everything on the page, for the settings search.
    var searchTerms: [String] {
        [title] + contributions.flatMap { contribution in
            [contribution.pluginName]
                + contribution.settings.flatMap { [$0.declaration.title, $0.declaration.summary, $0.declaration.section].compactMap { $0 } }
                + contribution.actions.flatMap { [$0.title, $0.summary, $0.section].compactMap { $0 } }
        }
    }
}

enum PluginSettingsRegistry {
    /// The pages enabled plugins register, ordered by group and title. A
    /// language page appears for every language an enabled plugin serves
    /// with a language server, so its status has a home even before the
    /// plugin declares options; a build-system page appears only when a
    /// plugin placed options or buttons on it. Settings without a page stay
    /// on the plugin's own Settings tab.
    static func pages(from snapshots: [PluginManagementSnapshot]) -> [ContributedSettingsPage] {
        var titles: [ContributedSettingsPage.Placement: String] = [:]
        var contributions: [ContributedSettingsPage.Placement: [ContributedSettingsPage.Contribution]] = [:]

        for plugin in snapshots where plugin.isEnabled
            && [.installed, .updateStaged].contains(plugin.installationStatus) {
            let declared = plugin.contributions
            for language in declared.languages where titles[.language(language.id)] == nil {
                titles[.language(language.id)] = language.displayName
            }
            for buildSystem in declared.buildSystems where titles[.buildSystem(buildSystem.id)] == nil {
                titles[.buildSystem(buildSystem.id)] = buildSystem.displayName
            }

            var placements: [ContributedSettingsPage.Placement] = declared.languageServerIDs.map { .language($0) }
            placements += plugin.settings.compactMap { $0.declaration.page.map(placement) }
            placements += declared.actions.compactMap { $0.page.map(placement) }
            var seen = Set<ContributedSettingsPage.Placement>()
            for page in placements where seen.insert(page).inserted {
                contributions[page, default: []].append(ContributedSettingsPage.Contribution(
                    pluginID: plugin.id,
                    pluginName: plugin.manifest.displayName,
                    settings: plugin.settings.filter { $0.declaration.page.map(placement) == page },
                    actions: declared.actions.filter { $0.page.map(placement) == page },
                    providesLanguageServer: page.languageID.map(declared.languageServerIDs.contains) ?? false
                ))
            }
        }

        return contributions.map { page, entries in
            ContributedSettingsPage(
                placement: page,
                title: titles[page] ?? fallbackTitle(page),
                contributions: entries.sorted { $0.pluginName.localizedStandardCompare($1.pluginName) == .orderedAscending }
            )
        }.sorted {
            if $0.group != $1.group { return $0.group == .build }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func placement(_ page: DeclarativePluginSetting.Page) -> ContributedSettingsPage.Placement {
        switch page {
        case .language(let id): .language(id)
        case .buildSystem(let id): .buildSystem(id)
        }
    }

    private static func fallbackTitle(_ page: ContributedSettingsPage.Placement) -> String {
        switch page {
        case .language(let id), .buildSystem(let id): id.prefix(1).uppercased() + id.dropFirst()
        }
    }
}

private extension ContributedSettingsPage.Placement {
    var languageID: String? {
        if case .language(let id) = self { id } else { nil }
    }
}
