package core

import (
	"context"
	"encoding/json"
)

// PluginFileRequest reads a resource through the remote workspace binding on
// the request context. Only openDocument accepts absolute host paths.
type PluginFileRequest struct {
	RootID     string              `json:"rootID"`
	Generation uint64              `json:"generation"`
	Attachment uint64              `json:"attachment"`
	Path       string              `json:"path"`
	Operation  PluginFileOperation `json:"operation"`
}

// PluginFileOperation selects a directory page, metadata, a bounded file read, or disk search.
type PluginFileOperation struct {
	Kind              string  `json:"kind"`
	Cursor            *string `json:"cursor,omitempty"`
	Limit             *int64  `json:"limit,omitempty"`
	MaximumBytes      *int64  `json:"maximumBytes,omitempty"`
	Query             *string `json:"query,omitempty"`
	Pattern           *string `json:"pattern,omitempty"`
	FileMask          *string `json:"fileMask,omitempty"`
	CaseSensitive     *bool   `json:"caseSensitive,omitempty"`
	WholeWords        *bool   `json:"wholeWords,omitempty"`
	RegularExpression *bool   `json:"regularExpression,omitempty"`
}

// ReadPluginFile returns a result already shaped for the plugin protocol.
func (c *Client) ReadPluginFile(ctx context.Context, request PluginFileRequest) (json.RawMessage, error) {
	var result json.RawMessage
	err := c.Execute(ctx, "workspace.pluginFile", request, &result)
	return result, err
}

// ReadWorkspaceConfiguration reads the settings source Core selected, over the
// request's remote connection. A nil text means the source does not exist.
func (c *Client) ReadWorkspaceConfiguration(ctx context.Context, path string, maximumBytes int64) (*string, error) {
	var result struct {
		Text *string `json:"text"`
	}
	err := c.Execute(ctx, "workspace.readConfiguration", struct {
		Path         string `json:"path"`
		MaximumBytes int64  `json:"maximumBytes"`
	}{path, maximumBytes}, &result)
	return result.Text, err
}

// ProjectPluginSettingsBaseline identifies the opened host directory and the
// exact source bytes. Neither the path nor the revision is editable UI state.
type ProjectPluginSettingsBaseline struct {
	WorkspaceIdentity string  `json:"workspaceIdentity"`
	BaseSHA256        *string `json:"baseSha256"`
}

// ProjectPluginSettings contains the private source and baseline for an editor.
type ProjectPluginSettings struct {
	Path     string                        `json:"path"`
	Text     *string                       `json:"text"`
	Baseline ProjectPluginSettingsBaseline `json:"baseline"`
}

// ReadProjectPluginSettings captures the preferences file on the bound host.
func (c *Client) ReadProjectPluginSettings(ctx context.Context) (ProjectPluginSettings, error) {
	var source ProjectPluginSettings
	err := c.Execute(ctx, "workspace.readPluginSettings", nil, &source)
	return source, err
}

// PublishProjectPluginSettings returns a committed write and distinguishes a
// stale remote source from transport or I/O failures.
func (c *Client) PublishProjectPluginSettings(ctx context.Context, baseline ProjectPluginSettingsBaseline, content *string) (committed, conflict bool, err error) {
	var result struct {
		Committed bool `json:"committed"`
	}
	err = c.Execute(ctx, "workspace.publishPluginSettings", struct {
		Baseline ProjectPluginSettingsBaseline `json:"baseline"`
		Content  *string                       `json:"content"`
	}{baseline, content}, &result)
	return result.Committed, remoteHostCode(err) == "CONFLICT", err
}

// PluginWatchChangesRequest describes one subscription and one batch of paths
// from its workspace's host watch.
type PluginWatchChangesRequest struct {
	RootID         string   `json:"rootID"`
	HostRoot       string   `json:"hostRoot"`
	Path           string   `json:"path"`
	Directory      bool     `json:"directory"`
	Recursive      bool     `json:"recursive"`
	HostPaths      []string `json:"hostPaths"`
	RequiresRescan bool     `json:"requiresRescan"`
}

// PluginWatchChanges projects scoped paths into a plugin event without disk I/O.
func (c *Client) PluginWatchChanges(ctx context.Context, request PluginWatchChangesRequest) (json.RawMessage, error) {
	var result json.RawMessage
	if request.HostPaths == nil {
		request.HostPaths = []string{}
	}
	err := c.Execute(WithoutRemoteWorkspace(ctx), "workspace.pluginWatchChanges", request, &result)
	return result, err
}
