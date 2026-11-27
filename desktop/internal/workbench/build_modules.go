package workbench

import (
	"path/filepath"
	"slices"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// unloadBuildModel removes the instance's contribution to the Project tree before it reloads.
func (p *project) unloadBuildModel(instance *buildInstance) {
	if instance.modelLoaded {
		instance.modelLoaded = false
		p.tree.changeModuleRoots(instance.Model.Projects, -1)
	}
}

// changeModuleRoots applies one model's addition or removal. Several models can
// name the same path. Core uses "." for the workspace root, which the tree calls "".
func (t *fileTree) changeModuleRoots(projects []core.BuildProject, delta int) {
	if len(projects) == 0 {
		return
	}
	if t.moduleRoots == nil {
		t.moduleRoots = make(map[string]int, len(projects))
	}
	changed := false
	for _, project := range projects {
		path := project.Path
		if path == "." {
			path = ""
		}
		before := t.moduleRoots[path]
		after := before + delta
		if after > 0 {
			t.moduleRoots[path] = after
		} else {
			delete(t.moduleRoots, path)
		}
		changed = changed || (before > 0) != (after > 0)
	}
	if changed {
		t.moduleRootsChanged()
	}
}

func (t *fileTree) clearModuleRoots() {
	if len(t.moduleRoots) > 0 {
		t.moduleRoots = nil
		t.moduleRootsChanged()
	}
}

func (t *fileTree) moduleRootsChanged() {
	t.measureDirty = true
	if t.wake != nil {
		t.wake()
	}
}

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

// reloadBuildForSavedFile follows a file saved inside a build instance's directory. Any saved
// file revokes the tests the instance discovered, since a source edit can add, rename or remove
// them. One of the instance's marker files (pom.xml, Cargo.toml and the like) also reloads the
// model, which is read from those files; a model that is loading gets a pending reload instead,
// so the new contents are read once the current read ends.
func (a *App) reloadBuildForSavedFile(p *project, path string) {
	if p == nil || path == "" {
		return
	}
	relative, err := filepath.Rel(p.root, path)
	if err != nil || strings.HasPrefix(relative, "..") {
		return
	}
	relative = filepath.ToSlash(relative)
	name := filepath.Base(relative)
	for index := range p.build.instances {
		instance := &p.build.instances[index]
		root := strings.Trim(filepath.ToSlash(filepath.Clean(filepath.FromSlash(instance.Root))), "/")
		if root != "." && root != "" && !strings.HasPrefix(relative, root+"/") {
			continue
		}
		p.revokeBuildTests(instance.ID)
		if !slices.Contains(instance.Markers, name) {
			continue
		}
		if instance.modelLoading {
			instance.modelReloadPending = true
			continue
		}
		a.reloadBuildModel(p, index)
	}
}
