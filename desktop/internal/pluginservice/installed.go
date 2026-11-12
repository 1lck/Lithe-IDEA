package pluginservice

import (
	"context"
	"errors"
	"fmt"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
)

// CurrentInstalled returns Core's current version per plugin, including disabled
// plugins for settings and inventory. A non-nil result may accompany diagnostics.
func (s *Service) CurrentInstalled(ctx context.Context) ([]pluginmanager.Entry, error) {
	if s == nil || s.Manager == nil {
		return nil, ErrAssembly
	}
	entries, err := s.Manager.Installed()
	if err != nil {
		return nil, err
	}
	return s.selectInstalled(ctx, entries, true)
}

func (s *Service) selectInstalled(ctx context.Context, entries []pluginmanager.Entry, includeDisabled bool) ([]pluginmanager.Entry, error) {
	if s == nil || s.kernel == nil {
		return nil, ErrAssembly
	}
	facts := make([]core.InstalledPluginFact, len(entries))
	for index, entry := range entries {
		facts[index] = core.InstalledPluginFact{PluginID: entry.Installed.ID, Version: entry.Installed.Version, Enabled: entry.Enabled}
	}
	selection, err := s.kernel.SelectInstalledPluginVersions(ctx, facts, includeDisabled)
	if err != nil {
		return nil, err
	}
	selected := make([]pluginmanager.Entry, 0, len(selection.Selected))
	for _, index := range selection.Selected {
		selected = append(selected, entries[index])
	}
	var rejected []error
	for _, failure := range selection.Rejected {
		entry := entries[failure.Index]
		rejected = append(rejected, fmt.Errorf("plugin %s version %s: %s", entry.Installed.ID, entry.Installed.Version, failure.Code))
	}
	return selected, errors.Join(rejected...)
}
