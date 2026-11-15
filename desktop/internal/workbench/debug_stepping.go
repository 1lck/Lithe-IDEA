package workbench

import (
	"context"
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// steppingAdapters lists the installed debug adapters that declare stepping filters
// (`features.stepFilters`), once per adapter ID, for the settings window's Build page.
// It runs off the window thread and reads only the installed packages.
func (a *App) steppingAdapters(ctx context.Context) ([]settingswindow.SteppingAdapter, error) {
	if a.plugins == nil || a.plugins.Backend == nil {
		return nil, nil
	}
	entries, err := a.plugins.Manager.Installed()
	if err != nil {
		return nil, err
	}
	plugins, pluginErr := a.plugins.DebugPlugins(ctx, entries)
	var adapters []settingswindow.SteppingAdapter
	for _, plugin := range plugins {
		for _, declaration := range plugin.Adapters {
			defaults, ok := core.DeclaredSteppingFilters(declaration.Features, declaration.Defaults)
			if !ok || slices.ContainsFunc(adapters, func(s settingswindow.SteppingAdapter) bool { return s.ID == declaration.AdapterID }) {
				continue
			}
			name := declaration.DisplayName
			if name == "" {
				name = declaration.AdapterID
			}
			adapters = append(adapters, settingswindow.SteppingAdapter{ID: declaration.AdapterID, Name: name, Defaults: defaults})
		}
	}
	slices.SortFunc(adapters, func(x, y settingswindow.SteppingAdapter) int {
		return strings.Compare(strings.ToLower(x.Name), strings.ToLower(y.Name))
	})
	if len(adapters) == 0 && pluginErr != nil {
		return nil, pluginErr
	}
	return adapters, nil
}

// steppingFiltersFor is a copy of the user's stepping policy for adapter, or nil when the
// user kept the adapter's declared defaults.
func (a *App) steppingFiltersFor(adapter string) *core.DebugSteppingFilters {
	filters, ok := a.settings.DebugSteppingFilters[adapter]
	if !ok {
		return nil
	}
	filters.ClassNameFilters = slices.Clone(filters.ClassNameFilters)
	return &filters
}

// setSteppingFilters stores the policy the settings window applied, or removes it when
// filters is nil. It takes effect at the next debug session.
func (a *App) setSteppingFilters(adapter string, filters *core.DebugSteppingFilters) {
	if filters == nil {
		if _, ok := a.settings.DebugSteppingFilters[adapter]; !ok {
			return
		}
		delete(a.settings.DebugSteppingFilters, adapter)
	} else {
		if a.settings.DebugSteppingFilters == nil {
			a.settings.DebugSteppingFilters = make(map[string]core.DebugSteppingFilters)
		}
		value := *filters
		value.ClassNameFilters = slices.Clone(value.ClassNameFilters)
		a.settings.DebugSteppingFilters[adapter] = value
	}
	a.saveSettings()
}

// debugFrameRow is one row of the call stack: a frame, or a run of frames the stepping
// filters match, collapsed into one row that shows them again.
type debugFrameRow struct {
	frame  int
	hidden int
}

// debugFrameRows lists the rows of frames. When hide is set, each run of filtered frames
// becomes one row, except the top frame and the selected one, which always show.
func debugFrameRows(dst []debugFrameRow, frames []core.DebugStackFrame, hide bool, selected int) []debugFrameRow {
	for i, frame := range frames {
		collapsible := hide && frame.IsFiltered && i != 0 && i != selected
		if !collapsible {
			dst = append(dst, debugFrameRow{frame: i})
			continue
		}
		if n := len(dst); n > 0 && dst[n-1].hidden > 0 {
			dst[n-1].hidden++
			continue
		}
		dst = append(dst, debugFrameRow{frame: i, hidden: 1})
	}
	return dst
}
