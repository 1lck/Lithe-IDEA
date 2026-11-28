package workbench

import (
	"context"
	"errors"
	"slices"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/agents"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// agentSettingsBridge lets the Agents settings page read, from its own thread, which plugins
// ask to read their agents' sessions and what the user chose. The window thread publishes the
// state; a failure of a background step records its reason.
type agentSettingsBridge struct {
	mu        sync.Mutex
	state     settingswindow.AgentSessionsState
	lastError string
}

// agentSessionsLoader is the Agents page's loader, nil when the window runs no agents.
func (a *App) agentSessionsLoader() settingswindow.AgentSessionsLoader {
	if a.agentKernel == nil {
		return nil
	}
	return agentSessionSettings{a: a}
}

// publishAgentSettings hands the Agents page the plugins that ask to read their agents'
// sessions, with the user's choice, and repaints it. It runs on the window thread.
func (a *App) publishAgentSettings() {
	v := &a.agentsView
	consent := agents.Consent(a.settings.AgentSessionConsent)
	state := settingswindow.AgentSessionsState{Loaded: v.configured, MCPSearch: a.settings.AgentSessionsMCPSearch}
	for _, plugin := range v.plugins {
		if !slices.Contains(plugin.Permissions, agents.PermissionReadSessions) {
			continue
		}
		name := plugin.DisplayName
		if name == "" {
			name = plugin.PluginID
		}
		entry := settingswindow.AgentSessionPlugin{
			PluginID: plugin.PluginID, Name: name, Roots: slices.Clone(plugin.SessionRoots),
			Allowed: consent.Plugin(plugin.PluginID),
		}
		for _, agent := range v.catalog {
			if agent.PluginID == plugin.PluginID {
				entry.Agents = append(entry.Agents, agent.DisplayName)
			}
		}
		state.Plugins = append(state.Plugins, entry)
	}
	b := &a.agentSettingsState
	b.mu.Lock()
	state.Error = b.lastError
	b.state = state
	b.mu.Unlock()
	a.invalidateSettingsWindow()
}

// recordAgentSettingsFailure keeps the reason the Agents page shows, or clears it.
func (a *App) recordAgentSettingsFailure(err error) {
	b := &a.agentSettingsState
	b.mu.Lock()
	b.lastError = ""
	if err != nil {
		b.lastError = err.Error()
	}
	b.state.Error = b.lastError
	b.mu.Unlock()
	a.invalidateSettingsWindow()
}

// setAgentSessionConsent saves whether Lithe may read the sessions of a plugin's agents and
// configures the agents again. Taking the consent back also drops the records Lithe cached
// from those sessions, after Core stopped reading them.
func (a *App) setAgentSessionConsent(pluginID string, allowed bool) {
	if pluginID == "" || agents.Consent(a.settings.AgentSessionConsent).Plugin(pluginID) == allowed {
		return
	}
	if allowed {
		a.performed("agents.sessions.allow", surfaceButton)
		if a.settings.AgentSessionConsent == nil {
			a.settings.AgentSessionConsent = map[string]bool{}
		}
		a.settings.AgentSessionConsent[pluginID] = true
	} else {
		a.performed("agents.sessions.revoke", surfaceButton)
		delete(a.settings.AgentSessionConsent, pluginID)
	}
	a.saveSettings()
	a.recordAgentSettingsFailure(nil)
	a.refreshIDEAPISessionTools()
	var forget []string
	if !allowed {
		for _, plugin := range a.agentsView.plugins {
			if plugin.PluginID == pluginID {
				forget = plugin.Agents
			}
		}
	}
	a.reconfigureAgentsForgetting(pluginID, forget)
	a.publishAgentSettings()
}

// reconfigureAgentsForgetting configures the agents again and then drops the cached records
// of the named agents of pluginID.
func (a *App) reconfigureAgentsForgetting(pluginID string, forget []string) {
	if a.plugins == nil || a.plugins.Manager == nil || a.agentKernel == nil {
		return
	}
	ticket := a.agentConfigureTicket()
	kernel := a.agentKernel
	a.background(nil, pluginStateTimeout, func(ctx context.Context) func(*App) {
		entries, err := a.plugins.Manager.Installed()
		if err != nil {
			return func(a *App) { a.backgroundFailed("agents_configure", err) }
		}
		snapshot, snapshotErr := a.plugins.ReadInstalled(ctx, entries)
		result := a.configureAgents(ctx, snapshot, ticket)
		result.err = errors.Join(snapshotErr, result.err)
		var failures []error
		for _, agentID := range forget {
			if _, err := kernel.Forget(ctx, pluginID, agentID); err != nil {
				failures = append(failures, err)
			}
		}
		forgetErr := errors.Join(failures...)
		return func(a *App) {
			a.applyAgentCatalog(result)
			if forgetErr != nil {
				a.backgroundFailed("agents_forget", forgetErr)
				a.recordAgentSettingsFailure(forgetErr)
			}
		}
	})
}

// agentSessionSettings implements settingswindow.AgentSessionsLoader on the App.
type agentSessionSettings struct{ a *App }

// State reads what the window thread published last.
func (s agentSessionSettings) State() settingswindow.AgentSessionsState {
	b := &s.a.agentSettingsState
	b.mu.Lock()
	defer b.mu.Unlock()
	state := b.state
	state.Plugins = slices.Clone(state.Plugins)
	return state
}

// SetAllowed hands the choice to the window thread, which owns the settings.
func (s agentSessionSettings) SetAllowed(pluginID string, allowed bool) {
	s.a.post(func(a *App) { a.setAgentSessionConsent(pluginID, allowed) })
}

// SetMCPSearch hands the choice to the window thread, which owns the settings.
func (s agentSessionSettings) SetMCPSearch(allowed bool) {
	s.a.post(func(a *App) { a.setAgentMCPSearch(allowed) })
}

// setAgentMCPSearch saves whether the MCP clients of an IDE connection may search and read the
// sessions Lithe may read, and reconnects an open connection to offer or withdraw the tools.
func (a *App) setAgentMCPSearch(allowed bool) {
	if a.settings.AgentSessionsMCPSearch == allowed {
		return
	}
	action := "agents.sessions.mcpSearch.revoke"
	if allowed {
		action = "agents.sessions.mcpSearch.allow"
	}
	a.performed(action, surfaceButton)
	a.settings.AgentSessionsMCPSearch = allowed
	a.saveSettings()
	a.recordAgentSettingsFailure(nil)
	a.refreshIDEAPISessionTools()
	a.publishAgentSettings()
}
