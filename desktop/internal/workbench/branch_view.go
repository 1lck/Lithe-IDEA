package workbench

import (
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/components"
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
	// branchRowHeight is the height of every row of the popup, as dense as IDEA's popup, and
	// branchIndent the step of each level of a tree: a folder's chevron sits one step left of
	// its icon, so the icons of one level line up whether or not the row folds.
	branchRowHeight = 24
	branchIndent    = chromeMarkSize + chromeGap
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

// branchInset is the left padding of a row at depth in the list: depth 0 is a section's head.
func branchInset(depth int) float32 { return chromeEdge + float32(depth)*branchIndent }

// drawBranchPopup declares the open popup under the branch button: the panel with the search
// field, the actions and the references, and the menu of the row the user opened. A press
// outside it, or Escape, closes it.
func (a *App) drawBranchPopup(c ui.C, p *project, anchor ui.Box) {
	b, t := &a.branch, a.text.Branch
	spec := ui.PopoverSpec{Align: ui.Start, Offset: chromeMenuOffset, Width: branchPopupWidth, ConsumeOutsidePress: true}
	ui.Popover(c, anchor, &b.open, spec, func() {
		ui.Column(c).FillWidth().MaxHeight(branchPopupMaxHeight).Gap(chromeMenuItems).Children(func() {
			a.drawBranchPanel(c, p, t)
		})
	})
	if !b.open {
		// The press outside or Escape closed it; a closed popup has no repository panel or row menu.
		b.repoOpen, b.menu = false, ""
	}
}

// drawBranchPanel declares the popup's contents: the search field, the actions, and the
// references. Without a search the sections show Core's folder trees; a search lists every match
// by its full name. A project folder with several repositories lists them instead, as IDEA does
// (drawWorkspaceBranchPanel).
func (a *App) drawBranchPanel(c ui.C, p *project, t i18n.BranchMessages) {
	if p.workspaceMode() {
		a.drawWorkspaceBranchPanel(c, p, t)
		return
	}
	b := &a.branch
	current := b.currentReference()
	query := branchQuery(b)
	ui.TextField(c, &b.search, t.Search, t.Search).FillWidth().AutoFocus()
	if a.drawBranchActions(c, p, current, query, true) {
		ui.Divider(c)
	}
	ui.Scroll(c).Scrollbars().FillWidth().MaxHeight(branchPopupMaxHeight).Children(func() {
		a.drawBranchReferences(c, p, t, query, [4]string{t.Recent, t.Local, t.Remote, t.Tags})
	})
}

// branchQuery is the search of the popup, trimmed and in lower case.
func branchQuery(b *branchState) string {
	return strings.ToLower(strings.TrimSpace(b.search.Text()))
}

// drawBranchReferences declares the sections of the references the popup read, under labels in
// the order of branchSectionKeys, filtered by query.
func (a *App) drawBranchReferences(c ui.C, p *project, t i18n.BranchMessages, query string, labels [4]string) {
	b := &a.branch
	switch {
	case b.err != nil && !b.loading:
		ui.Paragraph(c, t.LoadFailed(b.err.Error()), 4).Color(a.colors.Subtle).PadX(chromeEdge)
		return
	case !b.loaded:
		a.drawBranchNote(c, t.Loading)
		return
	}
	current := b.currentReference()
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
		if a.drawBranchSection(c, key, labels[i], collapsed, query == "") {
			c.After(func() { b.collapsed[key] = !b.collapsed[key] })
		}
		switch {
		case collapsed:
		case i == 0 || query != "":
			for _, r := range refs {
				a.drawBranchRow(c, p, key, r, r.ShortName, 1, r.FullName == current.FullName)
			}
		default:
			s := &b.sections[i-1]
			a.drawBranchNodes(c, p, s, key, s.nodes, 1, current)
		}
	}
	if listed == 0 {
		a.drawBranchNote(c, t.NoMatches)
	}
}

// drawWorkspaceBranchPanel declares the popup of a project folder with several repositories, as
// IDEA's: the search field, the commit of the Commit tool window, which spans every repository, a
// row per repository in Core's order with its color, its name and the branch it is on, and the
// branches every repository has (drawCommonBranches). A click on a repository's row opens its panel
// beside it with its actions and references; every write there acts in that repository alone, and
// every write on a common branch acts in all of them.
func (a *App) drawWorkspaceBranchPanel(c ui.C, p *project, t i18n.BranchMessages) {
	b := &a.branch
	query := branchQuery(b)
	ui.TextField(c, &b.search, t.Search, t.Search).FillWidth().AutoFocus()
	if commit := i18n.Shared(a.language(), "desktop.command.commit"); query == "" || strings.Contains(strings.ToLower(commit), query) {
		if a.drawBranchAction(c, "commit", icons.GitCommitHorizontal, commit, false) {
			c.After(a.commitFromBranches)
		}
		ui.Divider(c)
	}
	ui.Scroll(c).Scrollbars().FillWidth().MaxHeight(branchPopupMaxHeight).Children(func() {
		for _, repo := range p.workspaceRepositories() {
			a.drawWorkspaceBranchRepo(c, p, t, repo, query)
		}
		a.drawCommonBranches(c, p, t, query)
	})
}

// drawWorkspaceBranchRepo declares the row of one repository of the folder's popup and, while it is
// open, its panel beside it: the actions of drawBranchActions and the sections of its references,
// each named after the repository.
func (a *App) drawWorkspaceBranchRepo(c ui.C, p *project, t i18n.BranchMessages, repo workspaceRepository, query string) {
	b := &a.branch
	open := b.repoOpen && a.branchRoot(p) == repo.root
	branch := p.branchOf(repo.id)
	label := repo.name
	if branch != "" {
		label = i18n.SharedFormat(a.language(), "desktop.branch.repositoryPanel", map[string]string{"repository": repo.name, "branch": branch})
	}
	row := ui.Row(c.Key("repo/"+repo.id)).Height(branchRowHeight).Shrink(0).FillWidth().Items(ui.Center).Gap(chromeMenuGap).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).HitWith(ui.ID(c), label, gfx.HitOptions{Role: gfx.RoleMenuItem, Cursor: gfx.PointerCursorHand, Expandable: true, Expanded: open})
	if open {
		row = row.Background(a.colors.Selection)
	} else {
		row = a.chromeHover(row)
	}
	row.Children(func() {
		a.drawRepositorySwatch(c, p, repo.id)
		ui.Text(c, repo.name).Color(a.colors.Text).LineHeight(chromeLineHeight).Ellipsis().Shrink(1)
		ui.Spacer(c)
		if branch != "" {
			ui.Text(c, branch).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).LineHeight(chromeLineHeight).
				Ellipsis().MaxWidth(branchPopupWidth / 2)
		}
		ui.Icon(c, icons.ChevronRight).Size(chromeMarkSize, chromeMarkSize).Shrink(0).Color(a.colors.Subtle)
	})
	if row.Clicked() {
		c.After(func() { a.toggleBranchRepo(p, repo.root) })
	}
	if !open {
		return
	}
	// The press that closes the panel goes on to the popup, so a click on another repository opens
	// that one's panel at once.
	spec := ui.PopoverSpec{Side: components.PopoverRight, Align: ui.Start, Offset: chromeMenuOffset, Width: branchPopupWidth}
	ui.Popover(c, row, &b.repoOpen, spec, func() {
		ui.Column(c).FillWidth().MaxHeight(branchPopupMaxHeight).Gap(chromeMenuItems).Children(func() {
			if a.drawBranchActions(c, p, b.currentReference(), query, false) {
				ui.Divider(c)
			}
			ui.Scroll(c).Scrollbars().FillWidth().MaxHeight(branchPopupMaxHeight).Children(func() {
				lang := a.language()
				a.drawBranchReferences(c, p, t, query, [4]string{
					i18n.SharedFormat(lang, "desktop.branch.recentIn", map[string]string{"repository": repo.name}),
					i18n.SharedFormat(lang, "desktop.branch.localIn", map[string]string{"repository": repo.name}),
					i18n.SharedFormat(lang, "desktop.branch.remoteIn", map[string]string{"repository": repo.name}),
					i18n.SharedFormat(lang, "desktop.branch.tagsIn", map[string]string{"repository": repo.name}),
				})
			})
		})
	})
	if !b.repoOpen {
		// A closed panel has no row menu.
		b.menu = ""
	}
}

// commitFromBranches opens the Commit tool window's changes from the branch popup.
func (a *App) commitFromBranches() {
	a.performed("git.showChanges", surfaceButton)
	a.closeBranches()
	a.layout.commitTab = commitTabChanges
	a.showChanges()
}

// drawBranchActions declares the actions at the top of the popup in IDEA's order and reports
// whether it showed any: Fetch, which shows only while the search names it, then updating,
// committing, unless commit is false, and pushing the current branch, then creating a branch,
// checking out a revision and creating a tag. A search keeps the actions whose names contain it.
// Every action works in the repository the popup lists.
func (a *App) drawBranchActions(c ui.C, p *project, current core.GitReference, query string, commit bool) bool {
	b, t, g := &a.branch, a.text.Branch, a.text.Git
	lang := a.language()
	root := a.branchRoot(p)
	busy := b.busy || p.log.sync.busy
	onBranch := current.IsCurrent
	named := func(label string) bool { return query == "" || strings.Contains(strings.ToLower(label), query) }
	shown := 0
	if query != "" && named(g.Fetch) {
		shown++
		if a.drawBranchAction(c, "fetch", icons.Download, g.Fetch, busy) {
			c.After(func() {
				a.closeBranches()
				a.fetchAllAt(p, root, surfaceButton)
			})
		}
	}
	if named(g.UpdateBranch) {
		shown++
		if a.drawBranchAction(c, "update", icons.ArrowDownLeft, g.UpdateBranch, busy || !onBranch) {
			c.After(func() {
				a.closeBranches()
				a.updateCurrentBranchAt(p, root, current.ShortName, surfaceButton)
			})
		}
	}
	if label := i18n.Shared(lang, "desktop.command.commit"); commit && named(label) {
		shown++
		if a.drawBranchAction(c, "commit", icons.GitCommitHorizontal, label, false) {
			c.After(a.commitFromBranches)
		}
	}
	if push := i18n.Shared(lang, "git.contextMenu.push"); named(push) {
		shown++
		if a.drawBranchAction(c, "push", icons.ArrowUp, push, busy || !onBranch) {
			c.After(func() {
				a.closeBranches()
				a.openPushOf(p, root, core.GitReference{}, surfaceButton)
			})
		}
	}
	tag := i18n.Shared(lang, "desktop.tags.newTag")
	if shown > 0 && (named(t.NewBranch) || named(t.CheckoutRevision) || named(tag)) {
		ui.Divider(c)
	}
	if named(t.NewBranch) {
		shown++
		if a.drawBranchAction(c, "new", icons.Plus, t.NewBranch, busy) {
			c.After(func() { a.beginCreate(p, current) })
		}
	}
	if named(t.CheckoutRevision) {
		shown++
		if a.drawBranchAction(c, "revision", gfx.Icon{}, t.CheckoutRevision, busy) {
			c.After(a.beginRevision)
		}
	}
	if named(tag) {
		shown++
		if a.drawBranchAction(c, "tag", icons.Tag, tag, busy) {
			c.After(func() { a.beginCreateTag(p) })
		}
	}
	return shown > 0
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
// name, and reports a click on it. A zero icon leaves its place empty, so the names line up.
func (a *App) drawBranchAction(c ui.C, part string, icon gfx.Icon, label string, disabled bool) bool {
	options := gfx.HitOptions{Role: gfx.RoleMenuItem, Cursor: gfx.PointerCursorHand, Disabled: disabled}
	if disabled {
		options.Cursor = gfx.PointerCursorDefault
	}
	row := ui.Row(c.Part(part)).Height(branchRowHeight).Shrink(0).FillWidth().Items(ui.Center).Gap(chromeMenuGap).PadX(chromeEdge).
		Radius(a.theme.Metrics.RadiusItem()).HitWith(ui.ID(c), label, options)
	if !disabled {
		row = a.chromeHover(row)
	}
	text, mark := a.colors.Text, a.colors.Subtle
	if disabled {
		text = a.colors.Subtle
	}
	row.Children(func() {
		if len(icon.Commands) == 0 {
			ui.Spacer(c).Size(chromeIconSize, chromeIconSize).Grow(0).Shrink(0)
		} else {
			ui.Icon(c, icon).Size(chromeIconSize, chromeIconSize).Shrink(0).Color(mark)
		}
		ui.Text(c, label).Color(text).LineHeight(chromeLineHeight).Ellipsis()
	})
	return !disabled && row.Clicked()
}

// drawBranchNote declares a line of the list that says why it shows no branch.
func (a *App) drawBranchNote(c ui.C, note string) {
	ui.Row(c).Height(branchRowHeight).Shrink(0).Items(ui.Center).PadX(chromeEdge).Children(func() {
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
	head := ui.Row(c.Key("section/"+key)).Height(branchRowHeight).Shrink(0).FillWidth().Items(ui.Center).Gap(chromeGap).PadX(chromeEdge).
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

// drawBranchNodes declares the folders and references of nodes, a level of the folder tree
// Core built for section s, at depth. A folder starts closed; an open one shows its level
// under it. A reference row shows the last part of its name, which its folders spell out.
func (a *App) drawBranchNodes(c ui.C, p *project, s *logSection, section string, nodes []core.ReferenceTreeNode, depth int, current core.GitReference) {
	b := &a.branch
	for i := range nodes {
		node := &nodes[i]
		if node.Reference != nil {
			if r := *node.Reference; r >= 0 && r < len(s.refs) {
				ref := s.refs[r]
				a.drawBranchRow(c, p, section, ref, node.Name, depth, ref.FullName == current.FullName)
			}
			continue
		}
		key := "f" + s.kind + "/" + node.Path
		open := b.expanded[key]
		if a.drawBranchFolder(c, key, node.Name, depth, open) {
			c.After(func() { b.expanded[key] = !b.expanded[key] })
		}
		if open {
			a.drawBranchNodes(c, p, s, section, node.Children, depth+1, current)
		}
	}
}

// drawBranchFolder declares the row of a folder of references at depth, its chevron one step
// left of its icon, and reports a click on it.
func (a *App) drawBranchFolder(c ui.C, key, name string, depth int, open bool) bool {
	chevron := icons.ChevronRight
	if open {
		chevron = icons.ChevronDown
	}
	row := ui.Row(c.Key("folder/"+key)).Height(branchRowHeight).Shrink(0).FillWidth().Items(ui.Center).Gap(chromeGap).
		PadLeft(branchInset(depth)-branchIndent).PadRight(chromeEdge).Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(c), name, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand, Expandable: true, Expanded: open})
	a.chromeHover(row).Children(func() {
		ui.Icon(c, chevron).Size(chromeMarkSize, chromeMarkSize).Shrink(0).Color(a.colors.Subtle)
		ui.Row(c).Items(ui.Center).Gap(chromeMenuGap).Grow(1).Children(func() {
			ui.Icon(c, icons.Folder).Size(chromeIconSize, chromeIconSize).Shrink(0).Color(a.colors.Subtle)
			ui.Text(c, name).Color(a.colors.Text).LineHeight(chromeLineHeight).Ellipsis()
		})
	})
	return row.Clicked()
}

// branchTracking words how far the local branch r and its upstream are apart, as the log's
// reference pane does: "↑ahead ↓behind", empty when they are level or r tracks nothing.
func branchTracking(r core.GitReference) string {
	tracking := ""
	if r.Ahead > 0 {
		tracking = "↑" + strconv.Itoa(r.Ahead)
	}
	if r.Behind > 0 {
		tracking = strings.TrimSpace(tracking + " ↓" + strconv.Itoa(r.Behind))
	}
	return tracking
}

// drawBranchRow declares the row of reference r in section key at depth, named label: its
// mark, its name, how far it and its upstream are apart, the upstream on the right, and the
// chevron of its menu. A click opens the menu of the row beside it: drawCommonBranchRowMenu for a
// row of a common section, whose actions run in every repository, drawBranchRowMenu otherwise.
func (a *App) drawBranchRow(c ui.C, p *project, section string, r core.GitReference, label string, depth int, current bool) {
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
	options := gfx.HitOptions{Role: gfx.RoleMenuItem, Cursor: gfx.PointerCursorHand, Expandable: true, Expanded: open, Selected: current}
	if current {
		options.Value = t.Current
	}
	row := ui.Row(c.Key(rowKey)).Height(branchRowHeight).Shrink(0).FillWidth().Items(ui.Center).Gap(chromeMenuGap).
		PadLeft(branchInset(depth)).PadRight(chromeEdge).Radius(a.theme.Metrics.RadiusItem()).HitWith(ui.ID(c), r.ShortName, options)
	if open {
		row = row.Background(a.colors.Selection)
	} else {
		row = a.chromeHover(row)
	}
	row.Children(func() {
		ui.Icon(c, icon).Size(chromeIconSize, chromeIconSize).Shrink(0).Color(referenceColor(kind, a.colors.Dark))
		ui.Text(c, label).Color(a.colors.Text).LineHeight(chromeLineHeight).Ellipsis().Shrink(1)
		if tracking := branchTracking(r); tracking != "" {
			ui.Text(c, tracking).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).LineHeight(chromeLineHeight).Shrink(0)
		}
		ui.Spacer(c)
		if r.UpstreamShortName != "" {
			ui.Text(c, r.UpstreamShortName).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Subtle).LineHeight(chromeLineHeight).
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
	ui.Menu(c, row, &open, func(menu *ui.MenuItems) {
		menu.Beside()
		if strings.HasPrefix(section, commonSectionPrefix) {
			a.drawCommonBranchRowMenu(c, menu, p, r, current)
		} else {
			a.drawBranchRowMenu(c, menu, p, r, current)
		}
	})
	if !open {
		b.menu = ""
	}
}

// drawBranchRowMenu declares the items of the menu of reference r in IDEA's order: a branch
// from it and the two comparisons, the checkout, the update and push of a local branch, its
// rename, and the delete. The checked-out branch is not checked out again, compared with
// itself or deleted; only a local branch is updated, pushed or renamed. A remote branch is deleted
// from its remote. The comparisons, the update and the push work in the repository the popup lists.
func (a *App) drawBranchRowMenu(c ui.C, menu *ui.MenuItems, p *project, r core.GitReference, current bool) {
	b, t, g := &a.branch, a.text.Branch, a.text.Git
	lang := a.language()
	root := a.branchRoot(p)
	busy := b.busy || p.log.sync.busy
	head := b.currentReference()
	if menu.Item(t.NewBranchFrom(r.ShortName)).Clicked() {
		c.After(func() { a.beginCreate(p, r) })
	}
	if menu.Item(g.CompareWorkingTree).Disabled(p.log.comparing).Clicked() {
		c.After(func() {
			a.closeBranches()
			a.compareReferencesAt(p, root, r, nil)
		})
	}
	if !current && head.IsCurrent && menu.Item(g.CompareWithCurrent).Disabled(p.log.comparing).Clicked() {
		c.After(func() {
			a.closeBranches()
			a.compareReferencesAt(p, root, head, &r)
		})
	}
	if !current {
		menu.Separator()
		if menu.Item(t.Checkout).Disabled(busy).Clicked() {
			c.After(func() { a.checkoutBranch(p, r, surfaceMenu) })
		}
	}
	if r.Kind == "local" {
		menu.Separator()
		// Any other local branch fast-forwards from its upstream in place, as in IDEA.
		if menu.Item(i18n.Shared(lang, "git.log.updateBranch")).Disabled(busy || !current && r.UpstreamShortName == "").Clicked() {
			c.After(func() {
				a.closeBranches()
				a.updateBranchAt(p, root, r, surfaceMenu)
			})
		}
		if menu.Item(i18n.Shared(lang, "git.contextMenu.push")).Disabled(busy).Clicked() {
			c.After(func() {
				a.closeBranches()
				a.openPushOf(p, root, r, surfaceMenu)
			})
		}
		if menu.Item(t.Rename).Disabled(busy).Clicked() {
			c.After(func() { a.beginRename(p, r) })
		}
	}
	if r.Kind == "tag" || deletableBranch(r) && !current {
		menu.Separator()
		if menu.Item(t.Delete).Destructive().Disabled(busy).Clicked() {
			if r.Kind == "tag" {
				c.After(func() { a.beginDeleteTag(r) })
			} else {
				c.After(func() { a.beginDelete(r) })
			}
		}
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
	case branchDialogDeleteUnmerged, branchDialogForceDelete, branchDialogDeleteResult:
		a.drawBranchForceDeleteDialog(c, p)
	case branchDialogTag:
		a.drawTagDialog(c, p)
	case branchDialogTagDelete:
		a.drawTagDeleteDialog(c, p)
	case branchDialogRollback:
		a.drawBranchRollbackDialog(c, p)
	}
}

// branchDialog shows one dialog of the popup with its words, and closes it when the user
// dismisses it.
func (a *App) branchDialogOf(c ui.C, title, description string, body, footer func()) {
	open := true
	if ui.Modal(c, &open, title, ui.ModalSpec{Description: description, Width: branchDialogWidth}, body, footer) {
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
		if b.across {
			description = i18n.SharedFormat(a.language(), "desktop.branch.createFromInAll", map[string]string{"name": b.target.ShortName})
		}
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
			ui.Scroll(c).Scrollbars().FillWidth().MaxHeight(branchBlockingHeight).Children(func() {
				ui.Column(c).FillWidth().Gap(2).Children(func() {
					for _, path := range b.blocking {
						ui.Text(c, path).FontSize(a.theme.Metrics.FontSizeS).Color(a.colors.Text).Ellipsis()
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
