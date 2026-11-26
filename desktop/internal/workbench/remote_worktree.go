package workbench

import (
	"path"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
)

// A remote workspace's Git worktrees are host folders, which Core lists, creates and removes over
// the workspace's session as it does for its other Git work. Opening one is opening another host
// folder: the connection window opens, connects again over the connection the workspace was opened
// over, showing its steps and the questions OpenSSH asks, asks whether to trust the folder when
// that was never decided, and opens it in a tab of this window over a session of its own. A
// worktree already open in a tab with a live session is shown instead. Opening one in a new window
// and showing one in the system's file browser stay refused: a new client opens local folders only
// (#2231 S10), and the folder is not on this computer.
//
// The create dialog shows and takes host paths. Core derives its suggestion beside the repository
// from the repository's path alone, so the dialog sends every path as the path below the root's
// sibling that names it (remoteplaceholder.HostNamedPath): the suggestion then lies below the
// sibling too, which Core maps to the host for the creation. Nothing of a worktree's path or of the
// host is logged.

// remoteReopen is a host the connection window connects to once it has read its saved list:
// a worktree to open, or a host chosen in the title bar whose folder is chosen in the window.
type remoteReopen struct {
	// connectionID names the workspace, including the container when there is one.
	connectionID string
	host         remoteHost
	name         string
	// folder is the host folder, an absolute POSIX path, or empty to choose a folder.
	folder string
}

// openRemoteWorktree opens the worktree whose path in the workspace p is local, a path Core named
// in the list of worktrees.
func (a *App) openRemoteWorktree(p *project, local string) {
	folder, ok := remoteplaceholder.HostPath(p.root, p.remote.binding.RemoteRoot(), local)
	if !ok {
		// Core names every worktree below the root or its sibling, so this list is stale.
		a.operationRejected("git_worktree_open", "not_host_path")
		a.loadWorktrees(p)
		return
	}
	a.openRemoteHostFolder(p, folder)
}

// openRemoteHostFolder opens the host folder over the connection the remote workspace p was opened
// over: the tab that has it open over a live session, or the connection window, which connects and
// opens it.
func (a *App) openRemoteHostFolder(p *project, folder string) {
	r := p.remote
	// The workspace's root is anchor/<key>/<name> (remoteplaceholder.Root).
	anchor := filepath.Dir(filepath.Dir(p.root))
	if open := a.sessions.showing(remoteplaceholder.Root(anchor, r.connectionID, folder)); open != nil {
		if or := open.project.remote; or != nil && !or.closed && or.session != "" {
			a.sessions.activate(open)
			return
		}
	}
	if a.remote.open {
		// log-exempt: 连接窗口是模态窗口，打开时用户点不到工作树；这里只防重复打开。
		return
	}
	reopen := &remoteReopen{connectionID: r.connectionID, host: r.host, name: r.name, folder: folder}
	a.openRemote(surfaceButton)
	a.remote.reopen = reopen
}

// connectRemoteReopen connects the window to reopen's host, as Connect on its page does, and opens
// its folder. A saved connection deleted since the workspace opened is said so on the page the
// window shows instead.
func (a *App) connectRemoteReopen(reopen *remoteReopen) {
	r := &a.remote
	switch {
	case reopen.host.container != nil && (!reopen.host.overSSH() || r.entry(strings.TrimSuffix(reopen.connectionID, "/"+reopen.host.container.Identity())) != nil):
		a.connectRemoteTo(core.SavedRemoteConnection{ID: reopen.connectionID, Name: reopen.name}, reopen.host, reopen.folder)
		return
	case reopen.host.wsl != nil:
		r.selectRemoteWSL(reopen.host.wsl.Distribution)
		r.wsl.user.SetText(reopen.host.wsl.User)
	case r.entry(reopen.connectionID) != nil:
		r.selectEntry(reopen.connectionID)
	default:
		r.selectFirst()
		if reopen.folder == "" {
			a.operationRejected("remote_connect", "connection_removed")
			if r.readErr == "" {
				r.err = i18n.Shared(a.language(), "desktop.remote.hostSwitcher.connectionRemoved")
			}
		} else {
			a.operationRejected("git_worktree_open", "connection_removed")
			if r.readErr == "" {
				r.err = i18n.Shared(a.language(), "desktop.remote.worktree.connectionRemoved")
			}
		}
		return
	}
	a.connectRemote(reopen.folder)
}

// worktreeHostNamed is text, a path the create dialog shows, as Core is sent it: in a remote
// workspace, a host path absolute once trimmed as the path that names it
// (remoteplaceholder.HostNamedPath); anything else as it is, which Core finds not absolute. A local
// project's paths are sent as they are.
func (p *project) worktreeHostNamed(text string) string {
	if p.remote == nil {
		return text
	}
	if host := strings.TrimSpace(text); path.IsAbs(host) {
		if local, ok := remoteplaceholder.HostNamedPath(p.root, host); ok {
			return local
		}
	}
	return text
}

// worktreeShown is local, a path Core answered to the create dialog, as the dialog shows it: its
// host path in a remote workspace, and local itself for any other.
func (p *project) worktreeShown(local string) string {
	if p.remote == nil {
		return local
	}
	if host, ok := remoteplaceholder.HostPath(p.root, p.remote.binding.RemoteRoot(), local); ok {
		return host
	}
	return local
}
