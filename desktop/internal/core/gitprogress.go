package core

import (
	"context"
	"encoding/json"
)

// GitProgress is the latest phase of a Git transfer, as Core parses it from Git's own
// progress lines. Percent applies only to its Stage, never to a whole operation: a fetch of
// several remotes runs every phase once per remote.
type GitProgress struct {
	// Stage is one of enumerating, counting, compressing, receiving, resolving, writing
	// or updating.
	Stage string `json:"stage"`
	// Percent is nil when Git printed a phase without a percentage.
	Percent *int `json:"percent"`
	// Completed and Total are the object counts of the phase, zero when Git printed none.
	Completed uint64 `json:"completed"`
	Total     uint64 `json:"total"`
}

type gitProgressKey struct{}

// WithGitProgress returns a context under which the Git write operations (fetch, pull, ...)
// report the phase they are in to observe. observe runs on the goroutine that executes the
// request, once per progress line Git printed, so it must return promptly and must not wait
// for the UI thread; coalesce and post instead. Cancelling the returned context cancels the
// operation like any other request context.
func WithGitProgress(ctx context.Context, observe func(GitProgress)) context.Context {
	return context.WithValue(ctx, gitProgressKey{}, observe)
}

// gitProgressObserver is the event observer a git.write request installs for ctx, nil when
// ctx asks for no progress. Events of any other kind, and output lines that are not a
// recognised progress phase, are ignored.
func gitProgressObserver(ctx context.Context) func(json.RawMessage) {
	observe, _ := ctx.Value(gitProgressKey{}).(func(GitProgress))
	if observe == nil {
		return nil
	}
	return func(raw json.RawMessage) {
		var event struct {
			Type     string `json:"type"`
			Progress *struct {
				Stage     string  `json:"stage"`
				Percent   *int    `json:"percent"`
				Completed *uint64 `json:"completed"`
				Total     *uint64 `json:"total"`
			} `json:"progressDetails"`
		}
		if json.Unmarshal(raw, &event) != nil || event.Type != "output" || event.Progress == nil || event.Progress.Stage == "" {
			return
		}
		p := GitProgress{Stage: event.Progress.Stage, Percent: event.Progress.Percent}
		if event.Progress.Completed != nil {
			p.Completed = *event.Progress.Completed
		}
		if event.Progress.Total != nil {
			p.Total = *event.Progress.Total
		}
		observe(p)
	}
}
