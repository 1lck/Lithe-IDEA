package workbench

import (
	"context"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editor/rope"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/searchprefs"
)

type appSearchPreferences struct{ app *App }

func (s appSearchPreferences) Load(ctx context.Context) (searchprefs.Snapshot, error) {
	return (searchprefs.Source{Root: s.app.store.Dir()}).Load(ctx)
}
func (s appSearchPreferences) Save(ctx context.Context, baseline searchprefs.Snapshot, stored core.StoredSearchPreferences) (searchprefs.Snapshot, error) {
	result, err := (searchprefs.Source{Root: s.app.store.Dir()}).Save(ctx, baseline, stored)
	if err == nil {
		s.app.post(func(a *App) {
			a.searchPreferences = result.Effective
			if p := a.project; p != nil {
				a.refreshProjectSearch(p)
				if a.everywhereView.open {
					p.everywhere.query = ""
				}
			}
		})
	}
	return result, err
}
func (a *App) loadSearchPreferences() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	value, err := (appSearchPreferences{app: a}).Load(ctx)
	if err != nil {
		a.backgroundFailed("search_preferences_load", err)
		defaults, defaultErr := core.NewClient().ResolveSearchPreferences(ctx, nil, nil)
		if defaultErr != nil {
			a.backgroundFailed("search_preferences_defaults", defaultErr)
			return
		}
		a.searchPreferences = defaults
		return
	}
	a.searchPreferences = value.Effective
}

// Capture immutable rope roots on the window thread; materialize text only on the worker.
func captureSearchText(p *project) map[string]rope.Rope {
	var snapshots map[string]rope.Rope
	for _, doc := range p.docs.list {
		if doc.virtual || doc.scratch || !doc.dirty() {
			continue
		}
		path, inside := projectRelative(p.root, doc.path)
		if !inside {
			continue
		}
		if snapshots == nil {
			snapshots = make(map[string]rope.Rope)
		}
		snapshots[path] = doc.view.TextSnapshot()
	}
	return snapshots
}

func materializeSearchText(snapshots map[string]rope.Rope) map[string]string {
	if len(snapshots) == 0 {
		return nil
	}
	text := make(map[string]string, len(snapshots))
	for path, snapshot := range snapshots {
		text[path] = snapshot.String()
	}
	return text
}
