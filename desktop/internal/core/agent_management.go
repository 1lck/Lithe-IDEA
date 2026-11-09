package core

import (
	"context"
	"encoding/json"
	"errors"
)

// AgentTool is an executable and version actually found by Core on the login PATH.
type AgentTool struct {
	Version string `json:"version"`
	Path    string `json:"path"`
}

// AgentEnvironment contains the user's own runtime, not one installed by Lithe.
type AgentEnvironment struct {
	Node           *AgentTool `json:"node"`
	NPM            *AgentTool `json:"npm"`
	UsedLoginShell bool       `json:"usedLoginShell"`
}

// AgentCLIInstallation reports the owner and the owner's read-only update check.
// An absent update result is unknown, not false; UpdateHint is display text and
// must never be executed as a command.
type AgentCLIInstallation struct {
	Source           string  `json:"source"`
	CanUpdate        bool    `json:"canUpdate"`
	UpdateHint       string  `json:"updateHint"`
	UpdateAvailable  *bool   `json:"updateAvailable"`
	AvailableVersion *string `json:"availableVersion"`
	UpdateCheckError *string `json:"updateCheckError"`
}

// AgentCLIStatus describes the user's CLI required by an adapter, if any.
type AgentCLIStatus struct {
	Name           string                `json:"name"`
	Command        string                `json:"command"`
	MinimumVersion string                `json:"minimumVersion"`
	InstallHint    string                `json:"installHint"`
	Package        string                `json:"package"`
	Detected       *AgentTool            `json:"detected"`
	Installation   *AgentCLIInstallation `json:"installation"`
}

// AgentCatalogStatus is Core's verified adapter catalog and detected state.
type AgentCatalogStatus struct {
	ID               string          `json:"id"`
	Name             string          `json:"name"`
	Description      string          `json:"description"`
	Package          string          `json:"package"`
	Version          string          `json:"version"`
	InstalledVersion *string         `json:"installedVersion"`
	UpdateAvailable  *bool           `json:"updateAvailable"`
	Protocol         string          `json:"protocol"`
	MinimumNodeMajor uint32          `json:"minimumNodeMajor"`
	Verified         bool            `json:"verified"`
	CLI              *AgentCLIStatus `json:"cli"`
	Issues           []string        `json:"issues"`
}

// AgentManagementStatus describes actual detection and every supported adapter.
type AgentManagementStatus struct {
	Environment AgentEnvironment     `json:"environment"`
	Agents      []AgentCatalogStatus `json:"agents"`
}

// ReadAgentManagementStatus asks Core to detect the runtime, installed adapters
// and update ownership. It may run bounded read-only tool/version probes and
// must be called off the UI thread. It never initiates an install or update.
func (c *Client) ReadAgentManagementStatus(ctx context.Context, dataDirectory string) (AgentManagementStatus, error) {
	var result AgentManagementStatus
	err := c.Execute(ctx, "agent.status", struct {
		DataDirectory string `json:"dataDirectory"`
	}{DataDirectory: dataDirectory}, &result)
	return result, err
}

// AgentInstallProgress reports Core's actual transfer counters. The total is
// unknown; elapsed and idle are milliseconds, not a completion percentage.
type AgentInstallProgress struct {
	Stage               string `json:"stage"`
	DownloadedBytes     uint64 `json:"downloadedBytes"`
	BytesPerSecond      uint64 `json:"bytesPerSecond"`
	ElapsedMilliseconds uint64 `json:"elapsedMilliseconds"`
	IdleMilliseconds    uint64 `json:"idleMilliseconds"`
}

type agentInstallRequest struct {
	DataDirectory string `json:"dataDirectory"`
	AgentID       string `json:"agentId"`
}

// AgentAdapterInstallResult is Core's confirmed adapter version.
type AgentAdapterInstallResult struct {
	AgentID          string `json:"agentId"`
	InstalledVersion string `json:"installedVersion"`
}

// AgentCLIInstallResult contains the CLI version Core verified after updating.
// UpdaterWarning is separate from the operation error when a retry recovered.
type AgentCLIInstallResult struct {
	AgentID        string  `json:"agentId"`
	CLIVersion     string  `json:"cliVersion"`
	UpdaterWarning *string `json:"updaterWarning"`
}

// InstallAgentAdapter runs Core's adapter install after an explicit user action.
// The progress observer is synchronous and must return promptly. Observation
// failure and the install result are independent: never retry solely because
// progress was lost; refresh the actual installation state first.
func (c *Client) InstallAgentAdapter(ctx context.Context, dataDirectory, agentID string, progress func(AgentInstallProgress)) (AgentAdapterInstallResult, error, error) {
	var result AgentAdapterInstallResult
	observationErr, requestErr := c.runAgentInstall(ctx, "agent.install", dataDirectory, agentID, &result, progress)
	return result, observationErr, requestErr
}

// InstallAgentCLI asks Core to install or update the user's CLI through its
// verified owner. It is only for an explicit user action; Core determines the
// allowed updater and verifies the resulting version.
func (c *Client) InstallAgentCLI(ctx context.Context, dataDirectory, agentID string, progress func(AgentInstallProgress)) (AgentCLIInstallResult, error, error) {
	var result AgentCLIInstallResult
	observationErr, requestErr := c.runAgentInstall(ctx, "agent.installCli", dataDirectory, agentID, &result, progress)
	return result, observationErr, requestErr
}

// UninstallAgentAdapter removes only a Core-managed adapter after an explicit
// user action. It does not uninstall the user's CLI.
func (c *Client) UninstallAgentAdapter(ctx context.Context, dataDirectory, agentID string) error {
	return c.Execute(ctx, "agent.uninstall", agentInstallRequest{dataDirectory, agentID}, nil)
}

func (c *Client) runAgentInstall(ctx context.Context, command, dataDirectory, agentID string, result any, progress func(AgentInstallProgress)) (error, error) {
	var decodeErr error
	var observe func(json.RawMessage)
	if progress != nil {
		observe = func(raw json.RawMessage) {
			if decodeErr != nil {
				return
			}
			value, isProgress, err := decodeAgentInstallProgress(raw)
			if err != nil {
				decodeErr = err
			} else if isProgress {
				progress(value)
			}
		}
	}
	observationErr, requestErr := c.ExecuteWithEvents(ctx, command, agentInstallRequest{dataDirectory, agentID}, result, observe)
	return errors.Join(observationErr, decodeErr), requestErr
}

func decodeAgentInstallProgress(raw json.RawMessage) (AgentInstallProgress, bool, error) {
	var event struct {
		Kind     string          `json:"kind"`
		Progress json.RawMessage `json:"progress"`
	}
	if err := json.Unmarshal(raw, &event); err != nil {
		return AgentInstallProgress{}, false, ErrCoreEventsLost
	}
	if event.Kind != "agentInstallProgress" {
		return AgentInstallProgress{}, false, nil
	}
	var value AgentInstallProgress
	if len(event.Progress) == 0 || json.Unmarshal(event.Progress, &value) != nil || value.Stage == "" {
		return AgentInstallProgress{}, false, ErrCoreEventsLost
	}
	return value, true, nil
}
