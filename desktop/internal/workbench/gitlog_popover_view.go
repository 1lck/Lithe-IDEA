package workbench

import (
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file declares the popovers of the log tab: the menu of its actions, and the four
// filters the chips of the filter bar open.

// toggleLogPopover opens a popover of the log tab, or closes it when it is open.
func (a *App) toggleLogPopover(p *project, which logPopover) {
	l, v := &p.log, &a.logView
	if l.popover == which {
		l.popover = logPopoverNone
		return
	}
	l.popover = which
	switch which {
	case logPopoverUser:
		v.userSearch.SetText("")
		v.focus = logUserSearchID
	case logPopoverPath:
		v.pathField.SetText(l.path)
		v.focus = logPathID
	}
}

// drawLogPopover declares the filter popover which, when it is the open one, hangs off its
// chip. A press outside it, or Escape, closes it.
func (a *App) drawLogPopover(c ui.C, p *project, which logPopover, anchor ui.Box) {
	l := &p.log
	if l.popover != which {
		return
	}
	width := float32(logPopoverWidth)
	if which == logPopoverPath {
		width = logPathWidth
	}
	open := true
	spec := ui.PopoverSpec{Align: ui.Start, Offset: 4, Width: width, ConsumeOutsidePress: true}
	ui.PopoverWith(c, anchor, spec, &open, func() {
		switch l.popover {
		case logPopoverBranch:
			a.drawLogBranchFilter(c, p)
		case logPopoverUser:
			a.drawLogUserFilter(c, p)
		case logPopoverDate:
			a.drawLogDateFilter(c, p)
		case logPopoverPath:
			a.drawLogPathFilter(c, p)
		}
	})
	if !open {
		l.popover = logPopoverNone
	}
}

// drawLogMenu declares the menu of the Git actions under its button in the Git tool window's
// header, while it is open.
func (a *App) drawLogMenu(c ui.C, p *project, button ui.Box) {
	l, g := &p.log, a.text.Git
	if l.popover != logPopoverMenu {
		return
	}
	open := true
	ui.Menu(c, button, &open, func(menu *ui.MenuItems) {
		if menu.Item(g.FetchAll).Disabled(l.sync.busy).Clicked() {
			c.After(func() { a.fetchAll(p) })
		}
		if menu.Item(g.FetchOptions).Disabled(l.sync.busy).Clicked() {
			c.After(func() { a.openFetchOptions(p) })
		}
		if menu.Item(g.UpdateBranch).Disabled(l.current == "" || l.sync.busy).Clicked() {
			c.After(func() { a.updateCurrentBranch(p) })
		}
		if menu.Item(g.RefreshLog).Clicked() {
			c.After(func() { a.loadLog(p) })
		}
		menu.Separator()
		if menu.Item(g.ShowChanges).Clicked() {
			c.After(a.showChanges)
		}
	})
	if !open {
		l.popover = logPopoverNone
	}
}

// drawBranchSettingsMenu declares the menu of the reference pane's settings under its button,
// while it is open. The macOS menu also shows the repositories of the linked worktrees in the
// pane; the pane lists one repository's references, so that choice has nothing to act on yet.
func (a *App) drawBranchSettingsMenu(c ui.C, p *project, button ui.Box) {
	l, g := &p.log, a.text.Git
	if l.popover != logPopoverBranchSettings {
		return
	}
	open := true
	ui.Menu(c, button, &open, func(menu *ui.MenuItems) {
		if menu.Item(g.FetchOptions).Disabled(l.sync.busy).Clicked() {
			c.After(func() { a.openFetchOptions(p) })
		}
	})
	if !open {
		l.popover = logPopoverNone
	}
}

// drawLogBranchFilter declares the references the log can walk.
func (a *App) drawLogBranchFilter(c ui.C, p *project) {
	l := &p.log
	ui.Scroll(c).FillWidth().MaxHeight(logListMaxHeight).Children(func() {
		if a.logMenuItem(c, "all", a.text.Git.AllReferences, l.reference == "", false) {
			c.After(func() {
				l.popover, l.refSelected = logPopoverNone, ""
				a.setLogReference(p, "", "")
			})
		}
		for _, s := range l.sections[:2] {
			if len(s.refs) == 0 {
				continue
			}
			ui.Divider(c.Part(s.kind)).PadY(4)
			for _, r := range s.refs {
				if a.logMenuItem(c, r.FullName, r.ShortName, l.reference == r.FullName, false) {
					c.After(func() {
						l.popover, l.refSelected = logPopoverNone, r.FullName
						a.setLogReference(p, r.FullName, r.ShortName)
					})
				}
			}
		}
	})
}

// drawLogUserFilter declares the user filter: a search over the authors of the loaded
// commits.
func (a *App) drawLogUserFilter(c ui.C, p *project) {
	l, v, g := &p.log, &a.logView, a.text.Git
	query := strings.ToLower(strings.TrimSpace(v.userSearch.Text()))
	ui.Row(c).PadY(4).PadX(4).Children(func() {
		ui.TextFieldID(c, logUserSearchID, &v.userSearch, g.SearchUsers, g.SearchUsers).Grow(1)
	})
	ui.Scroll(c).FillWidth().MaxHeight(logListMaxHeight).Children(func() {
		if l.user != "" {
			if a.logMenuItem(c, "clear", g.ClearFilter, false, false) {
				c.After(func() { a.setLogUser(p, "") })
			}
		}
		shown := 0
		for _, user := range l.logUsers() {
			if query != "" && !strings.Contains(strings.ToLower(user), query) {
				continue
			}
			shown++
			if a.logMenuItem(c, "user/"+user, user, l.user == user, false) {
				c.After(func() { a.setLogUser(p, user) })
			}
		}
		if shown == 0 {
			ui.Text(c, g.NoMatchingUsers).Muted().TextCenter().FillWidth().PadY(12)
		}
	})
}

func (a *App) setLogUser(p *project, user string) {
	l := &p.log
	l.popover = logPopoverNone
	if l.user == user {
		return
	}
	l.user = user
	if !l.loading {
		a.reproject(p, 0)
	}
}

// drawLogDateFilter declares the date presets.
func (a *App) drawLogDateFilter(c ui.C, p *project) {
	l, g := &p.log, a.text.Git
	labels := [logDateCount]string{g.AnyTime, g.Today, g.Yesterday, g.Last7Days, g.Last30Days}
	for d := logAnyTime; d < logDateCount; d++ {
		if a.logMenuItem(c, "date/"+labels[d], labels[d], l.date == d, false) {
			c.After(func() {
				l.popover = logPopoverNone
				if l.date != d {
					l.date = d
					if !l.loading {
						a.reproject(p, 0)
					}
				}
			})
		}
	}
	if l.hasMore {
		ui.Divider(c)
		ui.Paragraph(c, g.OlderOutside, 3).Muted().FontSize(a.theme.Metrics.FontSizeS).PadX(8).PadY(4)
	}
}

// drawLogPathFilter declares the path filter: a field and the buttons that apply it.
func (a *App) drawLogPathFilter(c ui.C, p *project) {
	l, v, g := &p.log, &a.logView, a.text.Git
	apply := func(value string) {
		l.popover = logPopoverNone
		value = strings.TrimSpace(value)
		if l.path == value {
			return
		}
		l.path = value
		if !l.loading {
			a.reproject(p, 0)
		}
	}
	ui.Column(c).FillWidth().Pad(8).Gap(8).Children(func() {
		ui.Text(c, g.PathTitle).Weight(gfx.WeightMedium)
		if ui.TextFieldID(c, logPathID, &v.pathField, g.PathTitle, g.PathPlaceholder).FillWidth().Submitted() {
			c.After(func() { apply(v.pathField.Text()) })
		}
		ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
			if ui.Button(c.Part("clear"), g.Clear).Ghost().Clicked() {
				c.After(func() {
					v.pathField.SetText("")
					apply("")
				})
			}
			ui.Spacer(c)
			if ui.Button(c.Part("cancel"), g.Cancel).Secondary().Clicked() {
				c.After(func() { l.popover = logPopoverNone })
			}
			if ui.Button(c.Part("apply"), g.Apply).Clicked() {
				c.After(func() { apply(v.pathField.Text()) })
			}
		})
	})
}

// logMenuItem declares one item of a popover, named key among its siblings, with a check mark
// when it is chosen, and reports a click on it.
func (a *App) logMenuItem(c ui.C, key, label string, checked, disabled bool) bool {
	item := ui.Row(c.Key(key)).Height(logItemHeight+2).FillWidth().Shrink(0).Items(ui.Center).Gap(8).PadX(8).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(c), label, gfx.HitOptions{Role: gfx.RoleMenuItem}).Disabled(disabled)
	if !disabled {
		item = item.Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
	}
	item.Children(func() {
		if checked {
			ui.Icon(c, icons.Check).Size(14, 14).Color(a.colors.Accent)
		} else {
			ui.Row(c).Size(14, 14).Shrink(0)
		}
		color := a.colors.Text
		if disabled {
			color = a.colors.Subtle
		}
		ui.Text(c, label).Color(color).Ellipsis().Grow(1)
	})
	return !disabled && item.Clicked()
}
