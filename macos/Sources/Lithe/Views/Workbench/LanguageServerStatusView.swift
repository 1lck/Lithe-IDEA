import LitheModuleAPI
import SwiftUI

struct LanguageServerStatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let servers = model.statusBarLanguageServers
        if let status = LSPControlCenterPresenter.aggregateStatus(servers) {
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
                    if servers.count > 1 { Text("\(servers.count)").monospacedDigit() }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Language Services"))
                .accessibilityValue(Text(servers.map { "\($0.displayName): \($0.status.localizedTitle)" }.joined(separator: ", ")))
            }
            .buttonStyle(.litheNoPress)
            .fixedSize()
            .help("Language Services")
        }
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
        [.heading("Language Services")]
            + servers.map { serverItem($0, viewLogs: viewLogs, restart: restart, stop: stop) }
            + [
                .separator,
                .action("Restart All Servers", icon: restartIcon) { for server in servers { restart(server.id) } },
                .action("Stop All Servers", icon: stopIcon) { for server in servers { stop(server.id) } },
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
            LitheContextMenuItem.action("View logs") { viewLogs(server.id) }
            LitheContextMenuItem.action("Restart Server", icon: restartIcon) { restart(server.id) }
            LitheContextMenuItem.action("Stop Server", description: L10n.string("Starts again when a matching document is opened or edited."), icon: stopIcon) {
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
        case .stopped: L10n.string("Starts on demand when a matching file is opened")
        case .disabled: L10n.string("Off")
        case .error: L10n.string(key: "native.inline.failedToStartCheckTheLanguageServerConfiguration")
        }
    }
}
