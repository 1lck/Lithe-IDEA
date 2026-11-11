package core

import (
	"context"
	"encoding/json"
)

// This file wraps Rust Core's GitHub planning commands (shared/contracts/github.md). Core plans
// every request and normalizes every response; the host performs the HTTPS calls itself (see
// internal/githubapi) and never builds a path or a body of its own.

// GitHubRepo is a repository identity Core derives from a remote: its owner and name.
type GitHubRepo struct {
	Owner string `json:"owner"`
	Name  string `json:"name"`
}

// GitHubRequest is the typed input of github.requestPlan. Only the fields an operation needs are
// set; an absent one is left out.
type GitHubRequest struct {
	Operation   string      `json:"operation"`
	Repository  *GitHubRepo `json:"repository,omitempty"`
	PullNumber  uint64      `json:"pullNumber,omitempty"`
	ClientID    string      `json:"clientId,omitempty"`
	DeviceCode  string      `json:"deviceCode,omitempty"`
	Title       *string     `json:"title,omitempty"`
	Body        *string     `json:"body,omitempty"`
	Head        string      `json:"head,omitempty"`
	Base        string      `json:"base,omitempty"`
	Draft       *bool       `json:"draft,omitempty"`
	State       string      `json:"state,omitempty"`
	Event       string      `json:"event,omitempty"`
	MergeMethod string      `json:"mergeMethod,omitempty"`
	Labels      []string    `json:"labels,omitempty"`
	Assignees   []string    `json:"assignees,omitempty"`
}

// GitHubPlan is the HTTP request Core planned: the host it goes to, the method, the path and the
// query on that host, the JSON body, and whether the host attaches the account's token.
type GitHubPlan struct {
	Host                   string            `json:"host"`
	Method                 string            `json:"method"`
	Path                   string            `json:"path"`
	Query                  map[string]string `json:"query"`
	Body                   *string           `json:"body"`
	RequiresAuthentication bool              `json:"requiresAuthentication"`
}

// GitHubRequestPlan plans the request of one operation.
func (c *Client) GitHubRequestPlan(ctx context.Context, request GitHubRequest) (GitHubPlan, error) {
	var plan GitHubPlan
	if err := c.Execute(ctx, "github.requestPlan", request, &plan); err != nil {
		return GitHubPlan{}, err
	}
	return plan, nil
}

// GitHubNormalizeResponse turns the status and body of one response into the operation's normalized
// value, or the standard Core error.
func (c *Client) GitHubNormalizeResponse(ctx context.Context, operation string, status int, body string) (json.RawMessage, error) {
	var value json.RawMessage
	payload := struct {
		Operation string `json:"operation"`
		Status    int    `json:"status"`
		Body      string `json:"body"`
	}{operation, status, body}
	if err := c.Execute(ctx, "github.normalizeResponse", payload, &value); err != nil {
		return nil, err
	}
	return value, nil
}

// GitHubParseRemote derives the GitHub repository of a remote URL.
func (c *Client) GitHubParseRemote(ctx context.Context, remoteURL string) (GitHubRepo, error) {
	var repo GitHubRepo
	if err := c.Execute(ctx, "github.parseRemote", struct {
		RemoteURL string `json:"remoteUrl"`
	}{remoteURL}, &repo); err != nil {
		return GitHubRepo{}, err
	}
	return repo, nil
}

// DeviceTransitionRequest is one observation of the device flow.
type DeviceTransitionRequest struct {
	Event               string  `json:"event"`
	ExpiresIn           uint64  `json:"expiresIn"`
	Interval            uint64  `json:"interval"`
	ElapsedMilliseconds uint64  `json:"elapsedMilliseconds"`
	SuggestedInterval   *uint64 `json:"suggestedInterval,omitempty"`
}

// DeviceTransition is the next step of the device flow: wait, poll, authorize, expired, denied or
// failed, with the interval and the monotonic delay of a wait.
type DeviceTransition struct {
	Action           string `json:"action"`
	IntervalSeconds  uint64 `json:"intervalSeconds"`
	WaitMilliseconds uint64 `json:"waitMilliseconds"`
}

// GitHubDeviceTransition asks Core what the device flow does next.
func (c *Client) GitHubDeviceTransition(ctx context.Context, request DeviceTransitionRequest) (DeviceTransition, error) {
	var transition DeviceTransition
	if err := c.Execute(ctx, "github.deviceAuthorizationTransition", request, &transition); err != nil {
		return DeviceTransition{}, err
	}
	return transition, nil
}
