package workbench

import (
	"runtime"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/fileicons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/components"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/keymap"
	"github.com/vivaui/viva/ui"
)

// This file draws the Run/Debug Configurations dialog of runconfig_dialog.go.

const (
	// runConfigDialogWidth and runConfigDialogHeight size the dialog: wide enough for the
	// tree and a path with its options beside it, tall enough for a script's fields.
	runConfigDialogWidth  = 900
	runConfigDialogHeight = 620
	// runConfigDialogTreeWidth is the width of the tree and its toolbar.
	runConfigDialogTreeWidth = 260
)

// runConfigAddChord is the modifiers and key that add a configuration, as in IDEA: ⌃N on macOS
// and Alt+Insert elsewhere.
func runConfigAddChord() (gfx.Modifiers, string) {
	if runtime.GOOS == "darwin" {
		return gfx.ModifierControl, "n"
	}
	return gfx.ModifierAlt, "insert"
}

// runConfigDeleteKeys are the keys that take the selection out of the tree: ⌫ and ⌦ on macOS,
// whose keyboards label ⌫ Delete, and Delete elsewhere, where Backspace only edits text.
func runConfigDeleteKeys() []string {
	if runtime.GOOS == "darwin" {
		return []string{"backspace", "delete"}
	}
	return []string{"delete"}
}

// drawRunConfigDialog declares the dialog while it is open: the toolbar and tree on the left,
// the selected configuration's editor on the right, and Run, Cancel, Apply and OK below.
// Escape and the close button end it like Cancel.
func (a *App) drawRunConfigDialog(c ui.C, p *project) {
	d := &p.runConfigs.dialog
	if !d.open {
		return
	}
	p.collectRunConfigDialogRows(a)
	open := true
	title := i18n.Shared(a.language(), "desktop.runConfig.dialogTitle")
	ui.Modal(c, &open, title, ui.ModalSpec{Width: runConfigDialogWidth, Height: runConfigDialogHeight}, func() {
		k := c.Part("run-config-dialog")
		ui.Row(k).Fill().Children(func() {
			a.drawRunConfigDialogTree(k, p)
			ui.Column(k).Width(1).FillHeight().Shrink(0).Background(a.colors.Line)
			a.drawRunConfigDialogPane(k, p)
		})
	}, func() {
		a.drawRunConfigDialogFooter(c.Part("run-config-dialog-footer"), p)
	})
	if !open {
		c.After(func() { a.closeRunConfigDialog(p) })
	}
}

// drawRunConfigDialogTree declares the left column: the buttons that add, remove and copy a
// configuration, make a folder and sort the list by name, over the tree of configurations.
// With the keyboard in it, ⌃N, or Alt+Insert off macOS, opens the menu of kinds a new
// configuration can take. The editor beside it keeps ⌃N, which moves down a line in a text
// field on macOS.
func (a *App) drawRunConfigDialogTree(c ui.C, p *project) {
	s := &p.runConfigs
	d := &s.dialog
	language := a.language()
	k := c.Part("tree")
	column := ui.Column(k).Width(runConfigDialogTreeWidth).FillHeight().Shrink(0).Children(func() {
		ui.Row(k.Part("toolbar")).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(2).PadX(6).Children(func() {
			label := i18n.Shared(language, "desktop.runConfig.newConfiguration")
			add, clicked := a.gitToolButton(k.Part("add"), label, icons.Plus, d.newMenu == runConfigNewMenuToolbar, d.saving)
			if clicked {
				c.After(func() { d.toggleNewMenu(runConfigNewMenuToolbar) })
			}
			a.drawRunConfigNewMenu(k, p, add, runConfigNewMenuToolbar)
			if a.gitIconButton(k.Part("remove"), i18n.Shared(language, "desktop.runConfig.removeConfiguration"), icons.Minus, false, !p.runConfigDialogRemovable()) {
				c.After(func() {
					a.performed("run.configuration.remove", surfaceButton)
					a.removeRunConfigSelection(p)
				})
			}
			if a.gitIconButton(k.Part("copy"), i18n.Shared(language, "desktop.runConfig.copyConfiguration"), icons.Copy, false, !p.runConfigCopyable(d.selected)) {
				c.After(func() {
					a.performed("run.configuration.copy", surfaceButton)
					a.copyRunConfigDraft(p)
				})
			}
			folderable := !d.saving && (d.selected != "" || d.node.group != "")
			if a.gitIconButton(k.Part("folder"), i18n.Shared(language, "desktop.runConfig.newFolder"), icons.FolderPlus, false, !folderable) {
				c.After(func() {
					a.performed("run.configuration.folder", surfaceButton)
					a.addRunConfigFolder(p)
				})
			}
			if a.gitIconButton(k.Part("sort"), i18n.Shared(language, "desktop.runConfig.sortAlphabetically"), icons.ArrowDownAZ, p.runConfigDialogSorted(), d.saving) {
				c.After(func() {
					a.performed("run.configuration.sort", surfaceButton)
					p.toggleRunConfigDialogSort()
				})
			}
		})
		ui.Row(k).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
		ui.Column(k.Part("rows")).FillWidth().Grow(1).MinHeight(0).Children(func() {
			a.drawRunConfigDialogRows(k, p)
		})
		if s.hidden > 0 {
			ui.Row(k).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
			ui.Row(k.Part("hidden")).FillWidth().Shrink(0).Items(ui.Center).Gap(6).Pad(8).Children(func() {
				ui.Icon(c, icons.Info).Size(12, 12).Shrink(0).Color(a.colors.Subtle)
				ui.Paragraph(c, hiddenRunConfigurations(language, s.hidden), 2).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Grow(1).MinWidth(0)
			})
		}
	})
	if modifiers, key := runConfigAddChord(); column.Shortcut(modifiers, key) && !d.saving {
		c.After(func() { d.newMenu = runConfigNewMenuToolbar })
	}
}

// toggleNewMenu opens the menu of kinds at at, or closes it when it shows there.
func (d *runConfigDialog) toggleNewMenu(at runConfigNewMenu) {
	if d.newMenu == at {
		d.newMenu = runConfigNewMenuClosed
		return
	}
	d.newMenu = at
}

// drawRunConfigNewMenu declares the menu of kinds under anchor while it shows at at.
func (a *App) drawRunConfigNewMenu(c ui.C, p *project, anchor ui.Box, at runConfigNewMenu) {
	d := &p.runConfigs.dialog
	if d.newMenu != at {
		return
	}
	open := true
	ui.Menu(c, anchor, &open, func(menu *ui.MenuItems) {
		menu.WidthRange(200, 300)
		a.runConfigDialogTypeItems(c, menu, p)
	})
	if !open && d.newMenu == at {
		d.newMenu = runConfigNewMenuClosed
	}
}

// runConfigDialogTypeItems adds an item per kind to the menu of kinds, each creating a new
// configuration of that kind: the built-in kinds, then the ones enabled plugins declare. Every
// row stays one line: the description its plugin gives, and for a kind this platform cannot
// run (still offered) the note saying so, are the tip of an ⓘ at the row's end.
func (a *App) runConfigDialogTypeItems(c ui.C, menu *ui.MenuItems, p *project) {
	language := a.language()
	s := &p.runConfigs
	more := i18n.Shared(language, "native.moreInformation")
	viewport := c.Bounds()
	for _, listed := range s.types {
		kind := runConfigKindOfType(listed)
		item := menu.Item(s.kindTitle(language, kind)).Icon(s.kindIcon(kind, &a.pluginIcons, a.colors.Dark))
		if tip := runConfigTypeTip(language, listed); tip != "" {
			id := ui.ID(c.Key("kindinfo:" + kind.groupKey()))
			item = item.Trailing(runConfigTypeInfoWidth, func(canvas *gfx.Canvas, slot gfx.Rect, theme gfx.Theme) {
				a.paintRunConfigTypeInfo(canvas, theme, slot, viewport, id, more, tip)
			})
		}
		if item.Clicked() {
			c.After(func() {
				a.performed("run.configuration.new", surfaceButton)
				a.addRunConfigDraft(p, kind, nil)
			})
		}
	}
	if len(p.runConfigs.types) == 0 {
		menu.Item(i18n.Shared(language, "native.loading")).Disabled(true)
	}
}

// runConfigTypeInfoWidth is the slot a kind's ⓘ takes at the end of its row in the menu of
// kinds, and runConfigTypeInfoSize the ⓘ inside it.
const (
	runConfigTypeInfoWidth = 22
	runConfigTypeInfoSize  = 14
)

// runConfigTypeTip is what the ⓘ of a kind in the menu of kinds says: the note of a kind this
// platform cannot run, then the kind's description. It is empty for a kind with neither, whose
// row has no ⓘ.
func runConfigTypeTip(language i18n.Language, kind core.RunConfigurationType) string {
	var lines []string
	if kind.Unavailable() {
		lines = append(lines, runConfigTypeNote(language, kind))
	}
	if kind.Description != "" {
		lines = append(lines, kind.Description)
	}
	return strings.Join(lines, "\n")
}

// paintRunConfigTypeInfo paints a kind's ⓘ in slot, the end of its row in the menu of kinds, as
// a target of its own over the row's, so pressing it does not choose the kind. While the pointer
// rests on it, tip shows beside it as a field's ⓘ shows its tip; label names it for assistive
// technology, which reads tip as its hint.
func (a *App) paintRunConfigTypeInfo(canvas *gfx.Canvas, theme gfx.Theme, slot, viewport gfx.Rect, id gfx.ID, label, tip string) {
	size := float32(runConfigTypeInfoSize)
	bounds := gfx.Rect{X: slot.X + (slot.Width-size)/2, Y: slot.Y + (slot.Height-size)/2, Width: size, Height: size}
	canvas.HitWithOptions(id, bounds, label, gfx.HitOptions{Role: gfx.RoleButton, Hint: tip, SkipFocus: true})
	hovered := canvas.Hovered() == id
	tint := a.colors.Subtle
	if hovered {
		tint = a.colors.Text
	}
	canvas.DrawIcon(icons.Info, bounds, tint)
	if hovered && canvas.Pressed().IsZero() {
		components.BeginTooltip(canvas, theme, viewport, bounds, components.TooltipOptions{Layer: ui.TooltipLayer, Side: components.TooltipRight}).Paint(tip)
	}
}

// runConfigTypeNote is the short note of a kind this platform cannot run, beside its name.
func runConfigTypeNote(language i18n.Language, kind core.RunConfigurationType) string {
	if kind.Provider == runProviderBatch && kind.Availability != nil && kind.Availability.Code == "unsupportedPlatform" {
		return i18n.Shared(language, "desktop.runConfig.windowsOnlyType")
	}
	return i18n.Shared(language, "desktop.runConfig.typeNotRunnableHere")
}

// drawRunConfigDialogRows declares the tree, or while it has no rows, why: the list is being
// read, could not be read, or holds nothing yet, with the link that adds a configuration.
// Selecting a row shows its editor; Enter or a double click on a group or folder opens or
// closes it. A configuration can be dragged into another folder of its kind and, while the list
// is not sorted by name, to another place. Delete, or ⌫ on macOS, takes the selection out.
func (a *App) drawRunConfigDialogRows(c ui.C, p *project) {
	s := &p.runConfigs
	d := &s.dialog
	language := a.language()
	if len(d.rows) == 0 {
		d.selectedRow = -1
		a.drawRunConfigDialogEmptyTree(c.Part("empty"), p)
		return
	}
	if d.view.Node == nil {
		d.view.Node = func(i int) ui.TreeNode {
			row := d.rows[i]
			return ui.TreeNode{Depth: row.depth, Branch: row.key == "", Expanded: row.key == "" && !d.closed[row.node], Selected: i == d.selectedRow}
		}
		d.view.Key = func(i int) int { return d.runConfigDialogRowID(d.rows[i]) }
		d.view.Label = func(i int) string { return a.runConfigDialogRowLabel(p, d.rows[i]) }
		d.view.RowHeight = treelist.RowHeight
		d.view.Indent = treelist.Indent
		d.view.CanDrop = p.runConfigDialogCanDrop
	}
	d.view.Disclosure = &components.TreeDisclosure{
		Collapsed: fileicons.TreeChevron(false, a.colors.Dark),
		Expanded:  fileicons.TreeChevron(true, a.colors.Dark),
		Size:      16,
	}
	a.syncRunConfigDialogSelection(c.Canvas(), p)
	title := i18n.Shared(language, "desktop.runConfig.dialogTitle")
	tree := ui.Tree(c, &d.view, len(d.rows), d.view.Label, func(i int) { a.drawRunConfigDialogRow(c, p, i) }).
		Scrollbars().Label(title).Grow(1).FillWidth().MinHeight(0).PadY(treelist.PadY)
	d.painted = len(d.rows)
	for _, key := range runConfigDeleteKeys() {
		if tree.Shortcut(0, key) {
			c.After(func() {
				if p.runConfigDialogRemovable() {
					a.performed("run.configuration.remove", surfaceShortcut)
					a.removeRunConfigSelection(p)
					d.refocus = true
				}
			})
		}
	}
	if i, ok := d.view.Toggled(); ok && i < len(d.rows) {
		node := d.rows[i].node
		c.After(func() { p.toggleRunConfigDialogNode(node) })
	}
	if move, ok := d.view.Dropped(); ok {
		c.After(func() { a.dropRunConfigDialogRow(p, move) })
	}
	i, ok := d.view.Chosen()
	if !ok || i >= len(d.rows) {
		return
	}
	info, clicked := c.Canvas().ClickInfo()
	repeated := clicked && info.Clicks >= 2
	row := d.rows[i]
	// The row a click chose takes the keyboard, so the arrow keys and Delete go on from it.
	c.Canvas().RequestFocus(d.view.RowID(i))
	c.After(func() {
		a.selectRunConfigDialogRow(p, row)
		if row.key == "" && (!clicked || repeated) {
			p.toggleRunConfigDialogNode(row.node)
		}
	})
}

// syncRunConfigDialogSelection makes the selection follow the keyboard, as the Problems tree
// does: a row the arrow keys moved the focus to is selected. A selection asked to show is
// scrolled into view once the tree has painted its row, and takes the keyboard when the tree
// has it, or when Delete just took out the row that had it.
func (a *App) syncRunConfigDialogSelection(canvas *gfx.Canvas, p *project) {
	d := &p.runConfigs.dialog
	focused := canvas.Focused()
	inTree := false
	if focused != d.focus || d.reveal || d.refocus {
		for i := range min(len(d.rows), d.painted) {
			if focused != (gfx.ID{}) && d.view.RowID(i) == focused {
				inTree = true
				if focused != d.focus {
					a.selectRunConfigDialogRow(p, d.rows[i])
				}
				break
			}
		}
		d.focus = focused
	}
	selected := d.runConfigDialogRowIndex()
	d.selectedRow = selected
	if (d.reveal || d.refocus) && selected >= 0 {
		if selected >= d.painted {
			// The row has not painted yet, so the tree cannot scroll to it or focus it.
			canvas.RequestFrame()
		} else {
			if first, last := d.view.Visible(); selected < first || selected > last {
				d.view.ScrollTo(selected, ui.ListCenter)
				canvas.RequestFrame()
			}
			if inTree || d.refocus {
				canvas.RequestFocus(d.view.RowID(selected))
			}
			d.reveal, d.refocus = false, false
		}
	} else if selected < 0 {
		d.reveal, d.refocus = false, false
	}
	if d.view.Selected() != selected {
		d.view.Select(selected)
	}
}

// runConfigDialogRowLabel names a row to assistive technology and to typing its start: the
// group's title, the folder's name or the configuration's, followed by why this platform
// cannot run it.
func (a *App) runConfigDialogRowLabel(p *project, row runConfigDialogRow) string {
	d := &p.runConfigs.dialog
	switch {
	case row.key != "":
		label := a.runConfigDraftLabel(p, row.key)
		if unavailable := a.runConfigDraftUnavailable(p, row.key); unavailable != "" {
			label += ", " + unavailable
		}
		return label
	case row.node.folder != "":
		return row.node.folder
	case row.group < len(d.groups):
		return d.groups[row.group].title
	}
	return ""
}

// drawRunConfigDialogRow declares what row i shows after its arrow: a group's icon and title, a
// folder's, or a configuration's icon and name. A configuration this platform cannot run shows
// a warning icon; the pane says why, and so does the row's label to assistive technology. A
// tree row takes every press in it, so nothing in it can carry a hover hint of its own. A
// configuration has no arrow, so it keeps the arrow's room empty and its icon lines up under
// its group's or folder's.
func (a *App) drawRunConfigDialogRow(c ui.C, p *project, i int) {
	d := &p.runConfigs.dialog
	if i >= len(d.rows) {
		return
	}
	row := d.rows[i]
	if row.key == "" {
		icon := fileicons.ForDirectory("folder", a.colors.Dark)
		if row.node.folder == "" {
			icon = d.groups[row.group].icon
		}
		ui.Icon(c, icon).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(a.colors.Subtle)
		ui.Text(c, a.runConfigDialogRowLabel(p, row)).FontSize(treeFontSize).Color(a.colors.Text).Shrink(1).MinWidth(0).Ellipsis()
		return
	}
	k := c.KeyInt(i)
	unavailable := a.runConfigDraftUnavailable(p, row.key)
	ui.Row(k).Shrink(1).MinWidth(0).Items(ui.Center).Gap(c.Theme().Metrics.GapItem).PadLeft(treeChevron).Children(func() {
		icon, color := a.runConfigDraftIcon(p, row.key), a.colors.Subtle
		if unavailable != "" {
			icon, color = icons.CircleAlert, a.colors.Warning
		}
		ui.Icon(c, icon).Size(treelist.Icon, treelist.Icon).Shrink(0).Color(color)
		ui.Text(c, a.runConfigDraftLabel(p, row.key)).FontSize(treeFontSize).Color(a.colors.Text).Shrink(1).MinWidth(0).Ellipsis()
	})
}

// drawRunConfigDialogEmptyTree declares the tree while it has no rows, as IDEA does: that no
// configuration was added, and the link that adds one with its keys; or that the list is being
// read or could not be read.
func (a *App) drawRunConfigDialogEmptyTree(c ui.C, p *project) {
	s := &p.runConfigs
	d := &s.dialog
	language := a.language()
	ui.Column(c).Fill().Center().Gap(6).PadX(12).Children(func() {
		switch {
		case s.failure != "":
			ui.Paragraph(c, i18n.SharedFormat(language, "desktop.runConfig.loadFailed", map[string]string{"reason": s.failure}), 4).TextCenter().FillWidth().Color(a.colors.Subtle)
			return
		case s.loading || s.generation == 0:
			ui.Text(c, i18n.Shared(language, "native.loading")).Color(a.colors.Subtle)
			return
		}
		ui.Paragraph(c, i18n.Shared(language, "desktop.runConfig.emptyTree"), 3).TextCenter().FillWidth().Color(a.colors.Subtle)
		ui.Row(c.Part("add")).Items(ui.Center).Gap(6).Children(func() {
			link := ui.Button(c.Part("add-link"), i18n.Shared(language, "desktop.runConfig.addNew")).Link().Disabled(d.saving)
			if link.Clicked() {
				c.After(func() { d.toggleNewMenu(runConfigNewMenuTree) })
			}
			a.drawRunConfigNewMenu(c, p, link, runConfigNewMenuTree)
			modifiers, key := runConfigAddChord()
			if chord, ok := keymap.Parse(modifiers, key); ok {
				ui.Text(c, shortcuts.Keycaps(chord)).Color(a.colors.Subtle)
			}
		})
	})
}

// drawRunConfigDialogPane declares the right column: the editor of the selected
// configuration, under the reason this platform cannot run it; the name of the selected folder;
// or, with neither selected, the link that adds a configuration.
func (a *App) drawRunConfigDialogPane(c ui.C, p *project) {
	d := &p.runConfigs.dialog
	k := c.Part("pane")
	ui.Column(k).Grow(1).FillHeight().MinWidth(0).Children(func() {
		draft := d.drafts[d.selected]
		if draft == nil && d.node.folder == "" {
			a.drawRunConfigDialogStart(k, p)
			return
		}
		ui.Scroll(k).Scrollbars().FillWidth().Grow(1).Children(func() {
			ui.Column(k).FillWidth().Gap(10).PadSides(14, 20, 14, 16).Children(func() {
				switch {
				case draft == nil:
					a.drawRunConfigFolderPane(k, p)
				default:
					if text := a.runConfigDraftUnavailable(p, d.selected); text != "" {
						a.drawRunConfigDialogBanner(k, text)
					}
					a.drawRunConfigDraft(k, p, draft)
				}
				if d.failure != "" {
					ui.Paragraph(c, d.failure, 4).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
				}
			})
		})
	})
}

// drawRunConfigDraft declares the editor of one configuration: the form of a built-in run, the
// options of a build provider run, the name of a copy Apply makes, or why a run whose plugin
// cannot resolve has no editor.
func (a *App) drawRunConfigDraft(c ui.C, p *project, draft *runConfigDraft) {
	d := &p.runConfigs.dialog
	language := a.language()
	switch {
	case draft.form != nil:
		f := draft.form
		if f.loading && f.fields == nil {
			ui.Text(c, i18n.Shared(language, "native.loading")).Color(a.colors.Subtle)
		}
		a.drawRunConfigFormFields(c, p, f, f.ready() && !d.saving)
		if f.failure != "" {
			ui.Paragraph(c, f.failure, 4).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
		}
	case draft.editor != nil:
		ui.Text(c, draft.editor.name).Weight(gfx.WeightSemibold).Ellipsis().FillWidth()
		if draft.editor.loading {
			ui.Text(c, i18n.Shared(language, "native.loading")).Color(a.colors.Subtle)
		}
		a.drawRunConfigEditorPane(c, p, draft.editor)
	case draft.copyOf != "":
		a.drawRunConfigNameRow(c.Part("copy"), func(k ui.C, label string) {
			ui.TextField(k, &draft.copyName, label, "").Disabled(d.saving || draft.copied).FillWidth()
		})
		ui.Paragraph(c, i18n.Shared(language, "desktop.runConfig.copyPendingHint"), 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	default:
		ui.Text(c, a.runConfigDraftLabel(p, draft.key)).Weight(gfx.WeightSemibold).Ellipsis().FillWidth()
		ui.Paragraph(c, i18n.Shared(language, "desktop.runConfig.notEditable"), 3).Color(a.colors.Subtle)
	}
}

// drawRunConfigFolderPane declares the pane of the selected folder: its name, which renames it
// as it is typed, why a name cannot be taken, and what a folder is.
func (a *App) drawRunConfigFolderPane(c ui.C, p *project) {
	d := &p.runConfigs.dialog
	language := a.language()
	a.drawRunConfigNameRow(c.Part("folder"), func(k ui.C, label string) {
		if ui.TextField(k, &d.folderName, label, "").Disabled(d.saving).FillWidth().Changed() {
			c.After(func() { a.renameRunConfigFolder(p) })
		}
		if d.folderError != "" {
			ui.Text(c, d.folderError).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
		}
	})
	ui.Paragraph(c, i18n.Shared(language, "desktop.runConfig.folderHint"), 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
}

// drawRunConfigNameRow declares a Name row laid out as the form's are: the label in the form's
// label column and what field declares beside it.
func (a *App) drawRunConfigNameRow(c ui.C, field func(k ui.C, label string)) {
	label, ok := runConfigFieldLabel(a.language(), "name")
	if !ok {
		label = "name"
	}
	ui.Row(c).FillWidth().Items(ui.Start).Gap(8).Children(func() {
		ui.Row(c.Part("title")).Width(runConfigFormLabelWidth).MinHeight(28).Shrink(0).Items(ui.Center).Gap(4).Children(func() {
			ui.Text(c, label)
		})
		ui.Column(c.Part("value")).Grow(1).MinWidth(0).Gap(4).Children(func() { field(c.Part("field"), label) })
	})
}

// runConfigDraftIcon is the icon of configuration key in the tree: its kind's for a built-in
// run or a kind a plugin declares, its execution's for a build provider run, its original's for a copy not saved yet.
func (a *App) runConfigDraftIcon(p *project, key string) gfx.Icon {
	if configuration := p.runConfigs.configuration(key); configuration != nil {
		if kind, ok := runConfigKindOf(*configuration); ok {
			return p.runConfigs.kindIcon(kind, &a.pluginIcons, a.colors.Dark)
		}
		return runExecutionIcon(configuration.Execution)
	}
	if draft := p.runConfigs.dialog.drafts[key]; draft != nil {
		switch {
		case draft.form != nil:
			return p.runConfigs.kindIcon(draft.form.kind, &a.pluginIcons, a.colors.Dark)
		case draft.copyOf != "" && draft.icon.ViewBox > 0:
			return draft.icon
		}
	}
	return icons.FileCode
}

// drawRunConfigDialogStart declares the pane while no configuration or folder is selected, as
// IDEA does: the link that adds a configuration, and that one can be selected to edit it.
func (a *App) drawRunConfigDialogStart(c ui.C, p *project) {
	s := &p.runConfigs
	d := &s.dialog
	language := a.language()
	ui.Column(c.Part("start")).Fill().Center().Gap(4).PadX(16).Children(func() {
		link := ui.Button(c.Part("add-link"), i18n.Shared(language, "desktop.runConfig.addNewConfiguration")).Link().Disabled(d.saving)
		if link.Clicked() {
			c.After(func() { d.toggleNewMenu(runConfigNewMenuPane) })
		}
		a.drawRunConfigNewMenu(c, p, link, runConfigNewMenuPane)
		ui.Text(c, i18n.Shared(language, "desktop.runConfig.orSelectToEdit")).Color(a.colors.Subtle)
		if d.failure != "" {
			ui.Paragraph(c, d.failure, 4).TextCenter().FillWidth().FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
		}
	})
}

// drawRunConfigDialogBanner declares the warning over an editor whose configuration this
// platform cannot run, so the user sees why Run is off before editing.
func (a *App) drawRunConfigDialogBanner(c ui.C, text string) {
	k := c.Part("banner")
	ui.Row(k).FillWidth().Items(ui.Start).Gap(8).Pad(8).Radius(a.theme.Metrics.RadiusItem()).Border(1, a.colors.Warning).Children(func() {
		ui.Icon(c, icons.CircleAlert).Size(14, 14).Shrink(0).Color(a.colors.Warning)
		ui.Paragraph(c, text, 4).FontSize(a.theme.Metrics.FontSizeS).Grow(1).MinWidth(0)
	})
}

// drawRunConfigDialogFooter declares Run on the left, and Cancel, Apply and OK on the right.
// Run saves first and is off while the selected configuration cannot run here; Apply is off
// while nothing changed.
func (a *App) drawRunConfigDialogFooter(c ui.C, p *project) {
	d := &p.runConfigs.dialog
	language := a.language()
	busy := d.busy()
	ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
		if ui.Button(c, i18n.Shared(language, "desktop.runConfig.run")).Icon(icons.Play).Outline().Disabled(busy || !a.runConfigDialogRunnable(p)).Clicked() {
			c.After(func() {
				a.performed("run.configuration.dialog.run", surfaceButton)
				a.applyRunConfigDialog(p, runConfigDialogRun)
			})
		}
		ui.Spacer(c)
		if ui.Button(c, i18n.Shared(language, "desktop.git.cancel")).Outline().Clicked() {
			c.After(func() { a.closeRunConfigDialog(p) })
		}
		if ui.Button(c, i18n.Shared(language, "desktop.runConfig.apply")).Outline().Disabled(busy || !d.dirty()).Clicked() {
			c.After(func() {
				a.performed("run.configuration.dialog.apply", surfaceButton)
				a.applyRunConfigDialog(p, runConfigDialogApply)
			})
		}
		if ui.Button(c, i18n.Shared(language, "desktop.runConfig.ok")).Disabled(busy).Clicked() {
			c.After(func() {
				a.performed("run.configuration.dialog.save", surfaceButton)
				a.applyRunConfigDialog(p, runConfigDialogOK)
			})
		}
	})
}
