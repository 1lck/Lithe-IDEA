package workbench

import (
	"cmp"
	"context"
	"errors"
	"path"
	"slices"
	"strconv"
	"strings"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteconn"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteplaceholder"
	"github.com/1lck/Lithe-IDEA/desktop/internal/remoteserver"
	"github.com/vivaui/viva/ui"
)

// Connect in the Remote Development window opens a session to the selected saved connection's
// host, sending it the server build the client carries for the host's platform, then lists the
// host's folders so the user picks the one to open (#2231, R0). The session is the window's while
// the folder is chosen: Back, closing the window and quitting end it. Opening the folder hands it
// to the workspace (remote_workspace.go) and remembers the folder with the connection.
//
// Only a saved connection, a WSL distribution of this computer (remote_wsl.go), a running
// container of this computer (remote_container.go) or one running on the host a folder is chosen
// on (remote_host_containers.go) connects, as shown: the workspace connects again with the same,
// and the folder it remembers belongs to the saved entry. OpenSSH's questions are asked in the
// authentication dialog, as a test asks them.

// remoteBrowser chooses the host folder to open over a session the window connected.
type remoteBrowser struct {
	session core.RemoteSession
	// entryID and name are the saved connection's, or the WSL distribution's or the container's
	// identity and name.
	entryID string
	name    string
	host    remoteHost
	// recent are the connection's recent folders, latest first.
	recent []string
	// path is what the path field holds. dir is the folder listed last, or tried last when it
	// could not be listed; folders are its subfolders' names, links to folders among them, and
	// files the names of its other entries, shown greyed.
	path    ui.Field
	dir     string
	folders []string
	files   []string
	// skipped counts the entries whose names the host could not send.
	skipped uint32
	// repositories are the folders among folders holding a .git entry, found after the listing
	// shows; the list tags them Git.
	repositories map[string]bool
	list         ui.ListState
	loading      bool
	// listing counts the listings, so that only the latest applies.
	listing uint64
	// readErr is why dir could not be listed; err why the folder could not be opened.
	readErr string
	opening bool
	err     string
	// containers are the host's running containers, listed in place of its folders while set
	// (remote_host_containers.go).
	containers *remoteBrowserContainers
}

// stopConnect cancels a running connection; a session it opens anyway is ended when it returns.
func (r *remoteState) stopConnect() {
	if r.connect != nil {
		r.connect.cancel()
		r.connect = nil
	}
}

// connectable says whether Connect may start for what the page shows: a WSL distribution, a
// container, or a saved connection the form shows as saved; and nothing else runs.
func (r *remoteState) connectable() bool {
	return r.idle() && (r.wsl.selected != "" || r.containers.selected != nil || (r.entry(r.selected) != nil && !r.dirty()))
}

// idle says whether a connection may start: the window is open, and neither a folder is chosen,
// nor a connection, a test or a save runs.
func (r *remoteState) idle() bool {
	return r.open && r.browser == nil && r.connect == nil && r.probe == nil && !r.saving
}

// connectTarget is what Connect connects to: the WSL distribution or the container shown, as an
// entry named after it with its identity for id, or the selected saved connection.
func (r *remoteState) connectTarget() (core.SavedRemoteConnection, remoteHost) {
	if r.wsl.selected != "" {
		wsl := r.wsl.connection()
		return core.SavedRemoteConnection{ID: wsl.Identity(), Name: wsl.Distribution}, remoteHost{wsl: &wsl}
	}
	if r.containers.selected != nil {
		container := r.containers.connection()
		host := remoteHost{container: &container}
		identity := container.Identity()
		if target := r.containers.selected.runtime; target != nil && target.WSL != "" {
			host.wsl = &core.WSLConnection{Distribution: target.WSL}
			identity = host.wsl.Identity() + "/" + identity
		}
		return core.SavedRemoteConnection{ID: identity, Name: container.Container}, host
	}
	entry := *r.entry(r.selected)
	return entry, remoteHost{ssh: entry.Connection}
}

// connectRemote connects to the host the page shows, showing each step and the questions OpenSSH
// asks on the page, then opens folder on it, or lists the host's folders to choose one when folder
// is "".
func (a *App) connectRemote(folder string) {
	if !a.remote.connectable() {
		return
	}
	entry, host := a.remote.connectTarget()
	a.connectRemoteTo(entry, host, folder)
}

// connectRemoteTo connects to host, named as entry, as connectRemote does: the connection the
// steps try again, and a container on the host a folder is chosen on (remote_host_containers.go).
func (a *App) connectRemoteTo(entry core.SavedRemoteConnection, host remoteHost, folder string) {
	r := &a.remote
	if !r.idle() {
		return
	}
	r.result, r.err, r.fieldErr, r.confirmDelete, r.moreMenu = nil, "", remoteFieldRefusal{}, false, false
	a.performed("remote.connect", surfaceButton)
	ctx, cancel := context.WithTimeout(a.operationContext(context.Background()), remoteProbeTimeout)
	attempt := &remoteProbe{cancel: cancel}
	r.connect = attempt
	steps := newRemoteSteps(entry, host, folder, a.now())
	r.steps = steps
	ctx = core.WithRemoteStages(ctx, func(stage core.RemoteStage) {
		a.post(func(a *App) {
			if a.remote.steps == steps {
				steps.observe(a.now(), stage)
			}
		})
	})
	generation, kernel, root, secrets := r.generation, a.kernel, a.globalToolchainRoot(), a.remoteSecrets()
	answers := a.remoteAnswersFor(entry.ID, host)
	a.background(nil, 0, func(context.Context) func(*App) {
		defer cancel()
		// Core checks the actual target before sending a token. A changed target leaves the
		// original record available for its original host.
		resume, keptErr := remoteconn.NewestKept(ctx, secrets, entry.ID)
		result, err := a.connectRemoteHost(a.remoteAuthentication(ctx, answers, true), kernel, root, host, resume)
		settled := answers.settle(result.Status, err)
		if resume != nil && result.Session != nil && result.Session.ResumeConsumed {
			if forgetErr := remoteconn.ForgetKept(ctx, secrets, entry.ID, resume.Key); keptErr == nil {
				keptErr = forgetErr
			}
		}
		return func(a *App) {
			if keptErr != nil {
				a.backgroundFailed("remote_kept_sessions", keptErr)
			}
			a.remoteAnswersSettled(settled, true)
			r := &a.remote
			if !r.open || r.generation != generation || r.connect != attempt {
				if result.Session != nil {
					a.returnRemoteSession(entry.ID, *result.Session)
				}
				// log-exempt: 用户取消：连接已停止、换了连接或窗口已关闭，已打开的会话随即交还。
				return
			}
			r.connect = nil
			if err == nil && result.Status == core.RemoteProbeConnected && result.Session != nil {
				r.steps = nil
				a.browseRemote(entry, host, *result.Session)
				if folder != "" {
					a.openRemoteFolderAt(folder)
				}
				return
			}
			if result.Session != nil {
				a.returnRemoteSession(entry.ID, *result.Session)
			}
			if field, reason, ok := core.RemoteConnectionFieldError(err); ok {
				a.operationRejected("remote_connect", "field_refused")
				r.steps = nil
				refusal := remoteFieldRefusal{field: field, reason: reason}
				switch {
				case host.container != nil:
					r.err = remoteContainerRefusalText(a.language(), refusal)
				case host.wsl != nil:
					r.err = remoteWSLRefusalText(a.language(), refusal)
				default:
					r.err = remoteRefusalText(a.language(), refusal)
				}
				return
			}
			a.operationFailed("remote_connect", remoteConnectFailure(result, err))
			steps.fail(a.now(), remoteConnectOutcome(host, result, err), a.language())
			r.log.Open = true
		}
	})
}

// stopRemoteConnect stops the running connection.
func (a *App) stopRemoteConnect() {
	r := &a.remote
	if r.connect == nil {
		return
	}
	a.performed("remote.connect.stop", surfaceButton)
	r.stopConnect()
	r.steps = nil
}

// remoteConnectFailureText is the window's text for a connection that could not start for a
// reason of this computer: the client carries no server build, or the one installed in the cache
// changed. "" for any other error, which the test's texts cover.
func remoteConnectFailureText(language i18n.Language, err error) string {
	var coreErr *core.Error
	switch {
	case errors.Is(err, remoteserver.ErrNotBundled):
		return i18n.Shared(language, "desktop.remote.connect.notBundled")
	case errors.Is(err, remoteconn.ErrDamaged):
		return i18n.Shared(language, "desktop.remote.preferences.damaged")
	case errors.Is(err, remoteserver.ErrMismatch),
		errors.As(err, &coreErr) && coreErr.Code == core.CodeRemoteServerInvalid:
		return i18n.Shared(language, "desktop.remote.connect.serverInvalid")
	}
	return ""
}

// browseRemote starts choosing the folder to open over session to host, in the account's home
// directory.
func (a *App) browseRemote(entry core.SavedRemoteConnection, host remoteHost, session core.RemoteSession) {
	r := &a.remote
	r.browser = &remoteBrowser{session: session, entryID: entry.ID, name: entry.Name, host: host, recent: entry.RecentFolders}
	start := session.HomeDirectory
	if !path.IsAbs(start) {
		start = "/"
	}
	a.listRemoteFolder(path.Clean(start))
}

// leaveRemoteBrowser stops choosing a folder and gives its session back (returnRemoteSession).
func (a *App) leaveRemoteBrowser() {
	r := &a.remote
	if b := r.browser; b != nil {
		r.browser = nil
		a.returnRemoteSession(b.entryID, b.session)
	}
}

// leaveRemoteFlows ends the folder, trust, import or dev container page the window shows, so the
// list beside it can show another connection. It reports false, leaving them, while one of them is
// opening a folder, saving an import, or saving a folder's trust or building its dev container,
// which Cancel stops.
func (a *App) leaveRemoteFlows() bool {
	r := &a.remote
	if (r.trust != nil && r.trust.deciding) || (r.browser != nil && r.browser.opening) || (r.importer != nil && r.importer.applying) ||
		(r.devcontainer != nil && r.devcontainer.busy()) {
		return false
	}
	r.trust = nil
	r.importer = nil
	r.devcontainer = nil
	a.leaveRemoteBrowser()
	return true
}

// backFromRemoteBrowser is Back: the session ends and the form shows again.
func (a *App) backFromRemoteBrowser() {
	if a.remote.browser == nil {
		return
	}
	a.performed("remote.browse.back", surfaceButton)
	a.leaveRemoteBrowser()
}

// listRemoteFolder lists the host folder dir, an absolute clean POSIX path, in the browser.
func (a *App) listRemoteFolder(dir string) {
	r := &a.remote
	b := r.browser
	if b == nil || b.opening {
		return
	}
	b.listing++
	b.loading, b.readErr, b.err, b.dir = true, "", "", dir
	b.path.SetText(dir)
	listing, generation, kernel, session := b.listing, r.generation, a.kernel, b.session.ID
	a.background(nil, remoteReadDirTimeout, func(ctx context.Context) func(*App) {
		directory, err := kernel.RemoteReadDir(ctx, session, dir)
		return func(a *App) {
			r := &a.remote
			if !r.open || r.generation != generation || r.browser != b || b.listing != listing {
				// log-exempt: 用户取消：已换了文件夹、返回或关闭窗口，不再应用列出结果。
				return
			}
			b.loading, b.folders, b.files, b.skipped, b.repositories, b.list = false, nil, nil, 0, nil, ui.ListState{}
			if err != nil {
				a.operationFailed("remote_read_dir", remoteLogError(err))
				if remoteConnectionClosed(err) {
					// The session is gone: choosing over it cannot go on.
					a.leaveRemoteBrowser()
					r.err = i18n.Shared(a.language(), "desktop.remote.browse.lost")
					return
				}
				b.readErr = remoteReadDirFailureText(a.language(), err)
				return
			}
			b.folders, b.files, b.skipped = remoteEntryNames(directory, true), remoteEntryNames(directory, false), directory.SkippedNonUTF8
			a.markRemoteRepositories(b)
		}
	})
}

// remoteRepositoryChecks bounds how many of a folder's subfolders are looked into for .git, and
// remoteRepositoryParallel how many of those looks run at once over the session.
const (
	remoteRepositoryChecks   = 64
	remoteRepositoryParallel = 8
)

// markRemoteRepositories looks for a .git entry, a folder or a worktree's file, in the first
// subfolders of the folder b lists, so the list can tag Git repositories once the names show.
// A subfolder whose .git cannot be read stays untagged: the tag is a hint, and the listing
// already reports a lost session.
func (a *App) markRemoteRepositories(b *remoteBrowser) {
	names := slices.Clone(b.folders[:min(len(b.folders), remoteRepositoryChecks)])
	if len(names) == 0 {
		return
	}
	listing, generation, kernel, session, dir := b.listing, a.remote.generation, a.kernel, b.session.ID, b.dir
	a.background(nil, remoteReadDirTimeout, func(ctx context.Context) func(*App) {
		found := make([]bool, len(names))
		var wait sync.WaitGroup
		slots := make(chan struct{}, remoteRepositoryParallel)
		for i, name := range names {
			wait.Add(1)
			slots <- struct{}{}
			go func() {
				defer func() { <-slots; wait.Done() }()
				_, err := kernel.RemoteStat(ctx, session, path.Join(dir, name, ".git"))
				found[i] = err == nil
			}()
		}
		wait.Wait()
		return func(a *App) {
			r := &a.remote
			if !r.open || r.generation != generation || r.browser != b || b.listing != listing {
				// log-exempt: 用户取消：已换了文件夹、返回或关闭窗口，不再标记 Git 仓库。
				return
			}
			b.repositories = map[string]bool{}
			for i, name := range names {
				if found[i] {
					b.repositories[name] = true
				}
			}
		}
	})
}

// remoteEntryNames are the names of directory's folders and links to folders when folders is
// set, or of its other entries, hidden ones last.
func remoteEntryNames(directory core.RemoteDirectory, folders bool) []string {
	var names []string
	for _, entry := range directory.Entries {
		if entry.Metadata.IsDirectory() == folders {
			names = append(names, entry.Name)
		}
	}
	slices.SortStableFunc(names, func(x, y string) int {
		hiddenX, hiddenY := strings.HasPrefix(x, "."), strings.HasPrefix(y, ".")
		if hiddenX != hiddenY {
			if hiddenX {
				return 1
			}
			return -1
		}
		return cmp.Compare(strings.ToLower(x), strings.ToLower(y))
	})
	return names
}

// remoteReadDirFailureText says why a host folder could not be listed.
func remoteReadDirFailureText(language i18n.Language, err error) string {
	var coreErr *core.Error
	if errors.As(err, &coreErr) {
		switch coreErr.Code {
		case core.CodeWorkspaceNotFound:
			return i18n.Shared(language, "desktop.remote.browse.notFound")
		case core.CodePermissionDenied:
			return i18n.Shared(language, "desktop.remote.browse.denied")
		case core.CodeInvalidRequest:
			return i18n.Shared(language, "desktop.remote.browse.pathInvalid")
		}
	}
	return i18n.SharedFormat(language, "desktop.remote.browse.readFailed", map[string]string{"reason": remoteLogError(err).Error()})
}

// remoteFolderPath is text, typed in the path field, as the absolute clean host path to list: a
// leading ~ is the account's home directory. ok is false for a relative path, and for ~ when the
// host did not report the home directory.
func remoteFolderPath(text, home string) (dir string, ok bool) {
	text = strings.TrimSpace(text)
	if text == "~" || strings.HasPrefix(text, "~/") {
		if !path.IsAbs(home) {
			return "", false
		}
		text = home + text[1:]
	}
	if !path.IsAbs(text) || strings.ContainsRune(text, 0) {
		return "", false
	}
	return path.Clean(text), true
}

// goRemoteFolder lists the folder typed in the path field.
func (a *App) goRemoteFolder() {
	b := a.remote.browser
	if b == nil || b.opening {
		return
	}
	dir, ok := remoteFolderPath(b.path.Text(), b.session.HomeDirectory)
	if !ok {
		a.operationRejected("remote_read_dir", "path_not_absolute")
		b.readErr = i18n.Shared(a.language(), "desktop.remote.browse.pathInvalid")
		return
	}
	a.performed("remote.browse.go", surfaceButton)
	a.listRemoteFolder(dir)
}

// upRemoteFolder lists the parent of the folder shown.
func (a *App) upRemoteFolder() {
	b := a.remote.browser
	if b == nil || b.dir == "" || b.dir == "/" {
		return
	}
	a.performed("remote.browse.up", surfaceButton)
	a.listRemoteFolder(path.Dir(b.dir))
}

// target is the folder Open opens: the selected subfolder, or the folder shown.
func (b *remoteBrowser) target() string {
	if at := b.list.Selected(); at >= 0 && at < len(b.folders) {
		return path.Join(b.dir, b.folders[at])
	}
	return b.dir
}

// openable says whether Open may open the target now.
func (b *remoteBrowser) openable() bool {
	return !b.loading && !b.opening && b.readErr == "" && b.dir != ""
}

// openRemoteFolder opens the target as a remote workspace: it makes sure the placeholders' anchor
// is usable, remembers the folder with the connection, and hands the session to the workspace.
// A folder already open over the same connection is shown instead.
func (a *App) openRemoteFolder() {
	b := a.remote.browser
	if !a.remote.open || b == nil || !b.openable() {
		return
	}
	a.performed("remote.workspace.open", surfaceButton)
	a.openRemoteFolderAt(b.target())
}

// openRemoteFolderNow opens dir once its trust is decided (remote_trust.go), trusted when trusted
// is set and in safe mode otherwise. It also marks a saved connection as connected now, for the
// list's "2 hours ago"; a WSL distribution is not saved, so nothing is remembered for it.
func (a *App) openRemoteFolderNow(dir string, trusted bool) {
	r := &a.remote
	b := r.browser
	if !r.open || b == nil {
		return
	}
	b.opening, b.err = true, ""
	entryID, remember := b.entryID, b.host.saved()
	generation, kernel, toolRoot := r.generation, a.kernel, a.globalToolchainRoot()
	a.background(nil, remoteReadTimeout, func(ctx context.Context) func(*App) {
		anchor, err := a.remotePlaceholderAnchor()
		if err == nil {
			err = remoteplaceholder.Ensure(anchor)
		}
		var rememberErr error
		if err == nil && remember {
			// The folder is remembered even when the workspace then fails to open, as the editor
			// remembers a project it opened.
			var source remoteconn.Source
			source, rememberErr = remoteconn.Read(ctx, kernel, toolRoot)
			if rememberErr == nil {
				source, _, _, rememberErr = source.Edit(ctx, kernel, core.RemoteConnectionEdit{RememberFolder: &core.RemoteConnectionFolder{ID: entryID, Path: dir}})
			}
			if rememberErr == nil {
				// One edit after the other: each is made over the document the last one wrote.
				_, _, _, rememberErr = source.Edit(ctx, kernel, core.RemoteConnectionEdit{MarkConnected: &core.RemoteConnectionID{ID: entryID}})
			}
		}
		return func(a *App) {
			if rememberErr != nil {
				// Opening does not depend on it: the folder is only missing from the recent list.
				a.backgroundFailed("remote_remember_folder", documentLogError(rememberErr))
			}
			r := &a.remote
			if !r.open || r.generation != generation || r.browser != b {
				// log-exempt: 用户取消：窗口已关闭或已返回，会话已随之结束。
				return
			}
			b.opening = false
			if err != nil {
				a.operationFailed("remote_workspace_open", documentLogError(err))
				if errors.Is(err, remoteplaceholder.ErrAnchorUnusable) {
					b.err = i18n.SharedFormat(a.language(), "desktop.remote.browse.anchorUnusable", map[string]string{"path": anchor})
				} else {
					b.err = i18n.SharedFormat(a.language(), "desktop.remote.browse.openFailed", map[string]string{"reason": documentLogError(err).Error()})
				}
				return
			}
			target := remoteTarget{
				connectionID: b.entryID, name: b.name, host: b.host, session: b.session,
				remoteRoot: dir, root: remoteplaceholder.Root(anchor, b.entryID, dir), trusted: trusted,
			}
			// The session is the workspace's from here on.
			r.browser = nil
			a.closeRemote()
			a.openRemoteWorkspace(target)
		}
	})
}

// openRemoteWorkspace shows target: the tab that has the folder open over the same connection,
// which takes the session when it has lost its own and the trust the user just decided for the
// folder; this workbench when it has no project; a new tab otherwise.
func (a *App) openRemoteWorkspace(target remoteTarget) {
	if open := a.sessions.showing(target.root); open != nil {
		a.sessions.activate(open)
		p := open.project
		if r := p.remote; r != nil && !r.closed && r.session == "" && r.reconnecting == nil {
			r.stopRemoteTimer()
			p.trust.codeAllowed.Store(target.trusted)
			open.attachRemote(p, target.session)
			open.refreshRemoteTree(p)
			open.offerKeptPrograms(p, target.session)
		} else {
			a.returnRemoteSession(target.connectionID, target.session)
		}
		open.applyProjectTrust(p, target.trusted)
		return
	}
	if a.project == nil || a.sessions == nil {
		a.openRemoteProject(target)
		return
	}
	a.sessions.openRemoteTab(a, target)
}

// remoteSkippedText says how many entries of the folder shown have names the host could not send,
// "" when none.
func remoteSkippedText(language i18n.Language, skipped uint32) string {
	if skipped == 0 {
		return ""
	}
	return i18n.SharedFormat(language, "desktop.remote.browse.skipped", map[string]string{"count": strconv.FormatUint(uint64(skipped), 10)})
}
