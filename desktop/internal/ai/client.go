// Package ai is the desktop side of Lithe's AI generation: the commit message (matrix id
// ai-commit-generation), the editor's inline edit (ai-inline-edit) and the pull request
// description draft. It mirrors Core's lithe-ai crate. Core names and parses the user's own
// Codex or Claude configuration, captures the commit evidence, plans every provider request and
// decodes every answer; this package reads the files Core names, resolves the credential
// locator, makes the HTTP call and runs each generation from the first call to the last.
//
// Windows keep their own state, words and painting and call in here; nothing in this package
// draws, notifies or knows about a project. A key stays in memory: it is never logged,
// persisted or sent to Core.
package ai

import (
	"context"
	"encoding/json"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// Kernel is what the AI features ask Core. *Client implements it; a test can embed a *Client
// and replace one call.
type Kernel interface {
	ConfigurationSources(ctx context.Context, source, home string, environment map[string]string) ([]ConfigurationFile, error)
	ParseConfiguration(ctx context.Context, request ConfigurationParseRequest) (*Configuration, error)
	CommitContext(ctx context.Context, mode string, repositories []ContextRepository, maximumDiffCharacters int) (Evidence, error)
	CommitContextIsCurrent(ctx context.Context, mode string, repositories []ContextRepository, token string) (bool, error)
	PlanCommit(ctx context.Context, provider PlanProvider, options CommitOptions, files []EvidenceFile) (HTTPRequest, error)
	DecodeCommitMessage(ctx context.Context, protocol string, response json.RawMessage, includeBody bool) (string, error)
	PlanInlineEdit(ctx context.Context, provider InlineEditProvider, model InlineEditModel, edit InlineEdit) (InlineEditPlan, error)
	DecodeInlineEdit(ctx context.Context, wireProtocol string, response json.RawMessage) (string, error)
	PlanPullRequest(ctx context.Context, provider PlanProvider, options PullRequestOptions, comparison PullRequestComparison) (HTTPRequest, error)
	DecodePullRequest(ctx context.Context, protocol string, response json.RawMessage) (title, description string, err error)
}

// Client sends the AI commands over the Core client. Every call is read-only, may block, and
// runs off the window thread.
type Client struct{ core *core.Client }

// NewClient is the AI client of one Core client.
func NewClient(c *core.Client) *Client { return &Client{core: c} }

var _ Kernel = (*Client)(nil)
