package settingswindow

// AgentSessionsState is what the Agents page shows: the plugins whose agents can read the
// local session files their CLIs write, and whether the user lets Lithe read them. The
// settings window reads it on its own thread; the workbench keeps it current.
type AgentSessionsState struct {
	// Loaded is false until the workbench configured the agents once.
	Loaded  bool
	Plugins []AgentSessionPlugin
	// Error is the last failure of saving a choice or forgetting a plugin's records.
	Error string
}

// AgentSessionPlugin is one plugin that asks to read its agents' sessions.
type AgentSessionPlugin struct {
	PluginID string
	// Name is the plugin's display name, its ID when it has none.
	Name string
	// Agents are the display names of the plugin's agents, as Core configured them.
	Agents []string
	// Roots are the session directories the plugin's agents declare, as written in the
	// manifest: ${userHome} and ${env:NAME} stand for the home directory and a variable.
	Roots []string
	// Allowed is the user's choice; Lithe reads none of the plugin's session files without it.
	Allowed bool
}

// AgentSessionsLoader is the workbench side of the Agents page. Its methods are called on the
// settings window's thread and must not block on the window.
type AgentSessionsLoader interface {
	State() AgentSessionsState
	// SetAllowed saves the choice for a plugin and configures the agents again; taking it back
	// also drops the records Lithe cached from that plugin's session files.
	SetAllowed(pluginID string, allowed bool)
}
