package workbench

import (
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// moduleFor returns the build project a workspace-relative file belongs to: the project whose
// directory is the deepest ancestor of the file. Only models that are loaded and current take
// part. A model that is loading, reloading or failed is skipped, so a file is never named after
// a model the build system has since replaced. The project path is taken as workspace-relative,
// as the build model reports it for targets.
func (a *App) moduleFor(p *project, relative string) (core.BuildProject, bool) {
	if p == nil || relative == "" {
		return core.BuildProject{}, false
	}
	file := filepath.ToSlash(filepath.Clean(filepath.FromSlash(relative)))
	var best core.BuildProject
	bestLength, found := -1, false
	for index := range p.build.instances {
		instance := &p.build.instances[index]
		if !instance.modelLoaded || instance.modelLoading || instance.modelReloadPending {
			continue
		}
		for _, module := range instance.Model.Projects {
			directory := strings.Trim(filepath.ToSlash(filepath.Clean(filepath.FromSlash(module.Path))), "/")
			if directory == "." {
				directory = ""
			}
			if directory != "" && file != directory && !strings.HasPrefix(file, directory+"/") {
				continue
			}
			if len(directory) > bestLength {
				best, bestLength, found = module, len(directory), true
			}
		}
	}
	return best, found
}

// moduleName is the label a file shows for its build project, or "" when none owns it.
func (a *App) moduleName(p *project, relative string) string {
	module, ok := a.moduleFor(p, relative)
	if !ok {
		return ""
	}
	if module.DisplayName != "" {
		return module.DisplayName
	}
	return module.Name
}
