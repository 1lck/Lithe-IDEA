package workbench

import (
	"encoding/json"
	"slices"
	"sort"
	"time"
)

// A project reopens with its native plugin panels as they were left: the selected row, the open tree
// branches and a form's values. The state is written when the project closes and read when it opens
// again, by project root, in the same store as the editor session. Each window keeps at most 64 KiB, and
// a window that would keep more keeps nothing. Values of a field that no longer exists, or that no longer
// fits the field, are dropped when the form is built (initForm), so an old state never breaks a new form.

// nativePanelsFile holds the native panel state of the most recently closed projects, by root.
const nativePanelsFile = "plugin-native-panels.json"

// nativePanelStateLimit is the most a window may keep, as the contract's per-window state store allows.
const nativePanelStateLimit = 64 << 10

// savedNativePanel is one window's state: its selected row ID, the open branches (sorted) and a form's
// values keyed by control ID.
type savedNativePanel struct {
	Selected string         `json:"selected,omitempty"`
	Expanded []string       `json:"expanded,omitempty"`
	Form     map[string]any `json:"form,omitempty"`
}

// savedNativeProject is the native panel state of one project when it closed.
type savedNativeProject struct {
	SavedAt time.Time                   `json:"savedAt"`
	Panels  map[string]savedNativePanel `json:"panels"`
}

// restoreNativePanels reads what p kept for its native panels. Each window applies it when it first opens.
func (a *App) restoreNativePanels(p *project) {
	all := map[string]savedNativeProject{}
	if found, err := a.store.Load(nativePanelsFile, &all); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_native_state_load", documentLogError(err)))
		return
	} else if !found {
		return
	}
	if saved, ok := all[p.root]; ok {
		p.nativeSaved = saved.Panels
	}
}

// saveNativePanels records the native panels of p for the next time the project opens. A window that was
// never opened this session keeps what it had. A project with no state forgets it.
func (a *App) saveNativePanels(p *project) {
	all := map[string]savedNativeProject{}
	if _, err := a.store.Load(nativePanelsFile, &all); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_native_state_load", documentLogError(err)))
		all = map[string]savedNativeProject{}
	}
	panels := map[string]savedNativePanel{}
	for key, saved := range p.nativeSaved {
		panels[key] = saved
	}
	for key, state := range p.nativePanels {
		saved := state.capture()
		if encoded, err := json.Marshal(saved); err != nil || len(encoded) > nativePanelStateLimit {
			delete(panels, key)
			continue
		}
		panels[key] = saved
	}
	if len(panels) == 0 {
		delete(all, p.root)
	} else {
		all[p.root] = savedNativeProject{SavedAt: a.now(), Panels: panels}
	}
	if len(all) > editorSessionLimit {
		roots := make([]string, 0, len(all))
		for root := range all {
			roots = append(roots, root)
		}
		slices.SortFunc(roots, func(x, y string) int { return all[y].SavedAt.Compare(all[x].SavedAt) })
		for _, root := range roots[editorSessionLimit:] {
			delete(all, root)
		}
	}
	if err := a.store.Save(nativePanelsFile, all); err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_native_state_save", documentLogError(err)))
	}
}

// capture reads what a window keeps: its selection, its open branches and, for a form whose fields exist,
// their values.
func (s *nativePanelState) capture() savedNativePanel {
	saved := savedNativePanel{Selected: s.selected}
	for id, open := range s.expanded {
		if open {
			saved.Expanded = append(saved.Expanded, id)
		}
	}
	sort.Strings(saved.Expanded)
	if s.form != nil {
		if s.formReady {
			saved.Form = formValues(s, s.form)
		} else {
			saved.Form = s.savedForm
		}
	}
	return saved
}
