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
// live in the form, so the panel can come and go without losing them. ruled draws a line
// above the toolbar, which parts the form from what its parent shows above it; a page that
// opens on the form leaves it out.
//
// The panel has no scroll of its own: its header, the plugin's region and all of its rows
// are declared whole and scroll with the page its parent scrolls. Core caps a page at
// MAX_SETTINGS settings and MAX_SETTING_ACTIONS actions, so the rows of one form are a short
// form, which the project's scrolling rules let a view declare without virtualizing it. A
// scroll of the panel's own would take only the height a tall region leaves it, scroll inside
// that height once the page is at its end, and cut its first rows off under the region.
func (w *window) pluginSettingsPanel(c ui.C, id string, ruled bool) {
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
	language := w.marketLanguage()
	if p.id != id {
		p.language = language
		p.load(id)
	}
	p.follow(language)
	if p.sources != nil {
		w.sourceSettingsPanel(c, p.sources)
		return
	}
	page := w.dynamic.selected(w.dynamicPage)
	compiler := page != nil && page.Kind == "compiler"
	ui.Column(c).FillWidth().Grow(1).Gap(10).Children(func() {
		if !compiler {
			if ruled {
				ui.Row(c).FillWidth().Height(1).Background(w.pal.line)
			}
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
		}
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
			var unavailable *pluginbackend.SessionUnavailableError
			if errors.As(p.failed, &unavailable) && unavailable.Detail != "" {
				ui.Wrap(c, unavailable.Detail).FontSize(12).Color(w.pal.danger)
			}
		}
		if p.running {
			ui.Text(c, i18n.Shared(language, "native.loading")).FontSize(12).Color(w.pal.muted)
		}
		if w.ctrl.opts.PluginRuntime != nil {
			runtime := w.ctrl.opts.PluginRuntime(id)
			if runtime.RestartRequired || runtime.Restarting {
				ui.Wrap(c, i18n.Shared(language, "desktop.pluginSettings.restartRequired")).FontSize(12).Color(w.pal.muted)
				if w.ctrl.opts.RestartPlugin != nil && ui.Button(c, i18n.Shared(language, "desktop.pluginSettings.restart")).Disabled((!runtime.Running && !runtime.Failed) || runtime.Restarting || p.running || !p.loaded || runtime.Version != p.editor.Snapshot.State.Metadata.Version).Clicked() {
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
		if compiler {
			w.pluginSettingActions(c)
			w.pluginRegion(c, p, true)
			for _, item := range p.layout {
				if item.action {
					w.pluginSettingActionRow(c, item.row)
				}
			}
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
			w.infoButton(c, i18n.Shared(language, "desktop.pluginSettings.scopeHelp"))
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
		// The plugin's region sits between the header and its declared rows, which stay.
		w.pluginRegion(c, p, source != "")
		if len(p.layout) == 0 {
			if w.region == nil {
				ui.Text(c, i18n.Shared(language, "desktop.pluginSettings.empty")).FontSize(12).Color(w.pal.muted)
			}
			return
		}
		// Core's section references are walked in Core's order, without sorting or
		// regrouping them. The rows hold their own vertical padding, so they sit in a
		// column of their own rather than taking the gap the panel parts its header with.
		ui.Column(c.Part("rows")).FillWidth().Shrink(0).Children(func() {
			for index := range p.layout {
				w.pluginSettingsFormRow(c.KeyInt(index), p.layout[index], source != "")
			}
		})
	})
}

// pluginSettingsFormRow declares one row of the form: a section title, a setting or an
// action.
func (w *window) pluginSettingsFormRow(c ui.C, item pluginSettingLayout, hasSource bool) {
	switch {
	case item.action:
		w.pluginSettingActionRow(c, item.row)
	case item.row < 0:
		ui.Row(c).FillWidth().Shrink(0).Height(28).Items(ui.Center).Children(func() {
			ui.Text(c, item.title).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text)
		})
	default:
		w.pluginSettingRow(c, item.row, hasSource)
	}
}

// pluginSettingRow declares one setting on one line: its title on the leading side, and on
// the trailing side the control for its kind and Reset, so the controls of a page line up
// down its trailing edge. A text, path or list takes most of the line, and moves under the
// title where the pane is too narrow for both. What is known about the value, and the
// options of a multiple choice, follow under the line. Whatever the user does with the
// control changes the draft only.
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
	text := declaration.Kind != "boolean" && declaration.Kind != "enum" && declaration.Kind != "multiSelect"
	ui.Column(c).FillWidth().Shrink(0).Gap(4).PadY(6).Children(func() {
		// The title starts the line, and the value with its buttons ends it. A value typed in
		// or chosen from a list shares the line with the title two to three, and moves under
		// it, buttons and all, when the pane has no room for both at their minimum widths; a
		// switch leaves the title the rest of the line.
		ui.Flow(c).FillWidth().MinHeight(30).Items(ui.Center).Gap(8).LineGap(6).Children(func() {
			ui.Row(c.Part("title")).Basis(0).Grow(2).Shrink(1).MinWidth(120).Items(ui.Center).Gap(8).Children(func() {
				ui.Text(c, declaration.Title).FontSize(12).Weight(gfx.WeightSemibold).Color(w.pal.text).Shrink(1).MinWidth(0).Ellipsis()
				if declaration.Description != "" {
					w.infoButton(c, declaration.Description)
				}
			})
			value := ui.Row(c.Part("value")).Shrink(0).Justify(ui.End).Items(ui.Center).Gap(8)
			switch declaration.Kind {
			case "enum":
				value = value.Basis(0).Grow(3).MinWidth(220)
			case "boolean", "multiSelect":
			default:
				value = value.Basis(0).Grow(3).MinWidth(260)
			}
			value.Children(func() {
				switch declaration.Kind {
				case "boolean":
					// The title on the line names the switch, so the switch carries the title
					// for assistive technology only and shows no caption of its own.
					if ui.Switch(c, &control.input.On, "").Label(declaration.Title).Disabled(disabled).Changed() {
						control.reset = false
					}
				case "enum":
					labels := declaration.Options
					label := func(option int) string { return labels[option].Title }
					if disabled {
						ui.Text(c, label(control.input.Selected)).FontSize(12).Color(w.pal.muted).Grow(1).MinWidth(0).MaxWidth(230).TextEnd().Ellipsis()
					} else if ui.Select(c, &control.input.Selected, control.options, label).Grow(1).MinWidth(120).MaxWidth(230).Label(declaration.Title).Changed() {
						control.reset = false
					}
				case "multiSelect":
					// Its options are listed under the line.
				default:
					ui.TextField(c, &control.text, declaration.Title, declaration.Placeholder).ReadOnly(disabled).Grow(1).MinWidth(0).Height(30)
					if declaration.Kind == "file" || declaration.Kind == "directory" {
						if ui.Button(c, i18n.Shared(language, "desktop.pluginSettings.browse")).Outline().Small().Shrink(0).Disabled(disabled).Clicked() {
							// The native picker blocks, so it runs after the paint.
							c.After(func() { w.pickPluginSettingPath(index) })
						}
					}
				}
				if ui.Button(c, i18n.Shared(language, "desktop.pluginSettings.reset")).Outline().Small().Shrink(0).Disabled(disabled).Clicked() {
					control.apply(editor.ResetInput)
					control.reset = true
				}
			})
		})
		if text && control.text != control.input.Text {
			control.reset = false
		}
		if declaration.Kind == "multiSelect" {
			for i, option := range declaration.Options {
				ui.Row(c.Key(option.Value)).Height(26).FillWidth().Items(ui.Center).Gap(8).Children(func() {
					if ui.Checkbox(c, &control.input.Checks[i], option.Title).Disabled(disabled).Changed() {
						control.reset = false
					}
				})
			}
		}
		if declaration.Kind == "integer" && declaration.Minimum != nil && declaration.Maximum != nil {
			ui.Text(c, i18n.SharedFormat(language, "desktop.pluginSettings.range", map[string]string{"minimum": strconv.FormatInt(*declaration.Minimum, 10), "maximum": strconv.FormatInt(*declaration.Maximum, 10), "unit": declaration.Unit})).FontSize(11).Color(w.pal.muted).Ellipsis()
		}
		if editor.InvalidStored {
			ui.Text(c, i18n.Shared(language, "desktop.pluginSettings.invalidStored")).FontSize(11).Color(w.pal.danger)
		} else if !editor.Editable {
			ui.Text(c, i18n.Shared(language, "desktop.pluginSettings.globalOnly")).FontSize(11).Color(w.pal.muted)
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
