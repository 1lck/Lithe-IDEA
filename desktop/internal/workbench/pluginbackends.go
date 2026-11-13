package workbench

import (
	"context"
	"sync"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprovider"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

const (
	// pluginServerStartTimeout bounds resolving and launching one language server.
	pluginServerStartTimeout = 2 * time.Minute
	// pluginServerStopTimeout bounds a shutdown. Core keeps the session until it is
	// disposed, so this covers both the graceful stop and the disposal.
	pluginServerStopTimeout = 30 * time.Second
)

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
	completionTriggers []string
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
	if a.plugins == nil || languageID == "" {
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
		// servers; the first start answers for all of them.
		a.pluginServerMu.Unlock()
		return
	}
	a.pluginServerStarting[languageID] = true
	a.pluginServerMu.Unlock()
	request := a.pluginBackendRequest()
	p := a.project
	a.background(nil, pluginServerStartTimeout, func(ctx context.Context) func(*App) {
		if request.WorkingDirectory != "" {
			uri, uriErr := a.kernel.PluginDocumentURI(ctx, request.WorkingDirectory, "auto")
			if uriErr != nil {
				return func(a *App) { a.finishPluginServerStart(p, languageID, nil, uriErr) }
			}
			request.RootURI = uri
		}
		entries, err := a.plugins.Manager.Installed()
		if err != nil {
			return func(a *App) { a.finishPluginServerStart(p, languageID, nil, err) }
		}
		session, err := a.plugins.StartLanguageServer(ctx, entries, languageID, request)
		return func(a *App) { a.finishPluginServerStart(p, languageID, session, err) }
	})
}

// finishPluginServerStart takes the started session back on the window thread and
// runs its serve loop.
func (a *App) finishPluginServerStart(p *project, languageID string, session *pluginservice.LanguageSession, err error) {
	a.pluginServerMu.Lock()
	delete(a.pluginServerStarting, languageID)
	a.pluginServerMu.Unlock()
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_server_start", err))
		return
	}
	if session == nil {
		return
	}
	if session.Warnings != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_server_selection", session.Warnings))
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
	a.pluginServerMu.Unlock()
	// A restarted server has to republish everything: keeping the previous
	// process's diagnostics would show problems the new one may already have fixed.
	a.clearPluginDiagnostics(session.PluginID)
	a.releasePluginDocuments(session.PluginID)
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
						}
					})
				}
			case pluginFeaturesChanged:
				a.post(func(a *App) { a.applyServerFeatures(server, event) })
			case pluginSemanticTokensRefresh:
				a.post(func(a *App) { a.semanticTokensRefresh(server) })
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
		if serveErr := a.plugins.ServeLanguageSession(ctx, server.session, observe); serveErr != nil && ctx.Err() == nil {
			a.post(func(a *App) {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_server", serveErr))
			})
		}
		// A server that exits on its own, crashes, or ends after a stop must not
		// leave its last diagnostics behind. The window thread removes the entry
		// only when this is still the session it recorded, so a restart that
		// already replaced it keeps the new server's state.
		a.post(func(a *App) { a.pluginServerExited(server.session.PluginID, server) })
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
func (a *App) pluginServerExited(pluginID string, server *pluginServer) {
	a.pluginServerMu.Lock()
	if a.pluginServers[pluginID] != server {
		a.pluginServerMu.Unlock()
		return
	}
	delete(a.pluginServers, pluginID)
	for languageID, provider := range a.pluginServerLanguages {
		if provider == pluginID {
			delete(a.pluginServerLanguages, languageID)
		}
	}
	a.pluginServerMu.Unlock()
	a.clearPluginDiagnostics(pluginID)
	a.releasePluginDocuments(pluginID)
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
	a.pluginServerMu.Unlock()
	a.clearPluginDiagnostics(pluginID)
	a.releasePluginDocuments(pluginID)
	return session
}

// activatePluginWorkspace opens the workspace's context for plugin backends and
// starts the ones that asked for onWorkspaceOpen. It runs after the window shows
// the project, off the window thread, so it never delays opening the workspace.
func (a *App) activatePluginWorkspace(root string) {
	if a.plugins == nil {
		return
	}
	a.background(nil, pluginServerStartTimeout, func(ctx context.Context) func(*App) {
		entries, err := a.plugins.Manager.Installed()
		if err == nil {
			err = a.plugins.ActivateWorkspace(ctx, entries, root)
		}
		return func(a *App) {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_backend_start", err))
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
	for id := range a.pluginServerRestarting {
		delete(a.pluginServerSuppressed, id)
	}
	a.pluginServerRestarting = nil
	a.pluginSettingsRestart.Clear()
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
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_server_stop", err))
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
	}
	return request
}

// isCurrentPluginServer reads the shared registry while a build may register a server.
func (a *App) isCurrentPluginServer(pluginID string, server *pluginServer) bool {
	a.pluginServerMu.Lock()
	defer a.pluginServerMu.Unlock()
	return a.pluginServers[pluginID] == server
}
