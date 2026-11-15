package core

import (
	"context"
	"encoding/json"
)

// NavigationLocation is one place in the editor's back/forward history. Core compares only
// Document, Line and Column; Context is the host's own data (the pane, the scroll) that Core
// carries unchanged.
type NavigationLocation struct {
	Document string          `json:"document"`
	Line     int             `json:"line"`
	Column   int             `json:"column"`
	Context  json.RawMessage `json:"context,omitempty"`
}

// NavigationHistory is the back and forward stacks, oldest first. Core keeps the newest 100
// entries of each.
type NavigationHistory struct {
	Back    []NavigationLocation `json:"back"`
	Forward []NavigationLocation `json:"forward"`
}

// NavigationHistoryEvent is one change of the history: "record" a jump from Departure to
// Destination, or step "back" or "forward" from Current.
type NavigationHistoryEvent struct {
	Type        string              `json:"type"`
	Departure   *NavigationLocation `json:"departure"`
	Destination *NavigationLocation `json:"destination"`
	Current     *NavigationLocation `json:"current"`
}

// MarshalJSON writes only the fields of the event's own type, as Core rejects the others.
func (e NavigationHistoryEvent) MarshalJSON() ([]byte, error) {
	if e.Type == "record" {
		return json.Marshal(struct {
			Type        string              `json:"type"`
			Departure   *NavigationLocation `json:"departure"`
			Destination *NavigationLocation `json:"destination"`
		}{e.Type, e.Departure, e.Destination})
	}
	return json.Marshal(struct {
		Type    string              `json:"type"`
		Current *NavigationLocation `json:"current"`
	}{e.Type, e.Current})
}

// NavigationHistoryRecord is the event for a jump. A nil destination records the departure
// alone, as when the destination is not known yet.
func NavigationHistoryRecord(departure NavigationLocation, destination *NavigationLocation) NavigationHistoryEvent {
	return NavigationHistoryEvent{Type: "record", Departure: &departure, Destination: destination}
}

// NavigationHistoryBack is the event for stepping back from current.
func NavigationHistoryBack(current NavigationLocation) NavigationHistoryEvent {
	return NavigationHistoryEvent{Type: "back", Current: &current}
}

// NavigationHistoryForward is the event for stepping forward from current.
func NavigationHistoryForward(current NavigationLocation) NavigationHistoryEvent {
	return NavigationHistoryEvent{Type: "forward", Current: &current}
}

// ReduceNavigationHistory applies one event and returns the next state and, for a step, the
// location to open. The caller restores its previous state when the destination cannot be
// opened.
func (c *Client) ReduceNavigationHistory(ctx context.Context, state NavigationHistory, event NavigationHistoryEvent) (NavigationHistory, *NavigationLocation, error) {
	if state.Back == nil {
		state.Back = []NavigationLocation{}
	}
	if state.Forward == nil {
		state.Forward = []NavigationLocation{}
	}
	var response struct {
		State       NavigationHistory   `json:"state"`
		Destination *NavigationLocation `json:"destination"`
	}
	err := c.Execute(ctx, "editor.navigationHistory.reduce", struct {
		State NavigationHistory      `json:"state"`
		Event NavigationHistoryEvent `json:"event"`
	}{state, event}, &response)
	return response.State, response.Destination, err
}
