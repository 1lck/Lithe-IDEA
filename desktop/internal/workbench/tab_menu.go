package workbench

import (
	"slices"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// The context menu of an editor tab, as the IDE's: close this tab, the others, those on
// either side, the unmodified ones, all of them or all but the pinned ones; pin a file's tab;
// and for a file, copy its path and select it in the Project tool window. Pinned file tabs
// sit first in their group and survive Close Others, Close All but Pinned and the tab limit.

// tabMenuItems declares the menu of tab t in group, whose tabs are tabs.
func (a *App) tabMenuItems(c ui.C, group string, t shownTab, tabs []shownTab) func(*ui.MenuItems) {
	return func(menu *ui.MenuItems) {
		p := a.project
		if p == nil {
			return
		}
		language := a.language()
		menu.WidthRange(220, 280)
		at := slices.IndexFunc(tabs, func(s shownTab) bool { return s.member() == t.member() })
		closeAll := func(action string, keep func(i int, s shownTab) bool) {
			// The members are taken now: closing a tab changes the group the slice came from.
			var members []string
			for i, s := range tabs {
				if !keep(i, s) {
					members = append(members, s.member())
				}
			}
			c.After(func() {
				a.performed(action, surfaceMenu)
				a.closeMembers(p, members)
			})
		}
		if menu.Item(i18n.Shared(language, "desktop.tab.close")).Clicked() {
			c.After(func() { a.closeTab(t) })
		}
		tabPinned := func(s shownTab) bool { return p.terms.bench.Group(group).IsPinned(s.member()) }
		if menu.Item(i18n.Shared(language, "native.closeOtherTabs")).Disabled(len(tabs) < 2).Clicked() {
			closeAll("editor.tabs.closeOthers", func(i int, s shownTab) bool { return i == at || tabPinned(s) })
		}
		if menu.Item(i18n.Shared(language, "native.closeTabsToTheLeft")).Disabled(at <= 0).Clicked() {
			closeAll("editor.tabs.closeLeft", func(i int, s shownTab) bool { return i >= at || tabPinned(s) })
		}
		if menu.Item(i18n.Shared(language, "native.closeTabsToTheRight")).Disabled(at < 0 || at >= len(tabs)-1).Clicked() {
			closeAll("editor.tabs.closeRight", func(i int, s shownTab) bool { return i <= at || tabPinned(s) })
		}
		if menu.Item(i18n.Shared(language, "native.closeUnmodifiedTabs")).Clicked() {
			closeAll("editor.tabs.closeUnmodified", func(_ int, s shownTab) bool {
				return tabPinned(s) || s.doc == nil || s.doc.dirty()
			})
		}
		if menu.Item(i18n.Shared(language, "native.closeAllTabs")).Clicked() {
			closeAll("editor.tabs.closeAll", func(int, shownTab) bool { return false })
		}
		if slices.ContainsFunc(tabs, tabPinned) && menu.Item(i18n.Shared(language, "desktop.tab.closeAllButPinned")).Clicked() {
			closeAll("editor.tabs.closeAllButPinned", func(_ int, s shownTab) bool { return tabPinned(s) })
		}
		d := t.doc
		if d == nil || d.virtual || d.path == "" {
			return
		}
		menu.Separator()
		pinned := tabPinned(t)
		pin := i18n.Shared(language, "desktop.tab.pin")
		if pinned {
			pin = i18n.Shared(language, "desktop.tab.unpin")
		}
		if menu.Item(pin).Clicked() {
			c.After(func() { a.setTabPinned(p, group, d, !pinned) })
		}
		menu.Separator()
		path := d.path
		a.copyPathMenu(c, menu, path, true, "editor.tabs")
		if menu.Item(revealLabel(language)).Clicked() {
			c.After(func() {
				a.performed("editor.tabs.reveal", surfaceMenu)
				a.revealPath(path)
			})
		}
		_, inside := projectRelative(p.root, path)
		if _, ok := a.kernel.(localHistoryKernel); ok && inside && menu.Item(i18n.Shared(language, "desktop.history.show")).Clicked() {
			c.After(func() {
				a.performed("localHistory.show", surfaceMenu)
				a.openLocalHistory(p, path)
			})
		}
		if inside && menu.Item(i18n.Shared(language, "desktop.tab.selectInProject")).Clicked() {
			c.After(func() {
				a.performed("editor.tabs.selectInProject", surfaceMenu)
				a.selectDocument(p, d.id)
				a.reduceChrome(core.SetChromeOpen(itemProject, true))
				a.revealActiveFile(p)
			})
		}
	}
}

// documentPinned reports whether a group pins document d's tab.
func (p *project) documentPinned(d *document) bool {
	member := documentMember(d.id)
	return p.terms.bench.GroupOf(member).IsPinned(member)
}

// closeMembers closes the tabs of the given group members, one after another.
func (a *App) closeMembers(p *project, members []string) {
	for _, member := range members {
		if a.project != p {
			return
		}
		g := p.terms.bench.GroupOf(member)
		if g == nil {
			continue
		}
		tabs, _ := a.groupTabs(g.ID)
		if i := slices.IndexFunc(tabs, func(s shownTab) bool { return s.member() == member }); i >= 0 {
			a.closeTab(tabs[i])
		}
	}
}

// setTabPinned pins or unpins the tab of document d in group; Core keeps the pin. A pinned
// tab moves to the end of the pinned tabs at the front of the group; an unpinned one to just
// after them.
func (a *App) setTabPinned(p *project, group string, d *document, pinned bool) {
	action := "editor.tabs.unpin"
	if pinned {
		action = "editor.tabs.pin"
	}
	a.performed(action, surfaceMenu)
	member := documentMember(d.id)
	if !a.reduceTerminals(p, p.terms.bench, core.PinEditor(group, member, pinned)) {
		return
	}
	g := p.terms.bench.Group(group)
	if g == nil {
		return
	}
	front := 0
	for _, m := range g.Members {
		if m != member && g.IsPinned(m) {
			front++
		}
	}
	a.reduceTerminals(p, p.terms.bench, core.DropEditorTab(core.EditorDrop{
		Member: member, Target: core.JoinEditorGroup(group, front), Docked: dockedGroups, Dockable: dockable(member),
	}))
}
