package workbench

import (
	"context"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/processledger"
	"github.com/vivaui/viva/ui"
)

// startupSweepState is the start-up confirmation of the processes an earlier run of the app
// left behind. Nothing is ended before the user answers; dismissing the dialog leaves them recorded,
// so the next start asks again.
type startupSweepState struct {
	open      bool
	leftovers []processledger.Record
}

// startupSweepTimeout bounds the ending of the confirmed leftovers.
const startupSweepTimeout = 10 * time.Second

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
					"arg1": strconv.Itoa(record.PID), "arg2": record.Command,
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

// settleStartupSweep applies the answer off the window thread. The dialog closes at once; the
// ending itself is bounded.
func (a *App) settleStartupSweep(end bool) {
	service := a.plugins
	a.startupSweep = startupSweepState{}
	if service == nil {
		return
	}
	a.background(nil, startupSweepTimeout, func(ctx context.Context) func(*App) {
		ended, err := service.SettleStartupLeftovers(ctx, end)
		return func(a *App) {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("startup_sweep", err))
				return
			}
			a.emit(core.LevelInfo, "app.action.performed", map[string]any{"action": "startupSweep", "surface": "dialog", "ended": ended})
		}
	})
}
