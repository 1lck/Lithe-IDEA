package workbench

import (
	"context"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/1lck/Lithe-IDEA/desktop/internal/termview"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The names the kernel's tab groups and their members go by, and the sizes of a terminal's
// tab.
const (
	// toolGroup is the tab group of the Terminal tool window. It is the only group the
	// kernel keeps when it is empty, because the tool window stays where it is.
	toolGroup = "tool"
	// terminalMemberPrefix starts the member name of a terminal in a group: "terminal:3".
	terminalMemberPrefix = "terminal:"
	// editorGroupPrefix starts the name of a group of the editor area: "editor:2".
	editorGroupPrefix = "editor:"

	// terminalChipMinWidth and terminalChipMaxWidth bound the width of a tab, which is
	// otherwise the width of its title.
	terminalChipMinWidth = 72
	terminalChipMaxWidth = 168
	// terminalChipIcon is the size of the icon in a tab, and terminalChipGap the room
	// between the icon, the title and the close button.
	terminalChipIcon = 14
	terminalChipGap  = 6
	// terminalCloseSize is the side of a tab's close button and terminalCloseIcon the size
	// of the cross in it.
	terminalCloseSize = 20
	terminalCloseIcon = 12
	// terminalFocusFrames is how many frames a request to give a terminal the keyboard waits
	// for the terminal to be painted before it is given up. A terminal moved to another
	// group is painted again within a frame or two, once the layout has settled.
	terminalFocusFrames = 3
)

// The identities of the terminals' controls. Each is a scope whose At(n) is the control of
// the terminal with id n, so a terminal keeps its identity wherever it is moved.
var (
	// termTabs identifies the tab of a terminal, termClose its close button, termGrids its
	// character grid (which holds the keyboard focus) and termBars its scrollbar.
	termTabs  = tree.Sub(shellPage, tree.Name("terminal-tabs"))
	termClose = tree.Sub(shellPage, tree.Name("terminal-close"))
	termGrids = tree.Sub(shellPage, tree.Name("terminal-grids"))
	termBars  = tree.Sub(shellPage, tree.Name("terminal-bars"))
	// termNew identifies the button that opens another terminal. termTabMore and
	// termTabScrollbar are the button that lists the tool window's hidden tabs and the
	// scrollbar of its strip.
	termNew          = tree.ID(shellPage, "terminal-new")
	termTabMore      = tree.ID(shellPage, "terminal-tab-more")
	termTabScrollbar = tree.ID(shellPage, "terminal-tab-scrollbar")
)

// terminal is one shell of a project: the view that draws it and what the tabs call it.
type terminal struct {
	// id identifies the terminal for as long as the project is open. It is never reused, so
	// a hit or a kernel member that names it can never reach a later terminal.
	id int
	// number is the n of the title "Local (n)": the lowest number no other terminal of the
	// project has, so a closed terminal's number is handed out again.
	number int
	// shell is the program the terminal runs, as it was asked for: a path from the
	// new-terminal menu or the Terminal setting, or empty for the user's login shell.
	shell string
	view  *termview.View
}

// terminalSet is the terminals of a project and where each one is placed. The zero value is
// a project with no terminal and is safe to use.
type terminalSet struct {
	// list is every terminal, in the order they were opened, wherever it is placed.
	list []*terminal
	// next, nextGroup and nextNode are the last terminal id, editor group number and split
	// node id handed out.
	next, nextGroup, nextNode int
	// bench is the kernel's state of the tab groups: the Terminal tool window's group and
	// the groups of the editor area, with the terminals as members.
	bench core.EditorWorkbench
	// layout says how the editor area divides its room among its groups. It is nil while the
	// editor has no group.
	layout *splitNode
}

// find is the terminal with id, and nil when there is none.
func (s *terminalSet) find(id int) *terminal {
	for _, t := range s.list {
		if t.id == id {
			return t
		}
	}
	return nil
}

// freeNumber is the lowest positive number that no terminal's title uses.
func (s *terminalSet) freeNumber() int {
	n := 1
	for slices.ContainsFunc(s.list, func(t *terminal) bool { return t.number == n }) {
		n++
	}
	return n
}

// selected is the terminal group shows, and nil when the group is gone or shows none.
func (s *terminalSet) selected(group string) *terminal {
	g := s.bench.Group(group)
	if g == nil {
		return nil
	}
	if id, ok := memberTerminal(g.Selected); ok {
		return s.find(id)
	}
	return nil
}

// terminalMember is the name of terminal id as a member of a tab group.
func terminalMember(id int) string { return terminalMemberPrefix + strconv.Itoa(id) }

// memberTerminal is the terminal id a group member names, and false for a member that does
// not name one.
func memberTerminal(member string) (int, bool) {
	rest, ok := strings.CutPrefix(member, terminalMemberPrefix)
	if !ok {
		return 0, false
	}
	id, err := strconv.Atoi(rest)
	return id, err == nil && id > 0
}

// editorGroupID is the name of the n-th group the editor area has made.
func editorGroupID(n int) string { return editorGroupPrefix + strconv.Itoa(n) }

// emptyPolicy says what the kernel does with group when a move or a close leaves it empty:
// the Terminal tool window stays, and a group of the editor area goes away, together with
// its place in the split layout.
func emptyPolicy(group string) core.EmptyGroups {
	if group == toolGroup {
		return core.KeepEmptyGroups
	}
	return core.RemoveEmptyGroups
}

// tabActionKind is what a click on the terminals' controls asks for.
type tabActionKind uint8

const (
	// actionSelect shows the terminal of the clicked tab.
	actionSelect tabActionKind = iota
	// actionClose closes the terminal of the clicked tab.
	actionClose
	// actionNew opens another terminal in the Terminal tool window, running the action's
	// shell, or the Terminal setting's when the action names none.
	actionNew
	// actionSelectDocument and actionCloseDocument show and close the open file of the
	// clicked tab; the action's term is then the document's id.
	actionSelectDocument
	actionCloseDocument
)

// tabAction is a click recorded while the frame was declared. It is done after the frame
// is painted, because it changes the groups the frame was declared from.
type tabAction struct {
	kind  tabActionKind
	term  int
	shell string
}

// tabDecl is a terminal's tab as the frame declared it.
type tabDecl struct {
	term int
	box  ui.Box
}

// groupDecl is a tab group as the frame declared it: the boxes of its strip of tabs and of
// its body, and which terminal its body shows. A box is read only when its flag says the
// frame declared it, because the zero Box has no node behind it.
type groupDecl struct {
	id string
	// tool says the group is the Terminal tool window.
	tool              bool
	strip, body       ui.Box
	stripSet, bodySet bool
	tabs              []tabDecl
	selected          *terminal
	// doc is the open file the group shows instead, and nil when it shows a terminal.
	doc *document

	// What a group's strip declared for captureStrips (see tabstrip.go). state is the
	// strip's remembered state and current the member the group selects. chips are all its
	// tabs, files' included. view is the part of the strip that shows the tabs and content
	// the row of them inside it, which scrolls; more is the button that lists the hidden
	// tabs. A box is read only when its flag says it was declared.
	state            *tabStrip
	current          string
	chips            []chipDecl
	view, content    ui.Box
	more             ui.Box
	viewSet, moreSet bool
}

// place is where the group was laid out, for a drag to aim at.
func (g *groupDecl) place() dropPlace {
	p := dropPlace{group: g.id, tool: g.tool, tabs: make([]tabSlot, 0, len(g.tabs))}
	if g.stripSet {
		p.strip = g.strip.Rect()
	}
	if g.bodySet {
		p.body = g.body.Rect()
	}
	for _, t := range g.tabs {
		p.tabs = append(p.tabs, tabSlot{term: t.term, rect: t.box.Rect()})
	}
	return p
}

// splitDraw is a container of the editor's split tree as the frame declared it: its box and
// the box of its first child, which is what settle needs to reconcile the splitter.
type splitDraw struct {
	node             *splitNode
	container, first ui.Box
}

// terminalUI is what the window keeps for the terminals besides the project's own state:
// what the frame being painted declared, and the gesture that drags a tab.
type terminalUI struct {
	// tool is the Terminal tool window's group, and toolDrawn says the frame declared it.
	tool      groupDecl
	toolDrawn bool
	// groups are the groups of the editor area the frame declared, in the order of the
	// split tree.
	groups []groupDecl
	// empty is the box of the editor while it has no group, and emptyDrawn says the frame
	// declared it.
	empty      ui.Box
	emptyDrawn bool
	// splits are the containers of the editor's split tree the frame declared.
	splits []splitDraw
	// places and emptyRect are where the last frame laid the groups and the empty editor out,
	// as plain rectangles: the drag aims at them between frames, when the boxes are gone.
	places    []dropPlace
	emptyRect gfx.Rect
	// actions are the clicks the frame recorded, done after it is painted.
	actions []tabAction
	// focus is the terminal and docFocus the document that is to receive the keyboard once it
	// is painted, at most one of them, and focusAge how many frames it has waited.
	focus, docFocus, focusAge int
	// autoFailed says opening a terminal for an open Terminal tool window with none failed, so
	// it is not tried again every frame. The next time the tool window is shown it is tried
	// afresh.
	autoFailed bool
	drag       tabDrag
	// strips is what each editor group's strip of tabs remembers between frames, by group
	// (see tabstrip.go). hiddenScratch, tabWidths and tabStarts are reused by every frame so
	// laying the strips out allocates nothing once they have grown.
	strips        map[string]*tabStrip
	hiddenScratch []string
	tabWidths     []float32
	tabStarts     []int
	// shells is the new-terminal menu of the Terminal tool window (see terminal_shells.go).
	shells shellMenu
}

// each calls fn for every group the frame declared: the Terminal tool window, if it was
// shown, and then the groups of the editor area.
func (u *terminalUI) each(fn func(*groupDecl)) {
	if u.toolDrawn {
		fn(&u.tool)
	}
	for i := range u.groups {
		fn(&u.groups[i])
	}
}

// openTerminals gives a project that is being opened its first terminal, in the Terminal
// tool window and shown. No shell starts yet: a terminal's shell starts when it is first
// painted, so a project whose terminal is never shown never runs one.
func (a *App) openTerminals(p *project) {
	a.term = terminalUI{}
	p.terms = terminalSet{}
	a.newTerminal(p, "")
}

// closeTerminals ends the shells of a project that is being closed and forgets where its
// terminals were.
func (a *App) closeTerminals(p *project) {
	if p == nil {
		return
	}
	for _, t := range p.terms.list {
		t.view.Close()
	}
	p.terms = terminalSet{}
	a.term = terminalUI{}
}

// beginTerminalFrame forgets what the last frame declared for the terminals, before the
// next one declares it afresh. The gesture that drags a tab is not part of a frame and is
// kept.
func (a *App) beginTerminalFrame() {
	u := &a.term
	u.tool = groupDecl{id: toolGroup, tool: true}
	u.toolDrawn = false
	u.groups = u.groups[:0]
	u.emptyDrawn = false
	u.splits = u.splits[:0]
	u.actions = u.actions[:0]
}

// drawTerminalTabs declares the tabs in the header of the Terminal tool window, after its
// title: a tab for each terminal and open file of the tool window's group, then the buttons
// that open another terminal, and the room left over. The tabs keep their width and, when
// they do not fit, scroll sideways in one row, whatever the editor's tab setting says, with a
// thin bar along their top and a button that lists the tabs out of sight, as an editor
// group's strip does (see drawGroupStrip). The strip is recorded as the place a dragged tab
// can join the group.
func (a *App) drawTerminalTabs(f *ui.Frame) {
	u := &a.term
	decl := &u.tool
	decl.state = u.stripOf(toolGroup)
	decl.state.seen = true
	tabs, current := a.groupTabs(toolGroup)
	decl.current = current
	decl.strip = f.Row().Fill().Items(ui.Center).Gap(chromeGap).Clip()
	decl.stripSet = true
	decl.strip.Children(func() {
		controls := stripControls{more: termTabMore, bar: termTabScrollbar, moreIcon: icons.Ellipsis}
		a.drawGroupStrip(f, decl, controls, tabs, tabsScroll, nil, func() {
			// A ui Button cannot show an icon in this version of Viva, so this is a hit row
			// with an icon, like the tool window's hide control.
			add := f.Row().Size(shellHideSize, shellHideSize).Shrink(0).Center().Radius(a.theme.Metrics.RadiusItem()).
				HitWith(termNew, a.text.Terminal.NewTab, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).
				Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
			add.Children(func() {
				f.Icon(icons.Plus).Size(shellIconSize, shellIconSize).Color(a.colors.Subtle).
					StateFrom(add).Hover(ui.Look{}.Color(a.colors.Text))
			})
			if add.Clicked() {
				u.actions = append(u.actions, tabAction{kind: actionNew})
			}
			a.drawShellMenuButton(f)
		})
		f.Spacer()
	})
}

// drawTerminal declares the body of the Terminal tool window: an empty box that fills the
// room under the header. The selected terminal paints into the box's rectangle after the
// frame is laid out (see paintTerminal), the way the commit rows are painted into the log's
// list. When every terminal was moved to the editor the body says so instead.
func (a *App) drawTerminal(f *ui.Frame) {
	u := &a.term
	set := &a.project.terms
	u.tool.selected = set.selected(toolGroup)
	body := f.Row().Fill().Background(a.colors.Editor)
	if u.tool.selected == nil && len(set.list) > 0 {
		body.Items(ui.Center).PadX(shellContentPad).Children(func() {
			f.Paragraph(a.text.Terminal.NoTerminals, 3).Grow(1).TextCenter().Color(a.colors.Subtle)
		})
	}
	u.tool.body, u.tool.bodySet, u.toolDrawn = body, true, true
}

// drawTerminalTab declares one terminal's tab: an icon, the title and a close button. The
// selected tab has the active background and the others a hover one; the tab being dragged
// is dimmed where it stands. A click on the tab or on its close button is recorded for
// paintTerminal to do. pos is the tab's place among size tabs, for assistive technology.
func (a *App) drawTerminalTab(f *ui.Frame, t *terminal, selected bool, pos, size int) tabDecl {
	u := &a.term
	title := a.text.Terminal.Tab(t.number)
	chip := f.Row().Height(rowHeight).Items(ui.Center).Gap(terminalChipGap).PadSides(0, 2, 0, 8).
		MinWidth(terminalChipMinWidth).MaxWidth(terminalChipMaxWidth).Shrink(1).
		Radius(a.theme.Metrics.RadiusItem()).
		HitWith(termTabs.At(t.id), title, gfx.HitOptions{
			Role:     gfx.RoleTab,
			Cursor:   gfx.PointerCursorHand,
			Selected: selected,
			Hint:     a.text.Tools.DragHint,
			PosInSet: int32(pos + 1),
			SetSize:  int32(size),
		}).
		Pressed(ui.Look{}.Background(a.colors.Active))
	if selected {
		chip = chip.Background(a.colors.Active)
	} else {
		chip = chip.Hover(ui.Look{}.Background(a.colors.Hover))
	}
	if u.drag.active && u.drag.term == t.id {
		chip = chip.Opacity(chromeDragDim)
	}
	var closeButton ui.Box
	chip.Children(func() {
		f.Icon(icons.SquareTerminal).Size(terminalChipIcon, terminalChipIcon).Shrink(0).Color(a.colors.Subtle)
		label := f.Text(title).Ellipsis()
		if selected {
			label.Color(a.colors.Text)
		} else {
			label.Color(a.colors.Subtle).StateFrom(chip).Hover(ui.Look{}.Color(a.colors.Text))
		}
		closeButton = f.Row().Size(terminalCloseSize, terminalCloseSize).Shrink(0).Center().
			Radius(a.theme.Metrics.RadiusItem()).
			HitWith(termClose.At(t.id), a.text.Terminal.CloseTab, gfx.HitOptions{Role: gfx.RoleButton, Cursor: gfx.PointerCursorHand}).
			Hover(ui.Look{}.Background(a.colors.Hover)).Pressed(ui.Look{}.Background(a.colors.Active))
		closeButton.Children(func() {
			f.Icon(icons.X).Size(terminalCloseIcon, terminalCloseIcon).Color(a.colors.Subtle).
				StateFrom(closeButton).Hover(ui.Look{}.Color(a.colors.Text))
		})
	})
	switch {
	case closeButton.Clicked():
		u.actions = append(u.actions, tabAction{kind: actionClose, term: t.id})
	case chip.Clicked():
		u.actions = append(u.actions, tabAction{kind: actionSelect, term: t.id})
	}
	return tabDecl{term: t.id, box: chip}
}

// captureTerminals reads what the frame that was just laid out gave the terminals: where
// each group and the empty editor are, which is what the drag aims at, and how much room
// each split gave its first child.
func (a *App) captureTerminals() bool {
	u := &a.term
	u.places = u.places[:0]
	u.each(func(g *groupDecl) { u.places = append(u.places, g.place()) })
	u.emptyRect = gfx.Rect{}
	if u.emptyDrawn {
		u.emptyRect = u.empty.Rect()
	}
	for _, s := range u.splits {
		s.node.settle(s.container.Rect(), s.first.Rect())
	}
	if !u.toolDrawn {
		u.autoFailed = false
	}
	u.endShellMenuFrame()
	return a.captureStrips()
}

// paintTerminal paints the shown terminals into the boxes the frame declared for them and
// then does the clicks it recorded. A group that has no room, or is not in the frame because
// its tool window is hidden, paints nothing and declares no hit, so a hidden terminal takes
// no pointer or keyboard events.
//
// A Terminal tool window that is open with no terminal anywhere gets one: the user closed
// the last tab, hid the window and showed it again, or a failed start left it empty.
func (a *App) paintTerminal(canvas *gfx.Canvas) {
	p := a.project
	if p == nil {
		return
	}
	u := &a.term
	set := &p.terms
	if a.captureTerminals() {
		// A strip of tabs scrolled, or what it hides changed: the frame that shows it is
		// declared from what was just captured.
		canvas.RequestFrame()
	}
	if u.toolDrawn && len(set.list) == 0 && !u.autoFailed {
		if t := a.newTerminal(p, ""); t != nil {
			a.focusTerminal(t.id)
			canvas.RequestFrame()
		} else {
			u.autoFailed = true
		}
	}

	// The words are handed over each frame so a change of language reaches the terminals at
	// once; what a terminal already wrote into its grid stays in the language it was
	// written in.
	messages, look, editorLook := a.terminalMessages(), a.terminalLook(), a.editorLook()
	editorWords := a.editorMessages()
	u.each(func(g *groupDecl) {
		if !g.bodySet {
			return
		}
		rect := g.body.Rect()
		if rect.Width <= 0 || rect.Height <= 0 {
			return
		}
		if d := g.doc; d != nil {
			// The minimap's button was declared by the last paint; its click turns the minimap
			// of every view off or on, so the views painted after it in this frame follow too.
			if canvas.Clicked(docMinimapToggle.At(d.id)) {
				a.toggleMinimap(canvas)
			}
			d.view.SetWrap(a.softWrap)
			d.view.SetMinimap(!a.settings.HideMinimap)
			d.view.SetMessages(editorWords)
			d.view.Paint(canvas, rect, editorLook)
			hit := docViews.At(d.id)
			if canvas.Focused() == hit {
				p.docs.group = g.id
			}
			if u.docFocus == d.id {
				canvas.RequestFocus(hit)
				p.docs.group = g.id
				u.docFocus = 0
			}
			return
		}
		t := g.selected
		if t == nil {
			return
		}
		t.view.SetMessages(messages)
		t.view.Paint(canvas, rect, look)
		if u.focus == t.id {
			canvas.RequestFocus(termGrids.At(t.id))
			u.focus = 0
		}
	})
	if u.focus != 0 || u.docFocus != 0 {
		// The terminal or the file was not painted: it is behind another tab, or its group
		// has no room yet. Give it a few frames to appear before the request is dropped.
		u.focusAge++
		if u.focusAge > terminalFocusFrames {
			u.focus, u.docFocus = 0, 0
		}
	}

	if len(u.actions) == 0 {
		return
	}
	for _, action := range u.actions {
		switch action.kind {
		case actionSelect:
			a.selectTerminal(p, action.term)
		case actionClose:
			a.closeTerminal(p, action.term)
		case actionNew:
			if t := a.newTerminal(p, action.shell); t != nil {
				a.focusTerminal(t.id)
			}
		case actionSelectDocument:
			a.selectDocument(p, action.term)
		case actionCloseDocument:
			a.closeDocument(p, action.term)
		}
	}
	u.actions = u.actions[:0]
	canvas.RequestFrame()
}

// focusTerminal asks for the keyboard to go to terminal id as soon as it is painted, which
// is what a person who just picked, opened or moved a terminal expects to type into.
func (a *App) focusTerminal(id int) {
	a.term.focus, a.term.focusAge = id, 0
	a.term.docFocus = 0
}

// reduceTerminals applies action to state through the kernel and, if the kernel accepts
// it, makes the result the project's tab groups. A group the kernel removed leaves the split
// layout with it, so the layout never shows a group that does not exist. It reports whether
// the state changed; on an error nothing is changed and the notice banner says why.
func (a *App) reduceTerminals(p *project, state core.EditorWorkbench, action core.EditorAction) bool {
	ctx, cancel := context.WithTimeout(context.Background(), kernelCallTimeout)
	defer cancel()
	next, removed, err := a.kernel.ReduceEditorWorkbench(ctx, state, action)
	if err != nil {
		a.notify(a.text.Errors.Core(err.Error()))
		return false
	}
	set := &p.terms
	set.bench = next
	for _, group := range removed {
		set.layout = removeLeaf(set.layout, group)
	}
	return true
}

// newTerminal opens a terminal at the end of the Terminal tool window's tabs and shows it,
// running shell, or the shell the Terminal setting names when shell is empty, or the user's
// login shell when that is empty too. It is nil when the kernel refuses. Opening it starts nothing: its shell starts when it is
// first painted. The shell's output arrives on another goroutine, and Invalidate is what
// wakes the window to take it in (see pumpTerminal).
//
// The tool window's group is made if the state has none, so a project is never without
// the group the tool window's tabs are listed in.
func (a *App) newTerminal(p *project, shell string) *terminal {
	if shell == "" {
		shell = a.settings.TerminalShell
	}
	set := &p.terms
	state := set.bench
	if state.Group(toolGroup) == nil {
		state.Groups = append(slices.Clone(state.Groups), core.EditorGroup{ID: toolGroup})
	}
	id := set.next + 1
	if !a.reduceTerminals(p, state, core.OpenEditor(toolGroup, terminalMember(id), true)) {
		return nil
	}
	set.next = id
	t := &terminal{
		id:     id,
		number: set.freeNumber(),
		shell:  shell,
		view: termview.New(termview.Config{
			Dir:      p.root,
			Shell:    shell,
			HitID:    termGrids.At(id),
			BarID:    termBars.At(id),
			Messages: a.terminalMessages(),
			Notify:   a.invalidator.Invalidate,
			Failed:   a.terminalFailed,
		}),
	}
	set.list = append(set.list, t)
	return t
}

// closeTerminal ends terminal id's shell and removes its tab. The group shows the
// neighbouring tab instead and gives it the keyboard. A group of the editor that this
// leaves empty goes, with its place in the layout. When no terminal is left the Terminal
// tool window is hidden, and showing it again opens a new one (see paintTerminal).
func (a *App) closeTerminal(p *project, id int) {
	set := &p.terms
	t := set.find(id)
	if t == nil {
		return
	}
	member := terminalMember(id)
	g := set.bench.GroupOf(member)
	if g == nil {
		return
	}
	group := g.ID
	if !a.reduceTerminals(p, set.bench, core.CloseEditor(group, member, emptyPolicy(group), core.SelectAdjacent)) {
		return
	}
	t.view.Close()
	set.list = slices.DeleteFunc(set.list, func(x *terminal) bool { return x.id == id })
	if next := set.selected(group); next != nil {
		a.focusTerminal(next.id)
	}
	if len(set.list) == 0 {
		a.reduceChrome(core.SetChromeOpen(itemTerminal, false))
	}
}

// selectTerminal shows terminal id in its group and gives it the keyboard.
func (a *App) selectTerminal(p *project, id int) {
	set := &p.terms
	member := terminalMember(id)
	g := set.bench.GroupOf(member)
	if g == nil {
		return
	}
	if g.Selected != member && !a.reduceTerminals(p, set.bench, core.ActivateEditor(g.ID, member)) {
		return
	}
	a.focusTerminal(id)
}

// dropTerminal does what dropping terminal id on target asks for, and gives the terminal
// the keyboard if it was done: a tab dropped on a strip or on the middle of a group joins
// it, one dropped near the edge of a group splits it, and one dropped on an empty editor
// opens the first group. A target that is no place does nothing.
func (a *App) dropTerminal(id int, target dropTarget) {
	p := a.project
	if p == nil {
		return
	}
	done := false
	switch target.kind {
	case dropJoin:
		done = a.moveTerminal(p, id, target.group, target.index)
	case dropSplit:
		done = a.splitTerminal(p, id, target.group, target.edge)
	case dropEmpty:
		done = a.placeInEmptyEditor(p, id)
	}
	if done {
		a.focusTerminal(id)
	}
}

// moveTerminal puts terminal id into group as the tab at index, counted among the group's
// tabs without it, and shows it there. Inside its own group that reorders the tabs. It
// reports whether the kernel accepted the move.
func (a *App) moveTerminal(p *project, id int, group string, index int) bool {
	set := &p.terms
	member := terminalMember(id)
	src, dest := set.bench.GroupOf(member), set.bench.Group(group)
	if src == nil || dest == nil {
		return false
	}
	if src.ID == group {
		at := slices.Index(src.Members, member)
		index = min(max(index, 0), len(src.Members)-1)
		if at >= 0 && at != index && !a.reduceTerminals(p, set.bench, core.ReorderEditor(group, at, index)) {
			return false
		}
		return a.reduceTerminals(p, set.bench, core.ActivateEditor(group, member))
	}
	before := ""
	if index = max(index, 0); index < len(dest.Members) {
		before = dest.Members[index]
	}
	return a.reduceTerminals(p, set.bench, core.MoveEditor(core.EditorMove{
		Member: member, From: src.ID, To: group, Before: before, Activate: true,
		Empty: emptyPolicy(src.ID), Fallback: core.SelectAdjacent,
	}))
}

// moveIntoNewGroup moves terminal id into a group of the editor area that it makes, and
// returns the new group's name. The caller gives the group its place in the layout. The
// group it left goes if that leaves it empty, which the layout follows.
func (a *App) moveIntoNewGroup(p *project, id int) (string, bool) {
	set := &p.terms
	member := terminalMember(id)
	src := set.bench.GroupOf(member)
	if src == nil {
		return "", false
	}
	from := src.ID
	added := editorGroupID(set.nextGroup + 1)
	state := set.bench
	state.Groups = append(slices.Clone(state.Groups), core.EditorGroup{ID: added})
	if !a.reduceTerminals(p, state, core.MoveEditor(core.EditorMove{
		Member: member, From: from, To: added, Activate: true,
		Empty: emptyPolicy(from), Fallback: core.SelectAdjacent,
	})) {
		return "", false
	}
	set.nextGroup++
	return added, true
}

// splitTerminal moves terminal id into a new group beside the group target, on the side e
// names. Whether it can is checked before anything changes, so the layout never gets a
// group the state does not have: target must be in the layout, and a group's only tab
// cannot split off its own group, since nothing would be left to split from.
func (a *App) splitTerminal(p *project, id int, target string, e edge) bool {
	set := &p.terms
	src := set.bench.GroupOf(terminalMember(id))
	if src == nil || e == edgeNone || !set.layout.contains(target) {
		return false
	}
	if src.ID == target && len(src.Members) < 2 {
		return false
	}
	added, ok := a.moveIntoNewGroup(p, id)
	if !ok {
		return false
	}
	set.nextNode++
	set.layout = splitLeaf(set.layout, target, added, e, set.nextNode)
	return true
}

// placeInEmptyEditor moves terminal id into the first group of an editor that has none,
// which then fills the editor.
func (a *App) placeInEmptyEditor(p *project, id int) bool {
	set := &p.terms
	if set.layout != nil {
		return false
	}
	added, ok := a.moveIntoNewGroup(p, id)
	if !ok {
		return false
	}
	set.layout = newLeaf(added)
	return true
}
