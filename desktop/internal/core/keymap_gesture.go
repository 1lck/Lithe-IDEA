package core

import (
	"context"
	"encoding/json"
)

// ModifierGestureEvent is one input of the double-Shift gesture
// (keymap.modifierGestureStep): Kind is "keyDown", "reset" or "flags", and for
// "flags" Shift says whether Shift is down and OtherModifiers whether any other
// modifier is.
type ModifierGestureEvent struct {
	Kind           string
	Shift          bool
	OtherModifiers bool
}

// MarshalJSON encodes e as Core decodes it: a "flags" event always carries both
// flags, false included, and the other kinds carry nothing but their kind, since
// Core refuses a missing flag and an unknown field alike.
func (e ModifierGestureEvent) MarshalJSON() ([]byte, error) {
	if e.Kind != "flags" {
		return json.Marshal(struct {
			Kind string `json:"kind"`
		}{e.Kind})
	}
	return json.Marshal(struct {
		Kind           string `json:"kind"`
		Shift          bool   `json:"shift"`
		OtherModifiers bool   `json:"otherModifiers"`
	}{e.Kind, e.Shift, e.OtherModifiers})
}

// ModifierGestureStep advances the double-Shift gesture by one event. state is the
// opaque state the previous step returned (nil for idle); the host keeps it and
// never reads it. timestamp is seconds on a clock the host keeps.
func (c *Client) ModifierGestureStep(ctx context.Context, state json.RawMessage, event ModifierGestureEvent, timestamp float64) (json.RawMessage, bool, error) {
	request := struct {
		State     json.RawMessage      `json:"state,omitempty"`
		Event     ModifierGestureEvent `json:"event"`
		Timestamp float64              `json:"timestamp"`
	}{state, event, timestamp}
	var response struct {
		State     json.RawMessage `json:"state"`
		Triggered bool            `json:"triggered"`
	}
	if err := c.Execute(ctx, "keymap.modifierGestureStep", request, &response); err != nil {
		return state, false, err
	}
	return response.State, response.Triggered, nil
}
