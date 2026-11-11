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

// This file declares the branch popup of the title bar and the dialogs it opens, in the
// overlay page (git_overlay.go). The popup hangs off the branch button, which the title bar
// still declares with the Frame (branch_chrome.go); its state and the writes it starts are in
// branch.go.

const (
	// branchPopupWidth and branchPopupMaxHeight size the popup; a longer list scrolls.
	branchPopupWidth     = 360
	branchPopupMaxHeight = 560
	// branchDialogWidth is the width of the dialogs.
	branchDialogWidth = 440
	// branchBlockingHeight caps the list of paths the conflict dialog shows.
	branchBlockingHeight = 160
)

// branchSectionKeys are the keys of the sections of the list, recent ones first, as
// branchSession.collapsed keeps them. The last three follow branchSession.sections.
var branchSectionKeys = [4]string{"recent", "local", "remote", "tag"}

// branchRowKey is the key of the row of r in the section key: a branch is listed under
// Recent and under Local, and each row has a menu of its own.
func branchRowKey(section string, r core.GitReference) string {
	return section + "\x00" + r.FullName
}

// drawBranchPopup declares the open popup under the branch button: the panel with the search
// field, the actions and the references, and the menu of the row the user opened. A press
// outside it, or Escape, closes it.
func (a *App) drawBranchPopup(c ui.C, p *project, anchor ui.Box) {
	b, t := &a.branch, a.text.Branch
	spec := ui.PopoverSpec{Align: ui.Start, Offset: chromeMenuOffset, Width: branchPopupWidth, ConsumeOutsidePress: true}
	ui.PopoverWith(c, anchor, spec, &b.open, func() {
		ui.Column(c).FillWidth().MaxHeight(branchPopupMaxHeight).Gap(chromeMenuItems).Children(func() {
			a.drawBranchPanel(c, p, t)
		})
	})
	if !b.open {
		// The press outside or Escape closed it; a closed popup has no row menu.
		b.menu = ""
	}
}

// drawBranchPanel declares the popup's contents.
func (a *App) drawBranchPanel(c ui.C, p *project, t i18n.BranchMessages) {
	b := &a.branch
	current := b.currentReference()
	ui.TextField(c, &b.search, t.Search, t.Search).FillWidth().AutoFocus()
	if len(p.nested.repos) > 0 {
		a.drawBranchRepoPicker(c, p)
	}
	if a.drawBranchAction(c, "new", icons.Plus, t.NewBranch) {
		c.After(func() { a.beginCreate(p, current) })
	}
	if a.drawBranchAction(c, "revision", icons.GitCommitHorizontal, t.CheckoutRevision) {
		c.After(a.beginRevision)
	}
	if a.drawBranchAction(c, "tag", icons.Tag, i18n.Shared(a.language(), "desktop.tags.newTag")) {
		c.After(func() { a.beginCreateTag(p) })
	}
	ui.Divider(c)
	ui.Scroll(c).FillWidth().MaxHeight(branchPopupMaxHeight).Gap(chromeMenuItems).Children(func() {
		switch {
		case b.err != nil && !b.loading:
			ui.Paragraph(c, t.LoadFailed(b.err.Error()), 4).Color(a.colors.Subtle).PadX(chromeEdge)
			return
		case !b.loaded:
			a.drawBranchNote(c, t.Loading)
			return
		}
		query := strings.ToLower(strings.TrimSpace(b.search.Text()))
		listed := 0
		for i, key := range branchSectionKeys {
			refs := b.refs.RecentReferences
			if i > 0 {
				refs = b.sections[i-1].refs
			}
			if query != "" {
				refs = matchingReferences(refs, query)
				if i == 0 {
					// The recent branches are in Local as well; a search lists each once.
					refs = nil
				}
			}
			if len(refs) == 0 {
				continue
			}
			listed += len(refs)
			collapsed := query == "" && b.collapsed[key]
			if a.drawBranchSection(c, key, [4]string{t.Recent, t.Local, t.Remote, t.Tags}[i], collapsed, query == "") {
				c.After(func() { b.collapsed[key] = !b.collapsed[key] })
			}
			if collapsed {
				continue
			}
			for _, r := range refs {
				a.drawBranchRow(c, p, key, r, r.FullName == current.FullName)
			}
		}
		if listed == 0 {
			a.drawBranchNote(c, t.NoMatches)
		}
		if query == "" {
			a.drawNestedReferences(c, p, t)
		}
	})
}

// drawBranchRepoPicker declares the repository the popup lists, when the project has nested
// repositories: a row that names the picked one, which opens the list of every repository.
func (a *App) drawBranchRepoPicker(c ui.C, p *project) {
	b, pull := &a.branch, a.text.Sync.Pull
	picked := a.branchRoot(p)
	repos := a.pullRepos(p)
	name := ""
	for _, r := range repos {
		if r.root == picked {
			name = r.name
		}
	}
	chevron := icons.ChevronRight
	if b.repoOpen {
		chevron = icons.ChevronDown
	}
	row := ui.Row(c.Part("repo")).Height(chromeMenuRow).Shrink(0).FillWidth().Items(ui.Center).Gap(chromeGap).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).HitWith(ui.ID(c), pull.Repository, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Expandable: true, Expanded: b.repoOpen})
	a.chromeHover(row).Children(func() {
		ui.Text(c, pull.Repository).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).LineHeight(chromeLineHeight)
		ui.Text(c, name).Color(a.colors.Text).LineHeight(chromeLineHeight).Ellipsis().Grow(1)
		ui.Icon(c, chevron).Size(chromeMarkSize, chromeMarkSize).Shrink(0).Color(a.colors.Subtle)
	})
	if row.Clicked() {
		c.After(func() { b.repoOpen = !b.repoOpen })
	}
	if !b.repoOpen {
		return
	}
	for _, r := range repos {
		if a.logMenuItem(c, "repo/"+r.root, r.name, r.root == picked, false) {
			c.After(func() { a.selectBranchRepo(p, r.root) })
		}
	}
}

// matchingReferences returns the references of refs whose short name contains query, which
// is already lower case.
func matchingReferences(refs []core.GitReference, query string) []core.GitReference {
	var out []core.GitReference
	for _, r := range refs {
		if strings.Contains(strings.ToLower(r.ShortName), query) {
			out = append(out, r)
		}
	}
	return out
}

// drawBranchAction declares one of the actions at the top of the popup, an icon and its
// name, and reports a click on it.
func (a *App) drawBranchAction(c ui.C, part string, icon gfx.Icon, label string) bool {
	row := ui.Row(c.Part(part)).Height(chromeMenuRow).Shrink(0).FillWidth().Items(ui.Center).Gap(chromeMenuGap).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(c), label, gfx.HitOptions{Role: gfx.RoleMenuItem, Cursor: gfx.PointerCursorHand})
	a.chromeHover(row).Children(func() {
		ui.Icon(c, icon).Size(chromeIconSize, chromeIconSize).Color(a.colors.Subtle)
		ui.Text(c, label).Color(a.colors.Text).LineHeight(chromeLineHeight)
	})
	return row.Clicked()
}

// drawBranchNote declares a line of the list that says why it shows no branch.
func (a *App) drawBranchNote(c ui.C, note string) {
	ui.Row(c).Height(chromeMenuRow).Shrink(0).Items(ui.Center).PadX(chromeEdge).Children(func() {
		ui.Text(c, note).Color(a.colors.Subtle).LineHeight(chromeLineHeight)
	})
}

// drawBranchSection declares the head of a section and reports a click on it. A head folds
// its section while the list is not filtered; a filtered list shows every match.
func (a *App) drawBranchSection(c ui.C, key, label string, collapsed, foldable bool) bool {
	options := gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Expandable: true, Expanded: !collapsed}
	if !foldable {
		options.Cursor, options.Disabled = gfx.PointerCursorDefault, true
	}
	head := ui.Row(c.Key("section/"+key)).Height(chromeMenuTitle).Shrink(0).FillWidth().Items(ui.Center).Gap(chromeGap).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).HitWith(ui.ID(c), label, options)
	if foldable {
		head = a.chromeHover(head)
	}
	head.Children(func() {
		chevron := icons.ChevronDown
		if collapsed {
			chevron = icons.ChevronRight
		}
		ui.Icon(c, chevron).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Subtle)
		ui.Text(c, label).FontSize(a.theme.Metrics.FontSizeS).Bold().Color(a.colors.Subtle).LineHeight(chromeLineHeight)
	})
	return foldable && head.Clicked()
}

// drawBranchRow declares the row of reference r in section key: its mark, its name, its
// upstream and how far the two are apart, and the chevron of its menu. A click opens the
// menu of the row, which is declared under it.
func (a *App) drawBranchRow(c ui.C, p *project, section string, r core.GitReference, current bool) {
	b, t := &a.branch, a.text.Branch
	rowKey := branchRowKey(section, r)
	open := b.menu == rowKey
	kind := map[string]string{"local": "branch", "remote": "remote", "tag": "tag"}[r.Kind]
	icon := icons.GitBranch
	switch {
	case r.Kind == "tag":
		icon = icons.Tag
	case current:
		kind, icon = "head", icons.Tag
	}
	trailing := r.UpstreamShortName
	if r.Ahead > 0 {
		trailing = strings.TrimSpace(trailing + " ↑" + strconv.Itoa(r.Ahead))
	}
	if r.Behind > 0 {
		trailing = strings.TrimSpace(trailing + " ↓" + strconv.Itoa(r.Behind))
	}
	options := gfx.HitOptions{Role: gfx.RoleMenuItem, Cursor: gfx.PointerCursorHand, Expandable: true, Expanded: open, Selected: current}
	if current {
		options.Value = t.Current
	}
	row := ui.Row(c.Key(rowKey)).Height(chromeMenuRow).Shrink(0).FillWidth().Items(ui.Center).Gap(chromeMenuGap).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).HitWith(ui.ID(c), r.ShortName, options)
	if open {
		row = row.Background(a.colors.Selection)
	} else {
		row = a.chromeHover(row)
	}
	row.Children(func() {
		ui.Icon(c, icon).Size(chromeIconSize, chromeIconSize).Shrink(0).Color(referenceColor(kind, a.colors.Dark))
		ui.Text(c, r.ShortName).Color(a.colors.Text).LineHeight(chromeLineHeight).Ellipsis().Grow(1)
		if trailing != "" {
			ui.Text(c, trailing).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).LineHeight(chromeLineHeight).
				Ellipsis().MaxWidth(branchPopupWidth / 3)
		}
		ui.Icon(c, icons.ChevronRight).Size(chromeMarkSize, chromeMarkSize).Shrink(0).Color(a.colors.Subtle)
	})
	if row.Clicked() {
		c.After(func() {
			if b.menu == rowKey {
				b.menu = ""
			} else {
				b.menu = rowKey
			}
		})
	}
	if !open {
		return
	}
	// The checked-out branch is not checked out again, nor deleted; only a local branch is
	// renamed or deleted.
	ui.Menu(c, row, &open, func(menu *ui.MenuItems) {
		if !current && menu.Item(t.Checkout).Clicked() {
			c.After(func() { a.checkoutBranch(p, r) })
		}
		if menu.Item(t.NewBranchFrom(r.ShortName)).Clicked() {
			c.After(func() { a.beginCreate(p, r) })
		}
		if r.Kind == "tag" && menu.Item(t.Delete).Destructive().Clicked() {
			c.After(func() { a.beginDeleteTag(r) })
		}
		if r.Kind != "local" {
			return
		}
		if menu.Item(t.Rename).Clicked() {
			c.After(func() { a.beginRename(p, r) })
		}
		if !current && menu.Item(t.Delete).Destructive().Clicked() {
			c.After(func() { a.beginDelete(r) })
		}
	})
	if !open {
		b.menu = ""
	}
}

// drawBranchDialog declares the dialog the popup opened, if any.
func (a *App) drawBranchDialog(c ui.C, p *project) {
	b := &a.branch
	switch b.dialog {
	case branchDialogCreate, branchDialogRename:
		a.drawBranchNameDialog(c, p)
	case branchDialogRevision:
		a.drawBranchRevisionDialog(c, p)
	case branchDialogConflict:
		a.drawBranchConflictDialog(c, p)
	case branchDialogDelete:
		a.drawBranchDeleteDialog(c, p)
	case branchDialogTag:
		a.drawTagDialog(c, p)
	case branchDialogTagDelete:
		a.drawTagDeleteDialog(c, p)
	}
}

// branchDialog shows one dialog of the popup with its words, and closes it when the user
// dismisses it.
func (a *App) branchDialogOf(c ui.C, title, description string, body, footer func()) {
	open := true
	if ui.ModalWith(c, &open, title, ui.ModalSpec{Description: description, Width: branchDialogWidth}, body, footer) {
		c.After(a.cancelBranchDialog)
	}
}

// drawBranchNameDialog declares the dialog that creates a branch or renames one: the name
// field, cleaned by the kernel as the user types, and why the name cannot be used.
func (a *App) drawBranchNameDialog(c ui.C, p *project) {
	b, t := &a.branch, a.text.Branch
	a.syncBranchName(p)
	creating := b.dialog == branchDialogCreate
	title, description, confirm := t.RenameTitle, t.RenameFrom(b.target.ShortName), t.RenameButton
	if creating {
		title, description, confirm = t.NewBranchTitle, t.CreateFrom(b.target.ShortName), t.Create
	}
	problem := a.branchNameError()
	name := b.preview.CleanedName
	ready := !b.busy && problem == "" && name != "" && (creating || name != b.target.ShortName)
	submitted := false
	a.branchDialogOf(c, title, description, func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			submitted = ui.TextField(c, &b.name, t.BranchName, t.BranchName).FillWidth().Submitted()
			if problem != "" {
				ui.Paragraph(c, problem, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
			}
			if creating {
				ui.Checkbox(c, &b.checkout, t.CheckoutAfter).Disabled(b.busy)
			}
		})
	}, func() {
		if ui.Button(c, t.Cancel).Outline().Clicked() {
			c.After(a.cancelBranchDialog)
		}
		if ui.Button(c, confirm).Disabled(!ready).Clicked() {
			c.After(func() { a.submitBranchName(p) })
		}
	})
	if submitted && ready {
		c.After(func() { a.submitBranchName(p) })
	}
}

// submitBranchName creates or renames the branch of the open name dialog.
func (a *App) submitBranchName(p *project) {
	if a.branch.dialog == branchDialogCreate {
		a.submitCreate(p)
	} else {
		a.submitRename(p)
	}
}

// drawBranchRevisionDialog declares the dialog that checks out a typed tag or revision.
func (a *App) drawBranchRevisionDialog(c ui.C, p *project) {
	b, t := &a.branch, a.text.Branch
	ready := !b.busy && strings.TrimSpace(b.revision.Text()) != ""
	submitted := false
	a.branchDialogOf(c, t.RevisionTitle, t.RevisionPrompt, func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			submitted = ui.TextField(c, &b.revision, t.Revision, t.Revision).FillWidth().Submitted()
			ui.Paragraph(c, t.DetachedNote, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		})
	}, func() {
		if ui.Button(c, t.Cancel).Outline().Clicked() {
			c.After(a.cancelBranchDialog)
		}
		if ui.Button(c, t.Checkout).Disabled(!ready).Clicked() {
			c.After(func() { a.submitRevision(p) })
		}
	})
	if submitted {
		c.After(func() { a.submitRevision(p) })
	}
}

// drawBranchConflictDialog declares the dialog that lists the local changes a checkout
// would overwrite and offers to carry them over or to discard them.
func (a *App) drawBranchConflictDialog(c ui.C, p *project) {
	b, t := &a.branch, a.text.Branch
	a.branchDialogOf(c, t.ConflictTitle, t.ConflictPrompt(b.target.ShortName), func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			ui.Scroll(c).FillWidth().MaxHeight(branchBlockingHeight).Children(func() {
				ui.Column(c).FillWidth().Gap(2).Children(func() {
					for _, path := range b.blocking {
						ui.Text(c.Key(path), path).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Text).Ellipsis()
					}
				})
			})
			ui.Paragraph(c, t.ConflictHint, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		})
	}, func() {
		if ui.Button(c, t.Cancel).Outline().Clicked() {
			c.After(a.cancelBranchDialog)
		}
		if ui.Button(c, t.ForceCheckout).Destructive().Disabled(b.busy).Clicked() {
			c.After(func() { a.resolveConflict(p, core.CheckoutForce) })
		}
		if ui.Button(c, t.SmartCheckout).Disabled(b.busy).Clicked() {
			c.After(func() { a.resolveConflict(p, core.CheckoutSmart) })
		}
	})
}

// drawBranchDeleteDialog declares the dialog that confirms deleting a local branch. The
// focus starts on Cancel, the first control, so Enter does not delete by accident.
func (a *App) drawBranchDeleteDialog(c ui.C, p *project) {
	b, t := &a.branch, a.text.Branch
	a.branchDialogOf(c, t.DeleteTitle, t.DeletePrompt(b.target.ShortName), nil, func() {
		if ui.Button(c, t.Cancel).Outline().Clicked() {
			c.After(a.cancelBranchDialog)
		}
		if ui.Button(c, t.DeleteButton).Destructive().Disabled(b.busy).Clicked() {
			c.After(func() { a.confirmDelete(p) })
		}
	})
}
