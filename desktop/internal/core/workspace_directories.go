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

// CustomDirectoryType is a user-defined folder mode combining visual styling with indexing
// and inheritance traits, validated and persisted by Core.
type CustomDirectoryType struct {
	ID              string `json:"id"`
	Name            string `json:"name"`
	Tag             string `json:"tag,omitempty"`
	Icon            string `json:"icon"`
	Color           string `json:"color"`
	TintBg          bool   `json:"tintBg"`
	TintText        bool   `json:"tintText"`
	InheritBg       bool   `json:"inheritBg"`
	ExcludeIndexing bool   `json:"excludeIndexing"`
	ReadOnlyHint    bool   `json:"readOnlyHint"`
	MatchGlob       string `json:"matchGlob,omitempty"`
}

// CustomDirectoryIcon is a user-imported SVG icon entry managed by Core rules.
type CustomDirectoryIcon struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Path string `json:"path"`
}

// PluginDirectoryType is a directory type dynamically contributed by a plugin session.
type PluginDirectoryType struct {
	PluginID        string `json:"pluginId"`
	ID              string `json:"id"`
	Name            string `json:"name"`
	Tag             string `json:"tag,omitempty"`
	Icon            string `json:"icon"`
	Color           string `json:"color"`
	TintBg          bool   `json:"tintBg"`
	TintText        bool   `json:"tintText"`
	InheritBg       bool   `json:"inheritBg"`
	ExcludeIndexing bool   `json:"excludeIndexing"`
	ReadOnlyHint    bool   `json:"readOnlyHint"`
	MatchGlob       string `json:"matchGlob,omitempty"`
}

// PluginDirectoryMark is a directory mark dynamically contributed by a plugin session.
type PluginDirectoryMark struct {
	PluginID string `json:"pluginId"`
	Path     string `json:"path"`
	Role     string `json:"role"`
	Color    string `json:"color,omitempty"`
}

// DirectoryRulesState is a read-only view of persisted directory rules used by UI selectors
// and settings forms. Mutations always go through Core's workspace.reduceDirectoryAction.
type DirectoryRulesState struct {
	Marks               map[string]string     `json:"marks"`
	IncludedDirectories []string              `json:"includedDirectories"`
	PreviousRoles       map[string]string     `json:"previousRoles"`
	CustomTypes         []CustomDirectoryType `json:"customTypes,omitempty"`
	CustomIcons         []CustomDirectoryIcon `json:"customIcons,omitempty"`
	Colors              map[string]string     `json:"colors,omitempty"`
}

// ParseDirectoryRules decodes the persisted rules JSON for display purposes.
func ParseDirectoryRules(rules json.RawMessage) DirectoryRulesState {
	var state DirectoryRulesState
	if len(rules) == 0 {
		return state
	}
	_ = json.Unmarshal(rules, &state) // log-exempt: display-only decode of Core-owned state; invalid files are guarded by unreadable flag
	return state
}

// ResolvedDirectoryEntry is Core's deterministic presentation and indexing answer for one
// workspace-relative path.
type ResolvedDirectoryEntry struct {
	Role             string `json:"role"`
	Source           string `json:"source"`
	PluginID         string `json:"pluginId,omitempty"`
	Icon             string `json:"icon"`
	Color            string `json:"color,omitempty"`
	BgColor          string `json:"bgColor,omitempty"`
	TintText         bool   `json:"tintText"`
	Tag              string `json:"tag,omitempty"`
	Excluded         bool   `json:"excluded"`
	ReadOnlyHint     bool   `json:"readOnlyHint"`
	AutoFallbackRole string `json:"autoFallbackRole,omitempty"`
}

// DirectoryPresentationResult is the response of workspace.resolveDirectoryPresentation.
type DirectoryPresentationResult struct {
	Entries                   map[string]ResolvedDirectoryEntry `json:"entries"`
	ManualExcludedDirectories []string                          `json:"manualExcludedDirectories"`
}

func (c *Client) reduceDirectoryAction(ctx context.Context, path string, action map[string]any, caseInsensitive bool, rules json.RawMessage) (bool, json.RawMessage, error) {
	if len(rules) == 0 {
		rules = emptyDirectoryRules
	}
	payload := struct {
		Path            string          `json:"path"`
		Action          map[string]any  `json:"action"`
		CaseInsensitive bool            `json:"caseInsensitive"`
		Rules           json.RawMessage `json:"rules"`
	}{path, action, caseInsensitive, rules}
	var response struct {
		Changed bool            `json:"changed"`
		Rules   json.RawMessage `json:"rules"`
	}
	if err := c.Execute(ctx, "workspace.reduceDirectoryAction", payload, &response); err != nil {
		return false, nil, err
	}
	return response.Changed, response.Rules, nil
}

// ExcludeDirectory applies the exclusion of the directory path (workspace-relative, "." for the
// root) to rules, the persisted rule state of the root, and returns the complete state to store
// and whether it changed. The state is returned unchanged by the caller; it is never reinterpreted.
//
// ExcludeDirectory is a pure Core call; it does not read the disk.
func (c *Client) ExcludeDirectory(ctx context.Context, path string, caseInsensitive bool, rules json.RawMessage) (bool, json.RawMessage, error) {
	return c.reduceDirectoryAction(ctx, path, map[string]any{"kind": "exclude"}, caseInsensitive, rules)
}

// CancelDirectoryExclusion undoes the exclusion of path in rules: a manual exclusion gives
// the folder back the role it had, a Git exclusion becomes an include exception.
func (c *Client) CancelDirectoryExclusion(ctx context.Context, path string, caseInsensitive bool, rules json.RawMessage) (bool, json.RawMessage, error) {
	return c.reduceDirectoryAction(ctx, path, map[string]any{"kind": "cancelExclusion"}, caseInsensitive, rules)
}

// SetDirectoryRole assigns a built-in role (other than excluded) or a custom.* type ID to path.
func (c *Client) SetDirectoryRole(ctx context.Context, path, role string, caseInsensitive bool, rules json.RawMessage) (bool, json.RawMessage, error) {
	return c.reduceDirectoryAction(ctx, path, map[string]any{"kind": "setRole", "role": role}, caseInsensitive, rules)
}

// ClearDirectoryMark removes the directory's explicit mark, remembered role and color override.
func (c *Client) ClearDirectoryMark(ctx context.Context, path string, caseInsensitive bool, rules json.RawMessage) (bool, json.RawMessage, error) {
	return c.reduceDirectoryAction(ctx, path, map[string]any{"kind": "clearMark"}, caseInsensitive, rules)
}

// SetDirectoryColor sets or clears (when color is empty) a #rrggbb quick color override on path.
func (c *Client) SetDirectoryColor(ctx context.Context, path, color string, caseInsensitive bool, rules json.RawMessage) (bool, json.RawMessage, error) {
	var colorVal any
	if color != "" {
		colorVal = color
	}
	return c.reduceDirectoryAction(ctx, path, map[string]any{"kind": "setColor", "color": colorVal}, caseInsensitive, rules)
}

// UpsertCustomDirectoryType inserts or updates a custom directory type in rules.
func (c *Client) UpsertCustomDirectoryType(ctx context.Context, dirType CustomDirectoryType, rules json.RawMessage) (bool, json.RawMessage, error) {
	return c.reduceDirectoryAction(ctx, ".", map[string]any{"kind": "upsertCustomType", "directoryType": dirType}, false, rules)
}

// DeleteCustomDirectoryType deletes a custom directory type and clears marks referencing it.
func (c *Client) DeleteCustomDirectoryType(ctx context.Context, id string, rules json.RawMessage) (bool, json.RawMessage, error) {
	return c.reduceDirectoryAction(ctx, ".", map[string]any{"kind": "deleteCustomType", "id": id}, false, rules)
}

// UpsertCustomDirectoryIcon inserts or updates a user-imported custom icon in rules.
func (c *Client) UpsertCustomDirectoryIcon(ctx context.Context, dirIcon CustomDirectoryIcon, rules json.RawMessage) (bool, json.RawMessage, error) {
	return c.reduceDirectoryAction(ctx, ".", map[string]any{"kind": "upsertCustomIcon", "directoryIcon": dirIcon}, false, rules)
}

// DeleteCustomDirectoryIcon removes a custom icon and falls back referencing custom types to folder.
func (c *Client) DeleteCustomDirectoryIcon(ctx context.Context, id string, rules json.RawMessage) (bool, json.RawMessage, error) {
	return c.reduceDirectoryAction(ctx, ".", map[string]any{"kind": "deleteCustomIcon", "id": id}, false, rules)
}

// RelocateDirectoryRules migrates directory marks, previous roles, include exceptions and
// color overrides after a rename/move (when destination is non-empty) or drops them after a
// delete (when destination is empty).
func (c *Client) RelocateDirectoryRules(ctx context.Context, source, destination string, caseInsensitive bool, rules json.RawMessage) (json.RawMessage, error) {
	if len(rules) == 0 {
		rules = emptyDirectoryRules
	}
	payload := struct {
		Source          string          `json:"source"`
		Destination     *string         `json:"destination,omitempty"`
		CaseInsensitive bool            `json:"caseInsensitive,omitempty"`
		Rules           json.RawMessage `json:"rules"`
	}{
		Source:          source,
		CaseInsensitive: caseInsensitive,
		Rules:           rules,
	}
	if destination != "" {
		payload.Destination = &destination
	}
	var response struct {
		Rules json.RawMessage `json:"rules"`
	}
	if err := c.Execute(ctx, "workspace.relocateDirectoryRules", payload, &response); err != nil {
		return nil, err
	}
	return response.Rules, nil
}

// ResolveDirectoryPresentation computes deterministic per-path presentation and effective
// manual exclusions across user rules, optional shared project rules, plugin contributions,
// glob matches and Git ignores.
func (c *Client) ResolveDirectoryPresentation(ctx context.Context, rules, sharedRules json.RawMessage, pluginTypes []PluginDirectoryType, pluginMarks []PluginDirectoryMark, gitExcluded []string, caseInsensitive bool, paths []string) (DirectoryPresentationResult, error) {
	if len(rules) == 0 {
		rules = emptyDirectoryRules
	}
	// Core rejects a null paths; with no rows or glob candidates to ask about, explicit
	// exclusions still come back in manualExcludedDirectories.
	if paths == nil {
		paths = []string{}
	}
	payload := struct {
		Rules           json.RawMessage       `json:"rules"`
		SharedRules     json.RawMessage       `json:"sharedRules,omitempty"`
		PluginTypes     []PluginDirectoryType `json:"pluginTypes,omitempty"`
		PluginMarks     []PluginDirectoryMark `json:"pluginMarks,omitempty"`
		GitExcluded     []string              `json:"gitExcluded,omitempty"`
		CaseInsensitive bool                  `json:"caseInsensitive,omitempty"`
		Paths           []string              `json:"paths"`
	}{
		Rules:           rules,
		SharedRules:     sharedRules,
		PluginTypes:     pluginTypes,
		PluginMarks:     pluginMarks,
		GitExcluded:     gitExcluded,
		CaseInsensitive: caseInsensitive,
		Paths:           paths,
	}
	var result DirectoryPresentationResult
	if err := c.Execute(ctx, "workspace.resolveDirectoryPresentation", payload, &result); err != nil {
		return DirectoryPresentationResult{}, err
	}
	return result, nil
}
