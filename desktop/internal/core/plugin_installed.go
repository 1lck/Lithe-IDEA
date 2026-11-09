package core

import (
	"context"
)

// InstalledPluginFact is native identity and enablement, without filesystem paths.
type InstalledPluginFact struct {
	PluginID string `json:"pluginID"`
	Version  string `json:"version"`
	Enabled  bool   `json:"enabled"`
}

// InstalledPluginRejection identifies a malformed input record by its native index.
type InstalledPluginRejection struct {
	Index int    `json:"index"`
	Code  string `json:"code"`
}

// InstalledPluginSelection keeps healthy plugins available alongside diagnostics.
type InstalledPluginSelection struct {
	Selected       []int                      `json:"selected"`
	Rejected       []InstalledPluginRejection `json:"rejected"`
	MaximumEntries int                        `json:"maximumEntries"`
}

// SelectInstalledPluginVersions delegates numeric version choice and enablement
// to Core. The native owner maps indices back to its own file records.
func (c *Client) SelectInstalledPluginVersions(ctx context.Context, entries []InstalledPluginFact, includeDisabled bool) (InstalledPluginSelection, error) {
	const command = "plugins.installed.select"
	if entries == nil {
		entries = []InstalledPluginFact{}
	}
	var result InstalledPluginSelection
	if err := c.Execute(ctx, command, struct {
		Entries         []InstalledPluginFact `json:"entries"`
		IncludeDisabled bool                  `json:"includeDisabled"`
	}{entries, includeDisabled}, &result); err != nil {
		return InstalledPluginSelection{}, err
	}
	seen := make(map[int]bool, len(result.Selected))
	for _, index := range result.Selected {
		if index < 0 || index >= len(entries) || seen[index] {
			return InstalledPluginSelection{}, newParseError(command, "invalid selected record index", "")
		}
		seen[index] = true
	}
	for _, rejected := range result.Rejected {
		if rejected.Index < 0 || rejected.Index >= len(entries) || rejected.Code == "" {
			return InstalledPluginSelection{}, newParseError(command, "invalid rejected record index", "")
		}
	}
	return result, nil
}
