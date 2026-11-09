package workbench

import (
	"context"
	"path/filepath"
	"runtime"
	"time"

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
	// cancel ends the serve loop; the session itself is disposed by the stop call.
	cancel context.CancelFunc
	// done closes when the serve loop returns.
	done chan struct{}
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
	if a.pluginServers == nil {
		a.pluginServers = make(map[string]*pluginServer)
		a.pluginServerLanguages = make(map[string]string)
		a.pluginServerStarting = make(map[string]bool)
	}
	if provider, ok := a.pluginServerLanguages[languageID]; ok && a.pluginServers[provider] != nil {
		return
	}
	if a.pluginServerStarting[languageID] {
		// Opening several files of one language at once must not launch several
		// servers; the first start answers for all of them.
		return
	}
	a.pluginServerStarting[languageID] = true
	request := a.pluginBackendRequest()
	a.background(nil, pluginServerStartTimeout, func(ctx context.Context) func(*App) {
		entries, err := a.plugins.Manager.Installed()
		if err != nil {
			return func(a *App) { a.finishPluginServerStart(languageID, nil, err) }
		}
		session, err := a.plugins.StartLanguageServer(ctx, entries, languageID, request)
		return func(a *App) { a.finishPluginServerStart(languageID, session, err) }
	})
}

// finishPluginServerStart takes the started session back on the window thread and
// runs its serve loop.
func (a *App) finishPluginServerStart(languageID string, session *pluginservice.LanguageSession, err error) {
	delete(a.pluginServerStarting, languageID)
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_server_start", err))
		return
	}
	if session == nil {
		return
	}
	if a.plugins == nil {
		return
	}
	if existing := a.pluginServers[session.PluginID]; existing != nil {
		// Another start won the race; the extra session is disposed rather than
		// left running beside the one the window uses.
		a.stopPluginSession(session)
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	server := &pluginServer{session: session, cancel: cancel, done: make(chan struct{})}
	a.pluginServers[session.PluginID] = server
	a.pluginServerLanguages[languageID] = session.PluginID
	a.tasks.running.Add(1)
	go func() {
		defer a.tasks.running.Done()
		defer close(server.done)
		// The observer runs on this goroutine, so it hands the event to the window
		// thread instead of touching the window's state here.
		observe := func(event core.BackendEvent) {
			if event.Type != pluginbackend.EventDiagnostics {
				return
			}
			decoded, decodeErr := core.PluginDiagnosticsFromEvent(event)
			if decodeErr != nil {
				return
			}
			a.post(func(a *App) { a.applyPluginDiagnostics(decoded) })
		}
		if serveErr := a.plugins.ServeLanguageSession(ctx, session, observe); serveErr != nil && ctx.Err() == nil {
			a.post(func(a *App) {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_server", serveErr))
			})
		}
	}()
}

// stopPluginServer stops the language server of one plugin, if it is running.
func (a *App) stopPluginServer(pluginID string) {
	server, ok := a.pluginServers[pluginID]
	if !ok {
		return
	}
	delete(a.pluginServers, pluginID)
	for languageID, provider := range a.pluginServerLanguages {
		if provider == pluginID {
			delete(a.pluginServerLanguages, languageID)
		}
	}
	server.cancel()
	a.stopPluginSession(server.session)
}

// stopAllPluginServers stops every language server the window started. It runs when
// the project closes and when the client quits.
func (a *App) stopAllPluginServers() {
	if len(a.pluginServers) == 0 {
		a.pluginServers = nil
		a.pluginServerLanguages = nil
		a.pluginServerStarting = nil
		return
	}
	servers := make([]*pluginServer, 0, len(a.pluginServers))
	for _, server := range a.pluginServers {
		servers = append(servers, server)
	}
	a.pluginServers = nil
	a.pluginServerLanguages = nil
	a.pluginServerStarting = nil
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
	request := pluginservice.BackendRequest{Architecture: backendArchitecture()}
	if a.project != nil {
		request.RootURI = map[string]string{"path": a.project.root, "platform": runtime.GOOS}
		request.WorkingDirectory = a.project.root
	}
	return request
}

// backendArchitecture is the architecture name Core plans for.
func backendArchitecture() string {
	architecture := runtime.GOARCH
	if architecture == "amd64" {
		return "x64"
	}
	return architecture
}

// pluginDocumentURI is the identity the document rules use for one file.
func pluginDocumentURI(root, path string) string {
	if root == "" {
		return ""
	}
	relative, err := filepath.Rel(root, path)
	if err != nil {
		return ""
	}
	return "file:///" + filepath.ToSlash(relative)
}
