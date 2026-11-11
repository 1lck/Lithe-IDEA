package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
)

// runConfigBar declares the row above the build systems that picks a run configuration
// and runs it. It shows only once Core resolved at least one, or failed to.
func (a *App) runConfigBar(c ui.C, p *project) {
	s := &p.runConfigs
	if len(s.list) == 0 && s.failure == "" {
		return
	}
	language := a.language()
	label := i18n.Shared(language, "desktop.runConfig.label")
	ui.Row(c.Part("run-config")).Height(panelHeaderHeight).FillWidth().Shrink(0).Items(ui.Center).Gap(8).PadX(8).Children(func() {
		if s.failure != "" && len(s.list) == 0 {
			ui.Text(c, i18n.SharedFormat(language, "desktop.runConfig.loadFailed", map[string]string{"reason": s.failure})).
				FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Warning).Ellipsis().Grow(1)
			return
		}
		ui.Text(c, label).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0)
		ids := make([]string, len(s.list))
		for i := range s.list {
			ids[i] = s.list[i].ID
		}
		ui.Select(c.Part("choice"), &s.selected, ids, func(id string) string {
			if configuration := s.configuration(id); configuration != nil {
				return configuration.Name
			}
			return id
		}).Label(label).Grow(1).Shrink(1).MinWidth(0).MaxWidth(360)
		run := ui.Button(c.Part("run"), i18n.Shared(language, "desktop.runConfig.run")).Icon(icons.Play).Small()
		if p.build.operation != nil || s.selected == "" {
			run.Disabled(true)
		}
		if run.Clicked() {
			id := s.selected
			c.After(func() { a.runConfiguration(p, id) })
		}
		ui.Spacer(c)
	})
	ui.Divider(c)
}
