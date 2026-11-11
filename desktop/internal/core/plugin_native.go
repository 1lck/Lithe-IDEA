package core

import (
	"context"
	"encoding/json"
)

// ValidatePluginNativeData asks Core to check a native panel's data reply against the panel's
// declaration (ui 3). declaration is the validated native schema-1 object of the window, and data is
// the provider's {nodes} reply. Core applies the identity, label, nesting and node budgets of manifest
// validation and returns the checked nodes; a rejection is a *MarketplaceRejection carrying
// plugin.ui.invalidData. The host renders the returned nodes and never validates them itself.
func (c *Client) ValidatePluginNativeData(ctx context.Context, declaration, data json.RawMessage) (json.RawMessage, error) {
	const command = "plugins.nativeUI.validateData"
	var result struct {
		Status string                `json:"status"`
		Nodes  json.RawMessage       `json:"nodes"`
		Error  *MarketplaceRejection `json:"error"`
	}
	if err := c.Execute(ctx, command, struct {
		UI   json.RawMessage `json:"ui"`
		Data json.RawMessage `json:"data"`
	}{declaration, data}, &result); err != nil {
		return nil, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return nil, result.Error
	}
	if result.Status != "ok" || len(result.Nodes) == 0 || string(result.Nodes) == "null" {
		return nil, newParseError(command, "native data validation returned an invalid outcome", "")
	}
	return result.Nodes, nil
}
