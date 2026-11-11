package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/processledger"
	"github.com/vivaui/viva/ui"
)

// startupSweepState is the start-up question about the processes an earlier run of the app left
// behind that Core wants asked about. None of them is ended before the user answers; dismissing
// the question leaves them recorded, so the next start decides them again.
type startupSweepState struct {
	open      bool
	leftovers []processledger.Record
	// decisions are Core's decisions about leftovers, in the same order, which the answer is
	// settled with. They are nil when Core could not decide, and the answer is then applied as
	// given.
	decisions []core.ProcessDecision
	// settings are the termination settings the plan was made with.
	settings json.RawMessage
	// grace is how long an ended leftover gets to stop before it is killed.
	grace time.Duration
}

// leftoverRecord describes leftover number index as Core's record. The ledger only holds
// processes this app started, so each one is launched. Whether a terminal's shell was running
// a program cannot be told after the fact, so a terminal is not idle.
func leftoverRecord(index int, record processledger.Record) core.ProcessRecord {
	kind := "run"
	switch record.Kind {
	case processledger.KindTerminal:
		kind = "terminal"
	case processledger.KindBuild:
		kind = "oneShot"
	case processledger.KindDebug:
		kind = "debugAdapter"
	case processledger.KindProcess:
		kind = "pluginTool"
	}
	return core.ProcessRecord{ID: strconv.Itoa(index), Kind: kind, Ownership: "launched"}
}

// startupSweepKindLabel is the category label of one leftover: a run, a terminal, a build, a debug
// adapter or another process. A record written before kinds existed is a run.
func startupSweepKindLabel(language i18n.Language, kind string) string {
	switch kind {
	case processledger.KindTerminal:
		return i18n.Shared(language, "desktop.startupSweep.kind.terminal")
	case processledger.KindBuild:
		return i18n.Shared(language, "desktop.startupSweep.kind.build")
	case processledger.KindDebug:
		return i18n.Shared(language, "desktop.startupSweep.kind.debug")
	case processledger.KindProcess:
		return i18n.Shared(language, "desktop.startupSweep.kind.process")
	}
	return i18n.Shared(language, "desktop.startupSweep.kind.run")
}

// startupSweepTimeout bounds Core's plan and settlement of the leftovers, and, beyond their stop
// time, the ending of the ones that end.
const startupSweepTimeout = 10 * time.Second

// planStartupSweep has Core decide the processes an earlier run of the app left behind
// (processLifecycle.resolve in the startupSweep context) and acts on the plan: the ones Core
// ends are ended at once, the ones it asks about are listed in the start-up question, and the
// rest are forgotten and keep running. A plan that cannot be had asks about every leftover,
// since asking is the only choice that cannot end something the user wanted to keep.
func (a *App) planStartupSweep() {
	service := a.plugins
	if service == nil || a.kernel == nil {
		return
	}
	leftovers := service.StartupLeftovers()
	if len(leftovers) == 0 {
		return
	}
	settings := terminationSettings(a.settings.ProcessTermination)
	records := make([]core.ProcessRecord, len(leftovers))
	for i, record := range leftovers {
		records[i] = leftoverRecord(i, record)
	}
	a.background(nil, startupSweepTimeout, func(ctx context.Context) func(*App) {
		plan, err := a.kernel.ResolveProcessLifecycle(ctx, exitContextStartupSweep, settings, records)
		if err == nil && len(plan.Decisions) != len(leftovers) {
			err = fmt.Errorf("the plan decided %d of %d leftovers", len(plan.Decisions), len(leftovers))
		}
		return func(a *App) {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("startup_sweep_plan", err))
				a.startupSweep = startupSweepState{open: true, leftovers: leftovers, settings: settings, grace: buildprocess.StopGrace()}
				return
			}
			grace := time.Duration(plan.GracefulStopMilliseconds) * time.Millisecond
			question := startupSweepState{settings: settings, grace: grace}
			var ended, kept []processledger.Record
			for i, decision := range plan.Decisions {
				switch decision.Action {
				case "terminate":
					ended = append(ended, leftovers[i])
				case "ask", "confirm":
					question.leftovers = append(question.leftovers, leftovers[i])
					question.decisions = append(question.decisions, decision)
				default:
					kept = append(kept, leftovers[i])
				}
			}
			a.settleLeftovers(ended, kept, grace, "policy")
			question.open = len(question.leftovers) > 0
			a.startupSweep = question
		}
	})
}

// settleLeftovers forgets ended and kept off the window thread, ending the ones in ended with
// grace to stop before they are killed. surface says what decided them: Core's policy or the
// user's answer.
func (a *App) settleLeftovers(ended, kept []processledger.Record, grace time.Duration, surface string) {
	service := a.plugins
	if service == nil || len(ended)+len(kept) == 0 {
		return
	}
	a.background(nil, grace+startupSweepTimeout, func(ctx context.Context) func(*App) {
		_, keepErr := service.SettleStartupLeftovers(ctx, kept, false, 0)
		count, endErr := service.SettleStartupLeftovers(ctx, ended, true, grace)
		err := errors.Join(keepErr, endErr)
		return func(a *App) {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("startup_sweep", err))
				return
			}
			a.emit(core.LevelInfo, "app.action.performed", map[string]any{"action": "startupSweep", "surface": surface, "ended": count, "kept": len(kept)})
		}
	})
}

// drawStartupSweep declares the start-up confirmation while it is open.
func (a *App) drawStartupSweep(c ui.C) {
	s := &a.startupSweep
	if !s.open {
		return
	}
	language := a.language()
	open := true
	closed := ui.ModalWith(c, &open, i18n.Shared(language, "desktop.startupSweep.title"), ui.ModalSpec{Width: 460}, func() {
		ui.Column(c.Part("startup-sweep")).FillWidth().Gap(8).Children(func() {
			ui.Paragraph(c, i18n.SharedFormat(language, "desktop.startupSweep.body", map[string]string{"arg1": strconv.Itoa(len(s.leftovers))}), 4).
				FontSize(a.theme.Metrics.FontSizeS)
			for _, record := range s.leftovers {
				ui.Text(c, i18n.SharedFormat(language, "desktop.startupSweep.item", map[string]string{
					"arg1": startupSweepKindLabel(language, record.Kind), "arg2": strconv.Itoa(record.PID), "arg3": record.Command,
				})).FontSize(a.theme.Metrics.FontSizeS).Ellipsis()
			}
		})
	}, func() {
		if ui.Button(c.Part("startup-sweep-keep"), i18n.Shared(language, "desktop.startupSweep.keep")).Outline().Clicked() {
			c.After(func() { a.settleStartupSweep(false) })
		}
		if ui.Button(c.Part("startup-sweep-end"), i18n.Shared(language, "desktop.startupSweep.end")).Clicked() {
			c.After(func() { a.settleStartupSweep(true) })
		}
	})
	if closed {
		c.After(func() { a.startupSweep.open = false })
	}
}

// settleStartupSweep applies the answer to the start-up question: Core settles it with the
// plan's decisions (processLifecycle.settle), and the leftovers it ends are ended, the others
// forgotten. The question closes at once; the ending itself is bounded. A settlement that
// cannot be had ends nothing and leaves the leftovers recorded, so the next start asks again.
func (a *App) settleStartupSweep(end bool) {
	question := a.startupSweep
	a.startupSweep = startupSweepState{}
	if question.decisions == nil {
		// Core made no plan, so there is nothing to settle the answer with.
		if end {
			a.settleLeftovers(question.leftovers, nil, question.grace, "dialog")
		} else {
			a.settleLeftovers(nil, question.leftovers, question.grace, "dialog")
		}
		return
	}
	answer := "keep"
	if end {
		answer = "terminate"
	}
	decisions := make([]core.ProcessSettlementDecision, len(question.decisions))
	answers := make(map[string]string, len(question.decisions))
	byID := make(map[string]processledger.Record, len(question.decisions))
	for i, decision := range question.decisions {
		decisions[i] = core.ProcessSettlementDecision{ID: decision.ID, Action: decision.Action}
		answers[decision.ID] = answer
		byID[decision.ID] = question.leftovers[i]
	}
	a.background(nil, startupSweepTimeout, func(ctx context.Context) func(*App) {
		settlement, err := a.kernel.SettleProcessLifecycle(ctx, question.settings, decisions, answers, false)
		return func(a *App) {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("startup_sweep_settle", err))
				return
			}
			pick := func(ids []string) []processledger.Record {
				var picked []processledger.Record
				for _, id := range ids {
					if record, ok := byID[id]; ok {
						picked = append(picked, record)
					}
				}
				return picked
			}
			a.settleLeftovers(pick(settlement.Terminate), pick(settlement.Keep), question.grace, "dialog")
		}
	})
}
