package settingswindow

import (
	"context"
	"errors"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
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
	// entry is the selected entry of an entryList, -1 for none; menu whether its
	// add menu is open; attributes the option index of each entry's enum columns,
	// which its drop-downs bind to.
	entry      int
	menu       bool
	attributes [][]int
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
	// The module list of a form with a sidebar group, the item it shows (by
	// group and source ID, so a reload keeps it) and each source's open tab.
	nav            []sourceNavItem
	navTree        ui.TreeState
	selectedGroup  string
	selectedSource string
	tabs           map[string]*string
	chooser        sourceEntryChooser
}

func newSourceSettingsForm(loader PluginSettingsLoader, owner pluginservice.SettingsEditor, action string, editor pluginsettings.SourceEditor) *sourceSettingsForm {
	p := &sourceSettingsForm{loader: loader, owner: owner, action: action, tabs: make(map[string]*string)}
	p.navTree.Node, p.navTree.RowHeight, p.navTree.Indent = p.navNode, 28, 14
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
	p.chooser.open = false
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
			control := &sourceSettingControl{input: cloneSourceInput(input), base: cloneSourceInput(input), inherited: editor.State.InheritedInputs[source.ID][field.ID], entry: -1}
			control.choices = make([]int, len(field.Options)+1)
			for index := range control.choices {
				control.choices[index] = index
				if index > 0 && field.Options[index-1].Value == input.Choice && !input.Inherit {
					control.selected = index
				}
			}
			control.syncAttributes(field)
			fields[field.ID] = control
		}
		p.controls[source.ID] = fields
	}
	p.stale, p.failed = false, nil
	p.layout()
}

// syncAttributes points each enum column's drop-down at its entry's value.
func (control *sourceSettingControl) syncAttributes(field core.SourceSettingField) {
	control.attributes = control.attributes[:0]
	for _, entry := range control.input.Entries {
		row := make([]int, len(field.Attributes))
		for column, attribute := range field.Attributes {
			value := entryChoice(entry, attribute)
			for index, option := range attribute.Options {
				if option.Value == value {
					row[column] = index
				}
			}
		}
		control.attributes = append(control.attributes, row)
	}
}

func (p *sourceSettingsForm) layout() {
	p.rows = p.rows[:0]
	p.available = make(map[string][]int)
	p.layoutDirty = false
	p.navigation()
	snapshot := &p.editor.State.Snapshot
	all := func(core.SourceSettingField) bool { return true }
	for _, section := range p.editor.State.Layout {
		groupIndex := section.Group
		group := snapshot.Groups[groupIndex]
		// With a module list only the selected item is shown beside it.
		if len(p.nav) > 0 && group.ID != p.selectedGroup {
			continue
		}
		if group.Layout == "sidebar" {
			for _, sourceIndex := range section.Sources {
				source := snapshot.Sources[sourceIndex]
				if source.ID != p.selectedSource {
					continue
				}
				p.rows = append(p.rows, sourceSettingsRow{kind: sourceRowModule, group: groupIndex, source: sourceIndex, field: -1, entry: -1})
				sections := sourceSections(source)
				tab := p.tabs[source.ID]
				if tab == nil {
					tab = new(string)
					p.tabs[source.ID] = tab
				}
				if !slices.Contains(sections, *tab) {
					*tab = ""
					if len(sections) > 0 {
						*tab = sections[0]
					}
				}
				// One section needs no tab to choose it.
				if len(sections) > 1 {
					p.rows = append(p.rows, sourceSettingsRow{kind: sourceRowTabs, group: groupIndex, source: sourceIndex, field: -1, entry: -1})
				}
				current := *tab
				p.fieldRows(groupIndex, sourceIndex, func(field core.SourceSettingField) bool {
					return field.Section == "" || field.Section == current
				}, false)
			}
			continue
		}
		p.rows = append(p.rows, sourceSettingsRow{kind: sourceRowGroup, group: groupIndex, source: -1, field: -1, entry: -1})
		if p.add[group.ID] == nil {
			p.add[group.ID] = new(int)
		}
		for _, sourceIndex := range section.Sources {
			source := snapshot.Sources[sourceIndex]
			if group.Layout == "table" {
				visible := false
				for _, control := range p.controls[source.ID] {
					visible = visible || !control.input.Inherit
				}
				if visible {
					p.rows = append(p.rows, sourceSettingsRow{kind: sourceRowTable, group: groupIndex, source: sourceIndex, field: -1, entry: -1})
				}
				if !visible && source.Writable {
					p.available[group.ID] = append(p.available[group.ID], sourceIndex)
				}
			} else {
				p.fieldRows(groupIndex, sourceIndex, all, true)
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
	if sameSourceInput(control.input, control.base) {
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
		rows := func() {
			ui.List(c, &p.list, len(p.rows), func(row ui.ListRow) {
				row.Element.FillWidth().Children(func() { w.sourceSettingsRow(row.C, p, p.rows[row.Index]) })
			}).Scrollbars().FillWidth().Grow(1).MinHeight(settingsListMinHeight).Label(p.editor.State.Snapshot.Title)
		}
		if len(p.nav) == 0 {
			rows()
			return
		}
		ui.Row(c).FillWidth().Grow(1).MinHeight(settingsListMinHeight).Children(func() {
			ui.Tree(c, &p.navTree, len(p.nav), p.navLabel, func(i int) { w.sourceNavContent(c, p, i) }).
				Scrollbars().Width(sourceNavWidth).FillHeight().Shrink(0).Label(i18n.Shared(language, "desktop.sourceSettings.modules"))
			if i, ok := p.navTree.Chosen(); ok && i < len(p.nav) && !p.nav[i].heading {
				p.selectNav(p.nav[i])
			}
			ui.Column(c).Width(1).FillHeight().Shrink(0).Background(w.pal.line)
			ui.Column(c).Grow(1).MinWidth(0).FillHeight().PadLeft(14).Children(rows)
		})
	})
	w.sourceEntryChooser(c, p)
	// A click that selected a module or tab or changed an entry list changed the
	// rows being declared; lay them out again before the next paint.
	if p.layoutDirty {
		c.After(func() {
			if p.layoutDirty {
				p.layout()
			}
		})
	}
}

// sourceNavWidth is the width of the module list beside a sidebar form.
const sourceNavWidth = 168

// settingsListMinHeight is the least height of a source form's rows: they are the entries of
// a tool's own configuration, which has no upper bound, so they scroll by themselves beside
// the module tree. A window too short to give them that scrolls the page instead of squeezing
// them. It still fits whole under an installed plugin's header and tabs in the smallest
// window. A plugin's own declared settings are capped by Core and are not a list; they are
// declared whole and scroll with the page.
const settingsListMinHeight = 160

func (p *sourceSettingsForm) navNode(i int) ui.TreeNode {
	if i < 0 || i >= len(p.nav) {
		return ui.TreeNode{}
	}
	item := p.nav[i]
	return ui.TreeNode{Depth: item.depth, Selected: !item.heading && p.navSelected(item)}
}

func (p *sourceSettingsForm) navLabel(i int) string {
	if i < 0 || i >= len(p.nav) {
		return ""
	}
	if item := p.nav[i]; item.source >= 0 {
		return p.editor.State.Snapshot.Sources[item.source].Title
	}
	return p.editor.State.Snapshot.Groups[p.nav[i].group].Title
}

func (w *window) sourceNavContent(c ui.C, p *sourceSettingsForm, i int) {
	if i < 0 || i >= len(p.nav) {
		return
	}
	item := p.nav[i]
	if item.heading {
		ui.Text(c, p.navLabel(i)).FontSize(11).Weight(gfx.WeightSemibold).Color(w.pal.muted).Grow(1).MinWidth(0).Ellipsis()
		return
	}
	icon := icons.LayoutGrid
	if item.source >= 0 {
		icon = icons.Folder
	}
	ui.Row(c).Grow(1).MinWidth(0).Gap(6).Items(ui.Center).Children(func() {
		ui.Icon(c, icon).Size(14, 14).Color(w.pal.muted)
		ui.Text(c, p.navLabel(i)).FontSize(13).Color(w.pal.text).Grow(1).MinWidth(0).Ellipsis()
	})
}

// sourceSettingsRow declares one row of a source form's list.
func (w *window) sourceSettingsRow(c ui.C, p *sourceSettingsForm, item sourceSettingsRow) {
	language := w.marketLanguage()
	snapshot := &p.editor.State.Snapshot
	group := snapshot.Groups[item.group]
	switch item.kind {
	case sourceRowGroup:
		w.sourceSettingsGroup(c, p, group)
		return
	case sourceRowModule:
		source := snapshot.Sources[item.source]
		ui.Row(c).FillWidth().Items(ui.Center).Gap(8).PadY(6).Children(func() {
			ui.Text(c, source.Title).FontSize(15).Weight(gfx.WeightSemibold).Color(w.pal.text).Shrink(0)
			ui.Spacer(c)
			ui.Text(c, source.Path).FontSize(11).Color(w.pal.muted).Shrink(1).MinWidth(0).Ellipsis()
		})
		return
	case sourceRowTabs:
		source := snapshot.Sources[item.source]
		tab := p.tabs[source.ID]
		before := *tab
		ui.Tabs(c, tab, sourceSections(source), func(section string) string { return section })
		if *tab != before {
			p.layoutDirty = true
		}
		return
	case sourceRowEntry:
		w.sourceEntryRow(c, p, snapshot.Sources[item.source], snapshot.Sources[item.source].Fields[item.field], item.entry)
		return
	}
	source := snapshot.Sources[item.source]
	if item.kind == sourceRowTable {
		ui.Row(c).FillWidth().MinHeight(36).Items(ui.Center).Gap(8).Children(func() {
			ui.Text(c, source.Title).FontSize(12).Color(w.pal.text).Grow(1).Ellipsis()
			w.infoButton(c, source.Path)
			for _, field := range source.Fields {
				w.sourceSettingsControl(c.Key(field.ID), p, source, field)
			}
			if ui.Button(c, i18n.Shared(language, "desktop.sourceSettings.remove")).Outline().Disabled(p.busy || !source.Writable).Clicked() {
				for id, control := range p.controls[source.ID] {
					control.input = cloneSourceInput(control.inherited)
					control.selected = 0
					p.changed(source.ID, id)
				}
			}
		})
		return
	}
	field := source.Fields[item.field]
	ui.Column(c).FillWidth().Gap(5).PadY(6).Children(func() {
		if item.heading != "" {
			ui.Text(c, item.heading).FontSize(13).Weight(gfx.WeightSemibold).Color(w.pal.text).PadTop(6)
		}
		ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
			if field.Kind == "boolean" {
				w.sourceSettingsControl(c, p, source, field)
			} else {
				ui.Text(c, field.Title).FontSize(12).Weight(gfx.WeightSemibold).Color(w.pal.text)
			}
			if field.Description != "" {
				w.infoButton(c, field.Description)
			}
			ui.Spacer(c)
			// An entry list's rows follow it, so its origin goes beside its title.
			if field.Kind == "entryList" && field.EffectiveSource != "" {
				ui.Text(c, field.EffectiveSource).FontSize(11).Color(w.pal.muted).Shrink(1).MinWidth(0).Ellipsis()
			} else if item.field == 0 && group.Layout != "sidebar" {
				ui.Text(c, source.Path).FontSize(11).Color(w.pal.muted).Ellipsis()
			}
		})
		if field.Kind == "entryList" {
			w.sourceEffectiveHint(c, p, source, field)
			w.sourceEntryToolbar(c, p, source, field)
		} else if field.Kind != "boolean" {
			w.sourceSettingsControl(c, p, source, field)
		}
		if field.EffectiveSource != "" && field.Kind != "entryList" {
			ui.Text(c, field.EffectiveSource).FontSize(11).Color(w.pal.muted)
		}
		// A source the plugin projects read-only has nothing to reset, and an entry
		// list only resets to an inherited list the plugin knows.
		if source.Writable && field.Kind != "enum" && (field.Kind != "entryList" || inheritedKnown(field)) && !controlInherits(p, source.ID, field.ID) && ui.Button(c, i18n.Shared(language, "desktop.pluginSettings.reset")).Link().Disabled(p.busy || p.stale).Clicked() {
			control := p.controls[source.ID][field.ID]
			control.input = cloneSourceInput(control.inherited)
			control.entry = -1
			control.syncAttributes(field)
			p.changed(source.ID, field.ID)
			p.layoutDirty = true
		}
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
			// The choice stays readable and can be copied while the source takes no edit.
			value := label(control.selected)
			ui.TextField(c, &value, field.Title, "").ReadOnly(true).Grow(1).MinWidth(0).Height(30)
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
		list := field.Kind == "stringList" || field.Kind == "fileList"
		// A source that takes no edit keeps the value in the same field, read-only, so it
		// can still be selected and copied.
		if list {
			if ui.TextArea(c, &control.input.Text, field.Title, "").FillWidth().Height(100).ReadOnly(disabled).Changed() {
				control.input.Inherit = false
				p.changed(source.ID, field.ID)
			}
		} else {
			if ui.TextField(c, &control.input.Text, field.Title, "").FillWidth().Height(30).ReadOnly(disabled).Changed() {
				control.input.Inherit = false
				p.changed(source.ID, field.ID)
			}
		}
		if field.Kind == "fileList" && source.Writable && ui.Button(c, i18n.Shared(language, "desktop.pluginSettings.browse")).Outline().Disabled(disabled).Clicked() {
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
	w.sourceEffectiveHint(c, p, source, field)
}

// sourceEffectiveHint shows the value the tool uses when it differs from the draft or is inherited.
func (w *window) sourceEffectiveHint(c ui.C, p *sourceSettingsForm, source core.SettingsSource, field core.SourceSettingField) {
	language := w.marketLanguage()
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

// inheritedKnown reports whether the plugin projected the value a field takes
// without its override.
func inheritedKnown(field core.SourceSettingField) bool {
	return len(field.InheritedValue) > 0 && string(field.InheritedValue) != "null"
}

func controlInherits(p *sourceSettingsForm, source, field string) bool {
	return p.controls[source][field].input.Inherit
}
