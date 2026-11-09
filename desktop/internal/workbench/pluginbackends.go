package workbench

import (
	"context"
	"sync"
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
	session *pluginservice.LanguageSession
	// project is the project the server was started for. An event that arrives
	// after the window moved to another project is stale and is dropped.
	project *project
	// cancel ends the serve loop; the session itself is disposed by the stop call.
	cancel context.CancelFunc
	// done closes when the serve loop returns.
	done chan struct{}
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
			switch event.Type {
			case "stateChanged":
				if event.State == "ready" {
					a.post(func(a *App) {
						if a.isCurrentPluginServer(server.session.PluginID, server) {
							a.resumeDeferredSemantics()
						}
					})
				}
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
	a.pluginServerMu.Lock()
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
		a.stopPluginSession(server.session)
	}
	a.pluginServerMu.Unlock()
	a.clearPluginDiagnostics(pluginID)
	a.releasePluginDocuments(pluginID)
}

// stopAllPluginServers stops every language server the window started. It runs when
// the project closes and when the client quits.
func (a *App) stopAllPluginServers() {
	a.pluginServerMu.Lock()
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
