package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

func (a *App) searchScopeControls(c ui.C, p *project, language i18n.Language) bool {
	ready := true
	v := &a.searchView
	if v.scopeMode == "" {
		v.scopeMode = "project"
	}
	ui.Column(c).FillWidth().PadX(10).Gap(4).Children(func() {
		ui.Select(c.Part("scope-kind"), &v.scopeMode, []string{"project", "module", "directory", "custom"}, func(value string) string {
			switch value {
			case "module":
				return i18n.Shared(language, "desktop.search.scopeModule")
			case "directory":
				return i18n.Shared(language, "desktop.search.scopeDirectory")
			case "custom":
				return i18n.Shared(language, "desktop.search.scopeCustom")
			default:
				return i18n.Shared(language, "desktop.search.scopeProject")
			}
		}).FillWidth().Label(i18n.Shared(language, "desktop.search.scope"))
		switch v.scopeMode {
		case "project":
			v.scope.SetText("")
		case "module":
			paths := []string{}
			titles := map[string]string{}
			for _, instance := range p.build.instances {
				if !instance.modelLoaded || instance.modelLoading || instance.modelReloadPending {
					continue
				}
				for _, module := range instance.Model.Projects {
					paths = append(paths, module.Path)
					title := module.DisplayName
					if title == "" {
						title = module.Name
					}
					titles[module.Path] = title
				}
			}
			if len(paths) == 0 {
				ui.Text(c, i18n.Shared(language, "desktop.search.noModules")).Muted()

				ready = false
				return
			}
			if _, ok := titles[v.scopeModule]; !ok {
				v.scopeModule = paths[0]
			}
			ui.Select(c.Part("scope-module"), &v.scopeModule, paths, func(path string) string { return titles[path] }).FillWidth().Label(i18n.Shared(language, "desktop.search.scopeModule"))
			v.scope.SetText(v.scopeModule)
		default:
			ui.TextField(c.Part("scope-paths"), &v.scope, i18n.Shared(language, "desktop.search.scope"), "").FillWidth().Tooltip(i18n.Shared(language, "desktop.search.scopeHelp"))
		}
	})
	return ready
}

func (a *App) projectSearchRetry(c ui.C, p *project, language i18n.Language) {
	if ui.Button(c, i18n.Shared(language, "desktop.search.retry")).Outline().Clicked() {
		a.performed("workspace.search.retry", surfaceButton)
		p.search.failed = false
		if p.search.cursor != nil {
			a.loadMoreProjectSearch(p)
		} else {
			a.refreshProjectSearch(p)
		}
	}
}
