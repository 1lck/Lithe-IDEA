package core

import (
	"context"
	"encoding/json"
)

// Plugin web pages (`ui` 2). Core registers each page for its lifetime and
// decides what it is served and which bridge requests it may make; the
// desktop owns the web view, package reads, state storage, dialogs and the
// calls themselves. See plugins.web.* in rust-core-api.md.

// PluginWebTheme is the theme a page is shown with: "light" or "dark", and
// the host's --lithe-* CSS variables.
type PluginWebTheme struct {
	Theme     string            `json:"theme"`
	Variables map[string]string `json:"variables"`
}

// PluginWebOpen asks Core to register a page for one web tool window.
type PluginWebOpen struct {
	Manifest json.RawMessage `json:"manifest"`
	WindowID string          `json:"windowID"`
	Platform string          `json:"platform"`
	Locale   string          `json:"locale"`
	Theme    PluginWebTheme  `json:"theme"`
	// BuildSystems is whether this host serves build systems to pages.
	BuildSystems bool `json:"buildSystems"`
}

// PluginWebPage is a registered page and how to load it.
type PluginWebPage struct {
	Page          uint64 `json:"page"`
	PluginID      string `json:"pluginID"`
	WindowID      string `json:"windowID"`
	Scheme        string `json:"scheme"`
	URL           string `json:"url"`
	BridgeVersion int    `json:"bridgeVersion"`
	FileLimit     int64  `json:"fileLimit"`
	StateLimit    int    `json:"stateLimit"`
}

// OpenPluginWebPage registers a page (plugins.web.open).
func (c *Client) OpenPluginWebPage(ctx context.Context, request PluginWebOpen) (PluginWebPage, error) {
	var page PluginWebPage
	err := c.Execute(ctx, "plugins.web.open", request, &page)
	return page, err
}

// ClosePluginWebPage forgets a page and returns the calls still to cancel
// (plugins.web.close). Closing an unknown page is not an error.
func (c *Client) ClosePluginWebPage(ctx context.Context, page uint64) ([]string, error) {
	var result struct {
		CancelCalls []string `json:"cancelCalls"`
	}
	err := c.Execute(ctx, "plugins.web.close", struct {
		Page uint64 `json:"page"`
	}{page}, &result)
	return result.CancelCalls, err
}

// PluginWebResource is how one request of a page is answered: "bootstrap"
// with Body, "file" with the package path Segments to read (Document true for
// an HTML document), or "refused".
type PluginWebResource struct {
	Kind     string   `json:"kind"`
	MIME     string   `json:"mime"`
	Body     string   `json:"body"`
	Segments []string `json:"segments"`
	Document bool     `json:"document"`
}

// PluginWebResource decides how a page request is served (plugins.web.resource).
func (c *Client) PluginWebResource(ctx context.Context, page uint64, path string) (PluginWebResource, error) {
	var resource PluginWebResource
	err := c.Execute(ctx, "plugins.web.resource", struct {
		Page uint64 `json:"page"`
		Path string `json:"path"`
	}{page, path}, &resource)
	return resource, err
}

// PluginWebDocument puts the policy and the bridge first in an HTML document
// of the package (plugins.web.document).
func (c *Client) PluginWebDocument(ctx context.Context, page uint64, html string) (string, error) {
	var result struct {
		HTML string `json:"html"`
	}
	err := c.Execute(ctx, "plugins.web.document", struct {
		Page uint64 `json:"page"`
		HTML string `json:"html"`
	}{page, html}, &result)
	return result.HTML, err
}

// PluginWebAction is a checked bridge request for the host to carry out.
type PluginWebAction struct {
	ID     uint64          `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

// PluginWebRequestOutcome is one of: Reply, a message to post back at once;
// Action, a request to carry out; or Ignored, why nothing can be answered.
type PluginWebRequestOutcome struct {
	Reply   string           `json:"reply"`
	Action  *PluginWebAction `json:"action"`
	Ignored string           `json:"ignored"`
}

// PluginWebRequest checks one message a page posted (plugins.web.request).
func (c *Client) PluginWebRequest(ctx context.Context, page uint64, message string) (PluginWebRequestOutcome, error) {
	var outcome PluginWebRequestOutcome
	err := c.Execute(ctx, "plugins.web.request", struct {
		Page    uint64 `json:"page"`
		Message string `json:"message"`
	}{page, message}, &outcome)
	return outcome, err
}

// PluginWebError is a failure answered to a page; codes pass through as
// Core, the plugin or the bridge reported them.
type PluginWebError struct {
	Code            string `json:"code"`
	Message         string `json:"message"`
	PluginErrorCode string `json:"pluginErrorCode,omitempty"`
}

// PluginWebReply is the host's answer to an action. Exactly one of Result
// and Error is set; Call is the function call the action held.
type PluginWebReply struct {
	Page   uint64          `json:"page"`
	ID     uint64          `json:"id"`
	Method string          `json:"method"`
	Call   string          `json:"call,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *PluginWebError `json:"error,omitempty"`
}

// PluginWebReply frames an answer and releases what its action held
// (plugins.web.reply). The message is empty when the page closed meanwhile.
func (c *Client) PluginWebReply(ctx context.Context, reply PluginWebReply) (string, error) {
	var result struct {
		Message *string `json:"message"`
	}
	if err := c.Execute(ctx, "plugins.web.reply", reply, &result); err != nil || result.Message == nil {
		return "", err
	}
	return *result.Message, nil
}

// PluginWebEvent frames an event for a page (plugins.web.event). The message
// is empty when nothing is to be delivered.
func (c *Client) PluginWebEvent(ctx context.Context, page uint64, event string, payload any) (string, error) {
	var result struct {
		Message *string `json:"message"`
	}
	err := c.Execute(ctx, "plugins.web.event", struct {
		Page    uint64 `json:"page"`
		Event   string `json:"event"`
		Payload any    `json:"payload"`
	}{page, event, payload}, &result)
	if err != nil || result.Message == nil {
		return "", err
	}
	return *result.Message, nil
}
