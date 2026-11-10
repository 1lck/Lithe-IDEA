package settingswindow

import (
	"errors"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// scopeChoices are the two scopes a plugin's settings are edited in: global, then project.
var scopeChoices = []int{0, 1}

// scopeLabel is the words of scope.
func (w *window) scopeLabel(scope int) string {
	if scope == 1 {
		return i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.project")
	}
	return i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.global")
}

// pluginSettingsPanel is the form of the plugin id: the toolbar that reloads or saves it,
// what the last request said, the scope and then Core's rows in Core's order. The drafts
// live in the form, so the panel can come and go without losing them.
func (w *window) pluginSettingsPanel(c ui.C, id string) {
	if !w.selectPluginForm(id) {
		ui.Wrap(c, i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.draftLimit")).Color(w.pal.danger)
		return
	}
	p := w.pluginSettings
	if p.pageKey != w.dynamicPage {
		p.pageKey = w.dynamicPage
		p.layoutRows()
	}
	if p.loader == nil {
		return
	}
	if p.id != id {
		p.load(id)
	}
	language := w.marketLanguage()
	ui.Column(c).FillWidth().Gap(10).Children(func() {
		ui.Row(c).FillWidth().Height(1).Background(w.pal.line)
		ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
			ui.Text(c, i18n.Shared(language, "desktop.pluginSettings.title")).FontSize(14).Weight(gfx.WeightSemibold).Color(w.pal.text)
			ui.Spacer(c)
			reloadLabel := i18n.Shared(language, "desktop.pluginSettings.reload")
			if p.hasDraft() {
				reloadLabel = i18n.Shared(language, "desktop.pluginSettings.discardReload")
			}
			if ui.Button(c, reloadLabel).Outline().Disabled(p.running).Clicked() {
				p.load(id)
			}
			if ui.Button(c, i18n.Shared(language, "desktop.pluginSettings.save")).Disabled(p.running || p.stale || !p.loaded || !p.hasDraft()).Clicked() {
				p.save()
			}
		})
		if p.stale {
			ui.Wrap(c, i18n.Shared(language, "desktop.pluginSettings.sourceChanged")).Color(w.pal.danger)
		}
		if p.failed != nil {
			message := i18n.Shared(language, "desktop.pluginSettings.failed")
			var rejection *core.MarketplaceRejection
			if errors.As(p.failed, &rejection) {
				switch rejection.Code {
				case "plugin.settings.invalidEdit":
					message = i18n.Shared(language, "desktop.pluginSettings.invalidEdit")
				case "plugin.settings.invalidDocument":
					message = i18n.Shared(language, "desktop.pluginSettings.invalidDocument")
				case "plugin.settings.ownerChanged":
					message = i18n.Shared(language, "desktop.pluginSettings.conflict")
				}
			}
			if errors.Is(p.failed, pluginbackend.ErrNoSession) {
				message = i18n.Shared(language, "desktop.pluginSettings.actionProviderUnavailable")
			}
			if errors.Is(p.failed, configfile.ErrConflict) {
				message = i18n.Shared(language, "desktop.pluginSettings.conflict")
			}
			ui.Wrap(c, message).FontSize(12).Color(w.pal.danger)
		}
		if p.running {
			ui.Text(c, i18n.Shared(language, "native.loading")).FontSize(12).Color(w.pal.muted)
		}
		if w.ctrl.opts.PluginRuntime != nil {
			runtime := w.ctrl.opts.PluginRuntime(id)
			if runtime.RestartRequired || runtime.Restarting {
				ui.Wrap(c, i18n.Shared(language, "desktop.pluginSettings.restartRequired")).FontSize(12).Color(w.pal.muted)
				if w.ctrl.opts.RestartPlugin != nil && ui.Button(c, i18n.Shared(language, "desktop.pluginSettings.restart")).Disabled(!runtime.Running || runtime.Restarting || p.running || !p.loaded || runtime.Version != p.editor.Snapshot.State.Metadata.Version).Clicked() {
					scope := "global"
					if p.scope == 1 {
						scope = "project"
					}
					w.ctrl.opts.RestartPlugin(id, p.editor.Snapshot.State.Metadata.Version, scope, p.editor.Snapshot.Workspace())
				}
			}
		}
		if p.saved {
			ui.Text(c, i18n.Shared(language, "desktop.pluginSettings.saved")).FontSize(12).Color(w.pal.muted)
		}
		if p.editor.Snapshot.State.PluginID != id || (!p.loaded && len(p.controls[p.scope]) == 0) {
			return
		}
		ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
			if p.running || p.hasDraft() {
				// A scope change would drop the draft of the other scope's rows, so the list is
				// replaced by the words of the scope in force.
				ui.Text(c, w.scopeLabel(p.scope)).FontSize(12).Color(w.pal.muted).Width(180)
			} else if ui.Select(c, &p.scope, scopeChoices, w.scopeLabel).Width(180).Label(i18n.Shared(language, "desktop.pluginSettings.scope")).Changed() {
				p.saved = false
				p.failed = nil
			}
			ui.Text(c, i18n.Shared(language, "desktop.pluginSettings.scopeHelp")).FontSize(11).Color(w.pal.muted).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
		})
		source := p.editor.Snapshot.GlobalPath()
		if p.scope == 1 {
			source = p.editor.Snapshot.ProjectPath()
		}
		if source == "" {
			ui.Wrap(c, i18n.Shared(language, "desktop.pluginSettings.openProject")).FontSize(12).Color(w.pal.muted)
		} else {
			ui.Wrap(c, source).FontSize(11).Color(w.pal.muted)
		}
		w.pluginSettingActions(c)
		if len(p.layout) == 0 {
			ui.Text(c, i18n.Shared(language, "desktop.pluginSettings.empty")).FontSize(12).Color(w.pal.muted)
			return
		}
		// Core's section references are walked in Core's order, without sorting or
		// regrouping them; the list declares only the rows in its viewport.
		ui.List(c, &p.rows, len(p.layout), func(row ui.ListRow) {
			w.pluginSettingsListRow(row, p, source != "")
		}).FillWidth().Height(360).Shrink(0).Label(i18n.Shared(language, "desktop.pluginSettings.title"))
	})
}

// pluginSettingsListRow declares one row of the form's list: a section title, a setting
// or an action.
func (w *window) pluginSettingsListRow(row ui.ListRow, p *pluginSettingsForm, hasSource bool) {
	c := row.C
	item := p.layout[row.Index]
	row.Element.FillWidth().Children(func() {
		switch {
		case item.action:
			w.pluginSettingActionRow(c, item.row)
		case item.row < 0:
			ui.Row(c).FillWidth().Height(28).Items(ui.Center).Children(func() {
				ui.Text(c, item.title).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text)
			})
		default:
			w.pluginSettingRow(c, item.row, hasSource)
		}
	})
}

// pluginSettingRow declares one setting: its title, the control for its kind and what is
// known about its value. Whatever the user does with the control changes the draft only.
func (w *window) pluginSettingRow(c ui.C, index int, hasSource bool) {
	p := w.pluginSettings
	language := w.marketLanguage()
	row := &p.editor.Snapshot.State.Rows[index]
	declaration := &row.Declaration
	editor := p.editor.Snapshot.State.Editors.Global[index]
	if p.scope == 1 {
		editor = p.editor.Snapshot.State.Editors.Project[index]
	}
	control := &p.controls[p.scope][index]
	disabled := p.running || !p.loaded || !editor.Editable || !hasSource
	ui.Column(c).FillWidth().Shrink(0).Gap(5).PadY(8).Children(func() {
		ui.Row(c).FillWidth().Height(22).Items(ui.Center).Gap(8).Children(func() {
			ui.Text(c, declaration.Title).FontSize(12).Weight(gfx.WeightSemibold).Color(w.pal.text).Ellipsis()
			if declaration.Description != "" {
				w.infoButton(c, declaration.Description)
			}
			ui.Spacer(c)
			if ui.Button(c, i18n.Shared(language, "desktop.pluginSettings.reset")).Outline().Disabled(disabled).Clicked() {
				control.apply(editor.ResetInput)
				control.reset = true
			}
		})
		switch declaration.Kind {
		case "boolean":
			if ui.Switch(c, &control.input.On, declaration.Title).Disabled(disabled).Changed() {
				control.reset = false
			}
		case "enum":
			labels := declaration.Options
			label := func(option int) string { return labels[option].Title }
			if disabled {
				ui.Text(c, label(control.input.Selected)).FontSize(12).Color(w.pal.muted).Width(230)
			} else if ui.Select(c, &control.input.Selected, control.options, label).Width(230).Label(declaration.Title).Changed() {
				control.reset = false
			}
		case "multiSelect":
			for i, option := range declaration.Options {
				ui.Row(c.Key(option.Value)).Height(26).FillWidth().Items(ui.Center).Gap(8).Children(func() {
					if ui.Checkbox(c, &control.input.Checks[i], option.Title).Disabled(disabled).Changed() {
						control.reset = false
					}
				})
			}
		default:
			ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
				if disabled {
					// Box.Disabled does not apply to a TextField in pinned Viva, so a
					// field that cannot be edited is shown as the text it holds.
					ui.Row(c).Grow(1).MinWidth(0).Height(30).PadX(10).Border(1, w.pal.line).Radius(6).Items(ui.Center).Children(func() {
						ui.Text(c, control.text).FontSize(13).Color(w.pal.muted).Ellipsis().Label(declaration.Title)
					})
				} else {
					ui.TextField(c, &control.text, declaration.Title, declaration.Placeholder).Grow(1).MinWidth(0).Height(30)
				}
				if declaration.Kind == "file" || declaration.Kind == "directory" {
					if ui.Button(c, i18n.Shared(language, "desktop.pluginSettings.browse")).Outline().Disabled(disabled).Clicked() {
						// The native picker blocks, so it runs after the paint.
						c.After(func() { w.pickPluginSettingPath(index) })
					}
				}
			})
			if control.text != control.input.Text {
				control.reset = false
			}
		}
		if declaration.Kind == "integer" && declaration.Minimum != nil && declaration.Maximum != nil {
			ui.Text(c, i18n.SharedFormat(language, "desktop.pluginSettings.range", map[string]string{"minimum": strconv.FormatInt(*declaration.Minimum, 10), "maximum": strconv.FormatInt(*declaration.Maximum, 10), "unit": declaration.Unit})).FontSize(11).Color(w.pal.muted).Ellipsis()
		}
		if editor.InvalidStored {
			ui.Text(c, i18n.Shared(language, "desktop.pluginSettings.invalidStored")).FontSize(11).Color(w.pal.danger)
		} else if !editor.Editable {
			ui.Text(c, i18n.Shared(language, "desktop.pluginSettings.globalOnly")).FontSize(11).Color(w.pal.muted)
		} else if !editor.Overridden {
			ui.Text(c, i18n.Shared(language, "desktop.pluginSettings.inherited")).FontSize(11).Color(w.pal.muted)
		}
	})
}

func (w *window) pickPluginSettingPath(index int) {
	p := w.pluginSettings
	declaration := p.editor.Snapshot.State.Rows[index].Declaration
	var path string
	var err error
	if declaration.Kind == "directory" {
		path, err = app.OpenDirectory(app.OpenDirectoryOptions{Title: declaration.Title})
	} else {
		var paths []string
		paths, err = app.OpenFiles(app.OpenFileOptions{Title: declaration.Title})
		if len(paths) > 0 {
			path = paths[0]
		}
	}
	// log-exempt: 用户取消：关闭原生文件选择器不修改草稿。
	if errors.Is(err, app.ErrCanceled) {
		return
	}
	if err != nil {
		p.failed = err
		if w.ctrl.opts.MarketplaceError != nil {
			w.ctrl.opts.MarketplaceError(err)
		}
		return
	}
	if path != "" {
		control := &p.controls[p.scope][index]
		control.text = path
		control.reset = false
	}
}
