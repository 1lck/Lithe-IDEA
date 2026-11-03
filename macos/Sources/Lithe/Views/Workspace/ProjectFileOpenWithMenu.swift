import AppKit
import LitheModuleAPI

enum ProjectFileOpenWithMenu {
    @MainActor
    static func items(model: AppModel, url: URL) -> [LitheContextMenuItem] {
        guard model.canOpenProjectFilesExternally, let identity = model.currentWorkspaceIdentity else { return [] }
        let current = { model.currentWorkspaceIdentity == identity && model.canOpenProjectFilesExternally }
        let applications = model.externalApplications(for: url)
        var choices: [LitheContextMenuItem] = []
        for application in applications {
            let title = application.isDefault
                ? String(format: L10n.string("%@ (default)"), application.name) : application.name
            var item = LitheContextMenuItem.action(title, localizesTitle: false) {
                Task { @MainActor in
                    guard current() else { return }
                    await model.openProjectFileExternally(url, application: application.url)
                }
            }
            item.nativeImage = application.iconData.flatMap { NSImage(data: $0) }
            choices.append(item)
            if application.isDefault, applications.count > 1 { choices.append(.separator) }
        }
        if !choices.isEmpty { choices.append(.separator) }
        choices += [
            .action("App Store…") {
                Task { @MainActor in
                    guard current() else { return }
                    model.findExternalApplications(for: url)
                }
            },
            .action("Other…") {
                Task { @MainActor in
                    guard current() else { return }
                    await model.openProjectFileExternally(url, application: nil, chooseApplication: true)
                }
            }
        ]
        var submenu = LitheContextMenuItem.submenu("Open With", items: choices)
        submenu.usesSystemMenu = true
        return [submenu]
    }
}
