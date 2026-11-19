package core

import (
	"context"
	"encoding/json"
)

// PluginViewSurface names the declared place a plugin view is drawn in: exactly one of a tool
// window whose body is a view, or a settings region with a view.
type PluginViewSurface struct {
	ToolWindowID    string `json:"toolWindowID,omitempty"`
	SettingRegionID string `json:"settingRegionID,omitempty"`
}

// ApplyPluginViewResult asks Core to check what a plugin's view function returned for one view
// event (plugins.ui.applyResult). manifest is the installed manifest, surface the place the view is
// drawn in, view the whole view the host drew last (nil before the first result) and result the
// function's answer: {view}, {patches} or {}. Core checks the node vocabulary, the budgets, the
// surface's rules and every reference to the manifest, applies patches to a copy of view, and
// returns the whole view to draw and whether it differs from view. A refused result is a
// *MarketplaceRejection carrying plugin.ui.invalidView and the JSON path of the first problem; the
// host then keeps drawing view. The host renders the returned nodes and never validates them itself.
func (c *Client) ApplyPluginViewResult(ctx context.Context, manifest json.RawMessage, surface PluginViewSurface, view, result json.RawMessage) (json.RawMessage, bool, error) {
	const command = "plugins.ui.applyResult"
	request := struct {
		Manifest json.RawMessage   `json:"manifest"`
		Surface  PluginViewSurface `json:"surface"`
		View     json.RawMessage   `json:"view,omitempty"`
		Result   json.RawMessage   `json:"result"`
	}{Manifest: manifest, Surface: surface, Result: result}
	if len(view) > 0 && string(view) != "null" {
		request.View = view
	}
	var answer struct {
		Status string `json:"status"`
		View   *struct {
			View    json.RawMessage `json:"view"`
			Changed bool            `json:"changed"`
		} `json:"view"`
		Error *MarketplaceRejection `json:"error"`
	}
	if err := c.Execute(ctx, command, request, &answer); err != nil {
		return nil, false, err
	}
	if answer.Status == "rejected" && answer.Error != nil {
		return nil, false, answer.Error
	}
	if answer.Status != "ok" || answer.View == nil || len(answer.View.View) == 0 || string(answer.View.View) == "null" {
		return nil, false, newParseError(command, "plugin view check returned an invalid outcome", "")
	}
	return answer.View.View, answer.View.Changed, nil
}
