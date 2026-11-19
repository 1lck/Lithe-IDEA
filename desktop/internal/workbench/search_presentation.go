package workbench

import (
	"context"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// Only lightweight path identities cross Core again when a page or collapse changes.
func (a *App) projectSearchPresentation(p *project) {
	s := &p.search
	s.presentationGeneration++
	generation := s.presentationGeneration
	paths := make([]string, len(s.matches))
	for i := range s.matches {
		paths[i] = s.matches[i].Path
	}
	var collapsed []string
	for path, value := range s.collapsed {
		if value {
			collapsed = append(collapsed, path)
		}
	}
	a.background(p, kernelCallTimeout, func(ctx context.Context) func(*App) {
		projection, err := core.NewClient().SearchPresentation(ctx, paths, collapsed)
		return func(a *App) {
			if generation != s.presentationGeneration {
				return
			}
			if err != nil {
				a.operationFailed("workspace_search_presentation", err)
				s.failed = true
				return
			}
			s.presentation = projection
		}
	})
}
