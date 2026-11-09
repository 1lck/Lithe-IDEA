package core

import (
	"context"
	"encoding/json"
)

// DebugGeneration binds prepared facts to their still-current source snapshot.
type DebugGeneration struct {
	Generation        uint64 `json:"generation"`
	CurrentGeneration uint64 `json:"currentGeneration"`
}

// DebugTargetFacts are native observations, not adapter-specific DAP fields.
type DebugTargetFacts struct {
	Kind             string            `json:"kind"`
	Path             string            `json:"path,omitempty"`
	WorkingDirectory string            `json:"workingDirectory,omitempty"`
	Executable       string            `json:"executable,omitempty"`
	Arguments        []string          `json:"arguments"`
	Environment      map[string]string `json:"environment"`
}

// DebugStartFacts describe the registration, runtime and debuggee of one start.
type DebugStartFacts struct {
	Registration     DebugGeneration  `json:"registration"`
	RuntimeSelection *DebugGeneration `json:"runtimeSelection,omitempty"`
	Target           DebugTargetFacts `json:"target"`
}

// DebugExecutablePlan is Core's ordered native file lookup, or nil when unnecessary.
type DebugExecutablePlan struct {
	Setting    string `json:"setting"`
	Configured *struct {
		Path   string `json:"path"`
		Source string `json:"source"`
	} `json:"configured"`
	Candidates []string `json:"candidates"`
}

// PlanPluginDebugAdapter expands the same verified process declaration as other providers.
func (c *Client) PlanPluginDebugAdapter(ctx context.Context, manifest json.RawMessage, adapterID string, directories PluginBackendDirectories) (PluginBackendPlan, error) {
	return c.planPluginLaunch(ctx, struct {
		Manifest       json.RawMessage          `json:"manifest"`
		DebugAdapterID string                   `json:"debugAdapterID"`
		Request        PluginBackendDirectories `json:"request"`
	}{manifest, adapterID, directories})
}

// PlanDebugExecutable asks Core to expand the plugin's target lookup and settings.
func (c *Client) PlanDebugExecutable(ctx context.Context, manifest json.RawMessage, adapterID, workspace, targetPath string, settings, projectSettings map[string]json.RawMessage) (*DebugExecutablePlan, error) {
	const command = "debug.adapters.executablePlan"
	var result struct {
		Status string                `json:"status"`
		Error  *MarketplaceRejection `json:"error"`
		Plan   *DebugExecutablePlan  `json:"plan"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest        json.RawMessage            `json:"manifest"`
		AdapterID       string                     `json:"adapterID"`
		Workspace       string                     `json:"workspace"`
		TargetPath      string                     `json:"targetPath,omitempty"`
		Settings        map[string]json.RawMessage `json:"settings,omitempty"`
		ProjectSettings map[string]json.RawMessage `json:"projectSettings,omitempty"`
	}{manifest, adapterID, workspace, targetPath, settings, projectSettings}, &result); err != nil {
		return nil, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return nil, result.Error
	}
	if result.Status != "ok" {
		return nil, newParseError(command, "invalid executable lookup outcome", "")
	}
	return result.Plan, nil
}

// DebugStartArguments validates facts and projects them through the adapter's bindings.
func (c *Client) DebugStartArguments(ctx context.Context, manifest json.RawMessage, adapterID, request string, facts DebugStartFacts) (map[string]any, error) {
	const command = "debug.adapters.startArguments"
	var result struct {
		Status    string                `json:"status"`
		Error     *MarketplaceRejection `json:"error"`
		Arguments map[string]any        `json:"arguments"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest  json.RawMessage `json:"manifest"`
		AdapterID string          `json:"adapterID"`
		Request   string          `json:"request"`
		Facts     DebugStartFacts `json:"facts"`
	}{manifest, adapterID, request, facts}, &result); err != nil {
		return nil, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return nil, result.Error
	}
	if result.Status != "ok" || result.Arguments == nil {
		return nil, newParseError(command, "invalid debug start arguments", "")
	}
	return result.Arguments, nil
}
