package core

import (
	"encoding/json"
	"testing"
)

func TestModifierGestureStepSendsEveryEventKindCoreAccepts(t *testing.T) {
	client := NewClient()
	var state json.RawMessage
	steps := []struct {
		event     ModifierGestureEvent
		timestamp float64
		triggered bool
	}{
		{ModifierGestureEvent{Kind: "flags", Shift: true}, 1.0, false},
		{ModifierGestureEvent{Kind: "flags"}, 1.0, false},
		{ModifierGestureEvent{Kind: "keyDown"}, 1.1, false},
		{ModifierGestureEvent{Kind: "flags", Shift: true}, 1.2, false},
		{ModifierGestureEvent{Kind: "flags"}, 1.2, false},
		{ModifierGestureEvent{Kind: "flags", Shift: true}, 1.3, false},
		{ModifierGestureEvent{Kind: "flags"}, 1.3, true},
		{ModifierGestureEvent{Kind: "reset"}, 1.4, false},
	}
	for i, step := range steps {
		next, triggered, err := client.ModifierGestureStep(testContext(t), state, step.event, step.timestamp)
		if err != nil {
			t.Fatalf("step %d (%+v): %v", i, step.event, err)
		}
		if triggered != step.triggered {
			t.Fatalf("step %d (%+v) triggered %v, want %v", i, step.event, triggered, step.triggered)
		}
		state = next
	}
}
