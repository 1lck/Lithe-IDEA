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
		remote.SSHConnectionID = savedSSHID(target.connectionID, target.host.container)
		remote.SSHTargetFingerprint = target.host.sshTargetFingerprint
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
	// Saved SSH routes are revalidated against disk before reusing even a live tab.
	if remote.SSHConnectionID == "" && a.activateLiveRecentRemote(remote) {
		return
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
		if !matchesSavedTarget(saved, remote.SSHTargetFingerprint) {
			a.rejectChangedRecentSSH(saved.ID)
			return
		}
		if a.activateLiveRecentRemote(remote) {
			a.closeRemote()
			return
		}
		host.ssh, host.sshTargetFingerprint = saved.Connection, saved.TargetFingerprint
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

func savedSSHID(connectionID string, container *core.ContainerConnection) string {
	if container != nil {
		return strings.TrimSuffix(connectionID, "/"+container.Identity())
	}
	return connectionID
}

func matchesSavedTarget(saved *core.SavedRemoteConnection, fingerprint string) bool {
	return fingerprint != "" && saved.TargetFingerprint == fingerprint
}

func (a *App) rejectChangedRecentSSH(id string) {
	a.remote.selectEntry(id)
	a.operationRejected("remote_connect", "saved_target_changed")
	a.remote.err = i18n.Shared(a.language(), "desktop.welcome.recentSSHTargetChanged")
}

func (a *App) activateLiveRecentRemote(remote *core.RecentRemoteProject) bool {
	for _, tab := range a.sessions.list {
		p := tab.project
		if p != nil && recentRemoteMatchesProject(remote, p) && !p.remote.closed && p.remote.session != "" {
			a.sessions.activate(tab)
			return true
		}
	}
	return false
}

// recentIsOpen compares the transport and remote folder for remote workspaces.
func recentIsOpen(entry core.RecentProject, project *project) bool {
	if entry.Remote == nil {
		return entry.Path == project.root
	}
	return recentRemoteMatchesProject(entry.Remote, project)
}

func recentRemoteMatchesProject(recent *core.RecentRemoteProject, project *project) bool {
	r := project.remote
	return r != nil && r.connectionID == recent.ConnectionID &&
		r.binding.RemoteRoot() == recent.Folder &&
		(recent.SSHConnectionID == "" || (recent.SSHTargetFingerprint != "" && recent.SSHTargetFingerprint == r.host.sshTargetFingerprint))
}
