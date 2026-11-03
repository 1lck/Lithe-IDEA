import SwiftUI
import LitheModuleAPI

/// Keeps hidden rail entries discoverable through the registered Show action.
struct WorkbenchToolWindowsMenu: View {
    @ObservedObject var model: AppModel
    @State private var isPresented = false

    var body: some View {
        let items = Self.items(for: model)
        if !items.isEmpty {
            Button { isPresented.toggle() } label: {
                LitheIDEAIcon(resourcePath: "expui/general/moreHorizontal.svg", size: ActivityBarMetrics.iconSize)
            }
            .buttonStyle(LitheActivityBarButtonStyle(isSelected: isPresented))
            .workbenchHoverHelp(Text("Tool Windows"), placement: .trailing)
            .accessibilityLabel("Tool Windows")
            .accessibilityIdentifier("workbench-tool-windows-menu")
            .overlay {
                LitheDropdownPopover(isPresented: $isPresented, items: items) { EmptyView() }
            }
        }
    }

    @MainActor
    static func items(for model: AppModel) -> [LitheContextMenuItem] {
        // Read hidden rail entries from the full catalog, not its visible projection.
        let available = model.workbenchContributions
        func displayTitle(_ entry: ModuleContribution) -> String {
            model.workbenchUIRegistry.localizesTitle(for: entry) ? L10n.string(key: entry.title) : entry.title
        }
        return available.filter { $0.kind == .toolWindow }.sorted {
            let left = displayTitle($0), right = displayTitle($1)
            return left == right ? $0.id < $1.id : left.localizedStandardCompare(right) == .orderedAscending
        }.compactMap { contribution in
            let state = model.workbenchUIRegistry.state(for: contribution, model: model, available: available)
            guard state.isVisible,
                  model.workbenchFeature.contributionPreferences[contribution.id]?.isHidden == true else { return nil }
            let command = LitheCommandCatalog.commands.first {
                LitheCommandCatalog.toolWindow(for: $0.id)?.rawValue == contribution.id
            }
            let icon = model.workbenchUIRegistry.icon(for: contribution, role: .action)
                ?? model.workbenchUIRegistry.renderer(for: contribution)?.ideaAssetPath.map {
                    AnyView(LitheIDEAIcon(resourcePath: WorkbenchContributionIcon.Asset.actionPaths[$0] ?? $0,
                                          size: LitheTheme.Metrics.toolbarIconSize))
                }
            let show = LitheContextMenuItem.action(L10n.string("Show"),
                checked: state.isChecked,
                shortcut: command.flatMap { model.keyboardShortcutFeature.displayText(for: $0.id) },
                isEnabled: state.isEnabled && !state.isPending) {
                model.showContributionEntry(contribution)
            }
            var item = LitheContextMenuItem.submenu(contribution.title, icon: icon, items: [show])
            item.localizesTitle = model.workbenchUIRegistry.localizesTitle(for: contribution)
            item.isEnabled = show.isEnabled
            return item
        }
    }
}
