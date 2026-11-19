package core

import (
	"context"
	"encoding/json"
)

// ManagedRuntimePlatform uses plugin contract platform tokens, independent of Go names.
type ManagedRuntimePlatform struct {
	OS   string `json:"os"`
	Arch string `json:"arch"`
}

// ManagedRuntimeResolver is the packaged backend function that verifies a dependency set.
type ManagedRuntimeResolver struct {
	Function            string `json:"function"`
	TimeoutMilliseconds int    `json:"timeoutMilliseconds"`
}

// ManagedRuntimeDependency is Core's platform-selected, content-addressed download plan.
// Home is relative to the extracted root after StripPrefix; Executable is relative to Home.
type ManagedRuntimeDependency struct {
	ID          string   `json:"id"`
	Version     string   `json:"version"`
	Tool        string   `json:"tool,omitempty"`
	OS          string   `json:"os"`
	Arch        string   `json:"arch"`
	URL         string   `json:"url"`
	Mirrors     []string `json:"mirrors,omitempty"`
	SHA256      string   `json:"sha256"`
	Archive     string   `json:"archive"`
	StripPrefix string   `json:"stripPrefix"`
	Home        string   `json:"home"`
	Executable  string   `json:"executable"`
	CacheKey    string   `json:"cacheKey"`
}

// ManagedRuntimePlan describes downloads and the plugin-owned compatibility check.
type ManagedRuntimePlan struct {
	Resolve      *ManagedRuntimeResolver    `json:"resolve,omitempty"`
	Dependencies []ManagedRuntimeDependency `json:"dependencies"`
}

// ManagedRuntimeInstallation is a validated read-only home, managed or external.
type ManagedRuntimeInstallation struct {
	ID      string `json:"id"`
	Home    string `json:"home"`
	Version string `json:"version"`
}

// ManagedRuntimeResolution partitions every declared dependency into usable or missing.
type ManagedRuntimeResolution struct {
	Runtimes []ManagedRuntimeInstallation `json:"runtimes"`
	Missing  []string                     `json:"missing"`
}

// PlanManagedRuntimes validates the manifest and chooses immutable artifacts for a platform.
func (c *Client) PlanManagedRuntimes(ctx context.Context, manifest json.RawMessage, platform ManagedRuntimePlatform) (ManagedRuntimePlan, error) {
	const command = "plugins.managedRuntimes.plan"
	var result struct {
		Status string                `json:"status"`
		Error  *MarketplaceRejection `json:"error"`
		Plan   *ManagedRuntimePlan   `json:"plan"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest json.RawMessage        `json:"manifest"`
		Platform ManagedRuntimePlatform `json:"platform"`
	}{manifest, platform}, &result); err != nil {
		return ManagedRuntimePlan{}, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return ManagedRuntimePlan{}, result.Error
	}
	if result.Status != "ok" || result.Plan == nil {
		return ManagedRuntimePlan{}, newParseError(command, "runtime plan returned an invalid outcome", "")
	}
	return *result.Plan, nil
}

// DecodeManagedRuntimeResolution checks the plugin's answer before native paths are consumed.
func (c *Client) DecodeManagedRuntimeResolution(ctx context.Context, manifest json.RawMessage, platform ManagedRuntimePlatform, answer json.RawMessage) (ManagedRuntimeResolution, error) {
	const command = "plugins.managedRuntimes.decodeResolution"
	var result struct {
		Status     string                    `json:"status"`
		Error      *MarketplaceRejection     `json:"error"`
		Resolution *ManagedRuntimeResolution `json:"resolution"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest json.RawMessage        `json:"manifest"`
		Platform ManagedRuntimePlatform `json:"platform"`
		Result   json.RawMessage        `json:"result"`
	}{manifest, platform, answer}, &result); err != nil {
		return ManagedRuntimeResolution{}, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return ManagedRuntimeResolution{}, result.Error
	}
	if result.Status != "ok" || result.Resolution == nil {
		return ManagedRuntimeResolution{}, newParseError(command, "runtime resolution returned an invalid outcome", "")
	}
	return *result.Resolution, nil
}
