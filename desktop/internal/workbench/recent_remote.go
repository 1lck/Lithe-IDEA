package workbench

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

func (a *App) recordRemoteRecent(target remoteTarget) {
	remote := core.RecentRemoteProject{
		ConnectionID: target.connectionID, Name: target.name, Folder: target.remoteRoot,
		WSL: target.host.wsl, Container: target.host.container,
	}
	if target.host.overSSH() {
		remote.SSHConnectionID = target.connectionID
		if target.host.container != nil {
			remote.SSHConnectionID = strings.TrimSuffix(target.connectionID, "/"+target.host.container.Identity())
		}
	}
	a.changeRecent(core.RecordRemoteRecent(remote, a.now()), nil)
}

func (a *App) openRecent(path string) {
	for _, entry := range a.recent {
		if entry.Path == path && entry.Remote != nil {
			a.openRecentRemote(entry.Remote)
			return
		}
	}
	a.openProject(path)
}

func (a *App) openRecentRemote(remote *core.RecentRemoteProject) {
	// A live workspace is already the requested connection. Use its own anchor,
	// since the history records only the transport and remote folder.
	for _, tab := range a.sessions.list {
		p := tab.project
		if p != nil && p.remote != nil && p.remote.connectionID == remote.ConnectionID &&
			p.remote.binding.RemoteRoot() == remote.Folder && !p.remote.closed && p.remote.session != "" {
			a.sessions.activate(tab)
			return
		}
	}
	if a.remote.open {
		return
	}
	a.openRemote(surfaceButton)
	a.remote.reopen = &remoteReopen{recent: remote}
}

func (a *App) connectRecentRemote(remote *core.RecentRemoteProject) {
	host := remoteHost{wsl: remote.WSL, container: remote.Container}
	entry := core.SavedRemoteConnection{ID: remote.ConnectionID, Name: remote.Name}
	if remote.SSHConnectionID != "" {
		saved := a.remote.entry(remote.SSHConnectionID)
		if saved == nil {
			a.remote.selectFirst()
			a.operationRejected("remote_connect", "connection_removed")
			if a.remote.readErr == "" {
				a.remote.err = i18n.Shared(a.language(), "desktop.remote.hostSwitcher.connectionRemoved")
			}
			return
		}
		host.ssh = saved.Connection
		if host.container == nil {
			a.remote.selectEntry(saved.ID)
			entry = *saved
		}
	} else if host.wsl != nil && host.container == nil {
		a.remote.selectRemoteWSL(host.wsl.Distribution)
		a.remote.wsl.user.SetText(host.wsl.User)
	}
	a.connectRemoteTo(entry, host, remote.Folder)
}

// recentIsOpen compares the transport and remote folder for remote workspaces.
func recentIsOpen(entry core.RecentProject, project *project) bool {
	if entry.Remote == nil {
		return entry.Path == project.root
	}
	r := entry.Remote
	if project.remote == nil || project.remote.connectionID != r.ConnectionID {
		return false
	}
	return project.remote.binding.RemoteRoot() == r.Folder
}
