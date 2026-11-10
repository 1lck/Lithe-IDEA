package i18n

// DebugMessages are the Debug tool window's words.
type DebugMessages struct {
	PluginsUnavailable string
	Start              string
	Stop               string
	Continue           string
	Pause              string
	Starting           string
	Initialized        string
	Paused             string
	Running            string
	Terminated         string
	Failed             string
	ToggleBreakpoint   string
	RemoveBreakpoint   string
	Breakpoints        string
	NoBreakpoints      string
	Frames             string
	NoFrames           string
	OpenFrame          string
	NoAdapters         string
	NoDocument         string
	AttachHost         string
	AttachPort         string
	AttachInvalid      string
	RemoteAttach       string
	RemoteTitle        string
	RemoteCancel       string
	WaitingServer      string
	NoEndpoint         string
	TimedOut           string
	ConnectionClosed   string
	WriteTimedOut      string
	BufferLimit        string
	InvalidEndpoint    string
	// RemotePrompt asks whether to attach to a debuggee that is not local.
	RemotePrompt func(endpoint string) string
	// ConnectFailed reports a failed connection to the debug adapter.
	ConnectFailed func(endpoint string) string
}

func debugMessages(language Language) DebugMessages {
	return DebugMessages{
		PluginsUnavailable: Shared(language, "desktop.debug.pluginsUnavailable"),
		Start:              Shared(language, "desktop.debug.start"),
		Stop:               Shared(language, "desktop.debug.stop"),
		Continue:           Shared(language, "desktop.debug.continue"),
		Pause:              Shared(language, "desktop.debug.pause"),
		Starting:           Shared(language, "desktop.debug.starting"),
		Initialized:        Shared(language, "desktop.debug.initialized"),
		Paused:             Shared(language, "desktop.debug.paused"),
		Running:            Shared(language, "desktop.debug.running"),
		Terminated:         Shared(language, "desktop.debug.terminated"),
		Failed:             Shared(language, "desktop.debug.failed"),
		ToggleBreakpoint:   Shared(language, "desktop.debug.toggleBreakpoint"),
		RemoveBreakpoint:   Shared(language, "desktop.debug.removeBreakpoint"),
		Breakpoints:        Shared(language, "desktop.debug.breakpoints"),
		NoBreakpoints:      Shared(language, "desktop.debug.noBreakpoints"),
		Frames:             Shared(language, "desktop.debug.frames"),
		NoFrames:           Shared(language, "desktop.debug.noFrames"),
		OpenFrame:          Shared(language, "desktop.debug.openFrame"),
		NoAdapters:         Shared(language, "desktop.debug.noAdapters"),
		NoDocument:         Shared(language, "desktop.debug.noDocument"),
		AttachHost:         Shared(language, "desktop.debug.attachHost"),
		AttachPort:         Shared(language, "desktop.debug.attachPort"),
		AttachInvalid:      Shared(language, "desktop.debug.attachInvalid"),
		RemoteTitle:        Shared(language, "desktop.debug.remoteTitle"),
		RemoteAttach:       Shared(language, "desktop.debug.remoteAttach"),
		RemoteCancel:       Shared(language, "desktop.debug.remoteCancel"),
		WaitingServer:      Shared(language, "desktop.debug.waitingServer"),
		NoEndpoint:         Shared(language, "desktop.debug.noEndpoint"),
		TimedOut:           Shared(language, "desktop.debug.timedOut"),
		ConnectionClosed:   Shared(language, "desktop.debug.connectionClosed"),
		WriteTimedOut:      Shared(language, "desktop.debug.writeTimedOut"),
		BufferLimit:        Shared(language, "desktop.debug.bufferLimit"),
		InvalidEndpoint:    Shared(language, "desktop.debug.invalidEndpoint"),
		RemotePrompt: func(endpoint string) string {
			return SharedFormat(language, "desktop.debug.remotePrompt", map[string]string{"endpoint": endpoint})
		},
		ConnectFailed: func(endpoint string) string {
			return SharedFormat(language, "desktop.debug.connectFailed", map[string]string{"endpoint": endpoint})
		},
	}
}
