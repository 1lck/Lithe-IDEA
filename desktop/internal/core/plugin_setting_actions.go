package core

import (
	"context"
	"encoding/json"
)

// PluginSettingsOwner is the captured installed registration, not runtime admission.
type PluginSettingsOwner struct {
	PluginID string `json:"pluginID"`
	Version  string `json:"version"`
}

// PluginSettingsActionRequest supplies native facts for one explicitly selected action.
type PluginSettingsActionRequest struct {
	Enabled            bool                `json:"enabled"`
	Manifest           json.RawMessage     `json:"manifest"`
	Owner              PluginSettingsOwner `json:"owner"`
	ActionID           string              `json:"actionID"`
	Confirmed          bool                `json:"confirmed"`
	WorkspaceAvailable bool                `json:"workspaceAvailable"`
}

// PluginSettingsActionPlan is Core's checked confirmation or invocation projection.
// Only an invoke plan contains Function and Params; runtime ownership is checked
// again when the existing provider session receives that invocation.
type PluginSettingsActionPlan struct {
	Version  string          `json:"version"`
	Kind     string          `json:"kind"`
	PluginID string          `json:"pluginID"`
	ActionID string          `json:"actionID"`
	Title    string          `json:"title"`
	Reason   string          `json:"reason,omitempty"`
	Function string          `json:"function,omitempty"`
	Params   json.RawMessage `json:"params,omitempty"`
}

// PlanPluginSettingsAction resolves a manifest action without opening a backend
// or persisting a settings draft. Native callers own confirmation and identity.
func (c *Client) PlanPluginSettingsAction(ctx context.Context, request PluginSettingsActionRequest) (PluginSettingsActionPlan, error) {
	const command = "plugins.declarative.settingsActionPlan"
	var result struct {
		marketplaceOutcome
		Plan *PluginSettingsActionPlan `json:"plan"`
	}
	if err := c.Execute(ctx, command, request, &result); err != nil {
		return PluginSettingsActionPlan{}, err
	}
	if err := result.failure(command); err != nil {
		return PluginSettingsActionPlan{}, err
	}
	if result.Plan == nil {
		return PluginSettingsActionPlan{}, newParseError(command, "missing settings action plan", "")
	}
	return *result.Plan, nil
}

// PluginFunctionProviderCandidate binds a native-owned handle to its launch version.
type PluginFunctionProviderCandidate struct {
	SessionID string `json:"sessionID"`
	Version   string `json:"version"`
}

// SelectPluginFunctionProvider asks the runtime which existing, registered
// function session belongs to this exact workspace and installed version.
// Empty means no eligible session. It starts no backend and consumes no events.
func (c *Client) SelectPluginFunctionProvider(ctx context.Context, plugin, version, function, workspace string, candidates []PluginFunctionProviderCandidate) (string, error) {
	if candidates == nil {
		candidates = []PluginFunctionProviderCandidate{}
	}
	root, err := c.PluginDocumentURI(ctx, workspace, "auto")
	if err != nil {
		return "", err
	}
	var result struct {
		SessionID *string `json:"sessionID"`
	}
	err = c.Execute(ctx, "lsp.functionProvider", struct {
		PluginID   string                            `json:"pluginID"`
		Version    string                            `json:"version"`
		Function   string                            `json:"function"`
		RootURI    string                            `json:"rootUri"`
		Candidates []PluginFunctionProviderCandidate `json:"candidates"`
	}{plugin, version, function, root, candidates}, &result)
	if err != nil {
		return "", err
	}
	if result.SessionID == nil {
		return "", nil
	}
	return *result.SessionID, nil
}
