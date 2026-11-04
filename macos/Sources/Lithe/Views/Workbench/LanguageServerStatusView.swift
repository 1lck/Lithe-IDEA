import LitheModuleAPI
import SwiftUI

struct LanguageServerStatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let servers = model.statusBarLanguageServers
        let status = LSPControlCenterPresenter.aggregateStatus(servers)
        let startedCount = servers.filter(\.canStop).count
        LitheMenu(opensUpward: true) {
            LanguageServerStatusMenu.items(
                servers: servers,
                viewLogs: model.showLanguageServerLogs,
                restart: model.languageToolingFeature.restart,
                stop: model.languageToolingFeature.stop,
                settings: { model.showSettings(category: .lsp) }
            )
        } label: {
            HStack(spacing: 5) {
                Circle().fill(status.indicatorColor).frame(width: 7, height: 7)
                Text("LSP")
                if status == .stopped || status == .disabled {
                    Text(status.localizedTitle)
                } else if startedCount > 1 {
                    Text("\(startedCount)").monospacedDigit()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Language Services"))
            .accessibilityValue(Text(servers.isEmpty ? status.localizedTitle
                : servers.map { "\($0.displayName): \($0.status.localizedTitle)" }.joined(separator: ", ")))
        }
        .buttonStyle(.litheNoPress)
        .fixedSize()
        .help("Language Services")
    }
}

@MainActor
enum LanguageServerStatusMenu {
    private static var restartIcon: AnyView {
        AnyView(LitheIDEAIcon(resourcePath: "debugger/rerun.svg", size: 16, preservesOriginalColors: true))
    }

    private static var stopIcon: AnyView {
        AnyView(LitheIDEAIcon(resourcePath: "expui/run/stop.svg", size: 16, preservesOriginalColors: true))
    }

    static func items(
        servers: [LSPStatusBarServer],
        viewLogs: @escaping (String) -> Void,
        restart: @escaping (String) -> Void,
        stop: @escaping (String) -> Void,
        settings: @escaping () -> Void
    ) -> [LitheContextMenuItem] {
        let startedServers = servers.filter(\.canStop)
        return [.heading("Language Services")]
            + (servers.isEmpty ? [.heading("No registered language servers")] : [])
            + servers.map { serverItem($0, viewLogs: viewLogs, restart: restart, stop: stop) }
            + [
                .separator,
                .action(L10n.string(key: "native.inline.viewLogs"), localizesTitle: false) { viewLogs("") },
                .action("Restart All Servers", icon: restartIcon, isEnabled: !startedServers.isEmpty) {
                    for server in startedServers { restart(server.id) }
                },
                .action("Stop All Servers", icon: stopIcon, isEnabled: !startedServers.isEmpty) {
                    for server in startedServers { stop(server.id) }
                },
                .separator,
                .action("Language Server Settings...", icon: AnyView(
                    LitheIDEAIcon(resourcePath: "expui/general/settings.svg", size: 16, preservesOriginalColors: true)
                ), action: settings)
            ]
    }

    private static func serverItem(
        _ server: LSPStatusBarServer,
        viewLogs: @escaping (String) -> Void,
        restart: @escaping (String) -> Void,
        stop: @escaping (String) -> Void
    ) -> LitheContextMenuItem {
        var item = LitheContextMenuItem.submenu(server.displayName, icon: AnyView(
            Circle().fill(server.status.indicatorColor).frame(width: 8, height: 8)
        )) {
            LitheContextMenuItem.action(L10n.string(key: "native.inline.viewLogs"), localizesTitle: false) { viewLogs(server.id) }
            LitheContextMenuItem.action("Restart Server", icon: restartIcon,
                isEnabled: server.canStop) { restart(server.id) }
            LitheContextMenuItem.action("Stop Server", description: L10n.string("Starts again when a matching document is opened or edited."),
                icon: stopIcon, isEnabled: server.canStop) {
                stop(server.id)
            }
        }
        item.localizesTitle = false
        item.description = [server.status.localizedTitle, server.version].compactMap { $0 }.joined(separator: " · ")
        return item
    }
}

extension LSPServerStatus {
    var localizedTitle: String {
        switch self {
        case .starting: L10n.string("Starting")
        case .initializing: L10n.string("Initializing project index")
        case .active: L10n.string("Running")
        case .stopping: L10n.string("Stopping")
        case .stopped: L10n.string("Not started")
        case .disabled: L10n.string("Off")
        case .error: L10n.string(key: "native.inline.failedToStartCheckTheLanguageServerConfiguration")
        }
    }
}
