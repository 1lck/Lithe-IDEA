package core

import (
	"context"
	"encoding/json"
)

// OutputLinkMatcher is one `outputLinkMatchers` declaration of a plugin as Core
// validated it. The host passes it back unchanged; Core owns what it means.
type OutputLinkMatcher struct {
	ID      string `json:"id"`
	Pattern string `json:"pattern"`
	Scope   string `json:"scope,omitempty"`
	Resolve *struct {
		Function string `json:"function"`
	} `json:"resolve,omitempty"`
}

// OutputLinkSource is the matchers of one enabled plugin.
type OutputLinkSource struct {
	PluginID string              `json:"pluginID"`
	Matchers []OutputLinkMatcher `json:"matchers"`
}

// OutputLinkRequest asks Core to find links in console lines. Scope is "run" or
// "test"; Platform is "macos", "windows" or "linux".
type OutputLinkRequest struct {
	Scope          string             `json:"scope"`
	Platform       string             `json:"platform"`
	WorkspaceRoots []string           `json:"workspaceRoots"`
	Sources        []OutputLinkSource `json:"sources"`
	Lines          []string           `json:"lines"`
}

// OutputLink is one clickable range of a console line. Start and Length count
// UTF-16 code units of the line. Exactly one of Location and Resolve is set.
type OutputLink struct {
	Line      int             `json:"line"`
	Start     int             `json:"start"`
	Length    int             `json:"length"`
	PluginID  string          `json:"pluginID"`
	MatcherID string          `json:"matcherID"`
	Location  *OutputLocation `json:"location"`
	Resolve   *struct {
		Function string          `json:"function"`
		Groups   json.RawMessage `json:"groups"`
	} `json:"resolve"`
}

// OutputLocation is where a link opens. Paths are candidates (the host opens
// the first that exists); a resolved location carries Path alone. Line and
// Column are 1-based when present.
type OutputLocation struct {
	Paths  []string `json:"paths,omitempty"`
	Path   string   `json:"path,omitempty"`
	Line   int      `json:"line,omitempty"`
	Column int      `json:"column,omitempty"`
}

// MatchOutputLinks finds the links of console lines. The lines are matched in
// source order and then declaration order; Core skips overlapping matches and
// paths that leave every workspace root.
func (c *Client) MatchOutputLinks(ctx context.Context, request OutputLinkRequest) ([]OutputLink, error) {
	var response struct {
		Links []OutputLink `json:"links"`
	}
	if err := c.Execute(ctx, "outputLinks.match", request, &response); err != nil {
		return nil, err
	}
	return response.Links, nil
}

// DecodeOutputLinkResolution checks the answer of a matcher's resolve function.
// A nil location means the backend found nothing.
func (c *Client) DecodeOutputLinkResolution(ctx context.Context, reply json.RawMessage) (*OutputLocation, error) {
	if len(reply) == 0 {
		reply = json.RawMessage("null")
	}
	var location *OutputLocation
	if err := c.Execute(ctx, "outputLinks.decodeResolution", struct {
		Reply json.RawMessage `json:"reply"`
	}{reply}, &location); err != nil {
		return nil, err
	}
	return location, nil
}
