package core

import (
	"context"
	"encoding/json"
	"errors"
)

// RemoteNativeSettingsTarget names a source in an authorized host directory.
type RemoteNativeSettingsTarget struct {
	Scope string `json:"scope"`
	Path  string `json:"path"`
}

// RemoteNativeSettingsBaseline is a host-issued identity for conditional publication.
type RemoteNativeSettingsBaseline struct {
	Target   RemoteNativeSettingsTarget `json:"target"`
	Identity string                     `json:"identity"`
	Revision string                     `json:"revision"`
	HostPath string                     `json:"hostPath"`
	Writable bool                       `json:"writable"`
}

// RemoteNativeSettingsReplacement identifies a staged output without returning source bytes.
type RemoteNativeSettingsReplacement struct {
	Slot     uint16                       `json:"slot"`
	Baseline RemoteNativeSettingsBaseline `json:"baseline"`
	Revision string                       `json:"revision"`
}

// InspectRemoteNativeSettings verifies source identities on the captured workspace host.
func (c *Client) InspectRemoteNativeSettings(ctx context.Context, targets []RemoteNativeSettingsTarget) ([]RemoteNativeSettingsBaseline, error) {
	var sources []RemoteNativeSettingsBaseline
	err := c.Execute(ctx, "workspace.nativeSettings", struct {
		Kind    string                       `json:"kind"`
		Targets []RemoteNativeSettingsTarget `json:"targets"`
	}{"inspect", targets}, &sources)
	return sources, err
}

// StageRemoteNativeSettings allocates existing empty output files within private host staging.
func (c *Client) StageRemoteNativeSettings(ctx context.Context, id string, baselines []RemoteNativeSettingsBaseline) ([]string, error) {
	var files []string
	err := c.Execute(ctx, "workspace.nativeSettings", struct {
		Kind        string                         `json:"kind"`
		DirectoryID string                         `json:"directoryId"`
		Baselines   []RemoteNativeSettingsBaseline `json:"baselines"`
	}{"stage", id, baselines}, &files)
	return files, err
}

// PublishRemoteNativeSettings consumes staging and preserves partial and uncertain outcomes.
func (c *Client) PublishRemoteNativeSettings(ctx context.Context, id string, replacements []RemoteNativeSettingsReplacement) (slots []uint16, uncertain bool, err error) {
	var result struct {
		Slots     []uint16 `json:"committedSlots"`
		Uncertain bool     `json:"publicationUncertain"`
	}
	err = c.Execute(ctx, "workspace.nativeSettings", struct {
		Kind         string                            `json:"kind"`
		DirectoryID  string                            `json:"directoryId"`
		Replacements []RemoteNativeSettingsReplacement `json:"replacements"`
	}{"publish", id, replacements}, &result)
	var failure *Error
	if errors.As(err, &failure) && failure.Details != "" {
		if decodeErr := json.Unmarshal([]byte(failure.Details), &result); decodeErr != nil {
			return nil, true, errors.Join(err, decodeErr)
		}
	}
	return result.Slots, result.Uncertain, err
}

// IsRemoteNativeSettingsConflict recognizes a host refusal of an outdated source.
func IsRemoteNativeSettingsConflict(err error) bool {
	return remoteHostCode(err) == "CONFLICT"
}
