package workbench

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
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
)

// exitRecord is one running program of the closing project, with the name the
// confirmation shows for it.
type exitRecord struct {
	record core.ProcessRecord
	label  string
}

// runningExitRecords lists what Lithe started in this project and still owns:
// the plugin-started Run sessions and the debug session. Core decides what each
// one means for closing; the host only says what exists.
//
// Terminals and Agent tasks are not listed: this client has no foreground
// process probe for a terminal and the Agent panel keeps its own tasks.
func (a *App) runningExitRecords(p *project) []exitRecord {
	var records []exitRecord
	for _, entry := range p.build.runs {
		if entry.running {
			records = append(records, exitRecord{record: core.ProcessRecord{ID: "run:" + entry.id, Kind: "run", Ownership: "launched"}, label: entry.label})
		}
	}
	if d := &p.debug; d.session != nil && len(d.adapters) > 0 {
		name := d.adapters[d.selectedAdapter].Declaration.DisplayName
		records = append(records, exitRecord{
			record: core.ProcessRecord{ID: "debug:" + d.session.id, Kind: "debugAdapter", Ownership: "launched"},
			label:  i18n.SharedFormat(a.language(), "desktop.exit.debugSession", map[string]string{"adapter": name}),
		})
	}
	return records
}

// confirmProcessExit asks before a close that would end programs the user may
// not want ended, then calls proceed. Core's plan says which records need the
// question: every confirmStop record is listed in one confirmation whose only
// choices are stopping all of them or cancelling the close. With nothing to
// confirm, proceed runs at once. A plan that cannot be had is not a reason to
// trap the user in the window, so proceed runs and the error is logged.
func (a *App) confirmProcessExit(p *project, lifecycleContext string, proceed func()) {
	records := a.runningExitRecords(p)
	if len(records) == 0 {
		proceed()
		return
	}
	wire := make([]core.ProcessRecord, len(records))
	for i, record := range records {
		wire[i] = record.record
	}
	a.background(nil, debugOperationTimeout, func(ctx context.Context) func(*App) {
		plan, err := a.kernel.ResolveProcessLifecycle(ctx, lifecycleContext, nil, wire)
		return func(a *App) {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("process_exit_plan", err))
				proceed()
				return
			}
			var names []string
			for index, decision := range plan.Decisions {
				if decision.Action == "confirmStop" && index < len(records) {
					names = append(names, "• "+records[index].label)
				}
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
