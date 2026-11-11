package i18n

import "strconv"

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
	Variables          string
	Exceptions         string
	Disassembly        string
	NoVariables        string
	LoadingVariables   string
	LoadMore           string
	ViewTree           string
	ViewJSON           string
	EditValue          string
	SetValue           string
	NoExceptionFilters string
	NoDisassembly      string
	LoadBefore         string
	LoadAfter          string
	Reload             string
	EndOfCode          string
	BufferLimit        string
	InvalidEndpoint    string
	// RemotePrompt asks whether to attach to a debuggee that is not local.
	RemotePrompt func(endpoint string) string
	// ConnectFailed reports a failed connection to the debug adapter.
	ConnectFailed func(endpoint string) string
	// Threads names the thread selector and ThreadFallback words a thread without a name.
	Threads        string
	ThreadFallback func(id int) string
	// Watches, WatchPlaceholder, AddWatch, RemoveWatch and EvaluateFailed are the watch editor.
	Watches          string
	WatchPlaceholder string
	AddWatch         string
	RemoveWatch      string
	EvaluateFailed   string
	// Memory, NoMemory and MemoryUnreadableBytes are the read-only memory view,
	// and StepInto, StepOver and StepOut step the disassembly one instruction.
	Memory                string
	NoMemory              string
	MemoryUnreadableBytes func(bytes int) string
	StepInto              string
	StepOver              string
	StepOut               string
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
		Variables:          Shared(language, "desktop.debug.variables"),
		Exceptions:         Shared(language, "desktop.debug.exceptions"),
		Disassembly:        Shared(language, "desktop.debug.disassembly"),
		NoVariables:        Shared(language, "desktop.debug.noVariables"),
		LoadingVariables:   Shared(language, "desktop.debug.loadingVariables"),
		LoadMore:           Shared(language, "desktop.debug.loadMore"),
		ViewTree:           Shared(language, "desktop.debug.viewTree"),
		ViewJSON:           Shared(language, "desktop.debug.viewJson"),
		EditValue:          Shared(language, "desktop.debug.editValue"),
		SetValue:           Shared(language, "desktop.debug.setValue"),
		NoExceptionFilters: Shared(language, "desktop.debug.noExceptionFilters"),
		NoDisassembly:      Shared(language, "desktop.debug.noDisassembly"),
		LoadBefore:         Shared(language, "desktop.debug.loadBefore"),
		LoadAfter:          Shared(language, "desktop.debug.loadAfter"),
		Reload:             Shared(language, "desktop.debug.reload"),
		EndOfCode:          Shared(language, "desktop.debug.endOfCode"),
		BufferLimit:        Shared(language, "desktop.debug.bufferLimit"),
		InvalidEndpoint:    Shared(language, "desktop.debug.invalidEndpoint"),
		RemotePrompt: func(endpoint string) string {
			return SharedFormat(language, "desktop.debug.remotePrompt", map[string]string{"endpoint": endpoint})
		},
		ConnectFailed: func(endpoint string) string {
			return SharedFormat(language, "desktop.debug.connectFailed", map[string]string{"endpoint": endpoint})
		},
		Threads: Shared(language, "desktop.debug.threads"),
		ThreadFallback: func(id int) string {
			return SharedFormat(language, "desktop.debug.threadFallback", map[string]string{"id": strconv.Itoa(id)})
		},
		Watches:          Shared(language, "desktop.debug.watches"),
		WatchPlaceholder: Shared(language, "desktop.debug.watchPlaceholder"),
		AddWatch:         Shared(language, "desktop.debug.addWatch"),
		RemoveWatch:      Shared(language, "desktop.debug.removeWatch"),
		EvaluateFailed:   Shared(language, "desktop.debug.evaluateFailed"),
		Memory:           Shared(language, "desktop.debug.memory"),
		NoMemory:         Shared(language, "desktop.debug.noMemory"),
		MemoryUnreadableBytes: func(bytes int) string {
			return SharedFormat(language, "desktop.debug.memoryUnreadableBytes", map[string]string{"bytes": strconv.Itoa(bytes)})
		},
		StepInto: Shared(language, "desktop.debug.stepInto"),
		StepOver: Shared(language, "desktop.debug.stepOver"),
		StepOut:  Shared(language, "desktop.debug.stepOut"),
	}
}
