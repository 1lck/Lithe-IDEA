import Foundation
import LitheModuleAPI

extension AppModel {
    var canOpenProjectFilesExternally: Bool {
        guard let identity = currentWorkspaceIdentity else { return false }
        return platformUI.supportsExternalFileApplications
            && services.remoteConnections?.workspaces.contains(identity.url) != true
    }

    func externalApplications(for url: URL) -> [ExternalFileApplication] {
        canOpenProjectFilesExternally ? platformUI.applications(toOpen: url) : []
    }

    func openProjectFileExternally(_ url: URL, application: URL?, chooseApplication: Bool = false) async {
        guard canOpenProjectFilesExternally, let identity = currentWorkspaceIdentity else { return }
        var selected = application
        if chooseApplication {
            guard let choice = await platformUI.chooseExternalFileApplication() else { return }
            selected = choice
        }
        guard currentWorkspaceIdentity == identity, canOpenProjectFilesExternally else { return }
        do {
            try await platformUI.openFile(url, withApplicationAt: selected)
        } catch {
            guard currentWorkspaceIdentity == identity else { return }
            showNotification(String(format: L10n.string("Could not open %@: %@"), url.lastPathComponent, error.localizedDescription))
        }
    }

    func findExternalApplications(for url: URL) {
        guard canOpenProjectFilesExternally else { return }
        do { try platformUI.findApplicationsOnAppStore(for: url) }
        catch {
            showNotification(String(format: L10n.string("Could not open %@: %@"), L10n.string("App Store"), error.localizedDescription))
        }
    }
}
