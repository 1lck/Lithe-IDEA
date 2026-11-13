package workbench

import (
	"strconv"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// editorGroups declares the editor area as its tree of groups and reports whether there is
// one. With no tree the editor is empty, and editorArea declares what an empty editor shows
// instead.
func (a *App) editorGroups(c ui.C) bool {
	p := a.project
	if p == nil || p.terms.layout == nil {
		return false
	}
	a.editorNode(c, p.terms.layout).Fill()
	return true
}

// editorNode declares a node of the editor's tree: a group for a leaf, or for a container its
// two children with a splitter between them. The splitter is declared right after the first
// child and before the second, as Viva wants.
//
// The splitter keeps the share the first child takes of the container (its Ratio), so a
// window resized in either direction keeps the proportion, and a share that was chosen in a
// larger window never pushes the second child out of a smaller one: both children keep the
// least size of a group, which is also the splitter's own limit.
func (a *App) editorNode(c ui.C, n *splitNode) ui.Box {
	if n.leaf() {
		return a.editorGroup(c, n.group)
	}
	least := float32(editorGroupMinHeight)
	declare := ui.Column
	if n.row {
		least = editorGroupMinWidth
		declare = ui.Row
	}
	if n.state.Ratio <= 0 {
		n.state.Ratio = 0.5
	}
	var first, second ui.Box
	container := declare(c.KeyInt(n.id)).Clip().Children(func() {
		first = a.editorNode(c, n.first)
		ui.Splitter(c, &n.state).Mins(least, least).Label(a.text.Panel.Resize)
		second = a.editorNode(c, n.second)
	})
	if n.row {
		first.FillHeight().MinWidth(least).Shrink(1)
		second.Fill().MinWidth(least)
	} else {
		first.FillWidth().MinHeight(least).Shrink(1)
		second.Fill().MinHeight(least)
	}
	return container
}

// editorGroup declares one group of the editor: a strip of its tabs over a body that shows
// the selected file or terminal. The group is recorded for the drag, which aims at the strip
// and the body. A group that shows an open file ends its strip with the soft wrap switch, after
// the switch of a Markdown file's view.
func (a *App) editorGroup(c ui.C, id string) ui.Box {
	u := &a.term
	place := newGroupPlace(id, false)
	u.groups = append(u.groups, place)
	p := a.project
	doc := p.selectedDocument(id)
	return ui.Column(c.Key(id)).Background(a.colors.Editor).Clip().Children(func() {
		layout := a.tabLayout()
		strip := ui.Row(c).FillWidth().Shrink(0).Items(ui.Start).Gap(chromeGap).PadX(chromeGap).Background(a.colors.Panel).Clip()
		if layout != tabsRows {
			strip.Height(panelHeaderHeight)
		}
		strip.Draw(place.stripHook).Children(func() {
			// The tabs fill the strip and give up their room before the buttons do, so they
			// stay at the end of the strip's first row however many files are open.
			a.tabBar(c, place, layout, func() {
				if isMarkdownDocument(doc) {
					a.markdownModeSwitch(c, doc)
				}
				if doc != nil {
					a.softWrapSwitch(c)
				}
			})
		})
		if doc != nil && doc.conflicted {
			a.documentConflict(c, doc)
		}
		ui.Column(c).Fill().Draw(place.bodyHook).Children(func() {
			a.groupBody(c, id, doc)
		})
	})
}

// groupBody declares the body of group id: the control of the file it shows (a Markdown file
// with its rendered page), of the Diff tab, or of the terminal.
func (a *App) groupBody(c ui.C, id string, doc *document) {
	if isMarkdownDocument(doc) {
		a.markdownDocument(c, a.project, id, doc)
		return
	}
	if doc != nil {
		a.documentView(c, id, doc)
		return
	}
	if t := a.project.selectedDiff(id); t != nil {
		a.diffView(c, a.project, t)
		return
	}
	if t := a.project.selectedViewer(id); t != nil {
		a.viewerView(c, t)
		return
	}
	if t := a.project.terms.selected(id); t != nil {
		a.terminalView(c, t)
	}
}

// softWrapSwitch declares the switch that turns soft wrapping of the open files on and off,
// at the end of the strip of a group that shows a file. It looks pressed while wrapping is
// on. The click takes effect in this paint, which sets every view it paints to the new state.
func (a *App) softWrapSwitch(c ui.C) {
	on := a.softWrap
	k := c.Part("wrap")
	button := ui.Row(k).Size(shellHideSize, shellHideSize).Shrink(0).Center().Radius(a.theme.Metrics.RadiusItem()).
		HitWith(ui.ID(k), a.text.Editor.SoftWrap, gfx.HitOptions{Role: gfx.RoleSwitch, Checked: on, Cursor: gfx.PointerCursorHand}).
		Pressed(ui.Look{}.Background(a.colors.Active))
	icon := a.colors.Subtle
	if on {
		button = button.Background(a.colors.Active)
		icon = a.colors.Text
	} else {
		button = button.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	button.Children(func() {
		ui.Icon(k, icons.WrapText).Size(shellIconSize, shellIconSize).Color(icon).
			StateFrom(button).Hover(ui.Look{}.Color(a.colors.Text))
	})
	if button.Clicked() {
		a.softWrap = !on
	}
}

// documentView declares the control of an open file in the group that shows it. The editor
// view paints into it and takes keys, pointer, wheel and typing through the document's
// handlers (see documentInput).
func (a *App) documentView(c ui.C, group string, d *document) {
	// A part names the next element only, so it is given again for the control: its identity is
	// the one the view paints its hits under.
	name := "doc" + strconv.Itoa(d.id)
	d.hit = ui.ID(c.Part(name))
	d.group = group
	box := ui.Control(c.Part(name), d.name, &d.input).Fill().Draw(d.draw)
	ui.FocusBind(box, &a.focus, focusTarget{doc: d.id})
	if p := a.project; p != nil {
		a.foldSync(c, p, d)
		a.linkSync(c, p, d)
	}
	if p := a.project; p != nil && !d.virtual {
		ui.ContextMenu(c.Key("menu"+name), box, a.editorMenuItems(c, p, d))
		at := d.actionPanel.menuAt
		ui.MenuAt(c.Key("lanemenu"+name), at.X, at.Y+at.Height, &d.actionPanel.menuOpen, a.editorActionLaneMenu(c, p, d))
		a.gitGutterPeek(c, p, d, box)
	}
}

// documentInput makes the handlers and the painter of document d, once, when it is opened.
func (a *App) documentInput(p *project, d *document) {
	d.input = ui.Handlers{
		Role:    gfx.RoleTerminal,
		Key:     func(event gfx.KeyEvent) gfx.EventResult { return a.documentKey(p, d, event) },
		Pointer: func(event gfx.PointerEvent) gfx.EventResult { return a.documentPointer(p, d, event) },
		Scroll: func(event gfx.ScrollEvent) gfx.EventResult {
			a.pluginSemanticsScrolled(d)
			result, _ := d.view.Scroll(event)
			return result
		},
		Text: d.view.TextInput,
	}
	d.draw = func(dc *ui.DrawContext) {
		v := d.view
		v.Bind(d.hit, d.input.Parts())
		// The minimap's button was declared by the last paint; its click turns the minimap of
		// every view off or on, so the views painted after it in this paint follow too.
		if dc.Canvas.Clicked(d.input.Parts().At(1)) {
			a.toggleMinimap(dc.Canvas)
		}
		v.SetFont(a.editorFont())
		v.SetWrap(a.softWrap)
		v.SetVimMode(a.settings.VimMode)
		v.SetMinimap(!a.settings.HideMinimap)
		v.SetMessages(a.editorMessages())
		v.SetGutterClick(!d.virtual && a.gitGutterEnabled(), func(click editorview.GutterClick) {
			a.gitGutterClicked(d, click)
		})
		v.SetGutterContext(func(line int) {
			a.gutterContextLine(d, line)
		})
		// The blame of the caret line is set before the view paints, so the annotation shown
		// belongs to the line the frame draws.
		a.applyInlineBlame(p, d)
		a.applyDebugGutter(p, d)
		v.Paint(dc.Canvas, dc.Rect, a.editorLook())
		if dc.State.Focused {
			p.docs.group = d.group
		}
	}
}

// documentKey gives a key pressed while the file's control has the keyboard to the language
// popups, the language shortcuts and the editor.
func (a *App) documentKey(p *project, d *document, event gfx.KeyEvent) gfx.EventResult {
	// A semantic request belongs to the caret it was placed at. Every key path ends here, so
	// one sync covers arrows, edits and commands.
	defer a.pluginSemanticsCaretSync()
	if result := a.pluginSemanticsKey(event); result.Handled {
		return result
	}
	if result, handled := a.pluginSemanticsTrigger(event, p, d); handled {
		return result
	}
	if result, handled := a.lineEditKey(p, d, event); handled {
		return result
	}
	if result, handled := d.view.Key(event); handled {
		return result
	}
	return gfx.EventResult{}
}

// documentPointer gives a pointer event of the file's control to the language popups and the
// editor: the press on a text and the moves and the release of the selection it starts,
// wherever they go.
func (a *App) documentPointer(p *project, d *document, event gfx.PointerEvent) gfx.EventResult {
	// A semantic popup or request belongs to the caret and symbol it was opened at; any
	// pointer work that moved either closes it before the frame paints.
	defer a.pluginSemanticsCaretSync()
	if result, handled := a.documentLinkPointer(event, d); handled {
		return result
	}
	if result, handled := a.pluginSemanticsPointer(event, p, d); handled {
		return result
	}
	result, _ := d.view.Pointer(event)
	return result
}

// terminalView declares the control of a terminal in the group or the tool window that shows
// it. The terminal paints into it and takes keys, pointer, wheel and typing through its
// handlers (see terminalInput).
func (a *App) terminalView(c ui.C, t *terminal) {
	name := "term" + strconv.Itoa(t.id)
	t.hit = ui.ID(c.Part(name))
	if t.find.open {
		ui.Column(c.Part(name + "-find")).Fill().Children(func() {
			a.terminalFindBar(c, t)
			box := ui.Control(c.Part(name), a.text.Terminal.Label, &t.input).Fill().Draw(t.draw)
			box.DropTarget(&a.dnd.tree, a.terminalTreeAccept, a.terminalTreeDrop)
			ui.FocusBind(box, &a.focus, focusTarget{term: t.id})
			a.terminalMenu(c, name, box, t)
		})
		return
	}
	box := ui.Control(c.Part(name), a.text.Terminal.Label, &t.input).Fill().Draw(t.draw)
	// A project tree row dropped on the terminal pastes its path (terminal_drop.go).
	box.DropTarget(&a.dnd.tree, a.terminalTreeAccept, a.terminalTreeDrop)
	ui.FocusBind(box, &a.focus, focusTarget{term: t.id})
	a.terminalMenu(c, name, box, t)
}

// terminalInput makes the handlers and the painter of terminal t, once, when it is opened.
func (a *App) terminalInput(t *terminal) {
	t.input = ui.Handlers{
		Role: gfx.RoleTerminal,
		Key: func(event gfx.KeyEvent) gfx.EventResult {
			// The terminal sees the release of a key as well: a program can ask for them.
			result, _ := t.view.Key(event)
			return result
		},
		Pointer: func(event gfx.PointerEvent) gfx.EventResult {
			result, _ := t.view.Pointer(event)
			return result
		},
		Scroll: func(event gfx.ScrollEvent) gfx.EventResult {
			result, _ := t.view.Scroll(event)
			return result
		},
		Text: t.view.TextInput,
	}
	t.draw = func(dc *ui.DrawContext) {
		t.view.Bind(t.hit, t.input.Parts())
		// The words are handed over each paint so a change of language reaches the terminals
		// at once; what a terminal already wrote into its grid stays in the language it was
		// written in.
		t.view.SetMessages(a.terminalMessages())
		t.view.SetFont(a.terminalFont())
		t.view.Paint(dc.Canvas, dc.Rect, a.terminalLook())
	}
}

// terminalTabs declares the tabs in the header of the Terminal tool window, after its title:
// a tab for each terminal and open file of the tool window's group, then the buttons that
// open another terminal. The tabs keep their width and, when they do not fit, scroll sideways
// in one row, whatever the editor's tab setting says, with a button that lists the tabs out
// of sight, as an editor group's strip does (see tabBar). The strip is recorded as the place
// a dragged tab can join the group.
func (a *App) terminalTabs(c ui.C) {
	u := &a.term
	place := newGroupPlace(toolGroup, true)
	u.tool, u.toolDrawn = place, true
	ui.Row(c).Grow(1).Shrink(1).MinWidth(0).Height(panelHeaderHeight).Items(ui.Center).Gap(chromeGap).Clip().Draw(place.stripHook).Children(func() {
		a.tabBar(c, place, tabsScroll, func() {
			if ui.Button(c.Part("new"), a.text.Terminal.NewTab).Icon(icons.Plus).IconOnly().Ghost().Size(shellHideSize, shellHideSize).Shrink(0).Clicked() {
				c.After(func() { a.openToolTerminal("") })
			}
			a.shellMenuButton(c)
		})
		ui.Spacer(c)
	})
}

// terminalToolBody declares the body of the Terminal tool window: the selected terminal's
// control, or the message that says every terminal was moved to the editor.
//
// A Terminal tool window that is open with no terminal anywhere gets one: the user closed the
// last tab, hid the window and showed it again, or a failed start left it empty.
func (a *App) terminalToolBody(c ui.C, p *project) {
	u := &a.term
	set := &p.terms
	place := u.tool
	if place == nil {
		return
	}
	t := set.selected(toolGroup)
	body := ui.Column(c).Fill().Background(a.colors.Editor).Draw(place.bodyHook)
	switch {
	case t != nil:
		body.Children(func() { a.terminalView(c, t) })
	case len(set.list) > 0:
		body.Items(ui.Center).PadX(shellContentPad).Children(func() {
			ui.Paragraph(c, a.text.Terminal.NoTerminals, 3).Grow(1).TextCenter().Color(a.colors.Subtle)
		})
	case !u.autoFailed:
		c.After(func() {
			if t := a.newTerminal(p, ""); t != nil {
				a.focusTerminal(t.id)
			} else {
				a.term.autoFailed = true
			}
		})
	}
}

// onShortcut is the window's base handler of chords: the chords of the shell go to the
// terminal that has the keyboard and the editor's chords (copy, cut, paste, select all, undo,
// redo and save) to the file that has it, since a Control's Handlers see keys but not the
// chords a window is offered as shortcuts. The window's own chords are declared in the page
// (see windowShortcuts).
func (a *App) onShortcut(event gfx.KeyEvent) gfx.EventResult {
	if !event.Release {
		if result := a.pluginSemanticsShortcut(event); result.Handled {
			return result
		}
	}
	if result := a.terminalFindShortcut(event); result.Handled {
		return result
	}
	if t := a.focusedTerminal(event.Target); t != nil {
		if result, handled := t.Shortcut(event); handled {
			return result
		}
	}
	if result := a.lineEditShortcut(event); result.Handled {
		return result
	}
	if v := a.focusedDocument(event.Target); v != nil {
		if result, handled := v.Shortcut(event); handled {
			return result
		}
	}
	return gfx.EventResult{}
}

// onKey is the window's base handler of keys: what a Page leaves to it. That is the arrow keys
// of a splitter that has the keyboard, which a Page does not route to the splitter, and the
// keys of the dialogs that move a selection of their own while a field has the keyboard.
func (a *App) onKey(event gfx.KeyEvent) gfx.EventResult {
	// A language popup closes on Escape and takes the arrows whatever has the keyboard, and a
	// Search Everywhere that is open takes its arrows and Enter from its query field.
	defer a.pluginSemanticsCaretSync()
	if result := a.pluginSemanticsKey(event); result.Handled {
		return result
	}
	if a.project != nil && a.everywhereView.open {
		if result := a.everywhereKey(a.project, event); result.Handled {
			return result
		}
	}
	if event.Release {
		return gfx.EventResult{}
	}
	if r := a.splitterKey(event); r.Handled {
		return r
	}
	return gfx.EventResult{}
}

// splitterKey gives a key press to the splitters of the workbench that the last paint
// declared; only the one that has the keyboard focus acts on it, and the size it chose is
// remembered at once.
func (a *App) splitterKey(event gfx.KeyEvent) gfx.EventResult {
	if r := a.layout.key(event); r.Handled {
		return r
	}
	if r := a.commitView.splitKey(event); r.Handled {
		return r
	}
	if r := a.worktreeView.commit.splitKey(event); r.Handled {
		return r
	}
	if r := a.logView.splitKey(event); r.Handled {
		return r
	}
	if p := a.project; p != nil {
		for _, view := range p.vcs.views {
			if r := view.commit.splitKey(event); r.Handled {
				return r
			}
		}
	}
	if p := a.project; p != nil && p.terms.layout != nil {
		if r := p.terms.layout.key(event); r.Handled {
			return r
		}
	}
	if p := a.project; p != nil {
		if r := p.panels.debugSplit.Key(event); r.Handled {
			return r
		}
	}
	return gfx.EventResult{}
}

// key gives a key press to the splitters of a split tree; only the one that has the
// keyboard focus acts on it.
func (n *splitNode) key(event gfx.KeyEvent) gfx.EventResult {
	if n == nil || n.leaf() {
		return gfx.EventResult{}
	}
	if r := n.state.Key(event); r.Handled {
		return r
	}
	if r := n.first.key(event); r.Handled {
		return r
	}
	return n.second.key(event)
}

// onScroll is the window's base handler of the wheel: any turn over a strip of tabs that does
// not fit scrolls the strip, and a sideways swipe over the project tree scrolls the tree, which
// Viva's Tree does not do itself.
func (a *App) onScroll(event gfx.ScrollEvent) gfx.EventResult {
	if p := a.project; p != nil {
		if result := a.term.stripWheel(event); result.Handled {
			return result
		}
		return p.tree.wheel(event)
	}
	return gfx.EventResult{}
}

// verticalWheel adjusts a wheel turn for the lists and the trees of the page: Viva's List
// scrolls sideways by any horizontal part of a swipe, so one that is mostly vertical loses
// its horizontal part, as the lists of the tool windows always did. The editor and the
// terminals are given the wheel as it came.
func verticalWheel(event *gfx.ScrollEvent) {
	if event.Modifiers&gfx.ModifierShift == 0 && max(event.DeltaX, -event.DeltaX) < max(event.DeltaY, -event.DeltaY) {
		event.DeltaX = 0
	}
}

// onPointer is the window's base handler of the pointer: a pointer that leaves the window
// closes the hover popup of the editor, which no control sees leave.
func (a *App) onPointer(event gfx.PointerEvent) gfx.EventResult {
	if event.Kind == gfx.PointerExit {
		a.closeSemanticHover()
		a.cancelSemanticKind(pluginSemanticHover)
	}
	return gfx.EventResult{}
}
