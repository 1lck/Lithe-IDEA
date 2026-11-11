package workbench

import (
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// The editor keeps at most the user's number of file tabs open (Settings › Editor; 30
// by default, 0 for no limit). Opening one more closes a file tab chosen by the policy:
// the least recently used by default, or the one opened first. A tab with unsaved
// changes, one being saved and the tab just opened are never closed, and terminals and
// Agent conversations do not count.

// touchDocument marks document id as the most recently used.
func (p *project) touchDocument(id int) {
	if d := p.docs.find(id); d != nil {
		p.docs.clock++
		d.used = p.docs.clock
	}
}

// enforceTabLimit closes file tabs until at most the limit are open, sparing keep.
func (a *App) enforceTabLimit(p *project, keep *document) {
	limit := settingswindow.TabLimitOf(a.settings.EditorTabLimit)
	if limit <= 0 || len(p.docs.list) <= limit {
		return
	}
	var candidates []*document
	for _, d := range p.docs.list {
		if d != keep && !d.dirty() && !d.saving && !d.view.IsComposing() {
			candidates = append(candidates, d)
		}
	}
	oldest := a.settings.EditorTabPolicy == settingswindow.TabPolicyOldest
	slices.SortFunc(candidates, func(x, y *document) int {
		if oldest {
			return x.id - y.id
		}
		if x.used != y.used {
			if x.used < y.used {
				return -1
			}
			return 1
		}
		return x.id - y.id
	})
	for _, d := range candidates {
		if len(p.docs.list) <= limit {
			return
		}
		a.removeDocument(p, d)
	}
}
