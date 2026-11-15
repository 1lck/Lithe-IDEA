package core

import (
	"context"
	"encoding/json"
)

// SourceSettingsSnapshot is a plugin's bounded projection of native workspace
// files. The host never interprets a tool's configuration format.
type SourceSettingsSnapshot struct {
	Format  string                `json:"format"`
	Version int                   `json:"version"`
	Title   string                `json:"title"`
	Groups  []SourceSettingsGroup `json:"groups"`
	Sources []SettingsSource      `json:"sources"`
}

type SourceSettingsGroup struct {
	ID       string `json:"id"`
	Title    string `json:"title"`
	Layout   string `json:"layout"`
	RowTitle string `json:"rowTitle,omitempty"`
}

type SettingsSource struct {
	ID       string               `json:"id"`
	Group    string               `json:"group"`
	Title    string               `json:"title"`
	Path     string               `json:"path"`
	Revision string               `json:"revision"`
	Writable bool                 `json:"writable"`
	Fields   []SourceSettingField `json:"fields"`
}

type SourceSettingField struct {
	ID              string                `json:"id"`
	Title           string                `json:"title"`
	Description     string                `json:"description,omitempty"`
	Kind            string                `json:"kind"`
	Value           json.RawMessage       `json:"value"`
	InheritedValue  json.RawMessage       `json:"inheritedValue,omitempty"`
	EffectiveValue  json.RawMessage       `json:"effectiveValue"`
	EffectiveSource string                `json:"effectiveSource"`
	Options         []PluginSettingOption `json:"options,omitempty"`
}

// SourceSettingInput is the unparsed view draft projected by Core. Inherit
// retains absence of an override; displaying an effective value cannot save it.
type SourceSettingInput struct {
	Text    string `json:"text"`
	Choice  string `json:"choice"`
	On      bool   `json:"on"`
	Inherit bool   `json:"inherit"`
}

type SourceSettingsLimits struct {
	MaximumSourceBytes int64 `json:"maximumSourceBytes"`
	MaximumTotalBytes  int64 `json:"maximumTotalBytes"`
}

type SourceSettingsEffectiveDisplay struct {
	Kind  string `json:"kind"`
	Text  string `json:"text"`
	On    bool   `json:"on"`
	Count int    `json:"count"`
}

type SourceSettingsState struct {
	EffectiveDisplays map[string]map[string]SourceSettingsEffectiveDisplay `json:"effectiveDisplays"`
	Snapshot          SourceSettingsSnapshot                               `json:"snapshot"`
	InheritedInputs   map[string]map[string]SourceSettingInput             `json:"inheritedInputs"`
	Inputs            map[string]map[string]SourceSettingInput             `json:"inputs"`
	Limits            SourceSettingsLimits                                 `json:"limits"`
	Layout            []SourceSettingsLayout                               `json:"layout"`
}

type SourceSettingsLayout struct {
	Group   int   `json:"group"`
	Sources []int `json:"sources"`
}

type SourceSettingsEdits struct {
	SourceID string                        `json:"sourceID"`
	Values   map[string]SourceSettingInput `json:"values"`
}

type SourceSettingsWrite struct {
	SourceID string                     `json:"sourceID"`
	Path     string                     `json:"path"`
	Revision string                     `json:"revision"`
	Values   map[string]json.RawMessage `json:"values"`
}

type SourceSettingsReceipt struct {
	SourceID string `json:"sourceID"`
	Revision string `json:"revision"`
	Changed  bool   `json:"changed"`
}

func (c *Client) ReadSourceSettings(ctx context.Context, result json.RawMessage) (SourceSettingsState, error) {
	return settingsSurfaceResult[SourceSettingsState](ctx, c, "plugins.settings.sourceState", "state", struct {
		Result json.RawMessage `json:"result"`
	}{result})
}

func (c *Client) PlanSourceSettingsEdits(ctx context.Context, snapshot SourceSettingsSnapshot, edits []SourceSettingsEdits, confirmed bool) ([]SourceSettingsWrite, error) {
	return settingsSurfaceResult[[]SourceSettingsWrite](ctx, c, "plugins.settings.sourceEdit", "writes", struct {
		Snapshot  SourceSettingsSnapshot `json:"snapshot"`
		Edits     []SourceSettingsEdits  `json:"edits"`
		Confirmed bool                   `json:"confirmed"`
	}{snapshot, edits, confirmed})
}

func (c *Client) DecodeSourceSettingsReceipt(ctx context.Context, write SourceSettingsWrite, result json.RawMessage) (SourceSettingsReceipt, error) {
	return settingsSurfaceResult[SourceSettingsReceipt](ctx, c, "plugins.settings.sourceReceipt", "receipt", struct {
		Write  SourceSettingsWrite `json:"write"`
		Result json.RawMessage     `json:"result"`
	}{write, result})
}
