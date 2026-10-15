import SwiftUI
import LitheModuleAPI

/// One presentation for plugin icons in every host-owned UI location. Button
/// and menu styles own hover, selected tint and disabled opacity; template
/// icons inherit their foreground, while brand assets preserve their pixels.
struct WorkbenchContributionIcon: View {
    enum Role { case toolWindow, action, header
        var size: CGFloat {
            switch self {
            case .toolWindow: ActivityBarMetrics.iconSize
            case .action: LitheTheme.Metrics.toolbarIconSize
            case .header: 13
            }
        }
    }

    struct Asset {
        static let hostPaths: [String: String] = [
            "tool-window": "expui/toolwindows/toolWindowComponents@20x20.svg",
            "plugin": "expui/nodes/plugin.svg",
            "database": "database/expui/dbms@20x20.svg",
            "services": "expui/toolwindows/services@20x20.svg",
            "terminal": "terminal/terminal@20x20.svg",
            "search": "expui/general/search.svg",
            "refresh": "expui/general/refresh.svg",
            "run": "expui/toolwindows/run@20x20.svg",
            "debug": "expui/toolwindows/debug@20x20.svg",
            "settings": "expui/general/settings@20x20.svg",
            "add": "expui/general/add.svg",
            "remove": "expui/general/delete.svg",
            "git": "expui/toolwindows/vcs@20x20.svg",
            "problems": "expui/toolwindows/problems@20x20.svg"
        ]
        let hostPath: String?
        let mode: PluginUIIcon.Mode
        let light: NSImage?
        let dark: NSImage?

        init(_ declaration: PluginUIIcon?, resources: PluginUIIconResources?) {
            mode = declaration?.mode ?? .template
            light = resources.flatMap { NSImage(data: $0.light) }
            dark = resources?.dark.flatMap { NSImage(data: $0) }
            hostPath = declaration?.host.flatMap { Self.hostPaths[$0] }
                ?? (light == nil ? Self.hostPaths["tool-window"] : nil)
        }

        func image(isDark: Bool) -> NSImage? { isDark ? dark ?? light : light }
    }

    let asset: Asset
    let role: Role
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let hostPath = asset.hostPath {
            LitheIDEAIcon(resourcePath: hostPath, size: role.size, fallbackSystemImage: "square.grid.2x2",
                          preservesOriginalColors: asset.mode == .original)
                .accessibilityHidden(true)
        } else if let image = asset.image(isDark: colorScheme == .dark) {
            Image(nsImage: image)
                .renderingMode(asset.mode == .original ? .original : .template)
                .resizable()
                .scaledToFit()
                .frame(width: role.size, height: role.size)
                .accessibilityHidden(true)
        }
    }
}
