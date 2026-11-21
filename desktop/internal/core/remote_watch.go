package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
)

// RemoteWatchChange is one change below a watched host folder.
type RemoteWatchChange struct {
	// Path is the absolute host path that changed.
	Path string `json:"path"`
	// Kind is how it changed: "created", "modified" or "deleted".
	Kind string `json:"kind"`
}

// RemoteWatchEvents receive a host watch's events. They run on the request's goroutine and must
// return at once: they must not wait for a UI thread.
type RemoteWatchEvents struct {
	// Started is called once the host watches the folder, before any change. A change made
	// before it may not be reported.
	Started func()
	// Changed receives a batch of changes since the previous one, one per path, sorted by path.
	// overflow is true when the host lost changes: the folder must be read again instead of
	// trusting changes. Changed owns changes.
	Changed func(changes []RemoteWatchChange, overflow bool)
	// LimitReached is called when the host ran out of watches: part of the folder is no longer
	// watched, and the watch goes on for the rest.
	LimitReached func()
}

// remoteWatchEvent is one remote event of remote.runWatch, whose params are read by its kind.
type remoteWatchEvent struct {
	Type   string          `json:"type"`
	Event  string          `json:"event"`
	Params json.RawMessage `json:"params"`
}

// errRemoteWatchEvent is an event of remote.runWatch the client cannot read.
var errRemoteWatchEvent = errors.New("core: unreadable remote watch event")

// RemoteRunWatch watches root, an absolute host folder of sessionID, recursively until ctx ends
// or the folder is removed. Folders below root named like one of excludeNames are neither watched
// nor reported; the names are matched exactly against each path component. It blocks the
// calling goroutine for the watch's whole life, so run it off the UI thread.
//
// It returns nil once root was deleted or moved, which ends the watch. Ending ctx stops the
// watch: Core sends watch.stop and returns the context's error. A broken or unknown session fails
// with CodeConnectionClosed. An event the client cannot read stops the watch too and is returned
// as the error, since changes would be missed.
func (c *Client) RemoteRunWatch(ctx context.Context, sessionID, root string, excludeNames []string, events RemoteWatchEvents) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var unreadable error
	observer := func(raw json.RawMessage) {
		if unreadable != nil {
			return
		}
		if err := deliverRemoteWatchEvent(raw, events); err != nil {
			// Cancelling stops the watch rather than letting it miss changes unseen.
			unreadable = err
			cancel()
		}
	}
	type watchParams struct {
		Root         string   `json:"root"`
		ExcludeNames []string `json:"excludeNames"`
	}
	observationErr, err := c.ExecuteWithEvents(ctx, "remote.runWatch", struct {
		SessionID string      `json:"sessionId"`
		Params    watchParams `json:"params"`
	}{sessionID, watchParams{root, nonNil(excludeNames)}}, nil, observer)
	switch {
	case unreadable != nil:
		return unreadable
	case err != nil:
		return err
	}
	return observationErr
}

// deliverRemoteWatchEvent hands one event of remote.runWatch to events. Events of other kinds are
// not the watch's and are ignored, and so is the root's removal, which the request reports by
// ending.
func deliverRemoteWatchEvent(raw json.RawMessage, events RemoteWatchEvents) error {
	if !bytes.Contains(raw, []byte(`"remote"`)) {
		return nil
	}
	var event remoteWatchEvent
	if err := json.Unmarshal(raw, &event); err != nil || event.Type != "remote" {
		return nil
	}
	switch event.Event {
	case "watch.started":
		if events.Started != nil {
			events.Started()
		}
	case "watch.changed":
		var changed struct {
			Changes  []RemoteWatchChange `json:"changes"`
			Overflow bool                `json:"overflow"`
		}
		if err := json.Unmarshal(event.Params, &changed); err != nil {
			return errRemoteWatchEvent
		}
		if events.Changed != nil && (len(changed.Changes) > 0 || changed.Overflow) {
			events.Changed(changed.Changes, changed.Overflow)
		}
	case "watch.error":
		var failed struct {
			Code string `json:"code"`
		}
		if err := json.Unmarshal(event.Params, &failed); err != nil {
			return errRemoteWatchEvent
		}
		if failed.Code == "LIMIT_REACHED" && events.LimitReached != nil {
			events.LimitReached()
		}
	}
	return nil
}
