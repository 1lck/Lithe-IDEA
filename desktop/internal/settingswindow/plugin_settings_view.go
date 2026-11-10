package settingswindow

import (
	"errors"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"sort"
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginbackend"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

var (
	pluginSettingRows     = tree.Sub(root, tree.Name("plugin-settings-rows"))
	pluginSettingOptions  = tree.Sub(root, tree.Name("plugin-settings-options"))
	pluginSettingsScope   = tree.Sub(root, tree.Name("plugin-settings-scope"))
	pluginSettingsSave    = tree.ID(root, "plugin-settings-save")
	pluginSettingsReload  = tree.ID(root, "plugin-settings-reload")
	pluginSettingsScroll  = tree.ID(root, "plugin-settings-scroll")
	pluginSettingsRestart = tree.ID(root, "plugin-settings-restart")
)

func (w *window) drawPluginSettings(f *ui.Frame, id string) {
	p := &w.pluginSettings
	if p.loader == nil {
		return
	}
	if p.id != id {
		p.load(id)
	}
	f.Column().FillWidth().Gap(10).Children(func() {
		f.Row().FillWidth().Height(1).Background(w.pal.line)
		f.Row().FillWidth().Gap(8).Items(ui.Center).Children(func() {
			f.Text(i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.title")).FontSize(14).Weight(gfx.WeightSemibold).Color(w.pal.text)
			f.Spacer()
			if f.Button(pluginSettingsReload, i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.reload")).Outline().Disabled(p.running).Clicked() {
				p.load(id)
			}
			if f.Button(pluginSettingsSave, i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.save")).Disabled(p.running || !p.loaded || !p.hasDraft()).Clicked() {
				p.save()
			}
		})
		if p.failed != nil {
			message := i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.failed")
			var rejection *core.MarketplaceRejection
			if errors.As(p.failed, &rejection) {
				switch rejection.Code {
				case "plugin.settings.invalidEdit":
					message = i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.invalidEdit")
				case "plugin.settings.invalidDocument":
					message = i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.invalidDocument")
				case "plugin.settings.ownerChanged":
					message = i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.conflict")
				}
			}
			if errors.Is(p.failed, pluginbackend.ErrNoSession) {
				message = i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.actionProviderUnavailable")
			}
			if errors.Is(p.failed, configfile.ErrConflict) {
				message = i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.conflict")
			}
			f.Wrap(message).FontSize(12).Color(w.pal.danger)
		}
		if p.running {
			f.Text(i18n.Shared(w.marketLanguage(), "native.loading")).FontSize(12).Color(w.pal.muted)
		}
		if w.ctrl.opts.PluginRuntime != nil {
			runtime := w.ctrl.opts.PluginRuntime(id)
			if runtime.RestartRequired || runtime.Restarting {
				f.Wrap(i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.restartRequired")).FontSize(12).Color(w.pal.muted)
				if w.ctrl.opts.RestartPlugin != nil && f.Button(pluginSettingsRestart, i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.restart")).Disabled(!runtime.Running || runtime.Restarting || p.running || !p.loaded || runtime.Version != p.editor.Snapshot.State.Metadata.Version).Clicked() {
					scope := "global"
					if p.scope == 1 {
						scope = "project"
					}
					w.ctrl.opts.RestartPlugin(id, p.editor.Snapshot.State.Metadata.Version, scope, p.editor.Snapshot.Workspace())
				}
			}
		}
		if p.saved {
			f.Text(i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.saved")).FontSize(12).Color(w.pal.muted)
		}
		if p.editor.Snapshot.State.PluginID != id || (!p.loaded && len(p.controls[p.scope]) == 0) {
			return
		}
		state := &p.editor.Snapshot.State
		f.Row().FillWidth().Gap(8).Items(ui.Center).Children(func() {
			labels := []string{i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.global"), i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.project")}
			pick := f.Select(pluginSettingsScope, &p.scopeSelect, labels, p.scope).Width(180).Label(i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.scope")).Disabled(p.running || p.hasDraft())
			if scope, ok := pick.Picked(); ok {
				p.scope = scope
				p.saved = false
				p.failed = nil
			}
			f.Text(i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.scopeHelp")).FontSize(11).Color(w.pal.muted).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
		})
		source := p.editor.Snapshot.GlobalPath()
		if p.scope == 1 {
			source = p.editor.Snapshot.ProjectPath()
		}
		if source == "" {
			f.Wrap(i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.openProject")).FontSize(12).Color(w.pal.muted)
		} else {
			f.Wrap(source).FontSize(11).Color(w.pal.muted)
		}
		w.drawPluginSettingActions(f)
		if len(state.Rows) == 0 {
			f.Text(i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.empty")).FontSize(12).Color(w.pal.muted)
			return
		}
		// Geometry stays native. Walk Core's section references without sorting or
		// regrouping them, creating controls only in the nested form's viewport.
		scroll := w.view.ScrollState(pluginSettingsScroll)
		viewport := scroll.Viewport
		if viewport <= 0 {
			viewport = 360
		}
		top, bottom := max(float32(0), scroll.Offset-120), scroll.Offset+viewport+120
		f.ScrollArea(pluginSettingsScroll).FillWidth().Height(360).Shrink(0).Children(func() {
			first := sort.Search(len(p.layout), func(i int) bool { return p.layout[i].offset+p.layout[i].height >= top })
			last := sort.Search(len(p.layout), func(i int) bool { return p.layout[i].offset > bottom })
			if first < len(p.layout) && p.layout[first].offset > 0 {
				f.Row().Height(p.layout[first].offset).Shrink(0)
			}
			for _, item := range p.layout[first:last] {
				if item.row < 0 {
					f.Row().FillWidth().Height(item.height).Shrink(0).Items(ui.Center).Children(func() { f.Text(item.title).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text) })
				} else {
					w.pluginSettingRow(f, item.row, item.height, source != "")
				}
			}
			end := float32(0)
			if last > 0 {
				item := p.layout[last-1]
				end = item.offset + item.height
			}
			if p.height > end {
				f.Row().Height(p.height - end).Shrink(0)
			}

		})
	})
}

func (w *window) pluginSettingRow(f *ui.Frame, index int, height float32, hasSource bool) {
	p := &w.pluginSettings
	row := &p.editor.Snapshot.State.Rows[index]
	declaration := &row.Declaration
	editor := p.editor.Snapshot.State.Editors.Global[index]
	if p.scope == 1 {
		editor = p.editor.Snapshot.State.Editors.Project[index]
	}
	control := &p.controls[p.scope][index]
	disabled := p.running || !p.loaded || !editor.Editable || !hasSource
	// A stable stride reserves identities for the control, reset, browse and
	// option checkboxes; manifests bound option counts to at most 32.
	base := index * 64
	f.Column().FillWidth().Height(height).Shrink(0).Gap(5).PadY(8).Children(func() {
		f.Row().FillWidth().Height(22).Items(ui.Center).Gap(8).Children(func() {
			f.Text(declaration.Title).FontSize(12).Weight(gfx.WeightSemibold).Color(w.pal.text).Ellipsis()
			f.Spacer()
			if f.Button(pluginSettingRows.At(base+1), i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.reset")).Outline().Disabled(disabled).Clicked() {
				control.apply(editor.ResetInput)
				control.reset = true
			}
		})
		if declaration.Description != "" {
			f.Text(declaration.Description).FontSize(11).Color(w.pal.muted).Ellipsis()
		}
		switch declaration.Kind {
		case "boolean":
			if f.Switch(pluginSettingRows.At(base), control.input.On).Label(declaration.Title).Disabled(disabled).Clicked() {
				control.input.On = !control.input.On
				control.reset = false
			}
		case "enum":
			labels := make([]string, len(declaration.Options))
			for i, option := range declaration.Options {
				labels[i] = option.Title
			}
			pick := f.Select(tree.Sub(pluginSettingOptions, gfx.Index(index)), &control.selectState, labels, control.input.Selected).Width(230).Label(declaration.Title).Disabled(disabled)
			if selected, ok := pick.Picked(); ok {
				control.input.Selected = selected
				control.reset = false
			}
		case "multiSelect":
			for i, option := range declaration.Options {
				f.Row().Height(26).FillWidth().Items(ui.Center).Gap(8).Children(func() {
					if f.Checkbox(pluginSettingRows.At(base+3+i), control.input.Checks[i]).Label(option.Title).Disabled(disabled).Clicked() {
						control.input.Checks[i] = !control.input.Checks[i]
						control.reset = false
					}
					f.Text(option.Title).FontSize(12).Color(w.pal.text)
				})
			}
		default:
			f.Row().FillWidth().Height(30).Gap(8).Children(func() {
				if disabled {
					// Box.Disabled does not apply to Field in pinned Viva.
					// Its upstream InputSnapshot carries the actual native
					// read-only/disabled semantics, including accessibility.
					f.Input(components.InputSnapshot{ID: pluginSettingRows.At(base), Label: declaration.Title, Value: control.field.Text(), Placeholder: declaration.Placeholder, ReadOnly: true, Disabled: true}).Grow(1).MinWidth(0).Height(30)
				} else {
					f.Field(&control.field, pluginSettingRows.At(base), declaration.Title, declaration.Placeholder).Grow(1).MinWidth(0).Height(30)
				}
				if declaration.Kind == "file" || declaration.Kind == "directory" {
					if f.Button(pluginSettingRows.At(base+2), i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.browse")).Outline().Disabled(disabled).Clicked() {
						w.pickPluginSettingPath(index)
					}
				}
			})
			if control.field.Text() != control.input.Text {
				control.reset = false
			}
		}
		if declaration.Kind == "integer" && declaration.Minimum != nil && declaration.Maximum != nil {
			f.Text(i18n.SharedFormat(w.marketLanguage(), "desktop.pluginSettings.range", map[string]string{"minimum": strconv.FormatInt(*declaration.Minimum, 10), "maximum": strconv.FormatInt(*declaration.Maximum, 10), "unit": declaration.Unit})).FontSize(11).Color(w.pal.muted).Ellipsis()
		}
		if editor.InvalidStored {
			f.Text(i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.invalidStored")).FontSize(11).Color(w.pal.danger)
		} else if !editor.Editable {
			f.Text(i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.globalOnly")).FontSize(11).Color(w.pal.muted)
		} else if !editor.Overridden {
			f.Text(i18n.Shared(w.marketLanguage(), "desktop.pluginSettings.inherited")).FontSize(11).Color(w.pal.muted)
		}
	})
}

func (w *window) pickPluginSettingPath(index int) {
	p := &w.pluginSettings
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
		control.field.SetText(path)
		control.reset = false
	}
}

func (w *window) pluginSettingsTextInput(context app.TextInputContext) *app.TextInput {
	if input := ui.Fields(&w.search, &w.marketQuery)(context); input != nil {
		return input
	}
	p := &w.pluginSettings
	if p.running || !p.loaded || (p.scope == 1 && p.editor.Snapshot.Workspace() == "") {
		return nil
	}
	editors := p.editor.Snapshot.State.Editors.Global
	if p.scope == 1 {
		editors = p.editor.Snapshot.State.Editors.Project
	}
	for i := range p.controls[p.scope] {
		if !editors[i].Editable {
			continue
		}
		if input := ui.Fields(&p.controls[p.scope][i].field)(context); input != nil {
			return input
		}
	}
	return nil
}
