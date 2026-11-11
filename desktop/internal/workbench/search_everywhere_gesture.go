package workbench

import (
	"context"
	"encoding/json"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// Pressing Shift twice opens Search Everywhere. Core owns the gesture
// (keymap.modifierGestureStep: the state machine and its time limit); the window
// reports each Shift tap Viva saw (app.Config.OnModifierTap) and acts on what Core
// answers. A tap is a press and a release with nothing between, so it is reported
// to Core as both flag changes.

// modifierGestureKernel is the part of Core the gesture uses.
type modifierGestureKernel interface {
	ModifierGestureStep(ctx context.Context, state json.RawMessage, event core.ModifierGestureEvent, timestamp float64) (json.RawMessage, bool, error)
}

// gestureClock is the host clock the gesture's timestamps are read from.
var gestureClock = time.Now()

// onModifierTap advances the double-Shift gesture with one Shift tap.
func (a *App) onModifierTap(event gfx.ModifierTapEvent) gfx.EventResult {
	if event.Key != gfx.KeyShiftLeft && event.Key != gfx.KeyShiftRight {
		a.resetModifierGesture()
		return gfx.EventResult{}
	}
	kernel, ok := a.kernel.(modifierGestureKernel)
	if !ok {
		return gfx.EventResult{}
	}
	now := time.Since(gestureClock).Seconds()
	v := &a.everywhereView
	triggered := false
	for _, shift := range []bool{true, false} {
		state, fired, err := kernel.ModifierGestureStep(context.Background(), v.gesture,
			core.ModifierGestureEvent{Kind: "flags", Shift: shift}, now)
		if err != nil {
			// There is no second implementation of the rule; the gesture just does not fire.
			v.gesture = nil
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("keymap_modifier_gesture", err))
			return gfx.EventResult{}
		}
		v.gesture = state
		triggered = triggered || fired
	}
	if !triggered || a.project == nil {
		return gfx.EventResult{}
	}
	a.performed("search.everywhere", surfaceShortcut)
	a.openEverywhere(a.project)
	return gfx.EventResult{Handled: true, Repaint: true}
}

// resetModifierGesture forgets a half-made gesture, after another modifier tap.
func (a *App) resetModifierGesture() {
	kernel, ok := a.kernel.(modifierGestureKernel)
	if !ok || a.everywhereView.gesture == nil {
		return
	}
	state, _, err := kernel.ModifierGestureStep(context.Background(), a.everywhereView.gesture,
		core.ModifierGestureEvent{Kind: "reset"}, time.Since(gestureClock).Seconds())
	if err != nil {
		state = nil
	}
	a.everywhereView.gesture = state
}
