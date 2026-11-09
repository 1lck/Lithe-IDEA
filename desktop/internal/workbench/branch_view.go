package workbench

import (
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The identities of the branch popup and its dialogs.
var (
	// branchDismiss is the backdrop behind the open popup: a press on it closes the popup.
	branchDismiss = tree.ID(shellPage, "branch-dismiss")
	// branchPanel is the popup's panel, and branchScroll the list in it.
	branchPanel    = tree.ID(shellPage, "branch-panel")
	branchScroll   = tree.ID(shellPage, "branch-scroll")
	branchSearchID = tree.ID(shellPage, "branch-search")
	// branchNewID and branchRevisionID are the actions at the top of the popup.
	branchNewID      = tree.ID(shellPage, "branch-new")
	branchRevisionID = tree.ID(shellPage, "branch-revision")
	// branchSections identifies the heads of the sections: branchSections.At(i) is the
	// section i of branchSectionKeys.
	branchSections = tree.Sub(shellPage, tree.Name("branch-section"))
	// branchRows identifies the rows of the list in the order the frame lists them.
	branchRows = tree.Sub(shellPage, tree.Name("branch-row"))
	// The menu of one row and its items.
	branchMenuPanel    = tree.ID(shellPage, "branch-menu-panel")
	branchMenuCheckout = tree.ID(shellPage, "branch-menu-checkout")
	branchMenuNewFrom  = tree.ID(shellPage, "branch-menu-new-from")
	branchMenuRename   = tree.ID(shellPage, "branch-menu-rename")
	branchMenuDelete   = tree.ID(shellPage, "branch-menu-delete")
	// The dialogs share one scope: at most one of them is open. branchDialogAlt is the
	// second action of the conflict dialog, the forced checkout.
	branchDialogScope   = tree.ID(shellPage, "branch-dialog")
	branchDialogCancel  = tree.ID(shellPage, "branch-dialog-cancel")
	branchDialogClose   = tree.ID(shellPage, "branch-dialog-close")
	branchDialogConfirm = tree.ID(shellPage, "branch-dialog-confirm")
	branchDialogAlt     = tree.ID(shellPage, "branch-dialog-alt")
	branchNameID        = tree.ID(shellPage, "branch-name")
	branchCheckoutID    = tree.ID(shellPage, "branch-checkout-after")
	branchRevisionField = tree.ID(shellPage, "branch-revision-field")
	branchBlockingID    = tree.ID(shellPage, "branch-blocking")
)

const (
	// branchPopupWidth and branchPopupMaxHeight size the popup; a longer list scrolls.
	branchPopupWidth     = 360
	branchPopupMaxHeight = 560
	// branchMenuWidth is the width of a row's menu.
	branchMenuWidth = 260
	// branchDialogWidth is the width of the dialogs.
	branchDialogWidth = 440
	// branchBlockingHeight caps the list of paths the conflict dialog shows.
	branchBlockingHeight = 160
)

// branchSectionKeys are the keys of the sections of the list, recent ones first, as
// branchSession.collapsed keeps them. The last three follow branchSession.sections.
var branchSectionKeys = [4]string{"recent", "local", "remote", "tag"}

// drawChromeBranch declares the checked-out branch as the button that opens the branch
// popup, and shows nothing when the project is not a repository. It returns the button,
// which the popup is placed under, whether it is shown, and whether it was clicked.
func (a *App) drawChromeBranch(f *ui.Frame) (button ui.Box, shown, clicked bool) {
	name := a.project.git.branch()
	if name == "" {
		return ui.Box{}, false, false
	}
	open := a.branch.open
	button = f.Row().Height(chromeIconButton).Shrink(0).Items(ui.Center).Gap(chromeGap).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(chromeBranchButton, a.text.Title.BranchMenu, gfx.HitOptions{
			Role:       gfx.RoleButton,
			Cursor:     gfx.PointerCursorHand,
			Value:      name,
			Expandable: true,
			Expanded:   open,
		}).
		Pressed(ui.Look{}.Background(a.colors.Active))
	if open {
		button = button.Background(a.colors.Active)
	} else {
		button = button.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	button.Children(func() {
		f.Icon(icons.GitBranch).Size(chromeIconSize, chromeIconSize).Color(a.colors.Subtle)
		f.Text(name).Color(a.colors.Subtle).LineHeight(chromeLineHeight).Ellipsis().MaxWidth(chromeBranchMax)
		f.Icon(icons.ChevronDown).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Subtle)
	})
	return button, true, button.Clicked()
}

// branchRowKey is the key of the row of r in the section key: a branch is listed under
// Recent and under Local, and each row has a menu of its own.
func branchRowKey(section string, r core.GitReference) string {
	return section + "\x00" + r.FullName
}

// drawBranchPopup declares the open popup under anchor, the branch button: a backdrop that
// closes it, the panel with the search field, the actions and the references, and the menu
// of the row the user opened. What a click asks for is done once everything is declared.
func (a *App) drawBranchPopup(f *ui.Frame, anchor ui.Box) {
	p, b, t := a.project, &a.branch, a.text.Branch
	dismissed := f.Popup().At(0, 0).Fill().
		HitWith(branchDismiss, a.text.Errors.Dismiss, gfx.HitOptions{
			Role:          gfx.RoleButton,
			SkipFocus:     true,
			Backdrop:      true,
			PassSecondary: true,
		}).Clicked()

	var creating, revision bool
	toggled := -1
	opened := ""
	var menuAnchor ui.Box
	var menuRef core.GitReference
	hasMenu := false
	n := 0
	current := b.currentReference()
	f.Popup().BelowBox(anchor, chromeMenuOffset, ui.Start).
		Width(branchPopupWidth).MaxHeight(branchPopupMaxHeight).
		Background(a.theme.Popover).Border(1, a.theme.Border).Radius(chromeMenuRadius).Shadow(gfx.ShadowMD).
		HitWith(branchPanel, t.Popup, gfx.HitOptions{Role: gfx.RoleMenu, SkipFocus: true}).
		Children(func() {
			f.Column().FillWidth().Pad(chromeMenuPadding).Gap(chromeMenuItems).Children(func() {
				f.Field(&b.search, branchSearchID, t.Search, t.Search).FillWidth()
				creating = a.drawMenuAction(f, branchNewID, icons.Plus, t.NewBranch)
				revision = a.drawMenuAction(f, branchRevisionID, icons.GitCommitHorizontal, t.CheckoutRevision)
				a.drawMenuDivider(f)
			})
			f.ScrollArea(branchScroll).FillWidth().MaxHeight(branchPopupMaxHeight).
				PadSides(0, chromeMenuPadding, chromeMenuPadding, chromeMenuPadding).Gap(chromeMenuItems).Children(func() {
				switch {
				case b.err != nil && !b.loading:
					f.Paragraph(t.LoadFailed(b.err.Error()), 4).Color(a.colors.Subtle).PadX(chromeEdge)
					return
				case !b.loaded:
					a.drawBranchNote(f, t.Loading)
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
					if a.drawBranchSection(f, i, [4]string{t.Recent, t.Local, t.Remote, t.Tags}[i], collapsed, query == "") {
						toggled = i
					}
					if collapsed {
						continue
					}
					for _, r := range refs {
						rowKey := branchRowKey(key, r)
						row, clicked := a.drawBranchRow(f, n, r, r.FullName == current.FullName, b.menu == rowKey)
						n++
						if b.menu == rowKey {
							menuAnchor, menuRef, hasMenu = row, r, true
						}
						if clicked {
							opened = rowKey
						}
					}
				}
				if listed == 0 {
					a.drawBranchNote(f, t.NoMatches)
				}
			})
		})

	var choice gfx.ID
	if hasMenu {
		choice = a.drawBranchRowMenu(f, menuAnchor, menuRef, menuRef.FullName == current.FullName)
	} else {
		// The row of the open menu is no longer listed, filtered out or folded.
		b.menu = ""
	}
	if b.focusSearch {
		b.focusSearch = false
		f.Canvas().RequestFocus(branchSearchID)
	}

	switch {
	case creating:
		a.beginCreate(p, current)
	case revision:
		a.beginRevision()
	case choice == branchMenuCheckout:
		a.checkoutBranch(p, menuRef)
	case choice == branchMenuNewFrom:
		a.beginCreate(p, menuRef)
	case choice == branchMenuRename:
		a.beginRename(p, menuRef)
	case choice == branchMenuDelete:
		a.beginDelete(menuRef)
	case opened != "":
		if b.menu == opened {
			b.menu = ""
		} else {
			b.menu = opened
		}
	case toggled >= 0:
		key := branchSectionKeys[toggled]
		b.collapsed[key] = !b.collapsed[key]
	case dismissed:
		a.closeBranches()
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

// drawBranchNote declares a line of the list that says why it shows no branch.
func (a *App) drawBranchNote(f *ui.Frame, note string) {
	f.Row().Height(chromeMenuRow).Shrink(0).Items(ui.Center).PadX(chromeEdge).Children(func() {
		f.Text(note).Color(a.colors.Subtle).LineHeight(chromeLineHeight)
	})
}

// drawBranchSection declares the head of section i and reports a click on it. A head folds
// its section while the list is not filtered; a filtered list shows every match.
func (a *App) drawBranchSection(f *ui.Frame, i int, label string, collapsed, foldable bool) bool {
	options := gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Expandable: true, Expanded: !collapsed}
	if !foldable {
		options.Cursor, options.Disabled = gfx.PointerCursorDefault, true
	}
	head := f.Row().Height(chromeMenuTitle).Shrink(0).Items(ui.Center).Gap(chromeGap).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).HitWith(branchSections.At(i), label, options)
	if foldable {
		head = a.chromeHover(head)
	}
	head.Children(func() {
		chevron := icons.ChevronDown
		if collapsed {
			chevron = icons.ChevronRight
		}
		f.Icon(chevron).Size(chromeMarkSize, chromeMarkSize).Color(a.colors.Subtle)
		f.Text(label).FontSize(a.theme.Metrics.FontSizeS).Bold().Color(a.colors.Subtle).LineHeight(chromeLineHeight)
	})
	return foldable && head.Clicked()
}

// drawBranchRow declares the row of reference r, the n-th of the list: its mark, its name,
// its upstream and how far the two are apart, and the chevron of its menu. It returns the
// row, which the menu is placed beside, and whether it was clicked.
func (a *App) drawBranchRow(f *ui.Frame, n int, r core.GitReference, current, open bool) (ui.Box, bool) {
	t := a.text.Branch
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
	row := f.Row().Height(chromeMenuRow).Shrink(0).FillWidth().Items(ui.Center).Gap(chromeMenuGap).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).HitWith(branchRows.At(n), r.ShortName, options)
	if open {
		row = row.Background(a.colors.Selection)
	} else {
		row = a.chromeHover(row)
	}
	row.Children(func() {
		f.Icon(icon).Size(chromeIconSize, chromeIconSize).Shrink(0).Color(referenceColor(kind, a.colors.Dark))
		f.Text(r.ShortName).Color(a.colors.Text).LineHeight(chromeLineHeight).Ellipsis().Grow(1)
		if trailing != "" {
			f.Text(trailing).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).LineHeight(chromeLineHeight).
				Ellipsis().MaxWidth(branchPopupWidth / 3)
		}
		f.Icon(icons.ChevronRight).Size(chromeMarkSize, chromeMarkSize).Shrink(0).Color(a.colors.Subtle)
	})
	return row, row.Clicked()
}

// drawBranchRowMenu declares the menu of reference r beside its row and returns the item
// clicked, the zero ID for none. The checked-out branch is not checked out again, nor
// deleted; only a local branch is renamed or deleted.
func (a *App) drawBranchRowMenu(f *ui.Frame, anchor ui.Box, r core.GitReference, current bool) gfx.ID {
	t := a.text.Branch
	var chosen gfx.ID
	f.Popup().BesideBox(anchor, chromeMenuOffset, ui.Start).Width(branchMenuWidth).
		Background(a.theme.Popover).Border(1, a.theme.Border).Radius(chromeMenuRadius).Shadow(gfx.ShadowMD).
		HitWith(branchMenuPanel, t.RowMenu(r.ShortName), gfx.HitOptions{Role: gfx.RoleMenu, SkipFocus: true}).
		Pad(chromeMenuPadding).Gap(chromeMenuItems).
		Children(func() {
			item := func(id gfx.ID, label string) {
				if a.drawBranchMenuItem(f, id, label) {
					chosen = id
				}
			}
			if !current {
				item(branchMenuCheckout, t.Checkout)
			}
			item(branchMenuNewFrom, t.NewBranchFrom(r.ShortName))
			if r.Kind == "local" {
				item(branchMenuRename, t.Rename)
				if !current {
					item(branchMenuDelete, t.Delete)
				}
			}
		})
	return chosen
}

// drawBranchMenuItem declares one item of a row's menu and reports a click on it.
func (a *App) drawBranchMenuItem(f *ui.Frame, id gfx.ID, label string) bool {
	row := a.chromeHover(f.Row().Height(chromeMenuRow).Shrink(0).FillWidth().Items(ui.Center).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(id, label, gfx.HitOptions{Role: gfx.RoleMenuItem, Cursor: gfx.PointerCursorHand}))
	row.Children(func() {
		f.Text(label).Color(a.colors.Text).LineHeight(chromeLineHeight).Ellipsis()
	})
	return row.Clicked()
}

// drawBranchDialog declares the dialog the popup opened, if any.
func (a *App) drawBranchDialog(f *ui.Frame) {
	p, b := a.project, &a.branch
	if p == nil || b.dialog == branchDialogNone {
		return
	}
	switch b.dialog {
	case branchDialogCreate, branchDialogRename:
		a.drawBranchNameDialog(f, p)
	case branchDialogRevision:
		a.drawBranchRevisionDialog(f, p)
	case branchDialogConflict:
		a.drawBranchConflictDialog(f, p)
	case branchDialogDelete:
		a.drawBranchDeleteDialog(f, p)
	}
}

// branchDialogSpec is the spec every branch dialog shares, with its words and the control
// that takes the focus when it opens.
func branchDialogSpec(title, description string, focus gfx.ID) ui.DialogSpec {
	return ui.DialogSpec{Title: title, Description: description, Width: branchDialogWidth,
		Scope: branchDialogScope, DismissID: branchDialogCancel, CloseID: branchDialogClose, InitialFocusID: focus}
}

// drawBranchNameDialog declares the dialog that creates a branch or renames one: the name
// field, cleaned by the kernel as the user types, and why the name cannot be used.
func (a *App) drawBranchNameDialog(f *ui.Frame, p *project) {
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
	d := f.Dialog(branchDialogSpec(title, description, branchNameID))
	d.Body(func() {
		f.Column().FillWidth().Gap(8).Children(func() {
			submitted = f.Field(&b.name, branchNameID, t.BranchName, t.BranchName).FillWidth().Submitted()
			if problem != "" {
				f.Paragraph(problem, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.theme.Danger)
			}
			if creating {
				if f.Checkbox(branchCheckoutID, b.checkout).Label(t.CheckoutAfter).Disabled(b.busy).Clicked() {
					b.checkout = !b.checkout
				}
			}
		})
	})
	cancelled, confirmed := false, false
	d.Footer(func() {
		cancelled = f.Button(branchDialogCancel, t.Cancel).Outline().Clicked()
		confirmed = f.Button(branchDialogConfirm, confirm).Disabled(!ready).Clicked()
	})
	switch {
	case cancelled, d.Dismissed():
		a.cancelBranchDialog()
	case confirmed || submitted:
		if creating {
			a.submitCreate(p)
		} else {
			a.submitRename(p)
		}
	}
}

// drawBranchRevisionDialog declares the dialog that checks out a typed tag or revision.
func (a *App) drawBranchRevisionDialog(f *ui.Frame, p *project) {
	b, t := &a.branch, a.text.Branch
	ready := !b.busy && strings.TrimSpace(b.revision.Text()) != ""
	submitted := false
	d := f.Dialog(branchDialogSpec(t.RevisionTitle, t.RevisionPrompt, branchRevisionField))
	d.Body(func() {
		f.Column().FillWidth().Gap(8).Children(func() {
			submitted = f.Field(&b.revision, branchRevisionField, t.Revision, t.Revision).FillWidth().Submitted()
			f.Paragraph(t.DetachedNote, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		})
	})
	cancelled, confirmed := false, false
	d.Footer(func() {
		cancelled = f.Button(branchDialogCancel, t.Cancel).Outline().Clicked()
		confirmed = f.Button(branchDialogConfirm, t.Checkout).Disabled(!ready).Clicked()
	})
	switch {
	case cancelled, d.Dismissed():
		a.cancelBranchDialog()
	case confirmed || submitted:
		a.submitRevision(p)
	}
}

// drawBranchConflictDialog declares the dialog that lists the local changes a checkout
// would overwrite and offers to carry them over or to discard them.
func (a *App) drawBranchConflictDialog(f *ui.Frame, p *project) {
	b, t := &a.branch, a.text.Branch
	d := f.Dialog(branchDialogSpec(t.ConflictTitle, t.ConflictPrompt(b.target.ShortName), branchDialogConfirm))
	d.Body(func() {
		f.Column().FillWidth().Gap(8).Children(func() {
			f.ScrollArea(branchBlockingID).FillWidth().MaxHeight(branchBlockingHeight).Children(func() {
				f.Column().FillWidth().Gap(2).Children(func() {
					for _, path := range b.blocking {
						f.Text(path).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Text).Ellipsis()
					}
				})
			})
			f.Paragraph(t.ConflictHint, 3).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle)
		})
	})
	cancelled, forced, smart := false, false, false
	d.Footer(func() {
		cancelled = f.Button(branchDialogCancel, t.Cancel).Outline().Clicked()
		forced = f.Button(branchDialogAlt, t.ForceCheckout).Destructive().Disabled(b.busy).Clicked()
		smart = f.Button(branchDialogConfirm, t.SmartCheckout).Disabled(b.busy).Clicked()
	})
	switch {
	case cancelled, d.Dismissed():
		a.cancelBranchDialog()
	case forced:
		a.resolveConflict(p, core.CheckoutForce)
	case smart:
		a.resolveConflict(p, core.CheckoutSmart)
	}
}

// drawBranchDeleteDialog declares the dialog that confirms deleting a local branch. The
// focus starts on Cancel, so Enter does not delete by accident.
func (a *App) drawBranchDeleteDialog(f *ui.Frame, p *project) {
	b, t := &a.branch, a.text.Branch
	d := f.Dialog(branchDialogSpec(t.DeleteTitle, t.DeletePrompt(b.target.ShortName), branchDialogCancel))
	cancelled, confirmed := false, false
	d.Footer(func() {
		cancelled = f.Button(branchDialogCancel, t.Cancel).Outline().Clicked()
		confirmed = f.Button(branchDialogConfirm, t.DeleteButton).Destructive().Disabled(b.busy).Clicked()
	})
	switch {
	case cancelled, d.Dismissed():
		a.cancelBranchDialog()
	case confirmed:
		a.confirmDelete(p)
	}
}
