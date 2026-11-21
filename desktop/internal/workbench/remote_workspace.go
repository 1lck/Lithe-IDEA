package workbench

import (
	"context"
	"errors"
	"path"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteserver"
)

// A remote workspace is a project whose folder is on an SSH host or in a WSL distribution of this
// computer (#2231, R0; remote_wsl.go). Its root is a
// placeholder below a read-only file of the user's cache directory (remoteplaceholder), and its
// context carries a core.RemoteWorkspace binding: every Core request of the project runs on the
// host or is refused with not_supported, and a local call with a path of the project fails
// instead of touching a local folder that only looks like it.
//
// The workspace opens over a session the Remote Development window connected, and keeps it alive:
// a heartbeat asks the server's state, a failed request of the binding reports the connection
// lost, and the window then connects again on its own a few times, pausing longer each time.
// OpenSSH's questions are cancelled during those attempts, which must not ask the user anything
// they did not start; a host that needs a password then ends disconnected, and Reconnect in the
// status bar asks. Closing the project ends its session, and quitting ends every session Core
// keeps (App.Run).
//
// In this stage the workspace lists its folder in the Project tool window, the editor opens,
// saves and compares the host's files (remote_documents.go), Find in Files and Search Everywhere
// search them on the host (remote_search.go), its terminals run the host's login shell on the
// host (remote_terminal.go), and the host watches the folder, so a change made there shows in the
// tree and the open documents (remote_watch.go). It opens trusted or in safe mode as the user
// decided for the folder (remote_trust.go); trusted, its Git runs on the host (remote_git.go). The
// features that still read the project through the local file system (local history, language
// servers, run configurations and plugins, a plugin's terminal among them) are not started for
// it, or say so, until each moves to the host (R0, step 3).

const (
	// remoteHeartbeatInterval is the pause between two heartbeats of a connected workspace.
	remoteHeartbeatInterval = 15 * time.Second
	// remoteHeartbeatTimeout bounds one heartbeat. A server that does not answer in time is shown
	// unresponsive; remoteHeartbeatMisses in a row end the session and connect again.
	remoteHeartbeatTimeout = 10 * time.Second
	remoteHeartbeatMisses  = 3
	// remoteDisconnectTimeout bounds ending one session; remoteCloseAllTimeout bounds ending every
	// session while the application quits.
	remoteDisconnectTimeout = 10 * time.Second
	remoteCloseAllTimeout   = 10 * time.Second
	// remoteReadDirTimeout bounds listing one host folder in the folder browser.
	remoteReadDirTimeout = 30 * time.Second
)

// remoteLink is how the workspace's connection is doing, as the status bar shows it.
type remoteLink int

const (
	// remoteConnected: the last heartbeat was answered.
	remoteConnected remoteLink = iota
	// remoteUnresponsive: the session is open, but the last heartbeat went unanswered.
	remoteUnresponsive
	// remoteReconnecting: the session was lost and a new one is being opened.
	remoteReconnecting
	// remoteDisconnected: the session was lost and connecting again failed or gave up; Reconnect
	// tries again.
	remoteDisconnected
)

// remoteProject is the remote side of a project (project.remote).
type remoteProject struct {
	// binding carries the session and the two roots in every Core request of the project.
	binding *core.RemoteWorkspace
	// connectionID, name and host are the saved connection, the WSL distribution or the
	// container the workspace was opened over, as it was when the workspace opened; connecting
	// again uses the same. A WSL distribution's or a container's id is its identity
	// (core.WSLConnection.Identity, core.ContainerConnection.Identity).
	connectionID string
	name         string
	host         remoteHost
	// session is the session the binding is attached to, "" while there is none.
	session string
	// home is the host account's home directory, "" when the host did not report it.
	home    string
	link    remoteLink
	latency time.Duration
	// misses counts the heartbeats in a row that went unanswered.
	misses int
	// stopTimer stops the pending heartbeat or reconnection; timer tells its callback apart from
	// one a later schedule replaced.
	stopTimer func() bool
	timer     uint64
	beating   bool
	// attempt counts the attempts of the current reconnection; reconnecting is the running one.
	// delays are the pauses before its automatic attempts, read from the remote workspace
	// preferences when the connection was lost; lost tells a reading apart from one a later loss
	// or Reconnect replaced.
	attempt      int
	reconnecting *remoteProbe
	delays       []time.Duration
	lost         uint64
	// failure is why connecting again failed, nil while it has not.
	failure *remoteProbeOutcome
	// menuOpen is the status bar's menu of the connection.
	menuOpen bool
	// watch is the host watch of the folder over the session (remote_watch.go), nil while none
	// runs; watchWait is what it waits for then. watchNotified is set once the user was told the
	// folder is not watched in full.
	watch         *remoteWatch
	watchWait     remoteWatchWait
	watchNotified bool
	// ports is the Ports tool window's state (remote_ports.go).
	ports remotePorts
	// closed is set once the project closes; nothing of the workspace runs afterwards.
	closed bool
}

// remoteTarget is a host folder to open as a workspace over a connected session.
type remoteTarget struct {
	connectionID string
	name         string
	host         remoteHost
	session      core.RemoteSession
	// remoteRoot is the host folder, an absolute POSIX path; root is its local placeholder.
	remoteRoot string
	root       string
	// trusted opens the workspace trusted, as the user decided for the folder; it opens in safe
	// mode otherwise.
	trusted bool
}

// errRemoteSessionClosed is what the binding's loss reports: a request of the workspace found
// its connection closed.
var errRemoteSessionClosed = &core.Error{Code: core.CodeConnectionClosed, Message: "the connection to the host closed"}

// remoteLogError is err as the log keeps it. Core's message of a remote failure may name the host
// or a host path, so only its command and code are kept; any other error loses its paths.
func remoteLogError(err error) error {
	var coreErr *core.Error
	if errors.As(err, &coreErr) {
		return &core.Error{Command: coreErr.Command, Code: coreErr.Code, Message: "remote request failed"}
	}
	return documentLogError(err)
}

// logError is err as the log keeps it for a request of p: remoteLogError for a remote workspace,
// err itself for a local one.
func (p *project) logError(err error) error {
	if p.remote != nil {
		return remoteLogError(err)
	}
	return err
}

// remoteConnectionClosed reports whether err says the session's connection is gone.
func remoteConnectionClosed(err error) bool {
	var coreErr *core.Error
	return errors.As(err, &coreErr) && coreErr.Code == core.CodeConnectionClosed
}

// remoteHostPath is the host path of full, a path of the workspace's placeholder: below the
// project's root, or a host path outside it Core named, such as a worktree's
// (remoteplaceholder.HostPath). Any other path, and every path of a local project, is returned
// as it is.
func (p *project) remoteHostPath(full string) string {
	if p.remote == nil {
		return full
	}
	if host, ok := remoteplaceholder.HostPath(p.root, p.remote.binding.RemoteRoot(), full); ok {
		return host
	}
	return full
}

// remoteLocation is the workspace as the user names it: the connection's name and the host
// folder.
func (r *remoteProject) remoteLocation() string {
	return r.name + ":" + r.binding.RemoteRoot()
}

// remoteServerBundle is the server builds a connection sends: the ones the client carries,
// installed below the user's cache directory. It runs off the window thread.
func (a *App) remoteServerBundle() (remoteserver.Bundle, error) {
	if a.remoteBundle != nil {
		return a.remoteBundle()
	}
	dir, err := remoteserver.DefaultDir()
	if err != nil {
		return remoteserver.Bundle{}, err
	}
	return remoteserver.Resolve(dir)
}

// remotePlaceholderAnchor is the anchor below which the workspaces' placeholders lie. It runs off
// the window thread.
func (a *App) remotePlaceholderAnchor() (string, error) {
	if a.remoteAnchor != nil {
		return a.remoteAnchor()
	}
	return remoteplaceholder.DefaultAnchor()
}

// connectRemoteHost opens a session to host with the server builds the client carries and, for
// an SSH host, the SSH program of the remote workspace preferences under root. It runs off the
// window thread.
func (a *App) connectRemoteHost(ctx context.Context, kernel Kernel, root string, host remoteHost) (core.RemoteConnectResult, error) {
	bundle, err := a.remoteServerBundle()
	if err != nil {
		return core.RemoteConnectResult{}, err
	}
	servers := make([]core.RemoteServerBuild, len(bundle.Builds))
	for i, build := range bundle.Builds {
		servers[i] = core.RemoteServerBuild{Target: build.Target, Path: build.Path, SHA256: build.SHA256}
	}
	request := host.request(servers, bundle.Version)
	if host.overSSH() {
		// A WSL distribution starts through wsl.exe, and a container of this computer through its
		// engine's CLI, which the SSH program does not replace.
		if request.Preferences, err = remotePreferencesDocument(ctx, kernel, root); err != nil {
			return core.RemoteConnectResult{}, err
		}
	}
	return kernel.RemoteConnect(ctx, request)
}

// remoteConnectOutcome is the result of a connection to host as the window shows a test's.
func remoteConnectOutcome(host remoteHost, result core.RemoteConnectResult, err error) *remoteProbeOutcome {
	outcome := &remoteProbeOutcome{result: core.RemoteProbeResult{Status: result.Status, Host: result.Host, Diagnostics: result.Diagnostics}, err: err, wsl: host.wsl != nil, hosted: host.hosted()}
	if host.container != nil {
		outcome.engine = host.container.Engine
	}
	return outcome
}

// remoteConnectFailure is the error the log keeps for a connection that failed: err, or Core's
// fixed status when the connection was refused.
func remoteConnectFailure(result core.RemoteConnectResult, err error) error {
	if err != nil {
		return remoteLogError(err)
	}
	return errors.New("remote connect: " + string(result.Status))
}

// releaseRemoteSession ends the session id in the background; a session Core no longer knows is
// already gone.
func (a *App) releaseRemoteSession(id string) {
	if id == "" {
		return
	}
	kernel := a.kernel
	a.background(nil, remoteDisconnectTimeout, func(ctx context.Context) func(*App) {
		_, err := kernel.RemoteDisconnect(ctx, id)
		if err == nil {
			return nil
		}
		return func(a *App) { a.backgroundFailed("remote_disconnect", remoteLogError(err)) }
	})
}

// remoteAfterFunc runs f on its own goroutine after d and returns what stops it.
func (a *App) remoteAfterFunc(d time.Duration, f func()) func() bool {
	if a.remoteAfter != nil {
		return a.remoteAfter(d, f)
	}
	return time.AfterFunc(d, f).Stop
}

// scheduleRemote runs then on the window thread after d, replacing the pending heartbeat or
// reconnection. It does not run once the project closed or another schedule replaced it.
func (a *App) scheduleRemote(p *project, d time.Duration, then func(*App, *project)) {
	r := p.remote
	r.stopRemoteTimer()
	token := r.timer
	r.stopTimer = a.remoteAfterFunc(d, func() {
		a.post(func(a *App) {
			if a.project != p || r.closed || r.timer != token {
				return
			}
			r.stopTimer = nil
			then(a, p)
		})
	})
}

// stopRemoteTimer stops the pending heartbeat or reconnection; a callback already queued finds
// its token outdated.
func (r *remoteProject) stopRemoteTimer() {
	if r.stopTimer != nil {
		r.stopTimer()
		r.stopTimer = nil
	}
	r.timer++
}

// attachRemote makes session the workspace's session and starts its heartbeat, the host watch of
// its folder and, in a trusted workspace, the watch of its Git metadata, which reads the status
// again.
func (a *App) attachRemote(p *project, session string) {
	r := p.remote
	a.stopRemoteWatch(p)
	r.session, r.link, r.attempt, r.misses, r.failure = session, remoteConnected, 0, 0, nil
	r.binding.Attach(session)
	a.beatRemote(p)
	r.watchWait = remoteWatchReady
	a.startRemoteWatch(p)
	a.resumeRemoteGit(p)
}

// beatRemote asks the server of the workspace's session what still runs, and schedules the next
// heartbeat. An answer shows the connection alive with its round trip; a closed connection is
// lost; remoteHeartbeatMisses unanswered heartbeats in a row end the session as lost.
func (a *App) beatRemote(p *project) {
	r := p.remote
	if r == nil || r.closed || r.beating || r.session == "" {
		return
	}
	r.beating = true
	session, kernel := r.session, a.kernel
	a.background(p, remoteHeartbeatTimeout, func(ctx context.Context) func(*App) {
		started := time.Now()
		err := kernel.RemoteServerState(ctx, session)
		latency := time.Since(started)
		return func(a *App) {
			r.beating = false
			if r.closed || r.session != session {
				// log-exempt: 用户取消：工作区已关闭，或会话已被新会话取代，旧心跳的结果不再适用。
				return
			}
			switch {
			case err == nil:
				r.link, r.latency, r.misses = remoteConnected, latency, 0
				a.scheduleRemote(p, remoteHeartbeatInterval, (*App).beatRemote)
			case remoteConnectionClosed(err):
				a.loseRemote(p, session, err)
			default:
				r.misses++
				if r.misses == 1 {
					a.backgroundFailed("remote_heartbeat", remoteLogError(err))
				}
				if r.misses >= remoteHeartbeatMisses {
					a.loseRemote(p, session, err)
					return
				}
				r.link = remoteUnresponsive
				a.scheduleRemote(p, remoteHeartbeatInterval, (*App).beatRemote)
			}
		}
	})
}

// loseRemote handles the loss of session: the binding is left without one, Core ends what is left
// of it, and connecting again starts.
func (a *App) loseRemote(p *project, session string, err error) {
	r := p.remote
	if r == nil || r.closed || session == "" || r.session != session {
		// log-exempt: 同一次失败已经记录过：这个会话的丢失已记录并处理过（remote_session_lost），或工作区已关闭。
		return
	}
	a.backgroundFailed("remote_session_lost", remoteLogError(err))
	a.stopRemoteWatch(p)
	a.closeGitObservation(p)
	// Core stops the session's forwards with it.
	r.ports.reset()
	r.session, r.misses = "", 0
	r.binding.Detach()
	r.stopRemoteTimer()
	a.releaseRemoteSession(session)
	a.startRemoteReconnection(p)
}

// startRemoteReconnection reads how long to connect again from the remote workspace preferences
// and waits for the first pause. With no pauses, a reconnect limit of 0, the workspace stays
// disconnected until the user reconnects; preferences that cannot be read leave it disconnected
// with the reason in the status bar's menu.
func (a *App) startRemoteReconnection(p *project) {
	r := p.remote
	r.attempt, r.delays, r.link, r.failure = 0, nil, remoteReconnecting, nil
	r.lost++
	lost, kernel, root, host := r.lost, a.kernel, a.globalToolchainRoot(), r.host
	a.background(p, remoteReadTimeout, func(ctx context.Context) func(*App) {
		delays, err := remoteReconnectDelays(ctx, kernel, root)
		return func(a *App) {
			if a.project != p || r.closed || r.lost != lost || r.session != "" || r.reconnecting != nil {
				// log-exempt: 用户取消：工作区已关闭，或用户已手动重连，这次读取不再适用。
				return
			}
			if err != nil {
				a.backgroundFailed("remote_reconnect_preferences", documentLogError(err))
				r.link, r.failure = remoteDisconnected, remoteConnectOutcome(host, core.RemoteConnectResult{}, err)
				return
			}
			r.delays = delays
			if len(delays) == 0 {
				r.link = remoteDisconnected
				// log-exempt: 用户设置：自动重连上限为 0，连接丢失已记录（remote_session_lost）。
				return
			}
			a.scheduleRemote(p, delays[0], func(a *App, p *project) { a.reconnectRemote(p, false) })
		}
	})
}

// reconnectRemote opens a new session over the workspace's connection. userStarted is Reconnect
// in the status bar: it starts the attempts afresh, asks OpenSSH's questions in the window and
// does not try again on its own. An automatic attempt cancels every question and, while the host
// is unreachable, tries again after each pause of the reconnection's delays.
func (a *App) reconnectRemote(p *project, userStarted bool) {
	r := p.remote
	if r == nil || r.closed || r.reconnecting != nil || r.session != "" {
		return
	}
	if userStarted {
		r.attempt, r.delays = 0, nil
		r.lost++
	}
	r.attempt++
	r.stopRemoteTimer()
	r.link, r.failure = remoteReconnecting, nil
	ctx, cancel := context.WithTimeout(a.operationContext(p.ctx), remoteProbeTimeout)
	if userStarted {
		ctx = a.gitAuthentication(ctx)
	}
	attempt := &remoteProbe{cancel: cancel}
	r.reconnecting = attempt
	kernel, root, host := a.kernel, a.globalToolchainRoot(), r.host
	a.background(nil, 0, func(context.Context) func(*App) {
		defer cancel()
		result, err := a.connectRemoteHost(ctx, kernel, root, host)
		return func(a *App) {
			if a.project != p || r.closed || r.reconnecting != attempt {
				if result.Session != nil {
					a.releaseRemoteSession(result.Session.ID)
				}
				// log-exempt: 用户取消：工作区已关闭或这次重连已被取代，新会话随即结束。
				return
			}
			r.reconnecting = nil
			if err == nil && result.Status == core.RemoteProbeConnected && result.Session != nil {
				a.attachRemote(p, result.Session.ID)
				a.refreshRemoteTree(p)
				a.recheckRemoteDocuments(p)
				return
			}
			if result.Session != nil {
				a.releaseRemoteSession(result.Session.ID)
			}
			r.failure = remoteConnectOutcome(host, result, err)
			if !userStarted && r.attempt < len(r.delays) && remoteRetryable(result.Status, err) {
				r.link = remoteReconnecting
				a.scheduleRemote(p, r.delays[r.attempt], func(a *App, p *project) { a.reconnectRemote(p, false) })
				// log-exempt: 同一次失败已经记录过：导致重连的连接丢失已记录（remote_session_lost），最后一次尝试的结果另记 remote_reconnect。
				return
			}
			if userStarted {
				a.operationFailed("remote_reconnect", remoteConnectFailure(result, err))
			} else {
				a.backgroundFailed("remote_reconnect", remoteConnectFailure(result, err))
			}
			r.link = remoteDisconnected
		}
	})
}

// remoteRetryable reports whether an automatic reconnection that ended with status or err may
// succeed when tried again: the host could not be reached, or the connection broke or timed out.
// A refused login, an unknown host key or a missing server build needs the user.
func remoteRetryable(status core.RemoteProbeStatus, err error) bool {
	if err != nil {
		return remoteConnectionClosed(err) || errors.Is(err, context.DeadlineExceeded)
	}
	return status == core.RemoteProbeUnreachable
}

// refreshRemoteTree reads the Project tool window's listings again over the new session: the root
// when it could not be listed, otherwise the folders shown open.
func (a *App) refreshRemoteTree(p *project) {
	if p.tree.failed != "" {
		a.retryProjectTree(p)
		return
	}
	a.resyncTreeListings(p)
}

// reconnectRemoteByUser is Reconnect in the status bar.
func (a *App) reconnectRemoteByUser(surface actionSurface) {
	p := a.project
	if p == nil || p.remote == nil || p.remote.session != "" || p.remote.reconnecting != nil {
		return
	}
	a.performed("remote.workspace.reconnect", surface)
	a.reconnectRemote(p, true)
}

// closeRemoteWorkspace ends the workspace's session while its project closes; nothing of the
// workspace runs afterwards.
func (a *App) closeRemoteWorkspace(p *project) {
	r := p.remote
	if r == nil || r.closed {
		return
	}
	r.closed = true
	r.stopRemoteTimer()
	r.ports.reset()
	a.stopRemoteWatch(p)
	if r.reconnecting != nil {
		r.reconnecting.cancel()
		r.reconnecting = nil
	}
	r.binding.Detach()
	a.releaseRemoteSession(r.session)
	r.session, r.menuOpen = "", false
}

// refuseRemote reports whether p is a remote workspace. When it is, a feature that runs only on
// this computer refuses: the refusal is logged with operation and a notification says the
// feature does not work in a remote workspace yet.
func (a *App) refuseRemote(p *project, operation string) bool {
	if p == nil || p.remote == nil {
		return false
	}
	a.operationRejected(operation, "remote_workspace")
	a.notifyInfo(i18n.Shared(a.language(), "desktop.remote.workspace.localOnly"))
	return true
}

// openRemoteProject opens target as this workbench's project, which must have none: the window
// opens the folder in a new tab otherwise (windowSessions.openRemoteTab). The workspace takes
// target's session; when it cannot open, the session is ended.
func (a *App) openRemoteProject(target remoteTarget) {
	if a.project != nil || a.closingProject {
		a.releaseRemoteSession(target.session.ID)
		return
	}
	name := path.Base(target.remoteRoot)
	p := &project{root: target.root, name: name, commit: newCommitState()}
	r := &remoteProject{connectionID: target.connectionID, name: target.name, host: target.host, home: target.session.HomeDirectory}
	p.remote = r
	r.binding = core.NewRemoteWorkspace(target.root, target.remoteRoot, a.remoteSessionLost(p))
	// Trusted, the workspace's Git runs on the host, and its commands are kept in the Git console
	// as a local project's are; in safe mode Core runs none (remote_trust.go).
	p.trust.codeAllowed.Store(target.trusted)
	ctx := core.WithProjectCodeAllowed(core.WithGitConsole(context.Background(), a.gitConsole, target.root), p.trust.allowed)
	p.ctx, p.cancel = context.WithCancel(core.WithRemoteWorkspace(ctx, r.binding))
	a.searchView.reset()
	// Its first terminal runs on the host once it is shown, over the session attached below.
	a.openTerminals(p)
	a.project = p
	// The tool windows of a remote workspace, such as Ports, are shown while it is open.
	a.chrome.setRemote(true)
	a.notice = ""
	a.logView.reset()
	a.worktreeView.reset()
	// Attaching the session starts the watch of the Git metadata (remote_git.go).
	a.attachRemote(p, target.session.ID)
	a.loadGit(p)
	a.loadLog(p)
	// Unsaved edits of the folder's files are drafts on this computer; they open over the host's
	// files as a local project's do.
	a.restoreCheckpoints(p)
}

// remoteSessionLost is how a request of p reports, on its own goroutine, that it found the
// connection of session closed: the window thread then handles the loss.
func (a *App) remoteSessionLost(p *project) func(session string) {
	return func(session string) {
		a.post(func(a *App) {
			if a.project == p {
				a.loseRemote(p, session, errRemoteSessionClosed)
			}
		})
	}
}

// recheckRemoteDocuments compares every document of p with its host file once a new session
// opened: a change made on the host meanwhile is then found as any external change is, and a
// close that waited on a check that found the host away goes on.
func (a *App) recheckRemoteDocuments(p *project) {
	for _, d := range p.docs.list {
		if !d.virtual {
			d.checkPending = true
		}
	}
	a.scheduleDocumentChecks(p)
}
