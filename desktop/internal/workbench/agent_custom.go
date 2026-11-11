package workbench

import (
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// Custom Agents are the user's command-line ACP agents (settingswindow/agent_custom.go). They
// are listed after Core's catalog with an ID that cannot collide with an adapter's, and launched
// by command. Their definitions live in the application settings; nothing is installed for them.

// customAgentPrefix starts the catalog ID of every custom Agent.
const customAgentPrefix = "custom:"

// customAgentProtocol is the protocol a custom Agent is matched to providers by: the Responses
// gateway a user-provided agent must support (launch contract).
const customAgentProtocol = "responses"

// withCustomAgents returns Core's catalog followed by one entry per saved custom Agent. A custom
// entry counts as installed, because its command is the user's own.
func withCustomAgents(catalog []core.AgentCatalogStatus, custom []settingswindow.CustomAgentSetting) []core.AgentCatalogStatus {
	out := slices.Clone(catalog)
	for _, entry := range custom {
		if entry.ID == "" {
			continue
		}
		version := ""
		out = append(out, core.AgentCatalogStatus{
			ID: customAgentPrefix + entry.ID, Name: entry.Name, Protocol: customAgentProtocol,
			InstalledVersion: &version, Verified: false,
		})
	}
	return out
}

// isCustomAgent reports whether a catalog ID names a custom Agent.
func isCustomAgent(id string) bool { return strings.HasPrefix(id, customAgentPrefix) }

// customAgentFor returns the saved definition behind a custom catalog ID.
func (a *App) customAgentFor(id string) (settingswindow.CustomAgentSetting, bool) {
	if !isCustomAgent(id) {
		return settingswindow.CustomAgentSetting{}, false
	}
	key := strings.TrimPrefix(id, customAgentPrefix)
	for _, entry := range a.settings.CustomAgents {
		if entry.ID == key {
			return entry, true
		}
	}
	return settingswindow.CustomAgentSetting{}, false
}

// setCustomAgents stores the whole custom Agent list and rebuilds the open project's picker.
// A running connection keeps the Agent it launched with.
func (a *App) setCustomAgents(list []settingswindow.CustomAgentSetting) {
	a.settings.CustomAgents = slices.Clone(list)
	if p := a.project; p != nil && p.agent.statusLoaded {
		p.agent.agents = withCustomAgents(p.agent.catalog, a.settings.CustomAgents)
		p.agent.selected = clampIndex(p.agent.selected, len(p.agent.agents))
	}
	if a.settingsWindow != nil {
		a.settingsWindow.Invalidate()
	}
	a.saveSettings()
}
