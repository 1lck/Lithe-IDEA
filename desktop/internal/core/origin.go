package core

import (
	"context"
	"fmt"
	"sync/atomic"
)

// Origin is the user action a request belongs to. The client reports it with every request a
// context carrying it sends (RequestOrigin in the Rust protocol), and Core records the request
// under the action's operation, so the host's records of the action and Core's records of the
// requests it caused share one op. It is diagnostics only: Core never changes what a request
// does because of it, and drops a value of the wrong shape instead of failing the request.
type Origin struct {
	// Operation correlates the records of the action; NewOperation makes one. Empty means the
	// request belongs to no action.
	Operation string
	// Trigger is the stable id of the action, such as command.git.commit; Core keeps it when it
	// is a catalog token: letters, digits and ._:/-$, at most 64 bytes.
	Trigger string
}

type originKey struct{}

// WithOrigin returns a context whose requests belong to origin. An origin without an operation
// leaves ctx as it is.
func WithOrigin(ctx context.Context, origin Origin) context.Context {
	if origin.Operation == "" {
		return ctx
	}
	return context.WithValue(ctx, originKey{}, origin)
}

// OriginOf is the action the requests of ctx belong to; the zero Origin for none.
func OriginOf(ctx context.Context) Origin {
	origin, _ := ctx.Value(originKey{}).(Origin)
	return origin
}

var nextOperation atomic.Uint64

// NewOperation returns an operation id unique in the process, of the shape Core accepts for an
// op: letters, digits and ._:/@+-, at most 128 bytes.
func NewOperation() string {
	return fmt.Sprintf("action-%d", nextOperation.Add(1))
}

// requestOrigin is the origin of one request on the wire (RequestOrigin in the Rust protocol).
type requestOrigin struct {
	// Source is "user" for a request of an action and "background" for an automatic refresh.
	// Core decodes it as an enum, so it never carries another value.
	Source    string `json:"source,omitempty"`
	Trigger   string `json:"trigger,omitempty"`
	Operation string `json:"operation,omitempty"`
}

// requestOriginOf is the origin a request of ctx reports, nil when there is nothing to report.
// An automatic refresh is background even when an action started it: Core keeps the internal
// queries of a background request silent, as the refresh asks.
func requestOriginOf(ctx context.Context) *requestOrigin {
	origin := OriginOf(ctx)
	refresh, _ := ctx.Value(gitRefreshKey{}).(bool)
	switch {
	case origin.Operation == "" && !refresh:
		return nil
	case refresh:
		return &requestOrigin{Source: "background", Trigger: origin.Trigger, Operation: origin.Operation}
	default:
		return &requestOrigin{Source: "user", Trigger: origin.Trigger, Operation: origin.Operation}
	}
}
