package workbench

import (
	"context"
	"encoding/json"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// processExitKernel is the part of Core that decides how the programs Lithe
// started end when the window or the project closes.
type processExitKernel interface {
	ResolveProcessLifecycle(ctx context.Context, lifecycleContext string, settings json.RawMessage, records []core.ProcessRecord) (core.ProcessPlan, error)
	SettleProcessLifecycle(ctx context.Context, settings json.RawMessage, decisions []core.ProcessSettlementDecision, answers map[string]string, remember bool) (core.ProcessSettlement, error)
}

// Lifecycle contexts of Core's exit plan.
const (
	exitContextQuit           = "quit"
	exitContextCloseWorkspace = "closeWorkspace"
	// exitContextCloseTerminal is closing one terminal tab. Closing a project ends
	// its terminals too, so they are decided as closed tabs then.
	exitContextCloseTerminal = "closeTerminalTab"
	// exitContextStartupSweep decides what an earlier run of the app left running.
	exitContextStartupSweep = "startupSweep"
)

// exitRecord is one running program of the closing project, with the name the
// confirmation shows for it.
type exitRecord struct {
	record core.ProcessRecord
	label  string
}

// exitTerminal is one terminal of the closing project: the name the confirmation
// shows and the probe that tells, off the window thread, whether its shell is running
// a program.
type exitTerminal struct {
	id    int
	label string
	busy  func() bool
}

// exitTerminals lists the terminals of p whose shell runs, for Core to decide whether
// ending them needs the user's word.
func (a *App) exitTerminals(p *project) []exitTerminal {
	var terminals []exitTerminal
	for _, t := range p.terms.list {
		if probe := t.view.BusyProbe(); probe != nil {
			label := i18n.SharedFormat(a.language(), "desktop.exit.terminal", map[string]string{"terminal": a.terminalTitle(t)})
			terminals = append(terminals, exitTerminal{id: t.id, label: label, busy: probe})
		}
	}
	return terminals
}

// terminalRecords asks each probe and describes the terminals as Core's records: a
// terminal whose shell runs no program is idle and ends without a question.
func terminalRecords(terminals []exitTerminal) []exitRecord {
	records := make([]exitRecord, len(terminals))
	for i, t := range terminals {
		records[i] = exitRecord{
			record: core.ProcessRecord{ID: "terminal:" + strconv.Itoa(t.id), Kind: "terminal", Ownership: "launched", Idle: !t.busy()},
			label:  t.label,
		}
	}
	return records
}

// needsConfirmation reports that Core wants the user asked before the record ends.
// confirm (a busy terminal) and confirmStop (a run) are both shown in the one list,
// because a closing window can keep neither: the only other answer is not closing.
func needsConfirmation(action string) bool {
	return action == "confirmStop" || action == "confirm"
}

// confirmationNames resolves records in lifecycleContext with the user's termination
// settings and lists the names of those the user must confirm.
func (a *App) confirmationNames(ctx context.Context, lifecycleContext string, settings json.RawMessage, records []exitRecord) ([]string, error) {
	if len(records) == 0 {
		return nil, nil
	}
	wire := make([]core.ProcessRecord, len(records))
	for i, record := range records {
		wire[i] = record.record
	}
	plan, err := a.kernel.ResolveProcessLifecycle(ctx, lifecycleContext, settings, wire)
	if err != nil {
		return nil, err
	}
	var names []string
	for index, decision := range plan.Decisions {
		if needsConfirmation(decision.Action) && index < len(records) {
			names = append(names, "• "+records[index].label)
		}
	}
	return names, nil
}

// runningExitRecords lists what Lithe started in this project and still owns:
// the plugin-started Run sessions and the debug session. Core decides what each
// one means for closing; the host only says what exists. Terminals are listed by
// exitTerminals, because whether one is busy is read off the window thread.
func (a *App) runningExitRecords(p *project) []exitRecord {
	var records []exitRecord
	for _, entry := range p.build.runs {
		if entry.running {
			records = append(records, exitRecord{record: core.ProcessRecord{ID: "run:" + entry.id, Kind: "run", Ownership: "launched"}, label: entry.label})
		}
	}
	// Every live debug session owns an adapter process, a child session included.
	for _, session := range p.debug.sessions {
		name := session.adapter.Declaration.DisplayName
		records = append(records, exitRecord{
			record: core.ProcessRecord{ID: "debug:" + session.id, Kind: "debugAdapter", Ownership: "launched"},
			label:  i18n.SharedFormat(a.language(), "desktop.exit.debugSession", map[string]string{"adapter": name}),
		})
	}
	return records
}

// confirmProcessExit asks before a close that would end programs the user may
// not want ended, then calls proceed. Core's plan says which records need the
// question: the runs it marks confirmStop and the busy terminals it marks
// confirm are listed in one confirmation whose only choices are stopping all of
// them or cancelling the close. Closing a project decides its terminals as
// closed tabs, since they cannot outlive it. With nothing to confirm, proceed
// runs at once. A plan that cannot be had is not a reason to trap the user in
// the window, so proceed runs and the error is logged.
func (a *App) confirmProcessExit(p *project, lifecycleContext string, proceed func()) {
	records := a.runningExitRecords(p)
	terminals := a.exitTerminals(p)
	if len(records) == 0 && len(terminals) == 0 {
		proceed()
		return
	}
	terminalContext := exitContextCloseTerminal
	if lifecycleContext == exitContextQuit {
		terminalContext = exitContextQuit
	}
	settings := terminationSettings(a.settings.ProcessTermination)
	a.background(nil, debugOperationTimeout, func(ctx context.Context) func(*App) {
		names, err := a.confirmationNames(ctx, lifecycleContext, settings, records)
		if err == nil {
			var terminalNames []string
			terminalNames, err = a.confirmationNames(ctx, terminalContext, settings, terminalRecords(terminals))
			names = append(names, terminalNames...)
		}
		return func(a *App) {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("process_exit_plan", err))
				proceed()
				return
			}
			if len(names) == 0 {
				proceed()
				return
			}
			language := a.language()
			a.prompts.queue = append(a.prompts.queue, &pluginPrompt{
				title: i18n.Shared(language, "desktop.exit.title"),
				text:  i18n.SharedFormat(language, "desktop.exit.body", map[string]string{"processes": strings.Join(names, "\n")}),
				actions: []string{
					i18n.Shared(language, "desktop.exit.cancel"),
					i18n.Shared(language, "desktop.exit.stopAndClose"),
				},
				onAnswer: func(choice *int) {
					if choice != nil && *choice == 1 {
						proceed()
					}
				},
			})
		}
	})
}

// requestCloseTerminal closes terminal id for the user, first asking when its shell is
// running a program: Core decides with the "confirm before closing a terminal tab" rule.
// A terminal with no running shell closes at once. A plan that cannot be had does not
// keep the tab open, so the tab closes and the error is logged.
func (a *App) requestCloseTerminal(p *project, id int) {
	t := p.terms.find(id)
	if t == nil {
		return
	}
	probe := t.view.BusyProbe()
	if probe == nil {
		a.closeTerminal(p, id)
		return
	}
	title := a.terminalTitle(t)
	terminals := []exitTerminal{{id: id, label: title, busy: probe}}
	settings := terminationSettings(a.settings.ProcessTermination)
	a.background(nil, debugOperationTimeout, func(ctx context.Context) func(*App) {
		names, err := a.confirmationNames(ctx, exitContextCloseTerminal, settings, terminalRecords(terminals))
		return func(a *App) {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("terminal_close_plan", err))
			}
			if err != nil || len(names) == 0 {
				a.closeTerminal(p, id)
				return
			}
			language := a.language()
			a.prompts.queue = append(a.prompts.queue, &pluginPrompt{
				title: i18n.Shared(language, "desktop.terminal.closeBusyTitle"),
				text:  i18n.SharedFormat(language, "desktop.terminal.closeBusyBody", map[string]string{"terminal": title}),
				actions: []string{
					i18n.Shared(language, "desktop.exit.cancel"),
					i18n.Shared(language, "desktop.terminal.closeBusyConfirm"),
				},
				onAnswer: func(choice *int) {
					if choice != nil && *choice == 1 {
						a.closeTerminal(p, id)
					}
				},
			})
		}
	})
}

// setProcessTermination stores the Process Termination page's settings. The next close
// decides with them, and the stop time they give applies from Core's answer on.
func (a *App) setProcessTermination(value settingswindow.ProcessTermination) {
	a.settings.ProcessTermination = value
	a.saveSettings()
	a.refreshStopGrace()
}

// refreshStopGrace has Core resolve the stop time of the current termination settings and
// hands it to the processes Lithe stops (buildprocess.SetStopGrace). Until Core answers,
// processes keep the time they had: at start-up that is none, so one stopped before the
// answer is killed at once. An answer for settings that changed since is dropped, because the
// refresh of the newer ones is on its way. The first refresh also reads Core's rule for the
// stop time, which the Process Termination page shows.
func (a *App) refreshStopGrace() {
	if a.kernel == nil {
		return
	}
	a.stopGraceRequest++
	request, settings := a.stopGraceRequest, terminationSettings(a.settings.ProcessTermination)
	readRule := a.stopTime.Load() == nil
	a.background(nil, debugOperationTimeout, func(ctx context.Context) func(*App) {
		grace, err := resolveStopTime(ctx, a.kernel, settings)
		var rule *settingswindow.StopTime
		if err == nil && readRule {
			var read settingswindow.StopTime
			if read, err = stopTimeRule(ctx, a.kernel); err == nil {
				rule = &read
			}
		}
		return func(a *App) {
			if rule != nil {
				a.stopTime.Store(rule)
			}
			if request != a.stopGraceRequest {
				return
			}
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("process_stop_grace", err))
				return
			}
			buildprocess.SetStopGrace(grace)
			if a.settingsWindow != nil {
				a.settingsWindow.Invalidate()
			}
		}
	})
}

// resolveStopTime is the stop time Core gives settings.
func resolveStopTime(ctx context.Context, kernel processExitKernel, settings json.RawMessage) (time.Duration, error) {
	plan, err := kernel.ResolveProcessLifecycle(ctx, exitContextQuit, settings, nil)
	if err != nil {
		return 0, err
	}
	return time.Duration(plan.GracefulStopMilliseconds) * time.Millisecond, nil
}

// stopTimeRule reads Core's rule for the stop time: the time it gives no stored time, the
// smallest stored time and the largest. Core does not publish its limits, so they are the
// times it resolves for the smallest and the largest number a setting can hold; #1830 has Core
// publish them instead.
func stopTimeRule(ctx context.Context, kernel processExitKernel) (settingswindow.StopTime, error) {
	var seconds [3]int
	for i, stored := range []*uint32{nil, new(uint32), new(uint32(math.MaxUint32))} {
		grace, err := resolveStopTime(ctx, kernel, terminationSettings(settingswindow.ProcessTermination{GracefulStopSeconds: stored}))
		if err != nil {
			return settingswindow.StopTime{}, err
		}
		seconds[i] = int(grace / time.Second)
	}
	return settingswindow.StopTime{Default: seconds[0], Min: seconds[1], Max: seconds[2]}, nil
}

// stopTimeOption is how the Process Termination page reads Core's rule for the stop time once
// refreshStopGrace has read it; it is safe from any thread. It is nil where a stopped program
// is ended at once (buildprocess.StopsGracefully), so the page leaves the stop time out.
func (a *App) stopTimeOption() func() (settingswindow.StopTime, bool) {
	if !buildprocess.StopsGracefully {
		return nil
	}
	return func() (settingswindow.StopTime, bool) {
		if rule := a.stopTime.Load(); rule != nil {
			return *rule, true
		}
		return settingswindow.StopTime{}, false
	}
}

// terminationSettings is the settings as Core's TerminationSettings JSON: only the fields
// the user changed, so Core supplies the defaults of the rest.
func terminationSettings(value settingswindow.ProcessTermination) json.RawMessage {
	data, err := json.Marshal(value)
	if err != nil || string(data) == "{}" {
		return nil
	}
	return data
}
