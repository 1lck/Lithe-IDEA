package workbench

import (
	"context"
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

// Watches are expressions the user evaluates in the paused debuggee. Core owns the DAP
// evaluate request and its result; this file keeps the list and re-evaluates it whenever the
// debuggee stops again, so the values shown always belong to the current stop.

// debugWatchEntry is one expression and the value it last evaluated to.
type debugWatchEntry struct {
	expression string
	value      string
	typeName   string
	failure    string
}

// debugWatch is the Variables section's watch list and its editor.
type debugWatch struct {
	entries []debugWatchEntry
	input   string
	// history is the expressions evaluated in this session, oldest first and without repeats, and
	// pick is what the recent-expressions picker chose last.
	history []string
	pick    string
}

// maxWatchHistory bounds the recent expressions the picker offers.
const maxWatchHistory = 20

// rememberExpression moves an evaluated expression to the end of the history.
func (w *debugWatch) rememberExpression(expression string) {
	w.history = slices.DeleteFunc(w.history, func(item string) bool { return item == expression })
	w.history = append(w.history, expression)
	if len(w.history) > maxWatchHistory {
		w.history = w.history[len(w.history)-maxWatchHistory:]
	}
}

// valuesCleared drops the values of one stop but keeps the expressions: the next stop
// evaluates them again.
func (w *debugWatch) valuesCleared() {
	for index := range w.entries {
		w.entries[index].value, w.entries[index].typeName, w.entries[index].failure = "", "", ""
	}
}

// addDebugWatch adds the typed expression and evaluates it at the current frame.
func (a *App) addDebugWatch(p *project) {
	d := &p.debug
	expression := strings.TrimSpace(d.watch.input)
	if expression == "" || d.activeSession() == nil || d.state != "paused" {
		return
	}
	d.watch.entries = append(d.watch.entries, debugWatchEntry{expression: expression})
	d.watch.rememberExpression(expression)
	d.watch.input = ""
	index := len(d.watch.entries) - 1
	a.evaluateDebugWatch(p, index)
}

// removeDebugWatch drops one expression.
func (a *App) removeDebugWatch(p *project, index int) {
	d := &p.debug
	if index < 0 || index >= len(d.watch.entries) {
		return
	}
	d.watch.entries = append(d.watch.entries[:index], d.watch.entries[index+1:]...)
}

// refreshDebugWatches evaluates every expression at the current stop's first frame. It is
// called after a stack loads, so an expression is never evaluated against a stale frame.
func (a *App) refreshDebugWatches(p *project) {
	d := &p.debug
	if d.activeSession() == nil || len(d.watch.entries) == 0 || len(d.frames) == 0 {
		return
	}
	for index := range d.watch.entries {
		a.evaluateDebugWatch(p, index)
	}
}

// evaluateDebugWatch asks Core for one expression's value with the DAP "watch" context at
// the selected frame. A result that arrives after another stop is dropped by the generation
// check in debugOperation's completion path.
func (a *App) evaluateDebugWatch(p *project, index int) {
	d := &p.debug
	if index < 0 || index >= len(d.watch.entries) || d.activeSession() == nil || len(d.frames) == 0 {
		return
	}
	frameIndex := d.vars.frame
	if frameIndex < 0 || frameIndex >= len(d.frames) {
		frameIndex = 0
	}
	frameID := d.frames[frameIndex].ID
	expression := d.watch.entries[index].expression
	a.debugOperation(p, "evaluate", func(ctx context.Context, session *debugSession, operationID string) (core.DebugUpdate, error) {
		return a.kernel.InspectDebug(ctx, core.DebugInspectRequest{
			SessionID:   session.id,
			OperationID: operationID,
			Kind:        "evaluate",
			FrameID:     &frameID,
			Expression:  expression,
			Context:     "watch",
		})
	}, debugOperationHandlers{done: func(a *App, result core.DebugOperationResult) {
		if index >= len(d.watch.entries) || d.watch.entries[index].expression != expression {
			return
		}
		entry := &d.watch.entries[index]
		if result.Kind != "evaluate" || result.Variable == nil {
			entry.failure = a.text.Debug.EvaluateFailed
			entry.value, entry.typeName = "", ""
			return
		}
		entry.value, entry.typeName, entry.failure = result.Variable.Value, result.Variable.Type, ""
	}, failed: func(a *App, message string, _ bool) {
		if index < len(d.watch.entries) {
			d.watch.entries[index].failure = message
			d.watch.entries[index].value, d.watch.entries[index].typeName = "", ""
		}
	}})
}

// debugWatchView declares the watch editor and the values of the current stop.
func (a *App) debugWatchView(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	w := &d.watch
	if d.activeSession() == nil || d.state != "paused" {
		return
	}
	ui.Column(c).FillWidth().Shrink(0).Gap(4).PadX(8).PadY(4).Children(func() {
		ui.Row(c).FillWidth().Items(ui.Center).Gap(6).Children(func() {
			ui.Text(c, t.Watches).FontSize(12).Color(a.colors.Subtle)
			ui.Spacer(c)
			if len(w.entries) > 0 && ui.Button(c.Key("watchReload"), t.Reload).Ghost().Clicked() {
				c.After(func() { a.refreshDebugWatches(p) })
			}
		})
		if len(w.history) > 0 {
			// The recent expressions of this session: choosing one fills the field, to be evaluated as typed.
			ui.Select(c.Key("watchHistory"), &w.pick, w.history, func(expression string) string { return expression }).FillWidth()
			if w.pick != "" {
				w.input, w.pick = w.pick, ""
			}
		}
		submitted := ui.TextField(c.Key("watchInput"), &w.input, t.WatchPlaceholder, t.WatchPlaceholder).FillWidth().Submitted()
		if submitted || ui.Button(c.Key("watchAdd"), t.AddWatch).Outline().Disabled(strings.TrimSpace(w.input) == "").Clicked() {
			c.After(func() { a.addDebugWatch(p) })
		}
		for index := range w.entries {
			entry := w.entries[index]
			ui.Row(c.Key("watch/" + entry.expression)).FillWidth().Items(ui.Center).Gap(6).Children(func() {
				text := entry.expression
				if entry.value != "" {
					text += " = " + entry.value
				}
				if entry.typeName != "" {
					text += " (" + entry.typeName + ")"
				}
				if entry.failure != "" {
					text += " — " + entry.failure
				}
				color := a.colors.Text
				if entry.failure != "" {
					color = a.theme.Danger
				}
				ui.Text(c, text).Grow(1).Shrink(1).FontSize(12.5).Color(color).Ellipsis()
				i := index
				if ui.Button(c.KeyInt(i).Key("remove"), t.RemoveWatch).Ghost().Clicked() {
					c.After(func() { a.removeDebugWatch(p, i) })
				}
			})
		}
	})
}
