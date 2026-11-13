package workbench

import (
	"context"
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/keymap"
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

// debugWatch is the Variables pane's evaluate field, the result it evaluated last, and the
// watch list with its editor.
type debugWatch struct {
	entries []debugWatchEntry
	input   string
	// evaluated is the expression Enter evaluated in the field and its result; nil before one,
	// and its value is dropped with the stop it belongs to.
	evaluated *debugWatchEntry
	// history is the expressions evaluated in this session, oldest first and without repeats, and
	// pick is what the recent-expressions picker chose last.
	history []string
	pick    string
	// editOpen shows the watch at editIndex as a field holding edit. editFocus asks for the
	// keyboard on the next paint, and editFocused records that the field had it, so moving
	// the keyboard elsewhere ends the edit the way Enter does.
	editOpen    bool
	editIndex   int
	edit        ui.Field
	editFocus   bool
	editFocused bool
}

// beginEdit turns the watch at index into a field holding its expression.
func (w *debugWatch) beginEdit(index int) {
	if index < 0 || index >= len(w.entries) {
		return
	}
	w.editOpen, w.editIndex, w.editFocus, w.editFocused = true, index, true, false
	w.edit.SetText(w.entries[index].expression)
}

// endEdit closes the field without changing the watch.
func (w *debugWatch) endEdit() {
	w.editOpen, w.editFocus, w.editFocused = false, false, false
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
	w.evaluated = nil
}

// addDebugWatch adds the typed expression as a watch and, while the debuggee is paused,
// evaluates it at the current frame; a watch added while it runs is evaluated at the next stop.
func (a *App) addDebugWatch(p *project) {
	d := &p.debug
	expression := strings.TrimSpace(d.watch.input)
	if expression == "" {
		return
	}
	a.performed("debug.watch.add", surfaceButton)
	d.watch.entries = append(d.watch.entries, debugWatchEntry{expression: expression})
	d.watch.rememberExpression(expression)
	d.watch.input = ""
	if d.activeSession() != nil && d.state == "paused" {
		a.evaluateDebugWatch(p, len(d.watch.entries)-1)
	}
}

// evaluateDebugInput evaluates the typed expression once at the selected frame with the DAP
// "repl" context, the way IntelliJ IDEA's Evaluate field does, and keeps the expression in the
// field so it can be changed and evaluated again.
func (a *App) evaluateDebugInput(p *project) {
	d := &p.debug
	w := &d.watch
	expression := strings.TrimSpace(w.input)
	if expression == "" || d.activeSession() == nil || d.state != "paused" || len(d.frames) == 0 {
		return
	}
	a.performed("debug.evaluate", surfaceButton)
	w.rememberExpression(expression)
	entry := &debugWatchEntry{expression: expression}
	w.evaluated = entry
	a.evaluateDebugExpression(p, expression, "repl", func(value, typeName, failure string) {
		if w.evaluated != entry {
			return
		}
		entry.value, entry.typeName, entry.failure = value, typeName, failure
	})
}

// removeDebugWatch drops one expression.
func (a *App) removeDebugWatch(p *project, index int) {
	d := &p.debug
	if index < 0 || index >= len(d.watch.entries) {
		return
	}
	d.watch.entries = append(d.watch.entries[:index], d.watch.entries[index+1:]...)
	if w := &d.watch; w.editOpen {
		switch {
		case index == w.editIndex:
			w.endEdit()
		case index < w.editIndex:
			w.editIndex--
		}
	}
}

// commitDebugWatchEdit replaces the edited watch's expression with the field's text and
// evaluates it at the current frame. An empty or unchanged text keeps the watch as it was.
func (a *App) commitDebugWatchEdit(p *project) {
	d := &p.debug
	w := &d.watch
	if !w.editOpen {
		return
	}
	index := w.editIndex
	w.endEdit()
	expression := strings.TrimSpace(w.edit.Text())
	if index < 0 || index >= len(w.entries) || expression == "" || expression == w.entries[index].expression {
		return
	}
	w.entries[index] = debugWatchEntry{expression: expression}
	w.rememberExpression(expression)
	if d.activeSession() != nil && d.state == "paused" {
		a.evaluateDebugWatch(p, index)
	}
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

// evaluateDebugWatch evaluates one watch with the DAP "watch" context at the selected frame.
func (a *App) evaluateDebugWatch(p *project, index int) {
	d := &p.debug
	if index < 0 || index >= len(d.watch.entries) {
		return
	}
	expression := d.watch.entries[index].expression
	a.evaluateDebugExpression(p, expression, "watch", func(value, typeName, failure string) {
		if index >= len(d.watch.entries) || d.watch.entries[index].expression != expression {
			return
		}
		entry := &d.watch.entries[index]
		entry.value, entry.typeName, entry.failure = value, typeName, failure
	})
}

// evaluateDebugExpression asks Core for one expression's value in dapContext, the DAP context, at the
// selected frame, and hands done the value and its type, or the reason there is none. A result
// that arrives after another stop is dropped by the generation check in debugOperation's
// completion path.
func (a *App) evaluateDebugExpression(p *project, expression, dapContext string, done func(value, typeName, failure string)) {
	d := &p.debug
	if d.activeSession() == nil || len(d.frames) == 0 {
		return
	}
	frameIndex := d.vars.frame
	if frameIndex < 0 || frameIndex >= len(d.frames) {
		frameIndex = 0
	}
	frameID := d.frames[frameIndex].ID
	a.debugOperation(p, "evaluate", func(ctx context.Context, session *debugSession, operationID string) (core.DebugUpdate, error) {
		return a.kernel.InspectDebug(ctx, core.DebugInspectRequest{
			SessionID:   session.id,
			OperationID: operationID,
			Kind:        "evaluate",
			FrameID:     &frameID,
			Expression:  expression,
			Context:     dapContext,
		})
	}, debugOperationHandlers{done: func(a *App, result core.DebugOperationResult) {
		if result.Kind != "evaluate" || result.Variable == nil {
			done("", "", a.text.Debug.EvaluateFailed)
			return
		}
		done(result.Variable.Value, result.Variable.Type, "")
	}, failed: func(_ *App, message string, _ bool) {
		done("", "", message)
	}})
}

// debugEvaluateField declares the field over the variables, IntelliJ IDEA's: Enter evaluates
// the expression at the selected frame and Primary+Shift+Enter adds it as a watch. The
// expressions of this session are offered beside it, and the last result is shown under it.
func (a *App) debugEvaluateField(c ui.C, p *project) {
	w := &p.debug.watch
	evaluate, watch := shortcuts.Keycaps(debugEvaluateChord), shortcuts.Keycaps(debugAddWatchChord)
	placeholder := i18n.SharedFormat(a.language(), "desktop.debug.evaluatePlaceholder", map[string]string{
		"evaluate": evaluate,
		"watch":    watch,
	})
	ui.Row(c).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(8).Children(func() {
		field := ui.TextField(c.Key("watchInput"), &w.input, placeholder, placeholder).Grow(1)
		field.OnKey(func(event gfx.KeyEvent) gfx.EventResult {
			if event.Release || !isDebugAddWatch(event) {
				return gfx.EventResult{}
			}
			a.addDebugWatch(p)
			return gfx.EventResult{Handled: true, Repaint: true}
		})
		if field.Submitted() {
			c.After(func() { a.evaluateDebugInput(p) })
		}
		if len(w.history) > 0 {
			// The recent expressions of this session: choosing one fills the field, to be
			// evaluated as typed.
			ui.Select(c.Key("watchHistory"), &w.pick, w.history, func(expression string) string { return expression }).
				Label(a.text.Debug.Watches).Width(140).Shrink(0)
			if w.pick != "" {
				w.input, w.pick = w.pick, ""
			}
		}
	})
	if entry := w.evaluated; entry != nil {
		ui.Row(c.Key("evaluated")).FillWidth().Height(debugRowHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(10).Children(func() {
			ui.Icon(c, icons.Variable).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Accent)
			a.debugWatchText(c, *entry)
		})
	}
}

// debugEvaluateChord evaluates the expression in the field once.
var debugEvaluateChord = keymap.Chord{Key: gfx.KeyEnter}

// debugAddWatchChord adds the evaluate field's expression as a watch: ⇧⌘↵ on macOS, as in
// IntelliJ IDEA, and Ctrl+Shift+Enter elsewhere.
var debugAddWatchChord = keymap.Chord{Modifiers: keymap.Primary | gfx.ModifierShift, Key: gfx.KeyEnter}

// isDebugAddWatch reports whether event presses debugAddWatchChord.
func isDebugAddWatch(event gfx.KeyEvent) bool {
	chord, ok := keymap.FromEvent(event)
	return ok && chord.Key == gfx.KeyEnter &&
		chord.Modifiers&(gfx.ModifierShift|gfx.ModifierControl|gfx.ModifierAlt|gfx.ModifierMeta) == debugAddWatchChord.Modifiers
}

// debugWatchText declares an expression with its result as IntelliJ IDEA writes it,
// "expression = {type} value", or with the reason it has none.
func (a *App) debugWatchText(c ui.C, entry debugWatchEntry) {
	ui.Text(c, entry.expression).Shrink(0).FontSize(12.5).Color(treelist.Text(a.colors.Dark)).Weight(gfx.WeightMedium)
	switch {
	case entry.failure != "":
		ui.Text(c, entry.failure).Shrink(1).FontSize(12.5).Color(a.theme.Danger).Ellipsis()
	case entry.value != "" || entry.typeName != "":
		ui.Text(c, "=").Shrink(0).FontSize(12.5).Color(a.colors.Subtle)
		if entry.typeName != "" {
			ui.Text(c, "{"+entry.typeName+"}").Shrink(0).FontSize(12.5).Color(a.colors.Subtle)
		}
		ui.Text(c, entry.value).Shrink(1).FontSize(12.5).Color(a.colors.Text).Ellipsis().Mono()
	}
}

// debugWatchView declares the watches over the variables, each with its value at the current
// stop: a double click edits one in place and its button removes it.
func (a *App) debugWatchView(c ui.C, p *project) {
	t, d := a.text.Debug, &p.debug
	w := &d.watch
	if d.activeSession() == nil {
		w.endEdit()
	}
	if len(w.entries) == 0 {
		return
	}
	ui.Column(c).FillWidth().Shrink(0).Children(func() {
		for index := range w.entries {
			if w.editOpen && w.editIndex == index {
				ui.Row(c.Key("watchEditRow")).FillWidth().Height(debugRowHeight + 4).Shrink(0).Items(ui.Center).PadX(8).Children(func() {
					a.debugWatchEditField(c, p)
				})
				continue
			}
			entry := w.entries[index]
			k := c.Part("watch").KeyInt(index)
			row := ui.Row(k).FillWidth().Height(debugRowHeight).Shrink(0).Items(ui.Center).Gap(6).PadX(10).
				Hover(ui.Look{}.Background(a.colors.Hover)).
				HitWith(ui.ID(k), entry.expression, gfx.HitOptions{SkipFocus: true})
			row.Children(func() {
				ui.Icon(k, icons.Eye).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
				a.debugWatchText(k, entry)
				ui.Spacer(k)
				i := index
				if _, clicked := a.toolIconButton(k.Key("remove"), t.RemoveWatch, icons.X, false, false); clicked {
					c.After(func() { a.removeDebugWatch(p, i) })
				}
			})
			if row.DoubleClicked() {
				i := index
				c.After(func() {
					a.performed("debug.watch.edit", "debug")
					w.beginEdit(i)
				})
			}
			a.debugWatchMenu(k, row, p, index)
		}
	})
	ui.Divider(c)
}

// debugWatchEditField declares the field that edits one watch in place: Enter or moving the
// keyboard elsewhere keeps the new expression, and Escape keeps the old one.
func (a *App) debugWatchEditField(c ui.C, p *project) {
	w := &p.debug.watch
	id := ui.ID(c.Key("watchEdit"))
	canvas := c.Canvas()
	switch {
	case w.editFocus:
		canvas.RequestFocus(id)
		w.editFocus = false
	case canvas.Focused() == id:
		w.editFocused = true
	case w.editFocused:
		c.After(func() { a.commitDebugWatchEdit(p) })
	}
	label := i18n.Shared(a.language(), "native.editWatch")
	field := ui.TextFieldID(c, id, &w.edit, label, a.text.Debug.WatchPlaceholder).FillWidth()
	field.OnKey(func(event gfx.KeyEvent) gfx.EventResult {
		if event.Key != gfx.KeyEscape {
			return gfx.EventResult{}
		}
		w.endEdit()
		return gfx.EventResult{Handled: true, Repaint: true}
	})
	if field.Submitted() {
		c.After(func() { a.commitDebugWatchEdit(p) })
	}
}
