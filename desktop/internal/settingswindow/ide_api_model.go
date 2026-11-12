package settingswindow

// IDEAPIState is what the IDE Connection page shows for the open project. The
// settings window reads it on its own thread; the workbench keeps it current.
type IDEAPIState struct {
	// HasProject is false when no project is open; the page then has nothing to enable.
	HasProject bool
	// HelperMissing is true when the packaged lithe-mcp helper cannot be found.
	HelperMissing bool
	// Enabled is true while the project's connection is open.
	Enabled bool
	// Configure and Execute are the grants: the live ones while enabled, else the
	// choice remembered for the project.
	Configure bool
	Execute   bool
	// Error is the last refusal from enabling, disabling or saving the choice.
	Error string
}

// IDEAPILoader is the Core-backed surface of the IDE Connection page. Its methods are
// called on the settings window's thread and must not block on the window.
type IDEAPILoader interface {
	State() IDEAPIState
	// Enable opens the open project's connection with the grants.
	Enable(configure, execute bool)
	// Disable closes the connection and revokes its access.
	Disable()
	// Allow remembers the grants for the open project; they cannot change while enabled.
	Allow(configure, execute bool)
	// CopyConfiguration copies the stdio client configuration of the open connection.
	CopyConfiguration()
}
