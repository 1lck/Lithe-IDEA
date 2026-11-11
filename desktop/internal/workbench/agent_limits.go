package workbench

import "github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"

// Agent context limits are the user's own settings. They travel in the launch JSON
// as `contextLimits` (zero means unset, so the Agent keeps its default), and the
// context indicator caps its displayed capacity at the configured window because
// the Agent's reported size can differ from it.

// agentContextLimit is one Agent's limits in tokens.
type agentContextLimit struct {
	WindowTokens      uint64 `json:"windowTokens,omitempty"`
	AutoCompactTokens uint64 `json:"autoCompactTokens,omitempty"`
}

// agentContextLimitsFor returns the limits saved for one adapter id.
func (a *App) agentContextLimitsFor(agentID string) agentContextLimit {
	return a.settings.AgentContextLimits[agentID]
}

// agentContextLimits returns the limits of the open project's selected Agent.
func (a *App) agentContextLimits() agentContextLimit {
	if a.project == nil {
		return agentContextLimit{}
	}
	agent, ok := a.project.selectedAgent()
	if !ok {
		return agentContextLimit{}
	}
	return a.agentContextLimitsFor(agent.ID)
}

// setAgentContextLimits saves one Agent's limits; zero values clear them. The next
// connection reads them, and a running one keeps what it launched with.
func (a *App) setAgentContextLimits(agentID string, limit agentContextLimit) {
	if agentID == "" {
		return
	}
	if a.settings.AgentContextLimits == nil {
		a.settings.AgentContextLimits = map[string]agentContextLimit{}
	}
	if limit == (agentContextLimit{}) {
		delete(a.settings.AgentContextLimits, agentID)
	} else {
		a.settings.AgentContextLimits[agentID] = limit
	}
	if a.settingsWindow != nil {
		a.settingsWindow.Invalidate()
	}
	a.saveSettings()
}

// agentLaunchLimits is the launch JSON's contextLimits, nil when nothing is set.
func (a *App) agentLaunchLimits(agentID string) map[string]uint64 {
	limit := a.agentContextLimitsFor(agentID)
	if limit == (agentContextLimit{}) {
		return nil
	}
	out := map[string]uint64{}
	if limit.WindowTokens > 0 {
		out["windowTokens"] = limit.WindowTokens
	}
	if limit.AutoCompactTokens > 0 {
		out["autoCompactTokens"] = limit.AutoCompactTokens
	}
	return out
}

// agentSettingsBackend is the Core client the AI settings pages use, or nil when the
// window was built without an Agent kernel (the pages then say they are unavailable).
func (a *App) agentSettingsBackend() settingswindow.AgentSettingsBackend {
	if kernel, ok := a.agentKernel.(CoreAgentKernel); ok && kernel.Client != nil {
		return kernel.Client
	}
	return nil
}

// agentReportedContextFor is the context length the open project's connection reported for
// the adapter, 0 when it has not reported one. It reads only the open session's own usage.
func (a *App) agentReportedContextFor(agentID string) uint64 {
	if a.project == nil {
		return 0
	}
	agent, ok := a.project.selectedAgent()
	if !ok || agent.ID != agentID {
		return 0
	}
	if s := a.project.agent.activity.current(a.project.agent.sessionID); s != nil && s.usageKnown {
		return s.size
	}
	return 0
}
