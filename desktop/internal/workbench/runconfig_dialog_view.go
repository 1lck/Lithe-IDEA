package workbench

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/treelist"
	"github.com/vivaui/viva/gfx"
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
	// runConfigDialogIndent indents a configuration under its group's arrow.
	runConfigDialogIndent = treelist.Disclosure + 6
)

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
	ui.ModalWith(c, &open, title, ui.ModalSpec{Width: runConfigDialogWidth, Height: runConfigDialogHeight}, func() {
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
// configuration over the tree of configurations by kind.
func (a *App) drawRunConfigDialogTree(c ui.C, p *project) {
	s := &p.runConfigs
	d := &s.dialog
	language := a.language()
	k := c.Part("tree")
	ui.Column(k).Width(runConfigDialogTreeWidth).FillHeight().Shrink(0).Children(func() {
		ui.Row(k.Part("toolbar")).FillWidth().Height(panelHeaderHeight).Shrink(0).Items(ui.Center).Gap(2).PadX(6).Children(func() {
			label := i18n.Shared(language, "desktop.runConfig.newConfiguration")
			add, clicked := a.gitToolButton(k.Part("add"), label, icons.Plus, d.newMenu, d.saving)
			if clicked {
				d.newMenu = !d.newMenu
			}
			ui.Menu(k.Part("add-menu"), add, &d.newMenu, func(menu *ui.MenuItems) {
				menu.WidthRange(200, 300)
				a.runConfigDialogTypeItems(k, menu, p)
			})
			if a.gitIconButton(k.Part("remove"), i18n.Shared(language, "desktop.runConfig.removeConfiguration"), icons.Minus, false, !p.runConfigRemovable(d.selected)) {
				c.After(func() {
					a.performed("run.configuration.remove", surfaceButton)
					a.removeRunConfigDraft(p)
				})
			}
			draft := d.drafts[d.selected]
			copyable := !d.saving && draft != nil && draft.form != nil && draft.form.ready()
			if a.gitIconButton(k.Part("copy"), i18n.Shared(language, "desktop.runConfig.copyConfiguration"), icons.Copy, false, !copyable) {
				c.After(func() {
					a.performed("run.configuration.copy", surfaceButton)
					a.copyRunConfigDraft(p)
				})
			}
		})
		ui.Row(k).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
		ui.Column(k.Part("rows")).FillWidth().Grow(1).MinHeight(0).PadSides(4, 4, 4, 4).Children(func() {
			a.drawRunConfigDialogRows(k, p)
		})
		if s.hidden > 0 {
			ui.Row(k).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
			ui.Row(k.Part("hidden")).FillWidth().Shrink(0).Items(ui.Center).Gap(6).Pad(8).Children(func() {
				ui.Icon(k, icons.Info).Size(12, 12).Shrink(0).Color(a.colors.Subtle)
				ui.Paragraph(k, hiddenRunConfigurations(language, s.hidden), 2).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Grow(1).MinWidth(0)
			})
		}
	})
}

// runConfigDialogTypeItems adds an item per built-in kind to the + menu, each creating a new
// configuration of that kind. A kind this platform cannot run is still offered, saying so.
func (a *App) runConfigDialogTypeItems(c ui.C, menu *ui.MenuItems, p *project) {
	language := a.language()
	for _, kind := range p.runConfigs.types {
		label, ok := runConfigTypeLabel(language, kind.Provider)
		if !ok {
			continue
		}
		provider := kind.Provider
		item := menu.Item(label).Icon(runConfigTypeIcon(provider))
		if kind.Unavailable() {
			item = item.Description(runConfigTypeNote(language, kind))
		}
		if item.Clicked() {
			c.After(func() {
				a.performed("run.configuration.new", surfaceButton)
				a.addRunConfigDraft(p, provider, nil)
			})
		}
	}
	if len(p.runConfigs.types) == 0 {
		menu.Item(i18n.Shared(language, "native.loading")).Disabled(true)
	}
}

// runConfigTypeNote is the short note of a kind this platform cannot run, beside its name.
func runConfigTypeNote(language i18n.Language, kind core.RunConfigurationType) string {
	if kind.Provider == runProviderBatch && kind.Availability != nil && kind.Availability.Code == "unsupportedPlatform" {
		return i18n.Shared(language, "desktop.runConfig.windowsOnlyType")
	}
	return i18n.Shared(language, "desktop.runConfig.typeNotRunnableHere")
}

// drawRunConfigDialogRows declares the tree. Selecting a configuration shows its editor;
// Enter or a double click on a group opens or closes it.
func (a *App) drawRunConfigDialogRows(c ui.C, p *project) {
	s := &p.runConfigs
	d := &s.dialog
	language := a.language()
	if len(d.rows) == 0 {
		message := i18n.Shared(language, "desktop.runConfig.emptyHint")
		switch {
		case s.failure != "":
			message = i18n.SharedFormat(language, "desktop.runConfig.loadFailed", map[string]string{"reason": s.failure})
		case s.loading || s.generation == 0:
			message = i18n.Shared(language, "native.loading")
		}
		// The message wraps inside the narrow column instead of centering one long line over it.
		ui.Column(c.Part("empty")).Fill().Center().PadX(12).Children(func() {
			ui.Paragraph(c, message, 4).TextCenter().FillWidth().Color(a.colors.Subtle)
		})
		return
	}
	if d.view.Key == nil {
		d.view.Key = func(i int) int { return d.runConfigDialogRowID(d.rows[i]) }
		d.view.Label = func(i int) string {
			if row := d.rows[i]; row.key != "" {
				return a.runConfigDraftLabel(p, row.key)
			}
			return d.groups[d.rows[i].group].title
		}
	}
	selected := d.runConfigDialogRowIndex()
	if !d.view.Changed() && d.view.Selected() != selected {
		d.view.Select(selected)
	}
	title := i18n.Shared(language, "desktop.runConfig.dialogTitle")
	ui.List(c, &d.view, len(d.rows), func(row ui.ListRow) { a.drawRunConfigDialogRow(p, row, row.Index == selected) }).
		Scrollbars().Label(title).Grow(1).FillWidth()
	if d.view.Changed() {
		if i := d.view.Selected(); i >= 0 && i < len(d.rows) {
			row := d.rows[i]
			if row.key != "" {
				key := row.key
				c.After(func() { a.selectRunConfigDraft(p, key) })
			} else {
				key := d.groups[row.group].key
				c.After(func() { d.selected, d.group, d.newMenu = "", key, false })
			}
		}
	}
	if i, ok := d.view.Submitted(); ok && i >= 0 && i < len(d.rows) && d.rows[i].key == "" {
		key := d.groups[d.rows[i].group].key
		c.After(func() { p.toggleRunConfigDialogGroup(key) })
	}
}

// drawRunConfigDialogRow declares one row of the tree: a group's arrow, icon and title, or a
// configuration's icon and name. A configuration this platform cannot run shows a warning
// icon and says why on hover.
func (a *App) drawRunConfigDialogRow(p *project, row ui.ListRow, selected bool) {
	d := &p.runConfigs.dialog
	c, r := row.C, d.rows[row.Index]
	box := row.Element.Height(buildRowHeight).Items(ui.Center).Gap(6).PadX(6).Radius(a.theme.Metrics.RadiusItem())
	if selected {
		box = box.Background(a.colors.Selection)
	} else {
		box = box.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	group := d.groups[r.group]
	if r.key == "" {
		box.Children(func() {
			a.drawRunConfigDialogArrow(c, p, group)
			ui.Icon(c, group.icon).Size(14, 14).Shrink(0).Color(a.colors.Subtle)
			ui.Text(c, group.title).Ellipsis().Shrink(1).MinWidth(0)
		})
		return
	}
	unavailable := a.runConfigDraftUnavailable(p, r.key)
	if unavailable != "" {
		box = box.Tooltip(unavailable)
	}
	box.Children(func() {
		ui.Row(c.Part("indent")).Size(runConfigDialogIndent, treelist.Icon).Shrink(0)
		icon, color := a.runConfigDraftIcon(p, r.key), a.colors.Subtle
		if unavailable != "" {
			icon, color = icons.CircleAlert, a.colors.Warning
		}
		ui.Icon(c, icon).Size(14, 14).Shrink(0).Color(color)
		ui.Text(c, a.runConfigDraftLabel(p, r.key)).Ellipsis().Shrink(1).MinWidth(0)
	})
}

// runConfigDraftIcon is the icon of configuration key in the tree: its kind's for a built-in
// run, its execution's for a build provider run.
func (a *App) runConfigDraftIcon(p *project, key string) gfx.Icon {
	if configuration := p.runConfigs.configuration(key); configuration != nil {
		if configuration.IsProcess() {
			return runConfigTypeIcon(configuration.Provider)
		}
		return runExecutionIcon(configuration.Execution)
	}
	if draft := p.runConfigs.dialog.drafts[key]; draft != nil && draft.form != nil {
		return runConfigTypeIcon(draft.form.provider)
	}
	return icons.FileCode
}

// drawRunConfigDialogArrow declares the arrow that opens or closes a group of the tree.
func (a *App) drawRunConfigDialogArrow(c ui.C, p *project, group runConfigDialogGroup) {
	open := !p.runConfigs.dialog.closed[group.key]
	name, chevron := i18n.Shared(a.language(), "native.collapseSection"), icons.ChevronDown
	if !open {
		name, chevron = i18n.Shared(a.language(), "native.expandSection"), icons.ChevronRight
	}
	k := c.Part("arrow")
	slot := ui.Row(k).Size(treelist.Disclosure, treelist.Icon).Shrink(0).Center().
		HitWith(ui.ID(k), name+" "+group.title, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Expandable: true, Expanded: open, SkipFocus: true})
	slot.Children(func() {
		ui.Icon(k, chevron).Size(12, 12).Color(a.colors.Subtle)
	})
	if slot.Clicked() {
		key := group.key
		c.After(func() { p.toggleRunConfigDialogGroup(key) })
	}
}

// drawRunConfigDialogPane declares the right column: the editor of the selected
// configuration, under the reason this platform cannot run it, or, with nothing selected, the
// kinds a new configuration can take.
func (a *App) drawRunConfigDialogPane(c ui.C, p *project) {
	d := &p.runConfigs.dialog
	k := c.Part("pane")
	ui.Column(k).Grow(1).FillHeight().MinWidth(0).Children(func() {
		draft := d.drafts[d.selected]
		ui.Scroll(k).Scrollbars().FillWidth().Grow(1).Children(func() {
			ui.Column(k).FillWidth().Gap(10).PadSides(14, 20, 14, 16).Children(func() {
				if draft == nil {
					a.drawRunConfigDialogStart(k, p)
				} else {
					if text := a.runConfigDraftUnavailable(p, d.selected); text != "" {
						a.drawRunConfigDialogBanner(k, text)
					}
					a.drawRunConfigDraft(k, p, draft)
				}
				if d.failure != "" {
					ui.Paragraph(k, d.failure, 4).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
				}
			})
		})
	})
}

// drawRunConfigDraft declares the editor of one configuration: the form of a built-in run, the
// options of a build provider run, or why a run whose plugin cannot resolve has no editor.
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
	default:
		ui.Text(c, a.runConfigDraftLabel(p, draft.key)).Weight(gfx.WeightSemibold).Ellipsis().FillWidth()
		ui.Paragraph(c, i18n.Shared(language, "desktop.runConfig.notEditable"), 3).Color(a.colors.Subtle)
	}
}

// drawRunConfigDialogStart declares the pane while nothing is selected: a hint and a button
// per built-in kind that creates a configuration of it.
func (a *App) drawRunConfigDialogStart(c ui.C, p *project) {
	s := &p.runConfigs
	d := &s.dialog
	language, small := a.language(), a.theme.Metrics.FontSizeS
	ui.Paragraph(c, i18n.Shared(language, "desktop.runConfig.dialogHint"), 3).Color(a.colors.Subtle)
	if len(s.types) == 0 {
		ui.Text(c, i18n.Shared(language, "native.loading")).Color(a.colors.Subtle)
		return
	}
	for index, kind := range s.types {
		label, ok := runConfigTypeLabel(language, kind.Provider)
		if !ok {
			continue
		}
		provider := kind.Provider
		k := c.KeyInt(index)
		ui.Row(k).FillWidth().Items(ui.Center).Gap(8).Children(func() {
			if ui.Button(k, label).Icon(runConfigTypeIcon(provider)).Outline().Disabled(d.saving).Clicked() {
				c.After(func() {
					a.performed("run.configuration.new", surfaceButton)
					a.addRunConfigDraft(p, provider, nil)
				})
			}
			if kind.Unavailable() {
				ui.Text(k, runConfigTypeNote(language, kind)).FontSize(small).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
			}
		})
	}
}

// drawRunConfigDialogBanner declares the warning over an editor whose configuration this
// platform cannot run, so the user sees why Run is off before editing.
func (a *App) drawRunConfigDialogBanner(c ui.C, text string) {
	k := c.Part("banner")
	ui.Row(k).FillWidth().Items(ui.Start).Gap(8).Pad(8).Radius(a.theme.Metrics.RadiusItem()).Border(1, a.colors.Warning).Children(func() {
		ui.Icon(k, icons.CircleAlert).Size(14, 14).Shrink(0).Color(a.colors.Warning)
		ui.Paragraph(k, text, 4).FontSize(a.theme.Metrics.FontSizeS).Grow(1).MinWidth(0)
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
