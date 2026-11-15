package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// ideAPIPage is the IDE Connection page: one project's connection, its two grants and the
// client configuration to copy. Grants stay fixed while the connection is on.
func (w *window) ideAPIPage(c ui.C) {
	loader := w.ctrl.opts.IDEAPI
	st := loader.State()
	text := &w.text.IDEAPI
	p := &w.pal
	w.pageScroll(c, pageIDEAPI, func() {
		ui.Wrap(c, text.Intro).FontSize(12).Color(p.muted)
		w.card(c, text.Project, "", func() {
			ui.Column(c).FillWidth().Gap(8).Children(func() {
				if !st.HasProject {
					ui.Wrap(c, text.NoProject).FontSize(12).Color(p.muted)
					return
				}
				if st.HelperMissing {
					ui.Wrap(c, text.HelperMissing).FontSize(12).Color(p.muted)
				}
				status := text.StatusDisabled
				if st.Enabled {
					status = text.StatusEnabled
				}
				ui.Text(c, status).FontSize(12).Weight(gfx.WeightSemibold).Color(p.muted)
				configure := st.Configure
				ui.Switch(c.Key("configure"), &configure, text.AllowConfigure).Disabled(st.Enabled)
				if configure != st.Configure {
					c.After(func() { loader.Allow(configure, st.Execute) })
				}
				ui.Wrap(c, text.AllowConfigureHelp).FontSize(12).Color(p.muted)
				execute := st.Execute
				ui.Switch(c.Key("execute"), &execute, text.AllowExecute).Disabled(st.Enabled)
				if execute != st.Execute {
					c.After(func() { loader.Allow(st.Configure, execute) })
				}
				ui.Wrap(c, text.AllowExecuteHelp).FontSize(12).Color(p.muted)
				ui.Wrap(c, text.GrantsFixed).FontSize(12).Color(p.muted)
				ui.Row(c).Gap(8).Children(func() {
					if st.Enabled {
						if ui.Button(c.Key("disable"), text.Disable).Outline().Clicked() {
							c.After(func() { loader.Disable() })
						}
					} else if ui.Button(c.Key("enable"), text.Enable).Disabled(st.HelperMissing).Clicked() {
						c.After(func() { loader.Enable(st.Configure, st.Execute) })
					}
					if ui.Button(c.Key("copy"), text.CopyConfiguration).Outline().Disabled(!st.Enabled).Clicked() {
						c.After(func() { loader.CopyConfiguration() })
					}
				})
				if st.Error != "" {
					ui.Wrap(c, i18n.IDEAPIFailed(w.marketLanguage(), st.Error)).FontSize(12).Color(p.muted)
				}
			})
		})
	})
}
