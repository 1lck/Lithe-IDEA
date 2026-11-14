package workbench

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
)

// A user action is one operation from the click to the last thing it causes. performed starts
// it on the window thread and it lasts until the window callback it was started in returns
// (operating). Meanwhile every record the window writes carries its op, background work started
// for it carries it in its context, so Core records the requests the work sends under the same
// op (core.Origin), and the work's result is applied under it again, so a failure the result
// reports is found under the action that caused it.

// operation is the user action the window thread is running; the zero value is none.
type operation struct {
	// id is the op of the action's records and the operation of its Core requests.
	id string
	// trigger is the stable id of the action, the trigger of its Core requests.
	trigger string
}

// origin is what the action's Core requests report.
func (o operation) origin() core.Origin {
	return core.Origin{Operation: o.id, Trigger: o.trigger}
}

// operationContext is parent carrying the user action in progress, for work the window thread
// starts for it on another goroutine; parent itself when no action is in progress.
func (a *App) operationContext(parent context.Context) context.Context {
	return core.WithOrigin(parent, a.op.origin())
}

// within runs apply on the window thread under the action op, then restores the action that was
// in progress: the result of an action's work belongs to the action.
func (a *App) within(op operation, apply func(*App)) {
	previous := a.op
	a.op = op
	defer func() { a.op = previous }()
	apply(a)
}

// operating makes the window callbacks of config end the user action they start: an action
// started in a callback does not leak into the next one, such as a paint or a refresh that
// follows a click.
func (a *App) operating(config app.Config) app.Config {
	config.OnPointer = operatingOn(a, config.OnPointer)
	config.OnKey = operatingOn(a, config.OnKey)
	config.OnShortcut = operatingOn(a, config.OnShortcut)
	config.OnModifierTap = operatingOn(a, config.OnModifierTap)
	config.OnScroll = operatingOn(a, config.OnScroll)
	config.OnFileDrop = operatingOn(a, config.OnFileDrop)
	if focusLost := config.OnFocusLost; focusLost != nil {
		config.OnFocusLost = func() gfx.EventResult {
			defer a.endOperation()
			return focusLost()
		}
	}
	if wake := config.OnWake; wake != nil {
		config.OnWake = func() {
			defer a.endOperation()
			wake()
		}
	}
	if paint := config.Paint; paint != nil {
		config.Paint = func(canvas *gfx.Canvas, size gfx.Size) {
			defer a.endOperation()
			paint(canvas, size)
		}
	}
	if closeRequest := config.OnCloseRequest; closeRequest != nil {
		config.OnCloseRequest = func(allow func()) {
			defer a.endOperation()
			closeRequest(allow)
		}
	}
	return config
}

// operatingOn is handle ending the user action it starts; nil stays nil.
func operatingOn[E any](a *App, handle func(E) gfx.EventResult) func(E) gfx.EventResult {
	if handle == nil {
		return nil
	}
	return func(event E) gfx.EventResult {
		defer a.endOperation()
		return handle(event)
	}
}

// endOperation ends the user action in progress.
func (a *App) endOperation() {
	a.op = operation{}
}
