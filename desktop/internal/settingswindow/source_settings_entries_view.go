package settingswindow

import (
	"errors"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/app"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// Widths of an entry list's attribute columns, shared by the heading and the rows.
const (
	entryFlagWidth   = 64
	entryChoiceWidth = 120
)

func entryAttributeWidth(attribute core.SourceEntryAttribute) float32 {
	if attribute.Kind == "boolean" {
		return entryFlagWidth
	}
	return entryChoiceWidth
}

func sourceEntriesDisabled(p *sourceSettingsForm, source core.SettingsSource) bool {
	return p.busy || p.stale || !source.Writable
}

// sourceEntryToolbar is the line above an entry list: add, remove, move up and
// down, and the headings of its attribute columns. A read-only list keeps only
// the headings.
func (w *window) sourceEntryToolbar(c ui.C, p *sourceSettingsForm, source core.SettingsSource, field core.SourceSettingField) {
	language := w.marketLanguage()
	control := p.controls[source.ID][field.ID]
	disabled := sourceEntriesDisabled(p, source)
	entries := control.input.Entries
	// A read-only list without attribute columns has nothing to put on the line.
	if !source.Writable && (len(field.Attributes) == 0 || len(entries) == 0) {
		if len(entries) == 0 {
			ui.Text(c, i18n.Shared(language, "desktop.sourceSettings.entryEmpty")).FontSize(12).Color(w.pal.muted).PadX(8)
		}
		return
	}
	ui.Row(c).FillWidth().Height(28).PadRight(8).Items(ui.Center).Gap(2).Children(func() {
		if source.Writable {
			addLabel := i18n.Shared(language, "desktop.sourceSettings.entryAdd")
			add := ui.Button(c.Part("add"), addLabel).Icon(icons.Plus).IconOnly().Ghost().Size(26, 26).
				Disabled(disabled || len(entries) >= maximumSourceEntries).Tooltip(addLabel)
			if add.Clicked() {
				control.menu = !control.menu
			}
			ui.Menu(c, add, &control.menu, func(menu *ui.MenuItems) {
				for index, kind := range field.EntryKinds {
					item := menu.Item(i18n.SharedFormat(language, "desktop.sourceSettings.entryKind", map[string]string{"title": kind.Title}))
					if kind.Input == "choice" {
						item = item.Disabled(len(choiceEntries(field, index, entries)) == 0)
					}
					if item.Clicked() {
						w.addSourceEntries(c, p, source, field, index)
					}
				}
			})
			buttons := []struct {
				part, label string
				icon        gfx.Icon
				off         bool
				run         func()
			}{
				{"remove", i18n.Shared(language, "desktop.sourceSettings.entryRemove"), icons.Minus, control.entry < 0, func() { p.removeEntry(source.ID, field) }},
				{"up", i18n.Shared(language, "desktop.sourceSettings.entryUp"), icons.ArrowUp, control.entry <= 0, func() { p.moveEntry(source.ID, field, -1) }},
				{"down", i18n.Shared(language, "desktop.sourceSettings.entryDown"), icons.ArrowDown, control.entry < 0 || control.entry >= len(entries)-1, func() { p.moveEntry(source.ID, field, 1) }},
			}
			for _, button := range buttons {
				if ui.Button(c.Part(button.part), button.label).Icon(button.icon).IconOnly().Ghost().Size(26, 26).Disabled(disabled || button.off).Tooltip(button.label).Clicked() {
					button.run()
				}
			}
		}
		ui.Spacer(c)
		if len(entries) > 0 {
			for _, attribute := range field.Attributes {
				ui.Text(c, attribute.Title).FontSize(11).Color(w.pal.muted).Width(entryAttributeWidth(attribute)).Shrink(0).Ellipsis()
			}
		}
	})
	if len(entries) == 0 {
		ui.Text(c, i18n.Shared(language, "desktop.sourceSettings.entryEmpty")).FontSize(12).Color(w.pal.muted).PadX(8)
	}
}

// sourceEntryRow is one entry: its kind's icon, its title and detail, and its
// attribute columns. A click selects it for remove and move.
func (w *window) sourceEntryRow(c ui.C, p *sourceSettingsForm, source core.SettingsSource, field core.SourceSettingField, index int) {
	control := p.controls[source.ID][field.ID]
	if index >= len(control.input.Entries) {
		return
	}
	entry := control.input.Entries[index]
	disabled := sourceEntriesDisabled(p, source)
	selected := !disabled && control.entry == index
	icon := icons.LayoutGrid
	if kind := entryKindIndex(field, entry.Kind); kind >= 0 {
		switch field.EntryKinds[kind].Input {
		case "file":
			icon = icons.Archive
		case "directory":
			icon = icons.Folder
		}
	}
	label := entryLabel(entry)
	row := ui.Row(c).FillWidth().Height(28).PadX(8).Gap(8).Items(ui.Center).Radius(4).
		HitWith(ui.ID(c), label, gfx.HitOptions{Role: gfx.RoleOption, Selected: selected, Value: entry.Value, Disabled: disabled})
	if selected {
		row = row.Background(w.pal.selectionIdle)
	}
	row.Children(func() {
		ui.Icon(c, icon).Size(14, 14).Color(w.pal.muted)
		// The title keeps its width up to most of the row; the detail takes
		// what is left and is cut first.
		ui.Text(c, label).FontSize(12).Color(w.pal.text).Shrink(0).MaxWidthPercent(60).Ellipsis()
		ui.Text(c, entry.Detail).FontSize(11).Color(w.pal.muted).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
		for column, attribute := range field.Attributes {
			title := attribute.Title + " " + label
			if attribute.Kind == "boolean" {
				on := entryBool(entry, attribute.ID)
				ui.Row(c.Key(attribute.ID)).Width(entryFlagWidth).Shrink(0).Items(ui.Center).Children(func() {
					box := ui.Row(c).Size(16, 16).Radius(4).Border(1, w.pal.border).Center().
						HitWith(ui.ID(c), title, gfx.HitOptions{Role: gfx.RoleCheckbox, Checked: on, Disabled: disabled})
					if on {
						box = box.Background(w.pal.accent)
					}
					box.Children(func() {
						if on {
							ui.Icon(c, icons.Check).Size(12, 12).Color(w.pal.white)
						}
					})
					if !disabled && box.Clicked() {
						p.editEntries(source.ID, field, func(control *sourceSettingControl) {
							setEntryAttribute(&control.input.Entries[index], attribute.ID, !on)
						})
					}
				})
				continue
			}
			if column >= len(control.attributes[index]) {
				continue
			}
			choice := &control.attributes[index][column]
			indices := make([]int, len(attribute.Options))
			for option := range indices {
				indices[option] = option
			}
			optionTitle := func(option int) string { return attribute.Options[option].Title }
			if disabled {
				ui.Text(c, optionTitle(*choice)).FontSize(12).Color(w.pal.muted).Width(entryChoiceWidth).Shrink(0).Ellipsis()
				continue
			}
			if ui.Select(c.Key(attribute.ID), choice, indices, optionTitle).Width(entryChoiceWidth).Shrink(0).Label(title).Changed() {
				value := attribute.Options[*choice].Value
				p.editEntries(source.ID, field, func(control *sourceSettingControl) {
					setEntryAttribute(&control.input.Entries[index], attribute.ID, value)
				})
			}
		}
	})
	if !disabled && row.Clicked() {
		control.entry = index
	}
}

// addSourceEntries runs one add-menu item: a native picker for files or
// folders, or the dialog of the choices the list does not hold yet.
func (w *window) addSourceEntries(c ui.C, p *sourceSettingsForm, source core.SettingsSource, field core.SourceSettingField, kindIndex int) {
	kind := field.EntryKinds[kindIndex]
	control := p.controls[source.ID][field.ID]
	if kind.Input == "choice" {
		p.chooser = sourceEntryChooser{open: true, source: source.ID, field: field.ID, kind: kindIndex, picked: make([]bool, len(kind.Choices))}
		return
	}
	c.After(func() {
		var paths []string
		var err error
		if kind.Input == "directory" {
			var path string
			path, err = app.OpenDirectory(app.OpenDirectoryOptions{Title: kind.Title})
			paths = []string{path}
		} else {
			options := app.OpenFileOptions{Title: kind.Title, AllowMultiple: true}
			if len(kind.Extensions) > 0 {
				patterns := make([]string, len(kind.Extensions))
				for index, extension := range kind.Extensions {
					patterns[index] = "*." + extension
				}
				options.Filters = []app.FileFilter{{Name: kind.Title, Pattern: strings.Join(patterns, ";")}}
			}
			paths, err = app.OpenFiles(options)
		}
		// log-exempt: 用户取消：关闭原生选择器不修改条目草稿。
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
		p.addEntries(source.ID, field, pathEntries(control.input.Entries, kind.ID, paths))
	})
}

// sourceEntryChooser is the dialog that adds entries of a choice kind: the
// choices the list does not hold yet, each with a checkbox.
func (w *window) sourceEntryChooser(c ui.C, p *sourceSettingsForm) {
	chooser := &p.chooser
	if !chooser.open {
		return
	}
	language := w.marketLanguage()
	var source core.SettingsSource
	var field core.SourceSettingField
	found := false
	for _, candidate := range p.editor.State.Snapshot.Sources {
		if candidate.ID != chooser.source {
			continue
		}
		for _, candidateField := range candidate.Fields {
			if candidateField.ID == chooser.field && chooser.kind < len(candidateField.EntryKinds) {
				source, field, found = candidate, candidateField, true
			}
		}
	}
	if !found {
		chooser.open = false
		return
	}
	control := p.controls[source.ID][field.ID]
	kind := field.EntryKinds[chooser.kind]
	available := choiceEntries(field, chooser.kind, control.input.Entries)
	title := i18n.SharedFormat(language, "desktop.sourceSettings.chooseTitle", map[string]string{"title": kind.Title})
	ui.Modal(c, &chooser.open, title, ui.ModalSpec{Width: 480, Height: 440}, func() {
		if len(available) == 0 {
			ui.Wrap(c, i18n.Shared(language, "desktop.sourceSettings.chooseNone")).FontSize(12).Color(w.pal.muted)
			return
		}
		ui.List(c, &chooser.list, len(available), func(row ui.ListRow) {
			index := available[row.Index]
			choice := kind.Choices[index]
			row.Element.FillWidth().Children(func() {
				ui.Row(row.C).FillWidth().Gap(8).Items(ui.Center).PadY(4).Children(func() {
					ui.Checkbox(row.C, &chooser.picked[index], choice.Title).Shrink(0)
					ui.Text(row.C, choice.Detail).FontSize(11).Color(w.pal.muted).Grow(1).Shrink(1).MinWidth(0).Ellipsis()
				})
			})
		}).Scrollbars().FillWidth().Grow(1).MinHeight(200).Label(title)
	}, func() {
		if ui.Button(c, i18n.Shared(language, "desktop.sourceSettings.cancel")).Outline().Clicked() {
			chooser.open = false
		}
		var entries []core.SourceEntry
		for _, index := range available {
			if chooser.picked[index] && len(control.input.Entries)+len(entries) < maximumSourceEntries {
				choice := kind.Choices[index]
				entries = append(entries, core.SourceEntry{Kind: kind.ID, Value: choice.Value, Title: choice.Title, Detail: choice.Detail})
			}
		}
		if ui.Button(c, i18n.Shared(language, "desktop.sourceSettings.entryAdd")).Disabled(len(entries) == 0).Clicked() {
			p.addEntries(source.ID, field, entries)
			chooser.open = false
		}
	})
}
