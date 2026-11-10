package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

func (a *App) openPluginRename(p *project, d *document)                              {}
func (a *App) renameAborted()                                                        {}
func (a *App) applySemanticRename(pending *semanticPending, event core.BackendEvent) {}
