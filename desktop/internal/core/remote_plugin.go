package core

import (
	"context"
	"errors"
	"path"
)

// RemotePluginDeployment identifies a content-addressed tree on the host.
type RemotePluginDeployment struct {
	PluginID string `json:"pluginId"`
	Version  string `json:"version"`
	SHA256   string `json:"sha256"`
}

// RemoteInstalledPluginVersion identifies a release retained by the desktop.
type RemoteInstalledPluginVersion struct {
	PluginID string `json:"pluginId"`
	Version  string `json:"version"`
}

// SweepRemotePluginDeployments removes unused versions absent from the complete inventory.
func (c *Client) SweepRemotePluginDeployments(ctx context.Context, installed []RemoteInstalledPluginVersion) error {
	return c.remoteWorkspaceHostRequest(ctx, "fs.pluginDeploymentSweep", struct {
		Installed []RemoteInstalledPluginVersion `json:"installed"`
	}{installed}, nil)
}

// LookupRemotePluginDeployment acquires a session lease if the deployment exists.
func (c *Client) LookupRemotePluginDeployment(ctx context.Context, key RemotePluginDeployment) (string, error) {
	return c.remotePluginPath(ctx, "fs.pluginDeploymentLookup", key)
}

// CommitRemotePluginDeployment publishes a complete package from private scratch.
func (c *Client) CommitRemotePluginDeployment(ctx context.Context, key RemotePluginDeployment, directoryID string) (string, error) {
	return c.remotePluginPath(ctx, "fs.pluginDeploymentCommit", struct {
		Key         RemotePluginDeployment `json:"key"`
		DirectoryID string                 `json:"directoryId"`
	}{key, directoryID})
}

func (c *Client) remotePluginPath(ctx context.Context, method string, params any) (string, error) {
	var result struct {
		Path string `json:"path"`
	}
	if err := c.remoteWorkspaceHostRequest(ctx, method, params, &result); err != nil {
		return "", err
	}
	if result.Path == "" && method == "fs.pluginDeploymentLookup" {
		return "", nil
	}
	if !path.IsAbs(result.Path) {
		return "", errors.New("core: invalid remote plugin deployment directory")
	}
	return result.Path, nil
}

// CreateRemotePluginDirectory prepares private staging on the captured host.
func (c *Client) CreateRemotePluginDirectory(ctx context.Context, directory string) error {
	return c.remoteWorkspaceHostRequest(ctx, "fs.createDir", struct {
		Path      string `json:"path"`
		Recursive bool   `json:"recursive"`
		Mode      uint32 `json:"mode"`
	}{directory, true, 0o700}, nil)
}

// UploadRemotePluginFile streams a verified file to the captured workspace.
func (c *Client) UploadRemotePluginFile(ctx context.Context, source, target, sha256 string, mode uint32) error {
	const command = "remote.uploadFile"
	// Session commands carry their session ID in the payload. Capture the
	// attachment from the operation so staging cannot follow a reconnection.
	binding := RemoteWorkspaceOf(ctx)
	connection := binding.CapturedConnection(ctx)
	sessionID := connection.SessionID()
	if sessionID == "" {
		return &Error{Command: command, Code: CodeConnectionClosed, Message: "the remote workspace is not connected"}
	}
	observer := remoteStageObserver(ctx)
	observationErr, err := c.ExecuteWithEvents(ctx, command, struct {
		SessionID      string `json:"sessionId"`
		SourcePath     string `json:"sourcePath"`
		Path           string `json:"path"`
		SHA256         string `json:"sha256"`
		Mode           uint32 `json:"mode"`
		ReportProgress bool   `json:"reportProgress,omitempty"`
	}{sessionID, source, target, sha256, mode, observer != nil}, nil, observer)
	remoteWorkspaceAnswered(binding, connection.session, err)
	return errors.Join(observationErr, err)
}
