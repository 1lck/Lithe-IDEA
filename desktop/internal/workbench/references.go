package workbench

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"unicode/utf16"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// The References tool window: the answer of Find Usages laid out the way IntelliJ IDEA's Find
// tool window lays out its usages. A tree holds a Usages node over a node per file, each over
// its usages (the line number and the line, the found text in bold), and a read-only preview of
// the selected usage's file sits beside the tree with every usage in that file marked.
//
// Core normalizes the locations; this file groups them by file in the order the server gave
// them, lays the groups out as the tree's visible rows, reads the lines to show in the
// background (an open file's from its editor, a closed one's from disk, bounded), and opens a
// usage's file at its position.

const (
	// referencePreviewLimit bounds how much of one closed file is read to show its lines.
	referencePreviewLimit = 2 << 20
	// referencePreviewWidth cuts a shown line, in bytes, after it was cut in front of its usage.
	referencePreviewWidth = 240
	// referenceTreeWidth is the tree's width beside the preview until the user drags the
	// splitter; the tree and the preview keep at least their minimums while it is dragged.
	referenceTreeWidth  = 380
	referenceTreeMin    = 180
	referencePreviewMin = 200
)

// usageGroup is the references that lie in one file.
type usageGroup struct {
	// path is the file, empty for a location that is not a local file (a class in a jar).
	path string
	// display is the path relative to the project; name and dir are its base name and the
	// folder it is in, empty at the project's root.
	display, name, dir string
	// indices point into the state's targets.
	indices []int
	// collapsed hides the group's usages in the tree.
	collapsed bool
}

// referenceRowKind is what a row of the tree stands for.
type referenceRowKind uint8

const (
	referenceRowRoot referenceRowKind = iota
	referenceRowFile
	referenceRowUsage
)

// referenceRow is a visible row of the tree.
type referenceRow struct {
	kind  referenceRowKind
	group int
	// target indexes the state's targets on a usage row.
	target int
}

// referenceLine is a usage's line as its row shows it: without its indentation, cut in front of
// a far usage, and the UTF-16 range of the usage in what is left.
type referenceLine struct {
	text   string
	ranges []core.SearchNameRange
}

// referenceQuery is the document and position Find Usages was asked at, which Rerun asks again.
type referenceQuery struct {
	documentID   int
	line, column int
}

// referenceMarks is the view and the row the preview's marks were set for, so they are set once
// per change and not in every frame.
type referenceMarks struct {
	view *editorview.View
	key  int
}

// referencesState is the References tool window's answer and how it is shown.
type referencesState struct {
	project *project
	targets []core.PluginSemanticLocation
	groups  []usageGroup
	// groupOf is the group of each target, in step with targets.
	groupOf []int
	// lines is the line of each target, in step with targets; empty until read.
	lines      []referenceLine
	generation uint64
	// rows are the tree's visible rows; rootCollapsed hides everything under the Usages node.
	rows          []referenceRow
	rootCollapsed bool
	// selected is the key of the selected row; reveal asks the next frame to scroll it into view.
	selected int
	reveal   bool
	// focus is the keyboard focus the last frame saw, so only a move of it selects a row.
	focus gfx.ID
	view  ui.TreeState
	// hidePreview turns the preview off; it stays off for the next answers.
	hidePreview bool
	split       ui.SplitterState
	preview     sourcePreview
	marked      referenceMarks
	query       referenceQuery
	// symbol is the name that was searched for, shown on the header's tab.
	symbol string
}

// showReferences makes targets the contents of the References tool window and opens it, with
// the first usage selected. query is where they were asked for, and symbol the name there.
func (a *App) showReferences(p *project, targets []core.PluginSemanticLocation, query referenceQuery, symbol string) {
	s := &a.editor.refs
	if s.project != p {
		s.preview.close()
	}
	s.generation++
	s.project, s.targets, s.query, s.symbol = p, targets, query, symbol
	s.groups, s.groupOf = s.groups[:0], make([]int, len(targets))
	s.lines = make([]referenceLine, len(targets))
	s.rootCollapsed, s.marked = false, referenceMarks{}
	byPath := map[string]int{}
	for i, target := range targets {
		key := target.FilePath
		if key == "" {
			key = target.URI
		}
		g, ok := byPath[key]
		if !ok {
			display := key
			if rel, err := filepath.Rel(p.root, key); err == nil && !strings.HasPrefix(rel, "..") {
				display = rel
			}
			g = len(s.groups)
			byPath[key] = g
			s.groups = append(s.groups, newUsageGroup(target.FilePath, display))
		}
		s.groups[g].indices = append(s.groups[g].indices, i)
		s.groupOf[i] = g
	}
	s.layoutRows()
	s.selected, s.reveal = s.usageKey(0), true
	a.reduceChrome(core.SetChromeOpen(itemReferences, true))
	a.loadReferenceLines(p, s.generation)
}

// newUsageGroup is the group of the file at path, shown as display.
func newUsageGroup(path, display string) usageGroup {
	slashed := filepath.ToSlash(display)
	name, dir := slashed, ""
	if i := strings.LastIndexByte(slashed, '/'); i >= 0 {
		name, dir = slashed[i+1:], slashed[:i]
	}
	return usageGroup{path: path, display: display, name: name, dir: dir}
}

// closeReferences forgets the answer, as closing the header's tab does.
func (a *App) closeReferences() {
	s := &a.editor.refs
	s.preview.close()
	*s = referencesState{hidePreview: s.hidePreview, split: s.split, preview: s.preview, generation: s.generation + 1}
}

// rerunReferences asks for the usages again at the position they were asked at, while that
// document is open.
func (a *App) rerunReferences(p *project) {
	s := &a.editor.refs
	if d := s.queryDocument(p); d != nil {
		a.startPluginLocations(pluginSemanticReferences, p, d, s.query.line, s.query.column, false, false)
	}
}

// queryDocument is the open document the usages were asked in, or nil once it was closed.
func (s *referencesState) queryDocument(p *project) *document {
	if p == nil || s.project != p || s.query.documentID <= 0 {
		return nil
	}
	return p.docs.find(s.query.documentID)
}

// The keys of the rows: the Usages node is 0, a file's node follows, then the usages, so a row
// keeps its key while the nodes above it open and close.
func (s *referencesState) fileKey(group int) int   { return 1 + group }
func (s *referencesState) usageKey(target int) int { return 1 + len(s.groups) + target }

// key is the key of visible row i.
func (s *referencesState) key(i int) int {
	r := s.rows[i]
	switch r.kind {
	case referenceRowRoot:
		return 0
	case referenceRowFile:
		return s.fileKey(r.group)
	default:
		return s.usageKey(r.target)
	}
}

// layoutRows lays the tree's visible rows out again after a node opened or closed.
func (s *referencesState) layoutRows() {
	s.rows = append(s.rows[:0], referenceRow{kind: referenceRowRoot})
	if s.rootCollapsed {
		return
	}
	for g, group := range s.groups {
		s.rows = append(s.rows, referenceRow{kind: referenceRowFile, group: g})
		if group.collapsed {
			continue
		}
		for _, i := range group.indices {
			s.rows = append(s.rows, referenceRow{kind: referenceRowUsage, group: g, target: i})
		}
	}
}

// rowOf is the visible row of key, or -1 when it is hidden under a closed node.
func (s *referencesState) rowOf(key int) int {
	for i := range s.rows {
		if s.key(i) == key {
			return i
		}
	}
	return -1
}

// node describes visible row i to the Tree.
func (s *referencesState) node(i int) ui.TreeNode {
	r := s.rows[i]
	selected := s.key(i) == s.selected
	switch r.kind {
	case referenceRowRoot:
		return ui.TreeNode{Depth: 0, Branch: true, Expanded: !s.rootCollapsed, Selected: selected}
	case referenceRowFile:
		return ui.TreeNode{Depth: 1, Branch: true, Expanded: !s.groups[r.group].collapsed, Selected: selected}
	default:
		return ui.TreeNode{Depth: 2, Selected: selected}
	}
}

// toggle opens or closes the node of row i. The selection moves to the node when it was under it.
func (s *referencesState) toggle(i int) {
	if i < 0 || i >= len(s.rows) {
		return
	}
	switch r := s.rows[i]; r.kind {
	case referenceRowRoot:
		s.rootCollapsed = !s.rootCollapsed
	case referenceRowFile:
		s.groups[r.group].collapsed = !s.groups[r.group].collapsed
	default:
		return
	}
	key := s.key(i)
	s.layoutRows()
	if s.rowOf(s.selected) < 0 {
		s.selected = key
	}
}

// setExpanded opens or closes every file's node; the Usages node stays open so the files show.
// A usage that was selected hands the selection to its file when its node closes.
func (s *referencesState) setExpanded(expanded bool) {
	s.rootCollapsed = false
	for g := range s.groups {
		s.groups[g].collapsed = !expanded
	}
	s.layoutRows()
	if s.rowOf(s.selected) < 0 {
		if target, ok := s.selectedUsage(); ok {
			s.selected = s.fileKey(s.groupOf[target])
		} else {
			s.selected = 0
		}
	}
	s.reveal = true
}

// selectedUsage is the target of the selected row when it is a usage.
func (s *referencesState) selectedUsage() (int, bool) {
	target := s.selected - s.usageKey(0)
	return target, target >= 0 && target < len(s.targets)
}

// shownTarget is the usage the preview shows for the selected row: the usage itself, or the
// first usage of a file or of the whole answer.
func (s *referencesState) shownTarget() (int, bool) {
	switch {
	case len(s.groups) == 0 || s.selected < 0:
		return 0, false
	case s.selected == 0:
		return s.groups[0].indices[0], true
	case s.selected <= len(s.groups):
		return s.groups[s.selected-1].indices[0], true
	default:
		return s.selectedUsage()
	}
}

// stepTarget is the usage after the selected row in the tree's order, or before it when forward
// is false, counting the usages under closed nodes too, and false at either end. The toolbar asks
// it in every frame, so it walks the groups in place.
func (s *referencesState) stepTarget(forward bool) (int, bool) {
	// at is the place of the selection among the usages in the tree's order: a usage is on its
	// own place, and a file's node or the Usages node is just before the first usage under it.
	at, on, count := 0, false, 0
	target, usage := s.selectedUsage()
	for g, group := range s.groups {
		switch {
		case usage && s.groupOf[target] == g:
			at, on = count+slices.Index(group.indices, target), true
		case !usage && s.selected == s.fileKey(g):
			at = count
		}
		count += len(group.indices)
	}
	next := at - 1
	if forward {
		next = at
		if on {
			next = at + 1
		}
	}
	if next < 0 || next >= count {
		return 0, false
	}
	for _, group := range s.groups {
		if next < len(group.indices) {
			return group.indices[next], true
		}
		next -= len(group.indices)
	}
	return 0, false
}

// selectUsage selects the usage target, opening the nodes it lies under, and scrolls it into view.
func (s *referencesState) selectUsage(target int) {
	s.rootCollapsed = false
	s.groups[s.groupOf[target]].collapsed = false
	s.layoutRows()
	s.selected, s.reveal = s.usageKey(target), true
}

// stepReference selects the next or previous usage and opens it in the editor, as IDEA's Next
// and Previous Occurrence do.
func (a *App) stepReference(forward bool) {
	s := &a.editor.refs
	target, ok := s.stepTarget(forward)
	if !ok {
		return
	}
	s.selectUsage(target)
	a.openReference(s.targets[target])
}

// loadReferenceLines reads the line of every reference. An open file's lines come from its
// editor on the window thread, which only reads rope lines; closed files are read off it.
func (a *App) loadReferenceLines(p *project, generation uint64) {
	s := &a.editor.refs
	var closed []usageGroup
	for _, g := range s.groups {
		if g.path == "" {
			continue
		}
		if d := p.docs.byPath(g.path); d != nil {
			text := d.view.TextSnapshot()
			for _, i := range g.indices {
				if line := s.targets[i].Range.Start.Line; line >= 0 && line < text.LineCount() {
					s.lines[i] = referenceLineOf(text.Line(line), s.targets[i].Range)
				}
			}
			continue
		}
		closed = append(closed, g)
	}
	if len(closed) == 0 {
		return
	}
	targets := s.targets
	a.background(p, 0, func(context.Context) func(*App) {
		lines := make(map[int]referenceLine)
		for _, g := range closed {
			// A file that cannot be read keeps its rows without their lines.
			file := readLines(g.path, referencePreviewLimit)
			for _, i := range g.indices {
				if line := targets[i].Range.Start.Line; line >= 0 && line < len(file) {
					lines[i] = referenceLineOf(file[line], targets[i].Range)
				}
			}
		}
		return func(a *App) {
			s := &a.editor.refs
			if s.generation != generation || s.project != p {
				return
			}
			for i, line := range lines {
				if i < len(s.lines) {
					s.lines[i] = line
				}
			}
			a.invalidator.Invalidate()
		}
	})
}

// readLines is the lines of the file at path, read up to limit bytes; nil when it cannot be
// read.
func readLines(path string, limit int64) []string {
	file, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer file.Close()
	buf := make([]byte, limit)
	n, err := io.ReadFull(file, buf)
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, io.EOF) {
		return nil
	}
	return strings.Split(string(buf[:n]), "\n")
}

// referenceLineOf is the row text of a usage at at on line: without the indentation, cut in
// front of a far usage as the Find in Files rows are, and bounded, with the usage's range. A
// usage that runs past the line is marked to the line's end.
func referenceLineOf(line string, at core.PluginDocumentRange) referenceLine {
	line = strings.TrimSuffix(line, "\r")
	start := at.Start.UTF16Column
	end := at.End.UTF16Column
	if at.End.Line != at.Start.Line {
		end = len(utf16.Encode([]rune(line)))
	}
	var ranges []core.SearchNameRange
	if start >= 0 && end > start {
		ranges = []core.SearchNameRange{{Start: start, Length: end - start}}
	}
	text, ranges := previewAroundRanges(line, ranges)
	if len(text) > referencePreviewWidth {
		// Cut before the character the width falls in, not inside it.
		cut := referencePreviewWidth
		for cut > 0 && !utf8.RuneStart(text[cut]) {
			cut--
		}
		text = text[:cut]
	}
	return referenceLine{text: text, ranges: ranges}
}

// referenceRange is the byte range of a usage in view's text, and false when it is not there.
func referenceRange(view *editorview.View, at core.PluginDocumentRange) (editorview.Range, bool) {
	start, ok := view.ByteOffset(at.Start.Line, at.Start.UTF16Column)
	if !ok {
		return editorview.Range{}, false
	}
	end, ok := view.ByteOffset(at.End.Line, at.End.UTF16Column)
	if !ok || end < start {
		end = start
	}
	return editorview.Range{Start: start, End: end}, true
}

// syncReferencePreview makes the preview follow the selection: the shown usage's file, with every
// usage in it marked, the shown one selected and its line in the middle of the view. A location
// that is not a local file has no preview.
func (a *App) syncReferencePreview(p *project) {
	s := &a.editor.refs
	target, ok := s.shownTarget()
	if s.hidePreview || !ok {
		return
	}
	group := s.groups[s.groupOf[target]]
	if group.path == "" {
		if s.preview.path != "" || s.preview.view != nil {
			s.preview.close()
		}
		return
	}
	at := s.targets[target].Range
	a.showSourcePreview(p, &s.preview, group.path, at.Start.Line+1, func(a *App) bool {
		return a.editor.refs.project == p && !a.editor.refs.hidePreview
	})
	view := s.preview.view
	marks := referenceMarks{view: view, key: s.usageKey(target)}
	if view == nil || s.marked == marks {
		return
	}
	s.marked = marks
	matches := make([]editorview.Range, 0, len(group.indices))
	for _, i := range group.indices {
		if r, ok := referenceRange(view, s.targets[i].Range); ok {
			matches = append(matches, r)
		}
	}
	slices.SortFunc(matches, func(x, y editorview.Range) int { return x.Start - y.Start })
	view.SetSearchMatches(matches)
	if r, ok := referenceRange(view, at); ok {
		view.SetSelection(r.Start, r.End)
	}
	view.CenterLine(at.Start.Line)
}

// setReferencePreview turns the preview on or off; off releases its view.
func (a *App) setReferencePreview(show bool) {
	s := &a.editor.refs
	s.hidePreview = !show
	s.marked = referenceMarks{}
	if !show {
		s.preview.close()
	}
}

// openReference opens the file of a target at its position.
func (a *App) openReference(target core.PluginSemanticLocation) {
	a.openDefinitionTarget(target)
}
