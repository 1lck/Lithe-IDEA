package workbench

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// processExitKernel is the part of Core that decides how the programs Lithe
// started end when the window or the project closes.
type processExitKernel interface {
	ResolveProcessLifecycle(ctx context.Context, lifecycleContext string, settings json.RawMessage, records []core.ProcessRecord) (core.ProcessPlan, error)
}

// Lifecycle contexts of Core's exit plan.
const (
	exitContextQuit           = "quit"
	exitContextCloseWorkspace = "closeWorkspace"
	// exitContextCloseTerminal is closing one terminal tab. Closing a project ends
	// its terminals too, so they are decided as closed tabs then.
	exitContextCloseTerminal = "closeTerminalTab"
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
//
// Agent tasks are not listed: the Agent panel keeps its own tasks.
func (a *App) runningExitRecords(p *project) []exitRecord {
	var records []exitRecord
	for _, entry := range p.build.runs {
		if entry.running {
			records = append(records, exitRecord{record: core.ProcessRecord{ID: "run:" + entry.id, Kind: "run", Ownership: "launched"}, label: entry.label})
		}
	}
	if d := &p.debug; d.activeSession() != nil && len(d.adapters) > 0 {
		name := d.adapters[d.selectedAdapter].Declaration.DisplayName
		records = append(records, exitRecord{
			record: core.ProcessRecord{ID: "debug:" + d.activeSession().id, Kind: "debugAdapter", Ownership: "launched"},
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
// decides with them.
func (a *App) setProcessTermination(value settingswindow.ProcessTermination) {
	a.settings.ProcessTermination = value
	a.saveSettings()
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
