package core

import (
	"context"
	"encoding/json"
)

// SettingsContribution binds captured package bytes to native registration facts.
type SettingsContribution struct {
	Manifest json.RawMessage     `json:"manifest"`
	Owner    PluginSettingsOwner `json:"owner"`
	Enabled  bool                `json:"enabled"`
	// Localizations are the translation files read for the request's language, by
	// package-relative path: nil before the host read them, empty when it found none.
	Localizations map[string]string `json:"localizations"`
}

// SettingsPageContribution references the complete editor of one installed owner.
type SettingsPageContribution struct {
	PluginID string                  `json:"pluginID"`
	Version  string                  `json:"version"`
	Title    string                  `json:"title"`
	Sections []PluginSettingsSection `json:"sections"`
	// Region is the settings region the contributor placed on the page, nil when none.
	Region *PluginSettingsRegion `json:"region,omitempty"`
	// Localization reports the translation the catalog applied, present when the request
	// named a language; ReadRequired asks the host to read Candidates and ask again.
	Localization *PluginSettingsLocalization `json:"localization,omitempty"`
}

type SettingsPage struct {
	Key          string                     `json:"key"`
	Kind         string                     `json:"kind"`
	ID           string                     `json:"id"`
	Title        string                     `json:"title"`
	Contributors []SettingsPageContribution `json:"contributors"`
	Sections     []PluginSettingsSection    `json:"sections"`
}

type SettingsNavigationItem struct {
	ID       string  `json:"id"`
	Title    string  `json:"title"`
	Parent   *string `json:"parent"`
	Group    bool    `json:"group"`
	Expanded bool    `json:"expanded"`
	Keywords string  `json:"keywords,omitempty"`
}

type SettingsNavigationRow struct {
	ID       string `json:"id"`
	Title    string `json:"title"`
	Group    bool   `json:"group"`
	Expanded bool   `json:"expanded"`
	Level    uint8  `json:"level"`
	// Matched is set when the search hit this row itself rather than a row below
	// it; Path holds the ancestor titles so a hit can be listed with its place.
	Matched bool     `json:"matched,omitempty"`
	Path    []string `json:"path,omitempty"`
}

type SettingsDeliveryRequest struct {
	Scope           string   `json:"scope"`
	SamePreferences bool     `json:"samePreferences"`
	SameWorkspace   bool     `json:"sameWorkspace"`
	SameVersion     bool     `json:"sameVersion"`
	Enabled         bool     `json:"enabled"`
	Effects         []string `json:"effects"`
}

type SettingsDelivery struct {
	Refresh bool     `json:"refresh"`
	Effects []string `json:"effects"`
}

func settingsSurfaceResult[T any](ctx context.Context, c *Client, command, field string, input any) (T, error) {
	var zero T
	var result map[string]json.RawMessage
	if err := c.Execute(ctx, command, input, &result); err != nil {
		return zero, err
	}
	var status string
	if err := json.Unmarshal(result["status"], &status); err != nil {
		return zero, err
	}
	if status == "rejected" {
		var rejection MarketplaceRejection
		if err := json.Unmarshal(result["error"], &rejection); err != nil {
			return zero, err
		}
		return zero, &rejection
	}
	if status != "ok" || len(result[field]) == 0 || string(result[field]) == "null" {
		return zero, newParseError(command, "invalid settings surface outcome", "")
	}
	var value T
	if err := json.Unmarshal(result[field], &value); err != nil {
		return zero, err
	}
	return value, nil
}

// SettingsPages asks Core for the settings page catalog of plugins. language, when not empty,
// translates section headings and adds region keywords from each plugin's translation files,
// which the host supplies as SettingsContribution.Localizations.
func (c *Client) SettingsPages(ctx context.Context, plugins []SettingsContribution, language string) ([]SettingsPage, error) {
	if plugins == nil {
		plugins = []SettingsContribution{}
	}
	return settingsSurfaceResult[[]SettingsPage](ctx, c, "plugins.settings.catalog", "pages", struct {
		Plugins  []SettingsContribution `json:"plugins"`
		Language string                 `json:"language,omitempty"`
	}{plugins, language})
}

func (c *Client) SettingsNavigation(ctx context.Context, items []SettingsNavigationItem, query string) ([]SettingsNavigationRow, error) {
	if items == nil {
		items = []SettingsNavigationItem{}
	}
	return settingsSurfaceResult[[]SettingsNavigationRow](ctx, c, "plugins.settings.navigation", "rows", struct {
		Items []SettingsNavigationItem `json:"items"`
		Query string                   `json:"query"`
	}{items, query})
}

func (c *Client) SettingsDelivery(ctx context.Context, request SettingsDeliveryRequest) (SettingsDelivery, error) {
	if request.Effects == nil {
		request.Effects = []string{}
	}
	return settingsSurfaceResult[SettingsDelivery](ctx, c, "plugins.settings.delivery", "delivery", request)
}
