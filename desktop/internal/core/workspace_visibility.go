package core

import (
	"context"
	"encoding/json"
)

// VisibilityConfiguration is Core's answer to workspace.configureVisibility.
type VisibilityConfiguration struct {
	// HiddenDirectoryNames are the folder names the enabled plugins hide in every workspace,
	// at any depth: their build systems' dependency, cache and output folders and their VCS
	// metadata folders. Core sorts them and drops duplicates; its own folders, such as .git,
	// are not among them.
	HiddenDirectoryNames []string `json:"hiddenDirectoryNames"`
	// Rejected are the manifests Core could not validate, by their index in the request, in the
	// form build.detect reports them. Such a manifest hides nothing.
	Rejected []BuildDetectionRejection `json:"rejected"`
}

// ConfigureVisibility replaces the folder names the enabled plugins hide with those that
// manifests, the manifests of every enabled plugin, declare. The list is Core's for the whole
// process: every tree listing, search, file event and history check made after the call obeys
// it, in every workspace. An empty list leaves only Core's own folders hidden.
func (c *Client) ConfigureVisibility(ctx context.Context, manifests []json.RawMessage) (VisibilityConfiguration, error) {
	type plugin struct {
		Manifest json.RawMessage `json:"manifest"`
	}
	plugins := make([]plugin, 0, len(manifests))
	for _, manifest := range manifests {
		plugins = append(plugins, plugin{Manifest: manifest})
	}
	var result VisibilityConfiguration
	if err := c.Execute(ctx, "workspace.configureVisibility", struct {
		Plugins []plugin `json:"plugins"`
	}{plugins}, &result); err != nil {
		return VisibilityConfiguration{}, err
	}
	return result, nil
}
