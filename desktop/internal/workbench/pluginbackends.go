package workbench

import (
	"context"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprovider"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginruntime"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// pluginServerPreparation owns one start, including an optional runtime repair.
// Progress is written by the worker and read by the status bar; identity and
// cancellation remain protected by pluginServerMu.
type pluginServerPreparation struct {
	project              *project
	cancel               context.CancelFunc
	progress             atomic.Pointer[pluginruntime.Progress]
	cancelled            atomic.Bool
	pluginID             string
	revision             uint64
	retryWithoutProvider bool
}

func (p *pluginServerPreparation) stop() {
	p.cancelled.Store(true)
	p.cancel()
}

const (
	// pluginServerStartTimeout bounds resolving and launching one language server.
	pluginServerStartTimeout = 2 * time.Minute
	// pluginServerStopTimeout bounds a shutdown. Core keeps the session until it is
	// disposed, so this covers both the graceful stop and the disposal.
	pluginServerStopTimeout = 30 * time.Second
)

// failedPluginServer records a language server that failed to start or exited
// abnormally in the open project so the status bar and menu can surface the
// error and offer a retry without treating it as a live session.
type failedPluginServer struct {
	pluginID   string
	languageID string
	version    string
	project    *project
	message    string
	logs       []lspLogLine
	logsAdded  uint64
	// untrusted is set when Core planned no server because the project is in safe mode and the
	// server may run the project's code (#2208). It is no failure: the status bar says safe
	// mode, and trusting the project starts the server (applyProjectTrust).
	untrusted bool
}

func (f *failedPluginServer) displayID() string {
	if f == nil {
		return ""
	}
	if f.pluginID != "" {
		return f.pluginID
	}
	return f.languageID
}

// pluginServer is one running language server the window started.
type pluginServer struct {
	// Serialize native preference reread plus Core publication for this session.
	// A newer revision supersedes queued work without starting another process.
	settingsGate     chan struct{}
	settingsRevision atomic.Uint64
	session          *pluginservice.LanguageSession
	// project is the project the server was started for. An event that arrives
	// after the window moved to another project is stale and is dropped.
	project *project
	// cancel ends the serve loop; the session itself is disposed by the stop call.
	cancel context.CancelFunc
	// done closes when the serve loop returns.
	done chan struct{}
	// completionTriggers are the characters the server declared to open completion, from
	// Core's featuresChanged event. Only the window thread reads or writes them; nil
	// means the server declared none.
	completionTriggers      []string
	signatureHelpTriggers   []string
	signatureHelpRetriggers []string
	workspaceEdits          map[string]context.CancelFunc
	codeActionCommand       *deferredCodeActionCommand
	// features are the features the server offers, from Core's featuresChanged event
	// (documentSymbols, semanticTokens and so on). Only the window thread reads or writes it.
	features map[string]bool
	// state is the last state Core reported (starting, ready, failed, stopped), logs the
	// newest log lines of the session and logsAdded how many lines it has added in all, which
	// clearing the lines shown does not reset; only the window thread reads or writes them.
	state     string
	logs      []lspLogLine
	logsAdded uint64
	// sharedState is state again for other windows: the settings window's plugin page asks
	// whether the plugin is running from its own thread, so it reads this copy, which the
	// window thread writes whenever it writes state.
	sharedState atomic.Pointer[string]
	// buildMu guards both the attached clients and readiness. A ready event and
	// an attach race through the same lock, so a client either receives the
	// event or is marked ready from the recorded state, never both and never
	// neither.
	buildMu      sync.Mutex
	buildReady   bool
	buildEnded   bool
	buildClients map[*buildprovider.Client]struct{}
}

func (s *pluginServer) attachBuild(runner *pluginbackend.Runner, session pluginbackend.Session) *buildprovider.Client {
	s.buildMu.Lock()
	defer s.buildMu.Unlock()
	client := buildprovider.Attach(runner, session, s.buildReady && !s.buildEnded)
	if s.buildEnded {
		_ = client.Close(context.Background())
		return client
	}
	if s.buildClients == nil {
		s.buildClients = make(map[*buildprovider.Client]struct{})
	}
	s.buildClients[client] = struct{}{}
	return client
}

func (s *pluginServer) detachBuild(client *buildprovider.Client) {
	s.buildMu.Lock()
	delete(s.buildClients, client)
	s.buildMu.Unlock()
}

func (s *pluginServer) forwardBuild(event core.BackendEvent) {
	s.buildMu.Lock()
	if event.Type == "stateChanged" && event.State == "ready" {
		s.buildReady = true
	}
	if event.Type == "exit" {
		s.buildEnded = true
	}
	clients := make([]*buildprovider.Client, 0, len(s.buildClients))
	for client := range s.buildClients {
		if client.Closed() {
			delete(s.buildClients, client)
			continue
		}
		clients = append(clients, client)
	}
	s.buildMu.Unlock()
	for _, client := range clients {
		client.Observe(event)
	}
}

// isReady reports whether Core announced the session's language server ready.
func (s *pluginServer) isReady() bool {
	if s == nil {
		return false
	}
	s.buildMu.Lock()
	defer s.buildMu.Unlock()
	return s.buildReady && !s.buildEnded
}

func (s *pluginServer) endBuild() {
	s.buildMu.Lock()
	s.buildEnded = true
	clients := make([]*buildprovider.Client, 0, len(s.buildClients))
	for client := range s.buildClients {
		clients = append(clients, client)
	}
	s.buildClients = nil
	s.buildMu.Unlock()
	for _, client := range clients {
		_ = client.Close(context.Background())
	}
}

// startPluginServer starts the language server for languageID when an enabled
// plugin provides one.
//
// A language nothing serves is the ordinary case for most files, so a missing
// provider is not an error and nothing is logged for it.
func (a *App) startPluginServer(languageID string) {
	a.requestPluginServer(languageID, false)
}

func (a *App) languageServerStarting(languageID string) bool {
	a.pluginServerMu.Lock()
	defer a.pluginServerMu.Unlock()
	return a.pluginServerStarting[languageID]
}

func (a *App) requestPluginServer(languageID string, providersChanged bool) {
	if a.plugins == nil || languageID == "" {
		return
	}
	if a.project != nil && a.project.remote != nil {
		// log-exempt: 远程工作区的语言服务器要在主机上运行，现在还不支持；在本机启动只会读到空的占位文件夹，
		// 信任远程文件夹后也不在本机运行任何项目代码。
		return
	}
	a.pluginServerMu.Lock()
	if a.pluginServers == nil {
		a.pluginServers = make(map[string]*pluginServer)
		a.pluginServerLanguages = make(map[string]string)
		a.pluginServerStarting = make(map[string]bool)
	}
	if provider, ok := a.pluginServerLanguages[languageID]; ok && a.pluginServers[provider] != nil {
		a.pluginServerMu.Unlock()
		return
	}
	if a.pluginServerStarting[languageID] {
		// Opening several files of one language at once must not launch several
		// servers. A registry change can arrive after this start read the
		// old registry, so repeat selection if it returns without a provider.
		if preparation := a.pluginServerPreparations[languageID]; providersChanged && preparation != nil {
			preparation.retryWithoutProvider = true
		}
		a.pluginServerMu.Unlock()
		return
	}
	a.pluginServerStarting[languageID] = true
	if a.pluginServerPreparations == nil {
		a.pluginServerPreparations = make(map[string]*pluginServerPreparation)
	}
	p := a.project
	parent := context.Background()
	if p != nil && p.ctx != nil {
		parent = p.ctx
	}
	ctx, cancel := context.WithCancel(a.operationContext(parent))
	preparation := &pluginServerPreparation{project: p, cancel: cancel, revision: a.pluginServerRevision}
	a.pluginServerPreparations[languageID] = preparation
	a.pluginServerMu.Unlock()
	request := a.pluginBackendRequest()
	request.RuntimeProgress = func(progress pluginruntime.Progress) {
		preparation.progress.Store(&progress)
		a.invalidator.Invalidate()
	}
	// This task must return even after a project change to dispose a late session.
	// The preparation's context is nevertheless canceled with its project/window.
	a.background(nil, 0, func(context.Context) func(*App) {
		defer cancel()
		if request.WorkingDirectory != "" {
			uri, uriErr := a.kernel.PluginDocumentURI(ctx, request.WorkingDirectory, "auto")
			if uriErr != nil {
				return func(a *App) { a.finishPluginServerPreparation(preparation, languageID, "", "", nil, uriErr) }
			}
			request.RootURI = uri
		}
		entries, err := a.plugins.Manager.Installed()
		if err != nil {
			return func(a *App) { a.finishPluginServerPreparation(preparation, languageID, "", "", nil, err) }
		}
		var failedPluginID, failedVersion string
		if entry, ok, _ := a.plugins.LanguageServerProvider(ctx, entries, languageID); ok {
			failedPluginID, failedVersion = entry.Installed.ID, entry.Installed.Version
			a.pluginServerMu.Lock()
			preparation.pluginID = failedPluginID
			if a.pluginServerSuppressed[failedPluginID] || a.pluginServerChanges[failedPluginID] > preparation.revision {
				cancel()
			}
			a.pluginServerMu.Unlock()
		}
		session, err := a.plugins.StartLanguageServer(ctx, entries, languageID, request)
		return func(a *App) {
			a.finishPluginServerPreparation(preparation, languageID, failedPluginID, failedVersion, session, err)
		}
	})
}

func (a *App) finishPluginServerPreparation(preparation *pluginServerPreparation, languageID, pluginID, version string, session *pluginservice.LanguageSession, err error) {
	a.pluginServerMu.Lock()
	current := a.pluginServerPreparations[languageID] == preparation
	owner := pluginID
	if session != nil {
		owner = session.PluginID
	}
	changed := a.pluginServerChanges[owner] > preparation.revision
	retryWithoutProvider := preparation.retryWithoutProvider
	if current {
		delete(a.pluginServerPreparations, languageID)
	}
	a.pluginServerMu.Unlock()
	if !current || changed {
		// A result from the previous project cannot clear a newer start's marker.
		a.stopPluginSession(session)
		if current {
			a.pluginServerMu.Lock()
			delete(a.pluginServerStarting, languageID)
			a.pluginServerMu.Unlock()
			a.resumeStartingCompletion(preparation.project, languageID)
		}
		return
	}
	if preparation.cancelled.Load() && err == nil {
		// Cancel may be clicked after the worker finishes but before its queued
		// result reaches this window. It must still dispose that late session.
		a.stopPluginSession(session)
		session, err = nil, context.Canceled
	}
	a.finishPluginServerStart(preparation.project, languageID, pluginID, version, session, err)
	if retryWithoutProvider && session == nil && err == nil && a.project == preparation.project {
		a.startPluginServer(languageID)
	}
	if session == nil {
		a.resumeStartingCompletion(preparation.project, languageID)
	}
}

// finishPluginServerStart takes the started session back on the window thread and
// runs its serve loop.
func (a *App) finishPluginServerStart(p *project, languageID, failedPluginID, failedVersion string, session *pluginservice.LanguageSession, err error) {
	a.pluginServerMu.Lock()
	delete(a.pluginServerStarting, languageID)
	suppressed := failedPluginID != "" && a.pluginServerSuppressed[failedPluginID]
	a.pluginServerMu.Unlock()
	if err != nil {
		if a.project != p || suppressed {
			return
		}
		if errors.Is(err, context.Canceled) {
			a.recordPluginServerFailure(p, languageID, failedPluginID, failedVersion, errors.New(i18n.Shared(a.language(), "desktop.lsp.preparationCancelled")), nil, 0)
			return
		}
		if core.IsLaunchUntrustedWorkspace(err) {
			if p.trust.allowed() {
				// The project was trusted while Core planned this start: plan it again.
				a.startPluginServer(languageID)
				return
			}
			a.backgroundFailed("plugin_server_safe_mode", err)
			a.recordPluginServerSafeMode(p, languageID, failedPluginID, failedVersion)
			return
		}
		a.operationFailed("plugin_server_start", err)
		a.recordPluginServerFailure(p, languageID, failedPluginID, failedVersion, err, nil, 0)
		a.notifyPluginServerFailure(p, languageID, err)
		return
	}
	if session == nil {
		a.pluginServerMu.Lock()
		delete(a.pluginServerFailed, languageID)
		delete(a.pluginServerNotifiedErrors, languageID)
		a.pluginServerMu.Unlock()
		return
	}
	if session.Warnings != nil {
		a.backgroundFailed("plugin_server_selection", session.Warnings)
	}
	if a.plugins == nil {
		a.stopPluginSession(session)
		return
	}
	// A server started for a project the window has since replaced must not be
	// registered: it would outlive the workspace it was planned for.
	if a.project != p {
		a.stopPluginSession(session)
		return
	}
	a.pluginServerMu.Lock()
	if a.pluginServerSuppressed[session.PluginID] {
		a.pluginServerMu.Unlock()
		// The user disabled or removed the plugin while this start was resolving.
		// Do not register a server the plugin no longer owns.
		a.stopPluginSession(session)
		return
	}
	if existing := a.pluginServers[session.PluginID]; existing != nil {
		a.pluginServerMu.Unlock()
		// Another start won the race; the extra session is disposed rather than
		// left running beside the one the window uses.
		a.stopPluginSession(session)
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	server := &pluginServer{session: session, project: a.project, cancel: cancel, done: make(chan struct{})}
	a.pluginServers[session.PluginID] = server
	a.pluginSettingsRestart.Delete(session.PluginID)
	if a.settingsWindow != nil {
		a.settingsWindow.Invalidate()
	}
	a.pluginServerLanguages[languageID] = session.PluginID
	a.clearFailedPluginServerLocked(session.PluginID, languageID)
	a.pluginServerMu.Unlock()
	// A restarted server has to republish everything: keeping the previous
	// process's diagnostics would show problems the new one may already have fixed.
	a.clearPluginDiagnostics(session.PluginID)
	// A manual completion waiting for discovery predates the session being replaced.
	waiting := a.semantics.startingCompletion
	a.releasePluginDocuments(session.PluginID)
	if waiting != nil {
		a.semantics.startingCompletion = waiting
		a.semantics.project = waiting.project
		a.semantics.documentID = waiting.documentID
	}
	a.openDocumentsForPlugin(p, server, languageID)
	a.servePluginServer(server, ctx)
}

// servePluginServer runs one language server's event loop and forwards
// diagnostics to the window and build events to attached build providers.
func (a *App) servePluginServer(server *pluginServer, ctx context.Context) {
	a.tasks.running.Add(1)
	go func() {
		defer a.tasks.running.Done()
		defer close(server.done)
		defer server.endBuild()
		observe := func(event core.BackendEvent) {
			server.forwardBuild(event)
			if event.Type == "stateChanged" || event.Type == "log" {
				a.post(func(a *App) { a.recordServerEvent(server, event) })
			}
			switch event.Type {
			case "stateChanged":
				if event.State == "ready" {
					a.post(func(a *App) {
						if a.isCurrentPluginServer(server.session.PluginID, server) {
							a.resumeDeferredSemantics()
							a.resumeEverywhereSymbols(server.project)
							if p := a.project; p != nil && p == server.project {
								for _, d := range p.docs.list {
									a.scheduleEditorActions(p, d)
								}
							}
						}
					})
				}
			case pluginFeaturesChanged:
				a.post(func(a *App) { a.applyServerFeatures(server, event) })
			case pluginSemanticTokensRefresh:
				a.post(func(a *App) { a.semanticTokensRefresh(server) })
			case pluginInlayHintsRefresh:
				a.post(func(a *App) { a.inlayHintsRefresh(server) })
			case pluginWorkspaceApplyEdit:
				a.post(func(a *App) { a.applyServerWorkspaceEdit(server, event) })
			case pluginWorkspaceApplyEditCancelled:
				a.post(func(a *App) { a.cancelServerWorkspaceEdit(server, event) })
			case pluginSemanticCompleted:
				// The answer is handed to the window thread with the session it
				// belongs to, so a retired server cannot reopen a popup.
				a.post(func(a *App) { a.applyPluginSemanticEvent(server, event) })
			case pluginbackend.EventDiagnostics:
				decoded, decodeErr := core.PluginDiagnosticsFromEvent(event)
				if decodeErr != nil {
					return
				}
				a.post(func(a *App) { a.applyServerDiagnostics(server, decoded) })
			}
		}
		serveErr := a.plugins.ServeLanguageSession(ctx, server.session, observe)
		if ctx.Err() != nil {
			serveErr = nil
		}
		// A server that exits on its own, crashes, or ends after a stop must not
		// leave its last diagnostics behind. The window thread removes the entry
		// only when this is still the session it recorded, so a restart that
		// already replaced it keeps the new server's state.
		a.post(func(a *App) { a.pluginServerExited(server.session.PluginID, server, serveErr) })
	}()
}

// applyServerDiagnostics stores one event only while it still belongs to the
// project and session that received it. A retired server must not repopulate a
// diagnostics list after a project switch or a restart.
func (a *App) applyServerDiagnostics(server *pluginServer, event core.PluginDiagnosticsEvent) {
	if server == nil || server.session == nil {
		return
	}
	if a.project != server.project || !a.isCurrentPluginServer(server.session.PluginID, server) {
		return
	}
	a.applyPluginDiagnostics(server.session.PluginID, event)
}

// pluginServerExited forgets a serve loop that ended and withdraws the
// diagnostics its process published. A session that was already replaced by a
// newer start is left alone.
func (a *App) pluginServerExited(pluginID string, server *pluginServer, serveErr error) {
	a.pluginServerMu.Lock()
	if a.pluginServers[pluginID] != server {
		a.pluginServerMu.Unlock()
		return
	}
	delete(a.pluginServers, pluginID)
	var languages []string
	seenLang := make(map[string]bool)
	for languageID, provider := range a.pluginServerLanguages {
		if provider == pluginID {
			delete(a.pluginServerLanguages, languageID)
			if !seenLang[languageID] {
				seenLang[languageID] = true
				languages = append(languages, languageID)
			}
		}
	}
	if server.session != nil && server.session.LanguageID != "" && !seenLang[server.session.LanguageID] {
		languages = append(languages, server.session.LanguageID)
	}
	suppressed := a.pluginServerSuppressed[pluginID]
	a.pluginServerMu.Unlock()
	a.clearPluginDiagnostics(pluginID)
	a.releasePluginDocuments(pluginID)
	if serveErr != nil {
		a.operationFailed("plugin_server", serveErr)
		if a.project == server.project && !suppressed {
			for i, languageID := range languages {
				a.recordPluginServerFailure(server.project, languageID, pluginID, server.session.Version, serveErr, server.logs, server.logsAdded)
				if i == 0 {
					a.notifyPluginServerFailure(server.project, languageID, serveErr)
				}
			}
		}
	}
}

// stopPluginServer stops the language server of one plugin, if it is running, and
// withdraws the diagnostics it published whether or not the process is still
// tracked.
func (a *App) stopPluginServer(pluginID string) {
	a.stopPluginSession(a.detachPluginServer(pluginID))
}

// detachPluginServer takes a plugin's server out of the workbench, so no request
// reaches it and no start registers it again, and returns its session for the
// caller to stop; nil when none runs.
func (a *App) detachPluginServer(pluginID string) *pluginservice.LanguageSession {
	var session *pluginservice.LanguageSession
	a.pluginServerMu.Lock()
	delete(a.pluginServerRestarting, pluginID)
	a.pluginSettingsRestart.Delete(pluginID)
	if a.pluginServerSuppressed == nil {
		a.pluginServerSuppressed = make(map[string]bool)
	}
	// A start that is still resolving must not register this plugin afterwards.
	a.pluginServerSuppressed[pluginID] = true
	a.pluginServerRevision++
	if a.pluginServerChanges == nil {
		a.pluginServerChanges = make(map[string]uint64)
	}
	a.pluginServerChanges[pluginID] = a.pluginServerRevision
	for languageID, preparation := range a.pluginServerPreparations {
		if preparation.pluginID == pluginID {
			preparation.stop()
			delete(a.pluginServerPreparations, languageID)
			delete(a.pluginServerStarting, languageID)
		}
	}
	if server, ok := a.pluginServers[pluginID]; ok {
		delete(a.pluginServers, pluginID)
		for languageID, provider := range a.pluginServerLanguages {
			if provider == pluginID {
				delete(a.pluginServerLanguages, languageID)
			}
		}
		server.cancel()
		session = server.session
	}
	a.clearFailedPluginServerLocked(pluginID, "")
	a.pluginServerMu.Unlock()
	a.clearPluginDiagnostics(pluginID)
	a.releasePluginDocuments(pluginID)
	return session
}

// activatePluginWorkspace starts the backends that asked for onWorkspaceOpen
// using the identity the window already owns. It runs after the window shows
// the project, off the window thread, so it never delays opening the workspace.
func (a *App) activatePluginWorkspace(p *project) {
	if a.plugins == nil {
		return
	}
	workspace := p.pluginContext
	a.background(p, pluginServerStartTimeout, func(ctx context.Context) func(*App) {
		entries, err := a.plugins.Manager.Installed()
		if err == nil {
			err = a.plugins.ActivateWorkspace(ctx, entries, workspace)
		}
		return func(a *App) {
			if err != nil {
				a.operationFailed("plugin_backend_start", err)
			}
		}
	})
}

// closePluginBackends ends the workspace contexts and stops every plugin backend,
// bounded and off the window thread.
func (a *App) closePluginBackends() {
	if a.plugins == nil {
		return
	}
	// The sessions leave the host now, so a backend started for the next project
	// is never the one this stop ends.
	stop := a.plugins.DetachWorkspaces()
	a.background(nil, pluginServerStopTimeout, func(context.Context) func(*App) {
		stop()
		return nil
	})
}

// stopAllPluginServers stops every language server the window started. It runs when
// the project closes and when the client quits.
func (a *App) stopAllPluginServers() {
	a.closePluginBackends()
	a.pluginServerMu.Lock()
	for _, preparation := range a.pluginServerPreparations {
		preparation.stop()
	}
	a.pluginServerPreparations = nil
	for id := range a.pluginServerRestarting {
		delete(a.pluginServerSuppressed, id)
	}
	a.pluginServerRestarting = nil
	a.pluginSettingsRestart.Clear()
	a.pluginServerFailed = nil
	a.pluginServerNotifiedErrors = nil
	if len(a.pluginServers) == 0 {
		a.releaseAllPluginDocuments()
		a.pluginServers = nil
		a.pluginServerLanguages = nil
		a.pluginServerStarting = nil
		a.pluginServerMu.Unlock()
		return
	}
	servers := make([]*pluginServer, 0, len(a.pluginServers))
	for _, server := range a.pluginServers {
		servers = append(servers, server)
	}
	a.releaseAllPluginDocuments()
	a.pluginServers = nil
	a.pluginServerLanguages = nil
	a.pluginServerStarting = nil
	a.pluginServerMu.Unlock()
	for _, server := range servers {
		server.cancel()
		a.stopPluginSession(server.session)
	}
}

// stopPluginSession disposes one session away from the window thread.
func (a *App) stopPluginSession(session *pluginservice.LanguageSession) {
	if a.plugins == nil || session == nil {
		return
	}
	a.background(nil, pluginServerStopTimeout, func(ctx context.Context) func(*App) {
		err := a.plugins.StopLanguageServer(ctx, session)
		return func(a *App) {
			if err != nil {
				a.backgroundFailed("plugin_server_stop", err)
			}
		}
	})
}

// pluginBackendRequest is the workspace a language server serves.
func (a *App) pluginBackendRequest() pluginservice.BackendRequest {
	request := pluginservice.BackendRequest{Architecture: core.PluginArchitecture()}
	if a.project != nil {
		// The root URI is resolved by Core from the absolute path in the start
		// goroutine; a map here would not fit lsp.startServer's string field.
		request.WorkingDirectory = a.project.root
		request.Context = a.project.pluginContext
		// In safe mode Core plans only a server that declares it runs no project code; the
		// others wait for trust (finishPluginServerStart).
		request.ProjectCodeAllowed = a.project.trust.allowed()
	}
	return request
}

// isCurrentPluginServer reads the shared registry while a build may register a server.
func (a *App) isCurrentPluginServer(pluginID string, server *pluginServer) bool {
	a.pluginServerMu.Lock()
	defer a.pluginServerMu.Unlock()
	return a.pluginServers[pluginID] == server
}

// clearFailedPluginServerLocked drops recorded failure and dedup state for
// pluginID and languageID. Caller must hold a.pluginServerMu.
func (a *App) clearFailedPluginServerLocked(pluginID, languageID string) {
	if languageID != "" {
		delete(a.pluginServerFailed, languageID)
		delete(a.pluginServerNotifiedErrors, languageID)
	}
	if pluginID == "" {
		return
	}
	for lang, failed := range a.pluginServerFailed {
		if failed != nil && failed.pluginID == pluginID {
			delete(a.pluginServerFailed, lang)
			delete(a.pluginServerNotifiedErrors, lang)
		}
	}
}

func (a *App) recordPluginServerFailure(p *project, languageID, pluginID, version string, err error, logs []lspLogLine, logsAdded uint64) {
	if a.project != p || err == nil || languageID == "" {
		return
	}
	reason := strings.TrimSpace(err.Error())
	copiedLogs := append([]lspLogLine(nil), logs...)
	if reason != "" {
		errLine := lspLogLine{level: "ERROR", text: cutLogLine("[ERROR] " + reason), tag: len("[ERROR]")}
		if len(copiedLogs) >= lspLogLines {
			copy(copiedLogs, copiedLogs[len(copiedLogs)-lspLogLines+1:])
			copiedLogs = copiedLogs[:lspLogLines-1]
		}
		copiedLogs = append(copiedLogs, errLine)
		logsAdded++
	}
	a.pluginServerMu.Lock()
	if a.pluginServerFailed == nil {
		a.pluginServerFailed = make(map[string]*failedPluginServer)
	}
	a.pluginServerFailed[languageID] = &failedPluginServer{
		pluginID:   pluginID,
		languageID: languageID,
		version:    version,
		project:    p,
		message:    reason,
		logs:       copiedLogs,
		logsAdded:  logsAdded,
	}
	a.pluginServerMu.Unlock()
	a.invalidator.Invalidate()
}

// recordPluginServerSafeMode records that Core planned no server for languageID because the
// project is in safe mode and the server may run the project's code. The status bar, its menu
// and the LSP log say so and offer to trust the project, which starts the server.
func (a *App) recordPluginServerSafeMode(p *project, languageID, pluginID, version string) {
	if a.project != p || languageID == "" {
		return
	}
	message := i18n.Shared(a.language(), "desktop.trust.lspSafeMode")
	a.pluginServerMu.Lock()
	if a.pluginServerFailed == nil {
		a.pluginServerFailed = make(map[string]*failedPluginServer)
	}
	a.pluginServerFailed[languageID] = &failedPluginServer{
		pluginID:   pluginID,
		languageID: languageID,
		version:    version,
		project:    p,
		message:    message,
		logs:       []lspLogLine{{level: "INFO", text: cutLogLine("[INFO] " + message), tag: len("[INFO]")}},
		logsAdded:  1,
		untrusted:  true,
	}
	a.pluginServerMu.Unlock()
	a.invalidator.Invalidate()
}

func (a *App) notifyPluginServerFailure(p *project, languageID string, err error) {
	if a.project != p || err == nil {
		return
	}
	reason := strings.TrimSpace(err.Error())
	a.pluginServerMu.Lock()
	if a.pluginServerNotifiedErrors == nil {
		a.pluginServerNotifiedErrors = make(map[string]string)
	}
	if prev, ok := a.pluginServerNotifiedErrors[languageID]; ok && prev == reason {
		a.pluginServerMu.Unlock()
		return
	}
	a.pluginServerNotifiedErrors[languageID] = reason
	a.pluginServerMu.Unlock()

	lang := a.language()
	if reason == "" {
		a.notifyError(i18n.Shared(lang, "native.languageServerFailedToStart"))
		return
	}
	a.notifyError(i18n.SharedFormat(lang, "native.languageServerFailedToStart.variant2", map[string]string{"arg1": reason}))
}

// retryFailedLSPServer clears the recorded failure for languageID and starts
// its language server again.
func (a *App) retryFailedLSPServer(languageID string) {
	if a.project == nil || languageID == "" {
		return
	}
	a.pluginServerMu.Lock()
	if failed := a.pluginServerFailed[languageID]; failed != nil && failed.pluginID != "" {
		delete(a.pluginServerSuppressed, failed.pluginID)
	}
	delete(a.pluginServerFailed, languageID)
	delete(a.pluginServerNotifiedErrors, languageID)
	a.pluginServerMu.Unlock()
	a.invalidator.Invalidate()
	a.startPluginServer(languageID)
}

// retryFailedPluginServers re-triggers startup for any failed or unstarted
// language servers in the open project after toolchain settings change.
func (a *App) retryFailedPluginServers() {
	if a.project == nil || a.plugins == nil {
		return
	}
	seen := make(map[string]bool)
	var languages []string
	a.pluginServerMu.Lock()
	for lang, failed := range a.pluginServerFailed {
		if failed != nil && failed.project == a.project && !seen[lang] {
			seen[lang] = true
			languages = append(languages, lang)
			if failed.pluginID != "" {
				delete(a.pluginServerSuppressed, failed.pluginID)
			}
		}
	}
	a.pluginServerFailed = nil
	for _, doc := range a.project.docs.list {
		if doc.languageID == "" || seen[doc.languageID] {
			continue
		}
		if provider := a.pluginServerLanguages[doc.languageID]; provider != "" && a.pluginServers[provider] != nil {
			continue
		}
		if a.pluginServerStarting[doc.languageID] {
			continue
		}
		seen[doc.languageID] = true
		languages = append(languages, doc.languageID)
	}
	a.pluginServerMu.Unlock()
	a.invalidator.Invalidate()
	for _, lang := range languages {
		a.startPluginServer(lang)
	}
}
