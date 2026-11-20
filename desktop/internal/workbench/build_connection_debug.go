package workbench

import (
	"context"
	"errors"
	"net"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// Registry connection debugging of build provider service runs: a run declares a public debug
// adapter type (`debug.configurationType`) instead of an adapter of its own plugin. The host
// selects the one enabled adapter of that type that attaches over a connection, chooses a
// loopback port, asks the provider to prepare the service suspended on that port
// (`launchOptions.debug`), starts it as an ordinary run and attaches the adapter once the port
// accepts. The run and the debug session end together. The contract is Core's "Registry
// connection debugging"; the adapter may belong to any plugin.

// connectionDebug is one debug launch of a service run: the adapter the host selected, kept to
// attach exactly that registration, and the debug options the provider prepares the run with.
type connectionDebug struct {
	adapter debugAdapter
	launch  core.RunLaunchDebug
}

// connectionDebugRefusal is why no adapter can attach to a run's declared type: reason is the
// fixed log token, message the notice.
type connectionDebugRefusal struct {
	reason, message string
}

func (r *connectionDebugRefusal) Error() string { return r.reason }

// connectionDebugAdapter selects the enabled adapter that attaches over a connection and answers
// to configurationType. None, or more than one, is refused: nothing would attach to a suspended
// service, and picking one of several would be a guess.
func (a *App) connectionDebugAdapter(p *project, configurationType string) (debugAdapter, error) {
	var matches []debugAdapter
	for _, adapter := range p.debug.adapters {
		if adapter.Declaration.Serves("attach") && adapter.Declaration.AcceptsConnection &&
			slices.Contains(adapter.Declaration.ConfigurationTypes, configurationType) {
			matches = append(matches, adapter)
		}
	}
	lang := a.language()
	switch len(matches) {
	case 1:
		return matches[0], nil
	case 0:
		return debugAdapter{}, &connectionDebugRefusal{"no_adapter", i18n.SharedFormat(lang, "desktop.build.noConnectionDebugAdapter", map[string]string{"type": configurationType})}
	}
	names := make([]string, len(matches))
	for index, adapter := range matches {
		names[index] = adapter.Declaration.DisplayName
	}
	return debugAdapter{}, &connectionDebugRefusal{"ambiguous_adapter", i18n.SharedFormat(lang, "desktop.build.ambiguousConnectionDebugAdapter", map[string]string{
		"type": configurationType, "adapters": strings.Join(names, ", "),
	})}
}

// sameDebugAdapter reports whether two adapters are the same registration of the same installed
// plugin version.
func sameDebugAdapter(a, b debugAdapter) bool {
	return a.PluginID == b.PluginID && a.Version == b.Version && a.Directory == b.Directory && a.Declaration.ID == b.Declaration.ID
}

// freeLoopbackPort returns a loopback TCP port nothing listens on now; the debuggee binds it.
func freeLoopbackPort() (int, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	port := listener.Addr().(*net.TCPAddr).Port
	return port, listener.Close()
}

// prepareConnectionDebug selects the adapter for a run's declared type once the installed
// adapters are read, chooses the port and hands both to start, on the window thread. A debug
// session that already runs, or a refused selection, starts nothing and says why.
func (a *App) prepareConnectionDebug(p *project, configurationType string, start func(connectionDebug)) {
	if p == nil {
		return
	}
	a.whenDebugAdaptersLoaded(p, func() {
		if p.debug.activeSession() != nil {
			a.operationRejected("build_debug_connection", "session_running")
			a.notifyInfo(i18n.Shared(a.language(), "desktop.build.debugSessionRunning"))
			return
		}
		adapter, err := a.connectionDebugAdapter(p, configurationType)
		if err != nil {
			var refusal *connectionDebugRefusal
			if errors.As(err, &refusal) {
				a.operationRejected("build_debug_connection", refusal.reason)
				a.notifyError(refusal.message)
			}
			return
		}
		port, err := freeLoopbackPort()
		if err != nil {
			a.operationFailed("build_debug_port", err)
			a.notifyError(err.Error())
			return
		}
		start(connectionDebug{adapter: adapter, launch: core.RunLaunchDebug{
			AdapterID:         adapter.PluginID + "/" + adapter.Declaration.ID,
			ConfigurationType: configurationType,
			Target:            core.RunDebugConnection{Kind: "connection", Host: "127.0.0.1", Port: port},
		}})
	})
}

// debugRunConfiguration debugs configuration id, whose run declares a public debug type: the
// configuration's saved launch options apply as for Run, with the debuggee suspended for the
// selected adapter.
func (a *App) debugRunConfiguration(p *project, id, configurationType string) {
	a.prepareConnectionDebug(p, configurationType, func(debug connectionDebug) {
		// A run of the configuration that runs is stopped first and debugged once it ended.
		a.startRun(p, configurationRunKey(id), func(a *App, p *project) {
			// log-exempt: reported：startRunConfigurationWith reports why a start cannot happen.
			_, _ = a.startRunConfigurationWith(p, id, &debug)
		})
	})
}

// debugServiceTarget debugs one target of the selected instance through run, a service run that
// declares a public debug type, with the launch options of a run that has no configuration.
func (a *App) debugServiceTarget(p *project, targetID string, run pluginservice.BuildRunDeclaration) {
	a.prepareConnectionDebug(p, run.DebugConfigurationType, func(debug connectionDebug) {
		a.startBuildTarget(p, targetID, run, &debug)
	})
}

// attachServiceDebugger waits off the window thread until the debuggee listens on its port, then
// attaches the selected adapter on the window thread. A debuggee that never listens ends the run
// with the reason; one that exits first ends the run the ordinary way, as its exit reports.
func (a *App) attachServiceDebugger(ctx context.Context, p *project, op *buildOperation, debug connectionDebug, ended <-chan struct{}) {
	err := pluginservice.WaitForDebugPort(ctx, debug.launch.Target.Port, ended, pluginservice.RunDebugConnectTimeout)
	a.post(func(a *App) {
		if a.project != p || !p.build.owns(op) || op.cancelled {
			return
		}
		switch {
		case err == nil:
			// A plugin change since the selection is read first, so the adapter is checked
			// against the plugins as they are now.
			a.whenDebugAdaptersLoaded(p, func() {
				if p.build.owns(op) && !op.cancelled {
					a.attachServiceDebugSession(p, op, debug)
				}
			})
		case errors.Is(err, pluginservice.ErrDebuggeeEnded) || errors.Is(err, context.Canceled):
		default:
			a.operationFailed("build_debug_attach", err)
			a.notifyError(i18n.SharedFormat(a.language(), "desktop.build.debugPortTimeout", map[string]string{
				"seconds": strconv.Itoa(int(pluginservice.RunDebugConnectTimeout.Seconds())),
			}))
			a.stopOperation(p, op)
		}
	})
}

// attachServiceDebugSession starts the debug session on the selected adapter, which must still
// be installed and enabled as selected, attached to the service's port. The session owns the
// run: stopping it stops the service.
func (a *App) attachServiceDebugSession(p *project, op *buildOperation, debug connectionDebug) {
	index := slices.IndexFunc(p.debug.adapters, func(adapter debugAdapter) bool { return sameDebugAdapter(adapter, debug.adapter) })
	if index < 0 {
		a.operationFailed("build_debug_attach", errors.New("the selected debug adapter was disabled or replaced"))
		a.notifyError(i18n.SharedFormat(a.language(), "desktop.build.connectionDebugAdapterGone", map[string]string{"name": debug.adapter.Declaration.DisplayName}))
		a.stopOperation(p, op)
		return
	}
	if p.debug.activeSession() != nil {
		a.operationRejected("build_debug_connection", "session_running")
		a.notifyInfo(i18n.Shared(a.language(), "desktop.build.debugSessionRunning"))
		a.stopOperation(p, op)
		return
	}
	a.beginDebug(p, debugStart{
		adapter: p.debug.adapters[index], request: "attach", confirmed: true,
		target: &core.DebugTargetFacts{Kind: "connection", Host: debug.launch.Target.Host, Port: debug.launch.Target.Port},
		// Release calls stopRun off the window thread.
		stopRun: func() {
			a.post(func(a *App) { a.stopOperation(p, op) })
		},
	})
	session := p.debug.activeSession()
	if session == nil {
		// beginDebug reported why the session did not start; nothing debugs the suspended service.
		a.stopOperation(p, op)
		return
	}
	op.debugSession = session
}

// endServiceDebugSession ends the debug session attached to op's service once the service
// ended, so a session never outlives the process it debugs.
func (a *App) endServiceDebugSession(p *project, op *buildOperation) {
	session := op.debugSession
	if session == nil || !slices.Contains(p.debug.sessions, session) {
		return
	}
	a.endDebugSession(p, session)
}
