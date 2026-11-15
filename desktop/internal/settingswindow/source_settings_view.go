package settingswindow

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

type sourceSettingControl struct {
	input     core.SourceSettingInput
	base      core.SourceSettingInput
	inherited core.SourceSettingInput
	choices   []int
	selected  int
}

type sourceSettingsRow struct {
	group  int
	source int
	field  int
}

// A source form owns only presentation drafts. The worker receives a captured
// native editor and sends all parsing, normalization and edit planning to Core.
type sourceSettingsForm struct {
	owner              pluginservice.SettingsEditor
	action             string
	editor             pluginsettings.SourceEditor
	controls           map[string]map[string]*sourceSettingControl
	rows               []sourceSettingsRow
	list               ui.ListState
	add                map[string]*int
	available          map[string][]int
	pending            map[string]map[string]core.SourceSettingInput
	tableSources       map[string]bool
	layoutDirty        bool
	loader             PluginSettingsLoader
	effect             *ui.EffectState[pluginsettings.SourceEditor, int]
	key                int
	jobEdits           []core.SourceSettingsEdits
	jobEditor          pluginsettings.SourceEditor
	reload             bool
	busy, stale, saved bool
	failed             error
}

func newSourceSettingsForm(loader PluginSettingsLoader, owner pluginservice.SettingsEditor, action string, editor pluginsettings.SourceEditor) *sourceSettingsForm {
	p := &sourceSettingsForm{loader: loader, owner: owner, action: action}
	p.effect = ui.NewEffect[pluginsettings.SourceEditor, int](func(parent context.Context) (pluginsettings.SourceEditor, error) {
		ctx, cancel := context.WithTimeout(parent, 120*time.Second)
		defer cancel()
		if p.reload {
			result, err := p.loader.(PluginSettingsActionLoader).Action(ctx, p.owner, p.action, false)
			if err != nil {
				return p.jobEditor, err
			}
			if result.Sources == nil {
				return p.jobEditor, configfile.ErrConflict
			}
			return *result.Sources, nil
		}
		return p.loader.(PluginSourceSettingsLoader).SaveSources(ctx, p.owner, p.action, p.jobEditor, p.jobEdits)
	})
	p.apply(editor)
	return p
}

func (p *sourceSettingsForm) apply(editor pluginsettings.SourceEditor) {
	p.editor = editor
	p.controls = make(map[string]map[string]*sourceSettingControl)
	p.add = make(map[string]*int)
	p.pending = make(map[string]map[string]core.SourceSettingInput)
	p.tableSources = make(map[string]bool)
	for _, section := range editor.State.Layout {
		if editor.State.Snapshot.Groups[section.Group].Layout == "table" {
			for _, index := range section.Sources {
				p.tableSources[editor.State.Snapshot.Sources[index].ID] = true
			}
		}
	}
	for _, source := range editor.State.Snapshot.Sources {
		fields := make(map[string]*sourceSettingControl)
		for _, field := range source.Fields {
			input := editor.State.Inputs[source.ID][field.ID]
			control := &sourceSettingControl{input: input, base: input, inherited: editor.State.InheritedInputs[source.ID][field.ID]}
			control.choices = make([]int, len(field.Options)+1)
			for index := range control.choices {
				control.choices[index] = index
				if index > 0 && field.Options[index-1].Value == input.Choice && !input.Inherit {
					control.selected = index
				}
			}
			fields[field.ID] = control
		}
		p.controls[source.ID] = fields
	}
	p.stale, p.failed = false, nil
	p.layout()
}

func (p *sourceSettingsForm) layout() {
	p.rows = p.rows[:0]
	p.available = make(map[string][]int)
	p.layoutDirty = false
	for _, section := range p.editor.State.Layout {
		groupIndex := section.Group
		group := p.editor.State.Snapshot.Groups[groupIndex]
		p.rows = append(p.rows, sourceSettingsRow{group: groupIndex, source: -1, field: -1})
		if p.add[group.ID] == nil {
			p.add[group.ID] = new(int)
		}
		for _, sourceIndex := range section.Sources {
			source := p.editor.State.Snapshot.Sources[sourceIndex]
			if group.Layout == "table" {
				visible := false
				for _, control := range p.controls[source.ID] {
					visible = visible || !control.input.Inherit
				}
				if visible {
					p.rows = append(p.rows, sourceSettingsRow{group: groupIndex, source: sourceIndex, field: -1})
				}
				if !visible && source.Writable {
					p.available[group.ID] = append(p.available[group.ID], sourceIndex)
				}
			} else {
				for fieldIndex := range source.Fields {
					p.rows = append(p.rows, sourceSettingsRow{group: groupIndex, source: sourceIndex, field: fieldIndex})
				}
			}
		}
		if available := p.available[group.ID]; len(available) > 0 {
			selected := p.add[group.ID]
			valid := false
			for _, index := range available {
				valid = valid || index == *selected
			}
			if !valid {
				*selected = available[0]
			}
		}
	}
}

func (p *sourceSettingsForm) edits() []core.SourceSettingsEdits {
	var edits []core.SourceSettingsEdits
	for id, inputs := range p.pending {
		values := make(map[string]core.SourceSettingInput, len(inputs))
		for field, input := range inputs {
			values[field] = input
		}
		edits = append(edits, core.SourceSettingsEdits{SourceID: id, Values: values})
	}
	return edits
}

func (p *sourceSettingsForm) changed(source, field string) {
	control := p.controls[source][field]
	if control.input == control.base {
		delete(p.pending[source], field)
		if len(p.pending[source]) == 0 {
			delete(p.pending, source)
		}
	} else {
		if p.pending[source] == nil {
			p.pending[source] = make(map[string]core.SourceSettingInput)
		}
		p.pending[source][field] = control.input
	}
	p.saved = false
	if p.tableSources[source] {
		p.layoutDirty = true
	}
}

func (p *sourceSettingsForm) start(reload bool) {
	if p.busy {
		return
	}
	p.jobEditor, p.jobEdits = p.editor, p.edits()
	p.reload, p.busy, p.saved, p.failed = reload, true, false, nil
	p.key++
}

func (p *sourceSettingsForm) take() {
	if editor, err, ok := p.effect.Take(); ok {
		p.busy, p.failed = false, err
		if err == nil {
			p.apply(editor)
			p.saved = !p.reload
		} else if errors.Is(err, pluginsettings.ErrSourcesCommitted) || errors.Is(err, configfile.ErrConflict) {
			p.stale = true
		}
	}
	if p.layoutDirty {
		p.layout()
	}
}

func (w *window) sourceSettingsPanel(c ui.C, p *sourceSettingsForm) {
	language := w.marketLanguage()
	ui.Column(c).FillWidth().Grow(1).Gap(10).Children(func() {
		ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
			ui.Text(c, p.editor.State.Snapshot.Title).FontSize(14).Weight(gfx.WeightSemibold).Color(w.pal.text)
			ui.Spacer(c)
			if ui.Button(c, i18n.Shared(language, "desktop.pluginSettings.reload")).Outline().Disabled(p.busy).Clicked() {
				p.start(true)
			}
			if ui.Button(c, i18n.Shared(language, "desktop.pluginSettings.save")).Disabled(p.busy || p.stale || len(p.pending) == 0).Clicked() {
				p.start(false)
			}
			if ui.Button(c, i18n.Shared(language, "desktop.sourceSettings.close")).Outline().Disabled(p.busy).Clicked() {
				w.pluginSettings.sources = nil
			}
		})
		if p.busy {
			ui.Text(c, i18n.Shared(language, "native.loading")).FontSize(12).Color(w.pal.muted)
		}
		if p.failed != nil {
			message := i18n.Shared(language, "desktop.pluginSettings.failed")
			if p.stale {
				message = i18n.Shared(language, "desktop.pluginSettings.sourceChanged")
			}
			ui.Wrap(c, message).FontSize(12).Color(w.pal.danger)
		}
		if p.saved {
			ui.Text(c, i18n.Shared(language, "desktop.pluginSettings.saved")).FontSize(12).Color(w.pal.muted)
		}
		ui.List(c, &p.list, len(p.rows), func(row ui.ListRow) {
			item := p.rows[row.Index]
			group := p.editor.State.Snapshot.Groups[item.group]
			row.Element.FillWidth().Children(func() {
				if item.source < 0 {
					w.sourceSettingsGroup(row.C, p, group)
					return
				}
				source := p.editor.State.Snapshot.Sources[item.source]
				if item.field >= 0 {
					field := source.Fields[item.field]
					ui.Column(row.C).FillWidth().Gap(5).PadY(6).Children(func() {
						ui.Row(row.C).FillWidth().Items(ui.Center).Gap(8).Children(func() {
							if field.Kind == "boolean" {
								w.sourceSettingsControl(row.C, p, source, field)
							} else {
								ui.Text(row.C, field.Title).FontSize(12).Weight(gfx.WeightSemibold).Color(w.pal.text)
							}
							if field.Description != "" {
								w.infoButton(row.C, field.Description)
							}
							ui.Spacer(row.C)
							if item.field == 0 {
								ui.Text(row.C, source.Path).FontSize(11).Color(w.pal.muted).Ellipsis()
							}
						})
						if field.Kind != "boolean" {
							w.sourceSettingsControl(row.C, p, source, field)
						}
						if field.EffectiveSource != "" {
							ui.Text(row.C, field.EffectiveSource).FontSize(11).Color(w.pal.muted)
						}
						if field.Kind != "enum" && !controlInherits(p, source.ID, field.ID) && ui.Button(row.C, i18n.Shared(language, "desktop.pluginSettings.reset")).Link().Disabled(p.busy || p.stale || !source.Writable || controlInherits(p, source.ID, field.ID)).Clicked() {
							control := p.controls[source.ID][field.ID]
							control.input = control.inherited
							p.changed(source.ID, field.ID)
						}
					})
				} else {
					ui.Row(row.C).FillWidth().MinHeight(36).Items(ui.Center).Gap(8).Children(func() {
						ui.Text(row.C, source.Title).FontSize(12).Color(w.pal.text).Grow(1).Ellipsis()
						w.infoButton(row.C, source.Path)
						for _, field := range source.Fields {
							w.sourceSettingsControl(row.C.Key(field.ID), p, source, field)
						}
						if ui.Button(row.C, i18n.Shared(language, "desktop.sourceSettings.remove")).Outline().Disabled(p.busy || !source.Writable).Clicked() {
							for id, control := range p.controls[source.ID] {
								control.input = control.inherited
								control.selected = 0
								p.changed(source.ID, id)
							}
						}
					})
				}
			})
		}).Scrollbars().FillWidth().Grow(1).MinHeight(settingsListMinHeight).Label(p.editor.State.Snapshot.Title)
	})
}

func (w *window) sourceSettingsGroup(c ui.C, p *sourceSettingsForm, group core.SourceSettingsGroup) {
	language := w.marketLanguage()
	ui.Column(c).FillWidth().Gap(6).PadY(8).Children(func() {
		ui.Text(c, group.Title).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text)
		if group.Layout != "table" {
			return
		}
		available := p.available[group.ID]
		ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
			if len(available) > 0 {
				selected := p.add[group.ID]
				label := func(index int) string { return p.editor.State.Snapshot.Sources[index].Title }
				ui.Select(c, selected, available, label).Width(230).Label(group.Title).Disabled(p.busy)
				if ui.Button(c, i18n.Shared(language, "desktop.sourceSettings.add")).Outline().Disabled(p.busy).Clicked() {
					source := p.editor.State.Snapshot.Sources[*selected]
					for _, field := range source.Fields {
						control := p.controls[source.ID][field.ID]
						control.input.Inherit = false
						for index, option := range field.Options {
							if option.Value == control.input.Choice {
								control.selected = index + 1
							}
						}
						p.changed(source.ID, field.ID)
					}
				}
			} else {
				ui.Text(c, i18n.Shared(language, "desktop.sourceSettings.allEntriesShown")).FontSize(11).Color(w.pal.muted)
			}
		})
		if group.RowTitle != "" {
			ui.Text(c, group.RowTitle).FontSize(11).Color(w.pal.muted)
		}
	})
}

func (w *window) sourceSettingsControl(c ui.C, p *sourceSettingsForm, source core.SettingsSource, field core.SourceSettingField) {
	language := w.marketLanguage()
	control := p.controls[source.ID][field.ID]
	disabled := p.busy || p.stale || !source.Writable
	accessibleTitle := field.Title
	if p.tableSources[source.ID] {
		accessibleTitle = source.Title + " " + field.Title
	}
	switch field.Kind {
	case "enum":
		label := func(index int) string {
			if index > 0 {
				return field.Options[index-1].Title
			}
			value := control.inherited.Choice
			if value == "" {
				value = i18n.Shared(language, "desktop.sourceSettings.noValue")
			}
			for _, option := range field.Options {
				if option.Value == value {
					value = option.Title
					break
				}
			}
			return i18n.SharedFormat(language, "desktop.sourceSettings.inherit", map[string]string{"value": value})
		}
		if disabled {
			w.readOnlyField(c, field.Title, label(control.selected))
			return
		}
		if ui.Select(c, &control.selected, control.choices, label).Width(190).Label(accessibleTitle).Changed() {
			control.input.Inherit = control.selected == 0
			if control.selected > 0 {
				control.input.Choice = field.Options[control.selected-1].Value
			}
			p.changed(source.ID, field.ID)
		}
	case "boolean":
		if ui.Checkbox(c, &control.input.On, field.Title).Disabled(disabled).Changed() {
			control.input.Inherit = false
			p.changed(source.ID, field.ID)
		}
	default:
		if disabled {
			w.readOnlyField(c, field.Title, control.input.Text)
		} else if field.Kind == "stringList" || field.Kind == "fileList" {
			if ui.TextArea(c, &control.input.Text, field.Title, "").FillWidth().Height(100).Changed() {
				control.input.Inherit = false
				p.changed(source.ID, field.ID)
			}
		} else {
			if ui.TextField(c, &control.input.Text, field.Title, "").FillWidth().Height(30).Changed() {
				control.input.Inherit = false
				p.changed(source.ID, field.ID)
			}
		}
		if field.Kind == "fileList" && ui.Button(c, i18n.Shared(language, "desktop.pluginSettings.browse")).Outline().Disabled(disabled).Clicked() {
			c.After(func() {
				paths, err := app.OpenFiles(app.OpenFileOptions{Title: field.Title})
				// log-exempt: 用户取消：文件选择器取消不修改依赖草稿。
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
				if w.pluginSettings.sources != p || p.controls[source.ID][field.ID] != control {
					return
				}
				if len(paths) > 0 {
					if control.input.Text != "" && !strings.HasSuffix(control.input.Text, "\n") {
						control.input.Text += "\n"
					}
					control.input.Text += strings.Join(paths, "\n")
					control.input.Inherit = false
					p.changed(source.ID, field.ID)
				}
			})
		}
	}
	if display, ok := p.editor.State.EffectiveDisplays[source.ID][field.ID]; ok {
		value := display.Text
		switch display.Kind {
		case "unknown":
			value = i18n.Shared(language, "desktop.sourceSettings.noValue")
		case "boolean":
			value = i18n.Shared(language, "native.disabled.variant2")
			if display.On {
				value = i18n.Shared(language, "native.enabled.variant2")
			}
		case "list":
			value = i18n.SharedFormat(language, "desktop.sourceSettings.fileCount", map[string]string{"count": strconv.Itoa(display.Count)})
		}
		hint := i18n.SharedFormat(language, "desktop.sourceSettings.effective", map[string]string{"value": value})
		if display.Inherited {
			hint = i18n.SharedFormat(language, "desktop.sourceSettings.inherit", map[string]string{"value": value})
		}
		ui.Text(c, hint).FontSize(11).Color(w.pal.muted).Ellipsis()
	}

}

func controlInherits(p *sourceSettingsForm, source, field string) bool {
	return p.controls[source][field].input.Inherit
}
