package workbench

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

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
// Core groups the usages by file and orders them, lays the visible rows out under the nodes the
// user closed, moves a selection that a closed node hides, and says which usage each row shows
// and which usages come before and after it (lsp.references.query); it also cuts the usages'
// lines as their rows show them (lsp.references.lines). This file keeps which nodes are closed
// and which row is selected, reads the lines (an open file's from its editor, a closed one's
// from disk, bounded), and opens a usage's file at its position.

const (
	// referencePreviewLimit bounds how much of one closed file is read to show its lines.
	referencePreviewLimit = 2 << 20
	// referenceTreeWidth is the tree's width beside the preview until the user drags the
	// splitter; the tree and the preview keep at least their minimums while it is dragged.
	referenceTreeWidth  = 380
	referenceTreeMin    = 180
	referencePreviewMin = 200
)

// referenceQuery is the document and position Find Usages was asked at, which Rerun asks again.
type referenceQuery struct {
	documentID   int
	line, column int
}

// referenceMarks is the view and the usage the preview's marks were set for, so they are set
// once per change and not in every frame.
type referenceMarks struct {
	view   *editorview.View
	target int
}

// referencesState is the References tool window's answer and how it is shown.
type referencesState struct {
	project *project
	targets []core.PluginSemanticLocation
	// locations are the targets as Core groups them, in step with targets.
	locations []core.ReferenceLocation
	// groups and rows are Core's layout of the answer: the files, and the rows that show.
	groups []core.ReferenceGroup
	rows   []core.ReferenceRow
	// groupOf is the group of each target, in step with targets.
	groupOf []int
	// lines is the line of each target as its row shows it, in step with targets; empty until
	// read.
	lines      []core.ReferenceLine
	generation uint64
	// collapsed holds the fileKeys of the file nodes the user closed; rootCollapsed closes the
	// Usages node.
	collapsed     map[string]bool
	rootCollapsed bool
	// selected is the key of the selected row and selectedRow its place in rows, -1 for none;
	// reveal asks the next frame to scroll it into view.
	selected    string
	selectedRow int
	reveal      bool
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
	s.locations = make([]core.ReferenceLocation, len(targets))
	for i, target := range targets {
		s.locations[i] = referenceLocation(p.root, target)
	}
	s.lines = make([]core.ReferenceLine, len(targets))
	s.collapsed, s.rootCollapsed, s.selected, s.marked = nil, false, "", referenceMarks{}
	if !a.layoutReferences() {
		s.targets, s.locations, s.lines, s.groups, s.rows, s.selectedRow = nil, nil, nil, nil, nil, -1
		return
	}
	s.reveal = true
	a.reduceChrome(core.SetChromeOpen(itemReferences, true))
	a.loadReferenceLines(p, s.generation)
}

// referenceLocation is target as Core groups it: under its path, compared as this platform
// compares paths, or under its URI when it is not a local file; shown relative to the project
// root when it lies in it.
func referenceLocation(root string, target core.PluginSemanticLocation) core.ReferenceLocation {
	key, display := target.FilePath, target.URI
	if key == "" {
		key = target.URI
	} else {
		display = key
		if rel, err := filepath.Rel(root, key); err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			display = rel
		}
		display = filepath.ToSlash(display)
	}
	return core.ReferenceLocation{
		FileKey:     key,
		DisplayPath: display,
		Line:        max(target.Range.Start.Line, 0),
		Column:      max(target.Range.Start.UTF16Column, 0),
	}
}

// layoutReferences asks Core for the rows under the nodes that are closed and the selection
// that is kept. When Core fails it reports the failure and is false, and the rows stay.
func (a *App) layoutReferences() bool {
	s := &a.editor.refs
	collapsed := make([]string, 0, len(s.collapsed))
	for key := range s.collapsed {
		collapsed = append(collapsed, key)
	}
	slices.Sort(collapsed)
	ctx, cancel := context.WithTimeout(a.operationContext(context.Background()), kernelCallTimeout)
	defer cancel()
	result, err := a.kernel.QueryReferences(ctx, core.ReferencesQuery{
		Locations: s.locations, RootCollapsed: s.rootCollapsed, Collapsed: collapsed, Selected: s.selected,
	})
	if err != nil {
		a.operationFailed("references_query", err)
		a.notifyError(a.text.Errors.Core(err.Error()))
		return false
	}
	s.groups, s.rows, s.selected, s.selectedRow = result.Groups, result.Rows, result.Selected, -1
	if result.SelectedRow != nil {
		s.selectedRow = *result.SelectedRow
	}
	s.groupOf = make([]int, len(s.targets))
	for g, group := range s.groups {
		for _, i := range group.Indices {
			if i >= 0 && i < len(s.groupOf) {
				s.groupOf[i] = g
			}
		}
	}
	return true
}

// closeReferences forgets the answer, as closing the header's tab does.
func (a *App) closeReferences() {
	s := &a.editor.refs
	s.preview.close()
	*s = referencesState{hidePreview: s.hidePreview, split: s.split, preview: s.preview, generation: s.generation + 1, selectedRow: -1}
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

// key is the Tree's key of visible row i: the Usages node is 0, a file's node follows, then the
// usages, so a row keeps its key while the nodes above it open and close.
func (s *referencesState) key(i int) int {
	r := s.rows[i]
	switch r.Kind {
	case core.ReferenceRowRoot:
		return 0
	case core.ReferenceRowFile:
		return 1 + referenceRowGroup(r)
	default:
		return 1 + len(s.groups) + r.Shows
	}
}

// referenceRowGroup is the group of a file or usage row.
func referenceRowGroup(r core.ReferenceRow) int {
	if r.Group == nil {
		return 0
	}
	return *r.Group
}

// referenceUsageKey is Core's key of the row of usage target.
func referenceUsageKey(target int) string {
	return core.ReferenceRowUsage + ":" + strconv.Itoa(target)
}

// node describes visible row i to the Tree.
func (s *referencesState) node(i int) ui.TreeNode {
	r := s.rows[i]
	return ui.TreeNode{
		Depth:    r.Depth,
		Branch:   r.Kind != core.ReferenceRowUsage,
		Expanded: r.Expanded != nil && *r.Expanded,
		Selected: i == s.selectedRow,
	}
}

// rowOf is the visible row with key, or -1 when it is hidden under a closed node.
func (s *referencesState) rowOf(key string) int {
	return slices.IndexFunc(s.rows, func(r core.ReferenceRow) bool { return r.Key == key })
}

// selectRow selects the visible row with key; it is false when that row does not show.
func (s *referencesState) selectRow(key string) bool {
	i := s.rowOf(key)
	if i < 0 {
		return false
	}
	s.selected, s.selectedRow = key, i
	return true
}

// toggleReference opens or closes the node with key. Core moves the selection to the node when
// it was under it.
func (a *App) toggleReference(key string) {
	s := &a.editor.refs
	i := s.rowOf(key)
	if i < 0 {
		return
	}
	switch r := s.rows[i]; r.Kind {
	case core.ReferenceRowRoot:
		s.rootCollapsed = !s.rootCollapsed
	case core.ReferenceRowFile:
		file := s.groups[referenceRowGroup(r)].FileKey
		if s.collapsed[file] {
			delete(s.collapsed, file)
		} else {
			if s.collapsed == nil {
				s.collapsed = map[string]bool{}
			}
			s.collapsed[file] = true
		}
	default:
		return
	}
	a.layoutReferences()
}

// expandReferences opens or closes every file's node; the Usages node stays open so the files
// show. A usage that was selected hands the selection to its file when its node closes.
func (a *App) expandReferences(expanded bool) {
	s := &a.editor.refs
	s.rootCollapsed, s.collapsed = false, nil
	if !expanded {
		s.collapsed = make(map[string]bool, len(s.groups))
		for _, g := range s.groups {
			s.collapsed[g.FileKey] = true
		}
	}
	a.layoutReferences()
	s.reveal = true
}

// shownTarget is the usage the preview shows for the selected row: the usage itself, or the
// first usage of a file or of the whole answer.
func (s *referencesState) shownTarget() (int, bool) {
	if s.selectedRow < 0 || s.selectedRow >= len(s.rows) {
		return 0, false
	}
	return s.rows[s.selectedRow].Shows, true
}

// stepTarget is the usage after the selected row in the tree's order, or before it when forward
// is false, counting the usages under closed nodes too, and false at either end.
func (s *referencesState) stepTarget(forward bool) (int, bool) {
	if s.selectedRow < 0 || s.selectedRow >= len(s.rows) {
		return 0, false
	}
	step := s.rows[s.selectedRow].Previous
	if forward {
		step = s.rows[s.selectedRow].Next
	}
	if step == nil {
		return 0, false
	}
	return *step, true
}

// selectUsage selects the usage target, opening the nodes it lies under, and scrolls it into
// view.
func (a *App) selectUsage(target int) {
	s := &a.editor.refs
	s.rootCollapsed = false
	if target >= 0 && target < len(s.groupOf) && s.groupOf[target] < len(s.groups) {
		delete(s.collapsed, s.groups[s.groupOf[target]].FileKey)
	}
	s.selected = referenceUsageKey(target)
	a.layoutReferences()
	s.reveal = true
}

// stepReference selects the next or previous usage and opens it in the editor, as IDEA's Next
// and Previous Occurrence do.
func (a *App) stepReference(forward bool) {
	s := &a.editor.refs
	target, ok := s.stepTarget(forward)
	if !ok {
		return
	}
	a.selectUsage(target)
	a.openReference(s.targets[target])
}

// loadReferenceLines reads the line of every reference and has Core cut it for its row. An open
// file's lines come from its editor on the window thread, which only reads rope lines; closed
// files are read off it.
func (a *App) loadReferenceLines(p *project, generation uint64) {
	s := &a.editor.refs
	targets := s.targets
	// texts holds the text of each target's start line once read, and read says which are.
	texts, read := make([]string, len(targets)), make([]bool, len(targets))
	var closed []core.ReferenceGroup
	for _, g := range s.groups {
		path := targets[g.Indices[0]].FilePath
		if path == "" {
			continue
		}
		if d := p.docs.byPath(path); d != nil {
			text := d.view.TextSnapshot()
			for _, i := range g.Indices {
				if line := targets[i].Range.Start.Line; line >= 0 && line < text.LineCount() {
					texts[i], read[i] = text.Line(line), true
				}
			}
			continue
		}
		closed = append(closed, g)
	}
	kernel := a.kernel
	a.background(p, 0, func(ctx context.Context) func(*App) {
		for _, g := range closed {
			// A file that cannot be read keeps its rows without their lines.
			file := readLines(targets[g.Indices[0]].FilePath, referencePreviewLimit)
			for _, i := range g.Indices {
				if line := targets[i].Range.Start.Line; line >= 0 && line < len(file) {
					texts[i], read[i] = file[line], true
				}
			}
		}
		request, asked := referenceLinesRequest(targets, texts, read)
		if len(asked) == 0 {
			return nil
		}
		call, cancel := context.WithTimeout(ctx, kernelCallTimeout)
		defer cancel()
		lines, err := kernel.ReferenceLines(call, request)
		return func(a *App) {
			s := &a.editor.refs
			if s.generation != generation || s.project != p {
				return
			}
			if err == nil && len(lines) != len(asked) {
				err = errors.New("references lines answer does not match its usages")
			}
			if err != nil {
				a.backgroundFailed("references_lines", err)
				return
			}
			for k, i := range asked {
				if i < len(s.lines) {
					s.lines[i] = lines[k]
				}
			}
			a.invalidator.Invalidate()
		}
	})
}

// referenceLinesRequest asks Core to show the lines that were read, each distinct text sent
// once, and says which target each asked usage is.
func referenceLinesRequest(targets []core.PluginSemanticLocation, texts []string, read []bool) (core.ReferenceLinesRequest, []int) {
	var request core.ReferenceLinesRequest
	var asked []int
	index := map[string]int{}
	for i, target := range targets {
		if !read[i] {
			continue
		}
		k, ok := index[texts[i]]
		if !ok {
			k = len(request.Texts)
			index[texts[i]] = k
			request.Texts = append(request.Texts, texts[i])
		}
		at := target.Range
		request.Usages = append(request.Usages, core.ReferenceUsageLine{
			Text: k, Line: max(at.Start.Line, 0), Column: max(at.Start.UTF16Column, 0),
			EndLine: max(at.End.Line, 0), EndColumn: max(at.End.UTF16Column, 0),
		})
		asked = append(asked, i)
	}
	return request, asked
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
	path := s.targets[target].FilePath
	if path == "" {
		if s.preview.path != "" || s.preview.view != nil {
			s.preview.close()
		}
		return
	}
	at := s.targets[target].Range
	a.showSourcePreview(p, &s.preview, path, at.Start.Line+1, func(a *App) bool {
		return a.editor.refs.project == p && !a.editor.refs.hidePreview
	})
	view := s.preview.view
	marks := referenceMarks{view: view, target: target}
	if view == nil || s.marked == marks {
		return
	}
	s.marked = marks
	group := s.groups[s.groupOf[target]]
	matches := make([]editorview.Range, 0, len(group.Indices))
	for _, i := range group.Indices {
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
