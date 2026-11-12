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

// PluginSettingsMetadata is validated installed-plugin presentation metadata.
type PluginSettingsMetadata struct {
	DisplayName string `json:"displayName"`
	Version     string `json:"version"`
	Vendor      string `json:"vendor"`
}

// PluginSettingsSection references rows/actions in Core's presentation order.
type PluginSettingsSection struct {
	Title   string `json:"title"`
	Rows    []int  `json:"rows"`
	Actions []int  `json:"actions"`
}

// PluginSettingInput is Core's ready-to-render native control state.
// Integer fields use Text; Core parses uncommitted edits on save.
type PluginSettingInput struct {
	Text     string `json:"text"`
	On       bool   `json:"on"`
	Selected int    `json:"selected"`
	Checks   []bool `json:"checks"`
}

// PluginSettingEditorValue is Core's projection for one editor scope.
// The view does not compute inheritance, reset values or editing permission.
type PluginSettingEditorValue struct {
	Value         json.RawMessage    `json:"value"`
	ResetValue    json.RawMessage    `json:"resetValue"`
	Input         PluginSettingInput `json:"input"`
	ResetInput    PluginSettingInput `json:"resetInput"`
	Source        string             `json:"source"`
	Editable      bool               `json:"editable"`
	Overridden    bool               `json:"overridden"`
	InvalidStored bool               `json:"invalidStored"`
}

// PluginSettingsEditors supplies both scope projections without native reads.
type PluginSettingsEditors struct {
	Global  []PluginSettingEditorValue `json:"global"`
	Project []PluginSettingEditorValue `json:"project"`
}

// PluginSettingsState is a read-only projection, not permission to start a plugin.
type PluginSettingsState struct {
	Pages           []SettingsPage             `json:"pages"`
	PluginID        string                     `json:"pluginID"`
	Metadata        PluginSettingsMetadata     `json:"metadata"`
	Sections        []PluginSettingsSection    `json:"sections"`
	Editors         PluginSettingsEditors      `json:"editors"`
	Rows            []PluginSettingRow         `json:"rows"`
	Actions         []PluginSettingAction      `json:"actions"`
	Settings        map[string]json.RawMessage `json:"settings"`
	ProjectSettings map[string]json.RawMessage `json:"projectSettings"`
	Storage         PluginSettingsStorage      `json:"storage"`
}

// PluginSettingEdit supplies a typed override or unparsed editor Text.
// A nil Value removes the override only when Text is nil; Core validates both.
type PluginSettingEdit struct {
	ID    string          `json:"id"`
	Value json.RawMessage `json:"value"`
	Text  *string         `json:"text,omitempty"`
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
	return c.readPluginSettingsState(ctx, manifest, global, project, nil)
}

// ReadInstalledPluginSettingsState binds declaration metadata to native package
// registration facts. It does not admit capabilities or launch the package.
func (c *Client) ReadInstalledPluginSettingsState(ctx context.Context, manifest json.RawMessage, id, version string) (PluginSettingsState, error) {
	return c.readPluginSettingsState(ctx, manifest, nil, nil, &struct {
		PluginID string `json:"pluginID"`
		Version  string `json:"version"`
	}{id, version})
}

func (c *Client) readPluginSettingsState(ctx context.Context, manifest json.RawMessage, global, project *string, owner any) (PluginSettingsState, error) {
	const command = "plugins.declarative.settingsState"
	var result struct {
		Status string                `json:"status"`
		Error  *MarketplaceRejection `json:"error"`
		State  *PluginSettingsState  `json:"state"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest json.RawMessage `json:"manifest"`
		Owner    any             `json:"owner,omitempty"`
		Global   *string         `json:"globalDocument"`
		Project  *string         `json:"projectDocument"`
	}{manifest, owner, global, project}, &result); err != nil {
		return PluginSettingsState{}, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return PluginSettingsState{}, result.Error
	}
	if result.Status != "ok" || result.State == nil {
		return PluginSettingsState{}, newParseError(command, "invalid settings state outcome", "")
	}
	state := result.State
	if state.Metadata.DisplayName == "" || state.Metadata.Version == "" || len(state.Editors.Global) != len(state.Rows) || len(state.Editors.Project) != len(state.Rows) {
		return PluginSettingsState{}, newParseError(command, "invalid editor projection", "")
	}
	sections := append([]PluginSettingsSection(nil), state.Sections...)
	for _, page := range state.Pages {
		sections = append(sections, page.Sections...)
	}
	for _, section := range sections {
		for _, row := range section.Rows {
			if row < 0 || row >= len(state.Rows) {
				return PluginSettingsState{}, newParseError(command, "invalid editor row reference", "")
			}
		}
		for _, action := range section.Actions {
			if action < 0 || action >= len(state.Actions) {
				return PluginSettingsState{}, newParseError(command, "invalid editor action reference", "")
			}
		}
	}
	return *state, nil
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

// ExpandPluginWorkspaceConfiguration reuses Core's existing declaration template
// and inheritance rules. A nil configuration means this server declares none.
func (c *Client) ExpandPluginWorkspaceConfiguration(ctx context.Context, manifest json.RawMessage, languageID string, global, project map[string]json.RawMessage) (json.RawMessage, error) {
	const command = "plugins.declarative.workspaceConfiguration"
	var result struct {
		Status        string                `json:"status"`
		Error         *MarketplaceRejection `json:"error"`
		Configuration json.RawMessage       `json:"configuration"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest        json.RawMessage            `json:"manifest"`
		LanguageID      string                     `json:"languageID"`
		Settings        map[string]json.RawMessage `json:"settings,omitempty"`
		ProjectSettings map[string]json.RawMessage `json:"projectSettings,omitempty"`
	}{manifest, languageID, global, project}, &result); err != nil {
		return nil, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return nil, result.Error
	}
	if result.Status != "ok" || len(result.Configuration) == 0 {
		return nil, newParseError(command, "invalid workspace configuration outcome", "")
	}
	if string(result.Configuration) == "null" {
		return nil, nil
	}
	return result.Configuration, nil
}

// UpdatePluginWorkspaceConfiguration replaces a running plugin session's
// configuration through Core. sent=false means Core retained it until initialize.
func (c *Client) UpdatePluginWorkspaceConfiguration(ctx context.Context, session string, configuration json.RawMessage) (bool, error) {
	var result struct {
		Sent bool `json:"sent"`
	}
	err := c.Execute(ctx, "lsp.updateWorkspaceConfiguration", struct {
		SessionID     string          `json:"sessionId"`
		Configuration json.RawMessage `json:"configuration"`
	}{session, configuration}, &result)
	return result.Sent, err
}
