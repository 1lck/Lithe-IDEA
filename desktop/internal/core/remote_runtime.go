package core

import (
	"context"
	"errors"
	"path"
)

// RemoteManagedRuntimeLayout binds a cache entry to the approved archive and its native layout.
type RemoteManagedRuntimeLayout struct {
	Key           RemotePluginDeployment `json:"key"`
	ArchiveSHA256 string                 `json:"archiveSha256"`
	Archive       string                 `json:"archive"`
	StripPrefix   string                 `json:"stripPrefix"`
	Home          string                 `json:"home"`
	Executable    string                 `json:"executable"`
}

// RemoteManagedRuntimePaths are verified by the workspace host and live for the session.
type RemoteManagedRuntimePaths struct {
	Home       string `json:"home"`
	Executable string `json:"executable"`
}

// LookupRemoteManagedRuntime returns nil on a cache miss and otherwise leases the runtime.
func (c *Client) LookupRemoteManagedRuntime(ctx context.Context, layout RemoteManagedRuntimeLayout) (*RemoteManagedRuntimePaths, error) {
	return c.remoteManagedRuntime(ctx, "fs.managedRuntimeLookup", layout, layout.Executable != "")
}

// CreateRemoteRuntimeStaging allocates connection-owned scratch for a plugin or runtime deployment.
func (c *Client) CreateRemoteRuntimeStaging(ctx context.Context, id string) (string, error) {
	return c.createRemoteRunDirectory(ctx, "fs.createRuntimeStaging", id)
}

// CommitRemoteManagedRuntime verifies and unpacks the upload before leasing the published runtime.
func (c *Client) CommitRemoteManagedRuntime(ctx context.Context, layout RemoteManagedRuntimeLayout, id string) (*RemoteManagedRuntimePaths, error) {
	const method = "fs.managedRuntimeCommit"
	result, err := c.remoteManagedRuntime(ctx, method, struct {
		Layout      RemoteManagedRuntimeLayout `json:"layout"`
		DirectoryID string                     `json:"directoryId"`
	}{layout, id}, layout.Executable != "")
	if result == nil && err == nil {
		return nil, errors.New("core: remote runtime commit returned no installation")
	}
	return result, err
}

func (c *Client) remoteManagedRuntime(ctx context.Context, method string, payload any, executable bool) (*RemoteManagedRuntimePaths, error) {
	var result *RemoteManagedRuntimePaths
	if err := c.remoteWorkspaceHostRequest(ctx, method, payload, &result); err != nil || result == nil {
		return nil, err
	}
	if !path.IsAbs(result.Home) || (executable && !path.IsAbs(result.Executable)) || (!executable && result.Executable != "") {
		return nil, errors.New("core: invalid remote runtime installation paths")
	}
	return result, nil
}
