package workbench

import (
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file draws the Remote Development window's frame and its list: the search, import and new
// buttons above the saved connections under their groups, and the line that says where they are
// kept. The pages beside the list are in remote_detail_view.go and remote_steps_view.go; choosing
// a folder, trusting it and importing take the whole window.

// remoteListFooterHeight is the height of the line under the list.
const remoteListFooterHeight = 30

// remoteView declares the window while it is open. Escape, the scrim and the close button end it
// like Close.
func (a *App) remoteView(c ui.C) {
	r := &a.remote
	if !r.open || r.hostsOnly {
		return
	}
	language := a.language()
	open := true
	ui.Modal(c, &open, a.remoteTitle(language), ui.ModalSpec{Width: remoteWindowWidth, Height: remoteWindowHeight}, func() {
		k := c.Part("remote")
		ui.Row(k).Fill().Children(func() {
			a.remoteList(k, language)
			ui.Column(k).Width(1).FillHeight().Shrink(0).Background(a.colors.Line)
			page := k.Part("page")
			ui.Column(page).Grow(1).Basis(0).MinWidth(0).FillHeight().Children(func() {
				switch {
				case r.devcontainer != nil:
					a.remoteDevcontainerView(page, language, r.devcontainer)
				case r.importer != nil:
					a.remoteImportView(page, language, r.importer)
				case r.trust != nil:
					a.remoteTrustView(page, language, r.trust)
				case r.browser != nil:
					a.remoteBrowserView(page, r.browser)
				default:
					a.remotePage(page, language)
				}
			})
		})
	}, func() {
		k := c.Part("remote-footer")
		switch {
		case r.devcontainer != nil:
			a.remoteDevcontainerFooter(k, language, r.devcontainer)
		case r.importer != nil:
			a.remoteImportFooter(k, language, r.importer)
		case r.trust != nil:
			a.remoteTrustFooter(k, language, r.trust)
		case r.browser != nil:
			a.remoteBrowserFooter(k, r.browser)
		case r.steps != nil:
			a.remoteStepsFooter(k, language, r.steps)
		default:
			a.remoteFooter(k, language)
		}
	})
	if !open {
		c.After(a.closeRemote)
	}
}

// remoteTitle is the window's title, followed by where in it the user is: the connection shown,
// a new one, or the import.
func (a *App) remoteTitle(language i18n.Language) string {
	r := &a.remote
	crumb := ""
	switch {
	case r.devcontainer != nil:
		crumb = i18n.Shared(language, "desktop.remote.devcontainer.title")
	case r.importer != nil:
		crumb = i18n.Shared(language, "desktop.remote.import.titleMotty")
		if r.importer.source == remoteImportSSH {
			crumb = i18n.Shared(language, "desktop.remote.import.titleSsh")
		}
	case r.browser != nil:
		crumb = r.browser.name
	case r.steps != nil:
		crumb = r.steps.entry.Name
	case r.wsl.selected != "":
		crumb = r.wsl.selected
	case r.containers.selected != nil:
		crumb = r.containers.selected.Name
	case r.editing && r.entry(r.selected) == nil:
		crumb = i18n.Shared(language, "desktop.remote.newConnection")
	case r.editing:
		crumb = i18n.SharedFormat(language, "desktop.remote.editTitle", map[string]string{"name": r.entry(r.selected).Name})
	case r.entry(r.selected) != nil:
		crumb = r.entry(r.selected).Name
	}
	if crumb == "" {
		return i18n.Shared(language, "desktop.remote.title")
	}
	return i18n.SharedFormat(language, "desktop.remote.titleWith", map[string]string{"crumb": crumb})
}

// remoteList declares the list: its tools, the saved connections under their groups, and where
// they are kept.
func (a *App) remoteList(c ui.C, language i18n.Language) {
	r := &a.remote
	k := c.Part("list")
	title := i18n.Shared(language, "desktop.remote.saved")
	ui.Column(k).Width(remoteListWidth).FillHeight().Shrink(0).Children(func() {
		ui.Row(k.Part("tools")).FillWidth().Shrink(0).Items(ui.Center).Gap(4).PadSides(10, 8, 8, 10).Children(func() {
			search := ui.TextField(k.Part("search"), &r.query, i18n.Shared(language, "desktop.remote.search"), i18n.Shared(language, "desktop.remote.searchPlaceholder")).
				Icon(icons.Search).Grow(1).Basis(0).MinWidth(0).Disabled(len(r.source.Connections) == 0)
			if r.query.Text() != "" {
				search = search.Action(icons.X, i18n.Shared(language, "native.clearSearch"))
				if search.ActionClicked() {
					c.After(a.clearRemoteSearch)
				}
			}
			if search.Changed() {
				c.After(a.searchRemote)
			}
			a.remoteImportMenu(k.Part("import"), language)
			if a.gitIconButton(k.Part("devcontainer"), i18n.Shared(language, "desktop.remote.devcontainer.open"), icons.FileCode, false, r.saving || r.connect != nil) {
				c.After(a.openRemoteDevcontainer)
			}
			if a.gitIconButton(k.Part("new"), i18n.Shared(language, "desktop.remote.new"), icons.Plus, false, r.saving) {
				c.After(a.newRemote)
			}
		})
		rows := r.rows
		switch {
		case len(rows) == 0 && r.loading:
			a.remoteListNote(k.Part("loading"), i18n.Shared(language, "native.loading"))
		case len(rows) == 0 && r.found != nil:
			a.remoteListNote(k.Part("none"), i18n.Shared(language, "desktop.remote.noMatch"))
		case len(rows) == 0:
			a.remoteListNote(k.Part("empty"), i18n.Shared(language, "desktop.remote.empty"))
		default:
			a.remoteRows(k, language, title, rows)
		}
		ui.Row(k).FillWidth().Height(1).Shrink(0).Background(a.colors.Line)
		ui.Row(k.Part("footer")).FillWidth().Height(remoteListFooterHeight).Shrink(0).Items(ui.Center).Gap(4).PadX(8).Children(func() {
			if path := r.source.Path(); path != "" {
				a.remoteHelp(k.Part("storage"), i18n.SharedFormat(language, "desktop.remote.storageHelp", map[string]string{"path": path}))
			}
			ui.Text(c, i18n.SharedFormat(language, "desktop.remote.listFooter", map[string]string{"count": strconv.Itoa(len(r.source.Connections))})).
				FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
		})
	})
}

// remoteListNote declares a short line where the list's rows would be.
func (a *App) remoteListNote(c ui.C, text string) {
	ui.Column(c).FillWidth().Grow(1).Pad(14).Children(func() {
		ui.Paragraph(c, text, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
	})
}

// remoteRows declares the rows of the list; choosing one shows its overview.
func (a *App) remoteRows(k ui.C, language i18n.Language, title string, rows []remoteListRow) {
	r := &a.remote
	r.list.Label = func(row int) string {
		if row < 0 || row >= len(r.rows) {
			return ""
		}
		if r.rows[row].heading {
			return remoteGroupHeading(language, r.rows[row].group)
		}
		if r.rows[row].wsl != "" {
			return r.rows[row].wsl
		}
		if r.rows[row].container != nil {
			return r.rows[row].container.Name
		}
		return r.rows[row].entry.Name
	}
	r.list.Header = func(row int) bool { return row >= 0 && row < len(r.rows) && r.rows[row].heading }
	ui.List(k.Part("rows"), &r.list, len(rows), func(row ui.ListRow) {
		switch item := rows[row.Index]; {
		case item.heading:
			a.remoteHeadingRow(row, language, item)
		case item.wsl != "":
			a.remoteWSLRow(row, language, item.wsl)
		case item.container != nil:
			a.remoteContainerRow(row, language, *item.container)
		default:
			a.remoteEntryRow(row, language, *item.entry)
		}
	}).Scrollbars().FillWidth().Grow(1).Shrink(1).MinHeight(0).Label(title)
	if r.list.Changed() {
		away := r.steps != nil || r.browser != nil || r.importer != nil || r.devcontainer != nil
		at := r.list.Selected()
		switch {
		case at >= 0 && at < len(rows) && rows[at].entry != nil && (rows[at].entry.ID != r.selected || r.editing || r.wsl.selected != "" || r.containers.selected != nil || away):
			id := rows[at].entry.ID
			c := k
			c.After(func() {
				if !a.leaveRemoteFlows() {
					r.syncListSelection()
					return
				}
				a.performed("remote.connection.select", surfaceButton)
				r.selectEntry(id)
			})
		case at >= 0 && at < len(rows) && rows[at].wsl != "" && (rows[at].wsl != r.wsl.selected || away):
			name := rows[at].wsl
			c := k
			c.After(func() {
				if !a.leaveRemoteFlows() {
					r.syncListSelection()
					return
				}
				a.performed("remote.wsl.select", surfaceButton)
				r.selectRemoteWSL(name)
			})
		case at >= 0 && at < len(rows) && rows[at].container != nil &&
			(r.containers.selected == nil || rows[at].container.key() != r.containers.selected.key() || away):
			container := *rows[at].container
			c := k
			c.After(func() {
				if !a.leaveRemoteFlows() {
					r.syncListSelection()
					return
				}
				a.performed("remote.container.select", surfaceButton)
				r.selectRemoteContainer(container)
			})
		}
	} else {
		// The list selects only rows it has declared, so the row a save added becomes the
		// keyboard's row here, once the list declared it.
		r.syncListSelection()
	}
}

// remoteHeadingRow declares a group's heading: the arrow that folds it, its name and how many
// connections it holds. It stays at the top while its connections scroll under it, so it has the
// window's background.
func (a *App) remoteHeadingRow(row ui.ListRow, language i18n.Language, heading remoteListRow) {
	r := &a.remote
	rc := row.C
	name := remoteGroupHeading(language, heading.group)
	icon := icons.ChevronDown
	if r.found == nil && r.collapsed[heading.group] {
		icon = icons.ChevronRight
	}
	row.Element.Height(remoteHeadingHeight).Items(ui.Center).Gap(2).PadSides(0, 12, 0, 6).Background(a.theme.Popover)
	fold := ui.Button(rc.Part("fold"), i18n.SharedFormat(language, "desktop.remote.groupFold", map[string]string{"group": name})).
		Icon(icon).IconOnly().Ghost().Size(18, 18).Shrink(0).Disabled(r.found != nil)
	if fold.Clicked() {
		group := heading.group
		rc.After(func() { a.toggleRemoteGroup(group) })
	}
	ui.Text(rc, name).FontSize(a.theme.Metrics.FontSizeS).Weight(gfx.WeightSemibold).Color(a.colors.Subtle).Ellipsis().Shrink(1).MinWidth(0)
	ui.Text(rc, strconv.Itoa(heading.count)).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).Shrink(0).MarginLeft(4)
}

// remoteEntryRow declares a saved connection: the mark of its host in its color, its name over its
// address, and on the right whether a window has it open or when it last connected.
func (a *App) remoteEntryRow(row ui.ListRow, language i18n.Language, entry core.SavedRemoteConnection) {
	r := &a.remote
	rc := row.C
	small := a.theme.Metrics.FontSizeS
	row.Element.Height(remoteRowHeight).Items(ui.Center).Gap(9).PadSides(0, 12, 0, 0).Radius(6)
	if entry.ID == r.selected {
		row.Element.Background(a.colors.Selection)
	}
	// The stripe on the left is the connection's color; a connection without one keeps the
	// stripe's room so the rows stay aligned.
	stripe := ui.Row(rc.Part("stripe")).Width(3).Height(remoteRowHeight - 14).Shrink(0).Radius(1.5)
	if tint, marked := remoteColor(a.colors.Dark, entry.Color); marked {
		stripe.Background(tint)
	}
	a.remoteTile(rc.Part("tile"), remoteSystemMark(r.probedOutcome(entry.Connection)), entry.Name, entry.Color, 26, 10)
	ui.Column(rc).Grow(1).Basis(0).MinWidth(0).Gap(2).Children(func() {
		ui.Text(rc, entry.Name).Weight(gfx.WeightMedium).Ellipsis().MinWidth(0)
		ui.Text(rc, remoteAddress(entry.Connection)).Mono().FontSize(small).Color(a.colors.Subtle).Ellipsis().MinWidth(0)
	})
	if a.remoteLive(entry.ID) {
		ui.Row(rc.Part("live")).Shrink(0).Items(ui.Center).Gap(5).Children(func() {
			a.remoteDot(rc.Part("dot"), a.colors.Success, 6)
			ui.Text(rc, i18n.Shared(language, "desktop.remote.connectedNow")).FontSize(small).Color(a.colors.Success)
		})
		return
	}
	ui.Text(rc, a.remoteLastConnected(language, entry)).FontSize(small).Color(a.colors.Subtle).Shrink(0)
}

// remoteTile declares the square that marks a connection's host: the first letters of its system
// on the connection's color, as the build tree marks its build systems, or the first letter of its
// name, outlined, while the host was never tested.
func (a *App) remoteTile(c ui.C, mark, name string, color core.RemoteConnectionColor, size, fontSize float32) {
	tint, marked := remoteColor(a.colors.Dark, color)
	if !marked {
		tint = a.colors.Subtle
	}
	alpha := float32(0.14)
	if a.colors.Dark {
		alpha = 0.22
	}
	text := mark
	if text == "" {
		text = remoteNameMark(name)
	}
	tile := ui.Row(c).Size(size, size).Shrink(0).Center().Radius(size / 5).Background(tint.WithAlpha(alpha))
	if mark == "" {
		tile = tile.Stroke(1, a.colors.Line)
	}
	tile.Children(func() {
		ui.Text(c, text).FontSize(fontSize).Weight(gfx.WeightBold).Color(tint)
	})
}

// remoteNameMark is the first letter of name, upper-cased, or "?" for a name without one.
func remoteNameMark(name string) string {
	for _, r := range strings.TrimSpace(name) {
		return strings.ToUpper(string(r))
	}
	return "?"
}

// remoteDot declares a round mark of color.
func (a *App) remoteDot(c ui.C, color gfx.Color, size float32) {
	ui.Row(c).Size(size, size).Shrink(0).Radius(size / 2).Background(color)
}

// remotePill declares a small tag, as the run window marks a port.
func (a *App) remotePill(c ui.C, text string, color gfx.Color) {
	ui.Row(c).Shrink(0).Height(20).Items(ui.Center).PadX(6).Radius(4).Background(a.colors.Hover).Stroke(1, a.colors.TabIdleBorder).Children(func() {
		ui.Text(c, text).FontSize(a.theme.Metrics.FontSizeS).Color(color)
	})
}

// remoteStatusPill declares a tag tinted with color, with a dot before its text.
func (a *App) remoteStatusPill(c ui.C, text string, color gfx.Color) {
	ui.Row(c).Shrink(0).Height(20).Items(ui.Center).Gap(5).PadX(7).Radius(10).Background(color.WithAlpha(0.14)).Children(func() {
		a.remoteDot(c.Part("dot"), color, 6)
		ui.Text(c, text).FontSize(a.theme.Metrics.FontSizeS).Color(color)
	})
}

// remoteImportMenu declares the list's import button and the menu it opens: Motty's hosts and
// those of ~/.ssh/config, with how many each holds to import.
func (a *App) remoteImportMenu(c ui.C, language i18n.Language) {
	r := &a.remote
	anchor, clicked := a.gitToolButton(c, i18n.Shared(language, "desktop.remote.import"), icons.Download, r.importMenu, r.saving || !r.editable())
	if clicked {
		c.After(func() { r.importMenu = !r.importMenu })
	}
	if !r.importMenu {
		return
	}
	open := true
	ui.Menu(c, anchor, &open, func(menu *ui.MenuItems) {
		motty := menu.Item(i18n.Shared(language, "desktop.remote.import.motty"))
		ssh := menu.Item(i18n.Shared(language, "desktop.remote.import.ssh"))
		if r.imports.loaded {
			motty = motty.Description(a.remoteImportCountText(language, r.imports.motty))
			ssh = ssh.Description(a.remoteImportCountText(language, r.imports.sshConfig))
		}
		if motty.Clicked() {
			c.After(func() { a.openRemoteImport(remoteImportMotty) })
		}
		if ssh.Clicked() {
			c.After(func() { a.openRemoteImport(remoteImportSSH) })
		}
	})
	if !open {
		r.importMenu = false
	}
}

// remoteImportCountText says how many hosts a source holds to import.
func (a *App) remoteImportCountText(language i18n.Language, count int) string {
	if count == 0 {
		return i18n.Shared(language, "desktop.remote.import.none")
	}
	return i18n.SharedFormat(language, "desktop.remote.import.count", map[string]string{"count": strconv.Itoa(count)})
}
