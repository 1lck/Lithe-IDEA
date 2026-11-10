package workbench

import (
	"errors"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
	"github.com/vivaui/viva/app"
)

// ideAPIGrantsFile holds the grants the user chose for each project. It is a preference:
// it never opens a connection, which the user still enables for every session.
const ideAPIGrantsFile = "ide-api.json"

// ideAPIGrants are the remembered grants of one project.
type ideAPIGrants struct {
	Configure bool `json:"configure"`
	Execute   bool `json:"execute"`
}

// ideAPIBridge lets the settings window read and change the open project's connection
// from its own thread. The window thread sets the project; everything else takes the lock.
type ideAPIBridge struct {
	mu        sync.Mutex
	project   *project
	grants    ideAPIGrants
	lastError string
}

// ideAPISetProject records the open project, or nil when it closes, and loads the grants
// the user chose for it. The window thread calls it when the project changes.
func (a *App) ideAPISetProject(p *project) {
	grants := ideAPIGrants{}
	if p != nil {
		all := map[string]ideAPIGrants{}
		if _, err := a.store.Load(ideAPIGrantsFile, &all); err != nil {
			a.gitOperationFailed("ide_api_grants", err)
		}
		grants = all[p.root]
	}
	a.ideAPIBridgeState.mu.Lock()
	a.ideAPIBridgeState.project = p
	a.ideAPIBridgeState.grants = grants
	a.ideAPIBridgeState.lastError = ""
	a.ideAPIBridgeState.mu.Unlock()
}

// ideAPISettingsLoader is the IDE Connection page's loader. It is nil, which leaves the
// page unavailable, when the kernel is not the real Core client (a test double).
func (a *App) ideAPISettingsLoader() settingswindow.IDEAPILoader {
	if _, ok := a.kernel.(*core.Client); !ok {
		return nil
	}
	return ideAPISettings{a: a}
}

// ideAPISettings implements settingswindow.IDEAPILoader on the App.
type ideAPISettings struct{ a *App }

func (s ideAPISettings) bridge() *ideAPIBridge { return &s.a.ideAPIBridgeState }

func (s ideAPISettings) setError(err error) {
	b := s.bridge()
	b.mu.Lock()
	defer b.mu.Unlock()
	if err == nil {
		b.lastError = ""
		return
	}
	b.lastError = err.Error()
}

// State reads the open project's connection and grants.
func (s ideAPISettings) State() settingswindow.IDEAPIState {
	b := s.bridge()
	b.mu.Lock()
	p, grants, lastError := b.project, b.grants, b.lastError
	b.mu.Unlock()
	if p == nil {
		return settingswindow.IDEAPIState{Error: lastError}
	}
	state := settingswindow.IDEAPIState{HasProject: true, Configure: grants.Configure, Execute: grants.Execute, Error: lastError}
	if _, err := ideAPIHelperPath(); err != nil {
		state.HelperMissing = true
	}
	p.ideAPI.mu.Lock()
	if conn := p.ideAPI.conn; conn != nil {
		state.Enabled = true
		state.Configure = conn.permissions.Configure
		state.Execute = conn.permissions.Execute
	}
	p.ideAPI.mu.Unlock()
	return state
}

// Enable opens the connection with the grants the page shows. The Core call starts the helper
// and may take seconds, so it runs off the settings window's thread; the page is repainted
// when it answers.
func (s ideAPISettings) Enable(configure, execute bool) {
	b := s.bridge()
	b.mu.Lock()
	p := b.project
	b.mu.Unlock()
	if p == nil {
		s.setError(errors.New("no open project"))
		return
	}
	helper, err := ideAPIHelperPath()
	if err != nil {
		s.setError(err)
		return
	}
	permissions := core.IDEPermissions{Configure: configure, Execute: execute}
	go func() {
		_, err := s.a.ideAPIEnable(p, permissions, helper)
		s.setError(err)
		s.a.invalidateSettingsWindow()
	}()
}

// Disable closes the connection of the open project. The Core close also runs off the
// settings window's thread.
func (s ideAPISettings) Disable() {
	b := s.bridge()
	b.mu.Lock()
	p := b.project
	b.mu.Unlock()
	go func() {
		s.a.ideAPIDisable(p)
		s.setError(nil)
		s.a.invalidateSettingsWindow()
	}()
}

// Allow saves the grants of the open project. It is refused while the connection is on,
// because the grants stay fixed until it is disabled.
func (s ideAPISettings) Allow(configure, execute bool) {
	b := s.bridge()
	b.mu.Lock()
	p := b.project
	b.mu.Unlock()
	if p == nil {
		s.setError(errors.New("no open project"))
		return
	}
	p.ideAPI.mu.Lock()
	enabled := p.ideAPI.conn != nil
	p.ideAPI.mu.Unlock()
	if enabled {
		s.setError(errors.New("the connection is on; disable it to change its permissions"))
		return
	}
	all := map[string]ideAPIGrants{}
	if _, err := s.a.store.Load(ideAPIGrantsFile, &all); err != nil {
		s.setError(err)
		return
	}
	grants := ideAPIGrants{Configure: configure, Execute: execute}
	all[p.root] = grants
	if err := s.a.store.Save(ideAPIGrantsFile, all); err != nil {
		s.setError(err)
		return
	}
	b.mu.Lock()
	b.grants = grants
	b.mu.Unlock()
	s.setError(nil)
}

// CopyConfiguration copies the stdio client configuration of the enabled connection. The
// configuration names the helper and the descriptor, never a bearer credential.
func (s ideAPISettings) CopyConfiguration() {
	b := s.bridge()
	b.mu.Lock()
	p := b.project
	b.mu.Unlock()
	if p == nil {
		return
	}
	p.ideAPI.mu.Lock()
	var configuration string
	if conn := p.ideAPI.conn; conn != nil {
		configuration = string(conn.configuration)
	}
	p.ideAPI.mu.Unlock()
	if configuration == "" {
		return
	}
	if err := app.SetClipboardText(configuration); err != nil {
		s.setError(err)
	}
}
