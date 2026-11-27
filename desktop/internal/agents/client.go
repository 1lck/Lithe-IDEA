// Package agents is the desktop side of API-45 (Agent, matrix id agent-native-sessions). Core
// runs every agent CLI, relays its lines to the plugin backend that translates them, and keeps
// the local session records; this package names Core's agents.* and agentSessions.* commands,
// decodes their answers, folds a session's events into a bounded transcript and works out the
// permissions each plugin is granted.
//
// Nothing here draws, logs conversation text or knows any particular agent: CLI names, protocols
// and session directories come from plugin manifests and backends. Every call may block and runs
// off the window thread.
package agents

import (
	"context"
	"time"
)

// Executor is the one Core call the client needs; *core.Client implements it.
type Executor interface {
	Execute(ctx context.Context, command string, payload, result any) error
}

// Client sends the agents commands over a Core client.
type Client struct{ core Executor }

// NewClient is the agents client of one Core client.
func NewClient(core Executor) *Client { return &Client{core: core} }

// MaxWait is the longest wait Core accepts for agents.waitEvents.
const MaxWait = 30 * time.Second

// Configure replaces the agents Core knows with the ones these plugins declare. The host calls it
// whenever a plugin is installed, updated, enabled, disabled or removed, or a grant changes;
// Core ends live sessions whose agent is gone or may no longer run.
func (c *Client) Configure(ctx context.Context, plugins []ConfiguredPlugin) (Configured, error) {
	if plugins == nil {
		plugins = []ConfiguredPlugin{}
	}
	var out Configured
	err := c.core.Execute(ctx, "agents.configure", map[string]any{"plugins": plugins}, &out)
	return out, err
}

// Catalog lists the configured agents.
func (c *Client) Catalog(ctx context.Context) ([]CatalogAgent, error) {
	var out struct {
		Agents []CatalogAgent `json:"agents"`
	}
	err := c.core.Execute(ctx, "agents.catalog", nil, &out)
	return out.Agents, err
}

// Sessions lists the live sessions.
func (c *Client) Sessions(ctx context.Context) ([]LiveSession, error) {
	var out struct {
		Sessions []LiveSession `json:"sessions"`
	}
	err := c.core.Execute(ctx, "agents.sessions", nil, &out)
	return out.Sessions, err
}

// Start starts a native session. ctx must carry the user's operation: Core starts sessions only
// for origin.source=user.
func (c *Client) Start(ctx context.Context, request StartRequest) (string, error) {
	if request.Environment == nil {
		request.Environment = map[string]string{}
	}
	var out struct {
		Session string `json:"session"`
	}
	err := c.core.Execute(ctx, "agents.start", request, &out)
	return out.Session, err
}

// Prompt sends one turn of the user's text and answers the turn Core assigned.
func (c *Client) Prompt(ctx context.Context, session, text string) (uint64, error) {
	return c.turn(ctx, "agents.prompt", map[string]any{"session": session, "text": text})
}

// Cancel asks the backend to stop the turn in progress.
func (c *Client) Cancel(ctx context.Context, session string) (uint64, error) {
	return c.turn(ctx, "agents.cancel", map[string]any{"session": session})
}

// RespondPermission answers a pending permission request with one of the options the backend
// listed.
func (c *Client) RespondPermission(ctx context.Context, session, permission, option string) (uint64, error) {
	return c.turn(ctx, "agents.respondPermission", map[string]any{
		"session": session, "permission": permission, "option": option,
	})
}

func (c *Client) turn(ctx context.Context, command string, payload any) (uint64, error) {
	var out struct {
		Turn uint64 `json:"turn"`
	}
	err := c.core.Execute(ctx, command, payload, &out)
	return out.Turn, err
}

// Close ends a session: Core closes the CLI's input and ends it after three seconds.
func (c *Client) Close(ctx context.Context, session string) error {
	return c.core.Execute(ctx, "agents.close", map[string]any{"session": session}, nil)
}

// WaitEvents waits up to timeout for events after the sequence after. Core keeps the latest
// 8192 events of every session; Missed reports that some before the first one are gone.
func (c *Client) WaitEvents(ctx context.Context, after uint64, timeout time.Duration, limit int) (EventBatch, error) {
	timeout = min(max(timeout, 0), MaxWait)
	payload := map[string]any{"after": after, "timeoutMilliseconds": timeout.Milliseconds()}
	if limit > 0 {
		payload["limit"] = limit
	}
	var out EventBatch
	err := c.core.Execute(ctx, "agents.waitEvents", payload, &out)
	return out, err
}

// latestProbe is an after past any sequence Core will reach. Waiting after it without a timeout
// answers no events and, as next, the latest sequence; it stays far below the largest u64 so
// Core's own after+1 cannot overflow.
const latestProbe = 1 << 53

// Latest is the sequence of the latest event Core queued. A window that starts its first
// session waits after it, so it never reads the events of sessions other windows ran before.
func (c *Client) Latest(ctx context.Context) (uint64, error) {
	batch, err := c.WaitEvents(ctx, latestProbe, 0, 1)
	return batch.Next, err
}

// ConfigureRecords opens the session record cache.
func (c *Client) ConfigureRecords(ctx context.Context, config RecordsConfig) (RecordsConfigured, error) {
	if config.Environment == nil {
		config.Environment = map[string]string{}
	}
	var out RecordsConfigured
	err := c.core.Execute(ctx, "agentSessions.configure", config, &out)
	return out, err
}

// Sync reads one agent's changed session files through its plugin.
func (c *Client) Sync(ctx context.Context, pluginID, agentID string) (SyncReport, error) {
	var out SyncReport
	err := c.core.Execute(ctx, "agentSessions.sync", map[string]any{"pluginID": pluginID, "agentID": agentID}, &out)
	return out, err
}

// Forget drops one agent's cached records and answers how many files they came from.
func (c *Client) Forget(ctx context.Context, pluginID, agentID string) (int, error) {
	var out struct {
		Files int `json:"files"`
	}
	err := c.core.Execute(ctx, "agentSessions.forget", map[string]any{"pluginID": pluginID, "agentID": agentID}, &out)
	return out.Files, err
}

// List lists recorded sessions, newest first.
func (c *Client) List(ctx context.Context, query ListQuery) ([]RecordedSession, error) {
	var out struct {
		Sessions []RecordedSession `json:"sessions"`
	}
	err := c.core.Execute(ctx, "agentSessions.list", query, &out)
	return out.Sessions, err
}

// Search finds recorded spans that contain every word of the query.
func (c *Client) Search(ctx context.Context, query SearchQuery) ([]SearchHit, error) {
	var out struct {
		Hits []SearchHit `json:"hits"`
	}
	err := c.core.Execute(ctx, "agentSessions.search", query, &out)
	return out.Hits, err
}

// Read reads one recorded range of a session file as messages.
func (c *Client) Read(ctx context.Context, agent, path string, span ByteRange) (ReadResult, error) {
	var out ReadResult
	err := c.core.Execute(ctx, "agentSessions.read", map[string]any{"agent": agent, "path": path, "range": span}, &out)
	return out, err
}

// Stats sums the recorded usage of the agents the user lets Lithe read, with the latest rate
// limits.
func (c *Client) Stats(ctx context.Context, query StatsQuery) (Stats, error) {
	var out Stats
	err := c.core.Execute(ctx, "agentSessions.stats", query, &out)
	return out, err
}
