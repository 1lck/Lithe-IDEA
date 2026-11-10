package workbench

import (
	"context"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
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
	// title replaces "Local (n)" on the tab; a plugin terminal sets it.
	title string
	// plugin is set when a plugin backend owns the terminal.
	plugin *pluginTerminal
	// input and draw are the Control's handlers and painter, made once with the terminal;
	// hit is the identity the paint declared it with.
	input ui.Handlers
	draw  func(*ui.DrawContext)
	hit   gfx.ID
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

// tabSlotDecl is where the tab of one terminal was laid out in the last paint.
type tabSlotDecl struct {
	term int
	rect gfx.Rect
}

// groupPlace is a tab group as the last paint declared it: where its strip of tabs and its
// body were laid out and where each terminal's tab is, which is what a drag is aimed against.
// The rectangles are written by draw hooks as the paint goes, so between paints they are
// those of the last complete one.
type groupPlace struct {
	id string
	// tool says the group is the Terminal tool window.
	tool        bool
	strip, body gfx.Rect
	chips       []tabSlotDecl
	stripHook   func(*ui.DrawContext)
	bodyHook    func(*ui.DrawContext)
}

func newGroupPlace(id string, tool bool) *groupPlace {
	g := &groupPlace{id: id, tool: tool}
	g.stripHook = func(d *ui.DrawContext) { g.strip = d.Rect }
	g.bodyHook = func(d *ui.DrawContext) { g.body = d.Rect }
	return g
}

// chipHook is the draw hook of the i-th terminal tab the group declared.
func (g *groupPlace) chipHook(i int) func(*ui.DrawContext) {
	return func(d *ui.DrawContext) { g.chips[i].rect = d.Rect }
}

// place is where the group was laid out, for a drag to aim at.
func (g *groupPlace) place() dropPlace {
	p := dropPlace{group: g.id, tool: g.tool, strip: g.strip, body: g.body, tabs: make([]tabSlot, 0, len(g.chips))}
	for _, t := range g.chips {
		p.tabs = append(p.tabs, tabSlot{term: t.term, rect: t.rect})
	}
	return p
}

// tabID is the identity a terminal's tab was declared with, which a drag maps its source
// back to the terminal by.
type tabID struct {
	id   gfx.ID
	term int
}

// focusTarget names what is to have the keyboard once it is on screen: a terminal or an open
// file, at most one of them; the zero value is nothing. It is the field a page's FocusBind
// ties the terminals' and the editors' controls to.
type focusTarget struct {
	term, doc int
}

// terminalUI is what the window keeps for the terminals besides the project's own state: what
// the last paint declared, and the gesture that drags a tab.
type terminalUI struct {
	// tool is the Terminal tool window's group, when the paint declared it, and groups the
	// groups of the editor area the paint declared in the order of the split tree.
	tool   *groupPlace
	groups []*groupPlace
	// emptyRect is where the editor was laid out while it had no group, the place a tab can
	// be dropped to open the first one; emptyDrawn says the paint declared it.
	emptyRect  gfx.Rect
	emptyDrawn bool
	emptyDraw  func(*ui.DrawContext)
	// tabIDs are the identities of the terminals' tabs the paint declared.
	tabIDs []tabID
	// autoFailed says opening a terminal for an open Terminal tool window with none failed, so
	// it is not tried again every frame. The next time the tool window is shown it is tried
	// afresh.
	autoFailed bool
	toolDrawn  bool
	drag       tabDrag
	// strips is what each editor group's strip of tabs remembers between paints, by group
	// (see tabstrip.go).
	strips map[string]*tabStrip
	// shells is the new-terminal menu of the Terminal tool window (see terminal_shells.go).
	shells shellMenu
}

// emptyHook records where the editor is laid out while it has no group.
func (u *terminalUI) emptyHook(box ui.Box) {
	if u.emptyDraw == nil {
		u.emptyDraw = func(d *ui.DrawContext) { u.emptyRect = d.Rect }
	}
	u.emptyDrawn = true
	box.Draw(u.emptyDraw)
}

// tabOf is the terminal whose tab was declared with id.
func (u *terminalUI) tabOf(id gfx.ID) (int, bool) {
	for _, t := range u.tabIDs {
		if t.id == id {
			return t.term, true
		}
	}
	return 0, false
}

// places are where the groups were laid out, the Terminal tool window first.
func (u *terminalUI) places() []dropPlace {
	places := make([]dropPlace, 0, len(u.groups)+1)
	if u.tool != nil {
		places = append(places, u.tool.place())
	}
	for _, g := range u.groups {
		places = append(places, g.place())
	}
	return places
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
		a.finishPluginTerminal(t, "closed", nil)
	}
	p.terms = terminalSet{}
	a.term = terminalUI{}
}

// beginTerminalFrame forgets what the last paint declared for the terminals, before the next
// one declares it afresh. The gesture that drags a tab is not part of a paint and is kept.
func (a *App) beginTerminalFrame() {
	u := &a.term
	u.tool = nil
	u.groups = u.groups[:0]
	u.tabIDs = u.tabIDs[:0]
	u.emptyDrawn = false
	u.toolDrawn = false
}

// endTerminalFrame settles what the paint declared: a Terminal tool window that was not shown
// tries afresh the next time, and the strips of groups that are gone are dropped.
func (a *App) endTerminalFrame() {
	u := &a.term
	if !u.toolDrawn {
		u.autoFailed = false
	}
	if !u.emptyDrawn {
		u.emptyRect = gfx.Rect{}
	}
	u.shells.endFrame()
	a.endStripFrame()
}

// focusTerminal asks for the keyboard to go to terminal id as soon as it is painted, which
// is what a person who just picked, opened or moved a terminal expects to type into.
func (a *App) focusTerminal(id int) { a.focus = focusTarget{term: id} }

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
	return a.newTerminalWith(p, terminalOptions{shell: shell, activate: true})
}

// terminalOptions say what a terminal runs and whether opening it takes the tab group's
// selection. A user's terminal leaves everything but shell unset.
type terminalOptions struct {
	shell string
	// args is the program's argument list: nil runs the shell menu's way, an empty
	// slice runs it with none.
	args       []string
	env, unset []string
	dir        string
	title      string
	prefill    string
	// activate selects the new tab; a background plugin terminal leaves the
	// selection where it was.
	activate bool
	plugin   *pluginTerminal
}

// newTerminalWith is newTerminal with the options of a plugin terminal.
func (a *App) newTerminalWith(p *project, options terminalOptions) *terminal {
	shell := options.shell
	if shell == "" && options.plugin == nil {
		shell = a.settings.TerminalShell
	}
	set := &p.terms
	state := set.bench
	if state.Group(toolGroup) == nil {
		state.Groups = append(slices.Clone(state.Groups), core.EditorGroup{ID: toolGroup})
	}
	id := set.next + 1
	if !a.reduceTerminals(p, state, core.OpenEditor(toolGroup, terminalMember(id), options.activate)) {
		return nil
	}
	set.next = id
	dir := options.dir
	if dir == "" {
		dir = p.root
	}
	config := termview.Config{
		Dir:      dir,
		Shell:    shell,
		Args:     options.args,
		Env:      options.env,
		Unset:    options.unset,
		Prefill:  options.prefill,
		Messages: a.terminalMessages(),
		Notify:   a.invalidator.Invalidate,
		Failed:   a.terminalFailed,
	}
	t := &terminal{id: id, number: set.freeNumber(), shell: shell, title: options.title, plugin: options.plugin}
	if options.plugin != nil {
		config.Exited = func(status *int) { a.pluginTerminalExited(p, t, status) }
	}
	t.view = termview.New(config)
	a.terminalInput(t)
	set.list = append(set.list, t)
	if options.plugin != nil {
		// A plugin asked for this program; it runs even while the tab is not on show.
		t.view.Start()
	}
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
	a.finishPluginTerminal(t, "closed", nil)
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

// terminalTitle is the name on a terminal's tab: the plugin's title, or "Local (n)".
func (a *App) terminalTitle(t *terminal) string {
	if t.title != "" {
		return t.title
	}
	return a.text.Terminal.Tab(t.number)
}
