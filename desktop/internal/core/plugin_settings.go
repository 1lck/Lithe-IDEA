package core

import (
	"context"
	"encoding/json"
)

// PluginSettingPage identifies a declaration-owned settings surface.
type PluginSettingPage struct {
	LanguageID    string `json:"languageID,omitempty"`
	BuildSystemID string `json:"buildSystemID,omitempty"`
}

// PluginSettingOption is one value and its plugin-provided display title.
type PluginSettingOption struct {
	Value string `json:"value"`
	Title string `json:"title"`
}

// PluginSettingDeclaration is presentation metadata from a validated manifest.
// Core validates edits and supplies normalized scope/effect on the row.
type PluginSettingDeclaration struct {
	ID            string                `json:"id"`
	Kind          string                `json:"type"`
	Title         string                `json:"title"`
	Description   string                `json:"description,omitempty"`
	Default       json.RawMessage       `json:"default"`
	Minimum       *int64                `json:"minimum,omitempty"`
	Maximum       *int64                `json:"maximum,omitempty"`
	Unit          string                `json:"unit,omitempty"`
	Options       []PluginSettingOption `json:"options,omitempty"`
	Page          *PluginSettingPage    `json:"page,omitempty"`
	Section       string                `json:"section,omitempty"`
	Placeholder   string                `json:"placeholder,omitempty"`
	Pattern       string                `json:"pattern,omitempty"`
	MaximumLength *uint32               `json:"maxLength,omitempty"`
}

// PluginSettingValue is Core's chosen value and its inheritance source.
type PluginSettingValue struct {
	ID     string          `json:"id"`
	Value  json.RawMessage `json:"value"`
	Source string          `json:"source"`
}

// PluginSettingRow carries both the global editor value and project effect.
type PluginSettingRow struct {
	Declaration   PluginSettingDeclaration `json:"declaration"`
	Scope         string                   `json:"scope"`
	Effect        string                   `json:"effect"`
	Global        PluginSettingValue       `json:"global"`
	Effective     PluginSettingValue       `json:"effective"`
	GlobalStored  bool                     `json:"globalStored"`
	ProjectStored bool                     `json:"projectStored"`
}

// PluginSettingAction invokes a declared function only after a user action.
type PluginSettingAction struct {
	ID          string             `json:"id"`
	Title       string             `json:"title"`
	Description string             `json:"description,omitempty"`
	Page        *PluginSettingPage `json:"page,omitempty"`
	Section     string             `json:"section,omitempty"`
	Function    string             `json:"function"`
	Confirm     bool               `json:"confirm"`
}

// PluginSettingsStorage is Core's bounded read plan under native-owned roots.
type PluginSettingsStorage struct {
	GlobalRelativePath  string `json:"globalRelativePath"`
	ProjectRelativePath string `json:"projectRelativePath"`
	MaximumBytes        int64  `json:"maximumBytes"`
	ReadRequired        bool   `json:"readRequired"`
}

// PluginSettingsState is a read-only projection, not permission to start a plugin.
type PluginSettingsState struct {
	PluginID        string                     `json:"pluginID"`
	Rows            []PluginSettingRow         `json:"rows"`
	Actions         []PluginSettingAction      `json:"actions"`
	Settings        map[string]json.RawMessage `json:"settings"`
	ProjectSettings map[string]json.RawMessage `json:"projectSettings"`
	Storage         PluginSettingsStorage      `json:"storage"`
}

// PluginSettingEdit is one explicit override; a nil Value requests removal.
type PluginSettingEdit struct {
	ID    string          `json:"id"`
	Value json.RawMessage `json:"value"`
}

// PluginSettingsEditPlan contains complete text and declaration-owned effects.
// Native adapters still check cancellation, captured bytes and permissions.
type PluginSettingsEditPlan struct {
	Document string   `json:"document"`
	Delete   bool     `json:"delete"`
	Changed  bool     `json:"changed"`
	Effects  []string `json:"effects"`
}

// ReadPluginSettingsState asks Core to decode whole documents. Nil identifies a
// missing file; an existing empty file must be passed as a non-nil empty string.
func (c *Client) ReadPluginSettingsState(ctx context.Context, manifest json.RawMessage, global, project *string) (PluginSettingsState, error) {
	const command = "plugins.declarative.settingsState"
	var result struct {
		Status string                `json:"status"`
		Error  *MarketplaceRejection `json:"error"`
		State  *PluginSettingsState  `json:"state"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest json.RawMessage `json:"manifest"`
		Global   *string         `json:"globalDocument"`
		Project  *string         `json:"projectDocument"`
	}{manifest, global, project}, &result); err != nil {
		return PluginSettingsState{}, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return PluginSettingsState{}, result.Error
	}
	if result.Status != "ok" || result.State == nil {
		return PluginSettingsState{}, newParseError(command, "invalid settings state outcome", "")
	}
	return *result.State, nil
}

// EditPluginSettings validates the complete edit batch and preserves other
// plugins and dormant settings. The bridge never parses the stored schema.
func (c *Client) EditPluginSettings(ctx context.Context, manifest json.RawMessage, scope string, document *string, edits []PluginSettingEdit) (PluginSettingsEditPlan, error) {
	const command = "plugins.declarative.editSettings"
	var result struct {
		Status string                  `json:"status"`
		Error  *MarketplaceRejection   `json:"error"`
		Edit   *PluginSettingsEditPlan `json:"edit"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest json.RawMessage     `json:"manifest"`
		Scope    string              `json:"scope"`
		Document *string             `json:"document"`
		Edits    []PluginSettingEdit `json:"edits"`
	}{manifest, scope, document, edits}, &result); err != nil {
		return PluginSettingsEditPlan{}, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return PluginSettingsEditPlan{}, result.Error
	}
	if result.Status != "ok" || result.Edit == nil {
		return PluginSettingsEditPlan{}, newParseError(command, "invalid settings edit outcome", "")
	}
	return *result.Edit, nil
}
