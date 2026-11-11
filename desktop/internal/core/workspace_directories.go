package core

import (
	"context"
	"encoding/json"
)

// emptyDirectoryRules are the rules of a root that has none stored yet, in the shape Core keeps.
var emptyDirectoryRules = json.RawMessage(`{"marks":{},"includedDirectories":[],"previousRoles":{}}`)

// EmptyDirectoryRules are the directory rules of a root with none stored yet.
func EmptyDirectoryRules() json.RawMessage {
	return append(json.RawMessage(nil), emptyDirectoryRules...)
}

// ExcludeDirectory applies the exclusion of the directory path (workspace-relative, "." for the
// root) to rules, the persisted rule state of the root, and returns the complete state to store
// and whether it changed. The state is returned unchanged by the caller; it is never reinterpreted.
//
// ExcludeDirectory is a pure Core call; it does not read the disk.
func (c *Client) ExcludeDirectory(ctx context.Context, path string, caseInsensitive bool, rules json.RawMessage) (bool, json.RawMessage, error) {
	if len(rules) == 0 {
		rules = emptyDirectoryRules
	}
	payload := struct {
		Path            string          `json:"path"`
		Action          map[string]any  `json:"action"`
		CaseInsensitive bool            `json:"caseInsensitive"`
		Rules           json.RawMessage `json:"rules"`
	}{path, map[string]any{"kind": "exclude"}, caseInsensitive, rules}
	var response struct {
		Changed bool            `json:"changed"`
		Rules   json.RawMessage `json:"rules"`
	}
	if err := c.Execute(ctx, "workspace.reduceDirectoryAction", payload, &response); err != nil {
		return false, nil, err
	}
	return response.Changed, response.Rules, nil
}
