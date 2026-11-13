// Package githubapi performs GitHub HTTPS requests for the desktop client. Rust Core plans every
// request and normalizes every response (Lithe-core-rust rust/contracts/github.md); this package only sends the
// planned request on the trusted hosts, attaches the account's token when the plan asks for one,
// and bounds the response. A token is never put in an error or a log.
package githubapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

const (
	// apiBase and webBase are the only hosts a plan can select.
	apiBase = "https://api.github.com"
	webBase = "https://github.com"
	// maxResponseBytes bounds one response body the host reads.
	maxResponseBytes = 8 << 20
	// requestTimeout bounds one request, including reading its body.
	requestTimeout = 30 * time.Second
	// userAgent names the client to GitHub; it carries no user information.
	userAgent = "Lithe"
)

// ErrNotSignedIn is returned for a request that needs the account's token when there is none.
var ErrNotSignedIn = errors.New("github: not signed in")

// Planner is the part of Rust Core the transport uses. *core.Client implements it.
type Planner interface {
	GitHubRequestPlan(ctx context.Context, request core.GitHubRequest) (core.GitHubPlan, error)
	GitHubNormalizeResponse(ctx context.Context, operation string, status int, body string) (json.RawMessage, error)
}

// Client sends GitHub requests planned by Core.
type Client struct {
	planner Planner
	http    *http.Client
	apiURL  string
	webURL  string
}

// New returns a client that plans with planner and sends on the trusted hosts.
func New(planner Planner) *Client {
	return &Client{
		planner: planner,
		http: &http.Client{
			Timeout: requestTimeout,
			// A redirect could carry the token somewhere Core never planned, so none is followed.
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
		apiURL: apiBase,
		webURL: webBase,
	}
}

// Do plans request, sends it with token when the plan needs one, and returns the normalized value
// Core produces for the response.
func (c *Client) Do(ctx context.Context, request core.GitHubRequest, token string) (json.RawMessage, error) {
	plan, err := c.planner.GitHubRequestPlan(ctx, request)
	if err != nil {
		return nil, err
	}
	status, body, err := c.send(ctx, plan, token)
	if err != nil {
		return nil, err
	}
	return c.planner.GitHubNormalizeResponse(ctx, request.Operation, status, body)
}

// send performs one planned request and returns its status and its bounded body.
func (c *Client) send(ctx context.Context, plan core.GitHubPlan, token string) (int, string, error) {
	base, err := c.hostURL(plan.Host)
	if err != nil {
		return 0, "", err
	}
	if plan.RequiresAuthentication && token == "" {
		return 0, "", ErrNotSignedIn
	}
	target, err := url.Parse(base + plan.Path)
	if err != nil {
		return 0, "", errors.New("github: invalid planned path")
	}
	query := url.Values{}
	keys := make([]string, 0, len(plan.Query))
	for key := range plan.Query {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		query.Set(key, plan.Query[key])
	}
	target.RawQuery = query.Encode()
	var body io.Reader
	if plan.Body != nil {
		body = bytes.NewReader([]byte(*plan.Body))
	}
	req, err := http.NewRequestWithContext(ctx, plan.Method, target.String(), body)
	if err != nil {
		return 0, "", errors.New("github: could not build the request")
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("User-Agent", userAgent)
	if plan.Body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if plan.RequiresAuthentication {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		// The transport error can echo the URL; the token is only in a header and never there.
		return 0, "", fmt.Errorf("github: request failed: %w", ctxOrNetwork(ctx, err))
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes+1))
	if err != nil {
		return 0, "", errors.New("github: could not read the response")
	}
	if len(data) > maxResponseBytes {
		return 0, "", errors.New("github: response is too large")
	}
	return resp.StatusCode, string(data), nil
}

// hostURL is the base URL of a planned host; any other host is refused.
func (c *Client) hostURL(host string) (string, error) {
	switch strings.ToLower(host) {
	case "api":
		return c.apiURL, nil
	case "web":
		return c.webURL, nil
	}
	return "", errors.New("github: unknown planned host")
}

// ctxOrNetwork reports the context's error when the request ended because of it.
func ctxOrNetwork(ctx context.Context, err error) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return errors.New("network error")
}
