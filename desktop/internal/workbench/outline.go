package workbench

import (
	"hash/fnv"
	"sort"
	"strconv"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

// The Structure tool window: the symbols of the selected file as a tree.
//
// Core asks the language server and normalizes the answer into one tree shape whichever form
// the server used; this file only decides when to ask (the Structure window is open, the
// selected file is in step with its server and its text changed), which answer is stale, and
// how the tree is shown: the caret's symbol selected, a click or Enter going to the symbol.

const (
	// outlineDelay is how long after the last request the next one waits, so typing in a
	// large file does not ask the server for the symbols on every key.
	outlineDelay = 300 * time.Millisecond
)

// outlineRow is one visible row of the tree.
type outlineRow struct {
	symbol *core.DocumentSymbol
	depth  int
	// key is the symbol's place in the tree ("2.0.1": the index at each level), which names it
	// across answers while the tree keeps its shape; id is the same as a number for the Tree.
	key string
	id  int
}

// outlineState is the Structure window's state for the selected document.
type outlineState struct {
	project    *project
	documentID int
	// requested is the document revision the last request asked about, -1 for none; revision
	// is the revision the symbols describe, valid while loaded.
	requested, revision int
	requestedAt         time.Time
	pending             *semanticPending
	loaded, failed      bool
	symbols             []core.DocumentSymbol
	// sorted lists each level by name instead of by position.
	sorted bool
	// collapsed are the keys of the symbols the user folded.
	collapsed map[string]bool
	rows      []outlineRow
	// rowsDirty says rows is behind symbols, sorted or collapsed.
	rowsDirty bool
	view      ui.TreeState
	// caretLine and caretColumn are where the caret was when the selection last followed it;
	// followed says the answer has been followed once.
	caretLine, caretColumn int
	follow                 bool
	// selected is the row index the tree shows as selected, -1 for none.
	selected int
}

// outlineReset drops the answer, for another document or project.
func (a *App) outlineReset(p *project, documentID int) {
	s := &a.editor.outline
	if a.editorRequestWaiting(s.pending) {
		a.cancelSemantic(s.pending)
	}
	*s = outlineState{project: p, documentID: documentID, requested: -1, selected: -1, sorted: s.sorted, collapsed: map[string]bool{}, follow: true}
}

// outlineSync keeps the symbols in step with the selected document and asks for a new answer
// when its text changed. It returns the next time it wants a frame to try again, zero for none.
func (a *App) outlineSync(p *project, d *document, now time.Time) (retryIn time.Duration) {
	s := &a.editor.outline
	if s.project != p || s.documentID != d.id {
		a.outlineReset(p, d.id)
	}
	revision := d.view.Revision()
	if s.pending != nil && !a.editorRequestWaiting(s.pending) {
		s.pending = nil
	}
	if s.pending != nil || s.requested == revision {
		return 0
	}
	if d.virtual || !a.semanticDocumentReady(d) {
		// The synchronization that finishes later wakes the window (see resumeDeferredSemantics).
		return outlineDelay
	}
	server, offered := a.editorServer(d, featureDocumentSymbols)
	if server == nil {
		return outlineDelay
	}
	if !offered {
		s.requested, s.failed = revision, true
		return 0
	}
	if wait := s.requestedAt.Add(outlineDelay).Sub(now); wait > 0 {
		return wait
	}
	s.requested, s.requestedAt = revision, now
	s.pending = a.submitEditorRequest(pluginSemanticDocumentSymbols, p, d, server, core.PluginSemanticRequest{})
	return 0
}

// applyOutline takes the answer of a documentSymbols request.
func (a *App) applyOutline(pending *semanticPending, event core.BackendEvent, failed bool) {
	s := &a.editor.outline
	if s.pending != pending {
		return
	}
	s.pending = nil
	defer a.invalidator.Invalidate()
	if failed {
		s.failed = true
		return
	}
	p, d := a.currentSemanticDocument(pending.documentID)
	if p != pending.project || d == nil || s.project != p || s.documentID != d.id {
		return
	}
	symbols, err := core.PluginDocumentSymbols(event)
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_document_symbols", err))
		s.failed = true
		return
	}
	s.symbols, s.revision, s.loaded, s.failed = symbols, pending.revision, true, false
	s.rowsDirty, s.follow = true, true
}

// outlineBuildRows flattens the symbols into the rows of the unfolded tree, in position order or
// by name, and drops the keys of folded symbols that no longer exist.
func (s *outlineState) buildRows() {
	s.rows = s.rows[:0]
	var walk func(symbols []core.DocumentSymbol, depth int, prefix string)
	walk = func(symbols []core.DocumentSymbol, depth int, prefix string) {
		order := make([]int, len(symbols))
		for i := range order {
			order[i] = i
		}
		if s.sorted {
			sort.SliceStable(order, func(x, y int) bool { return symbols[order[x]].Name < symbols[order[y]].Name })
		}
		for _, i := range order {
			key := prefix + strconv.Itoa(i)
			s.rows = append(s.rows, outlineRow{symbol: &symbols[i], depth: depth, key: key, id: outlineID(key)})
			if len(symbols[i].Children) > 0 && !s.collapsed[key] {
				walk(symbols[i].Children, depth+1, key+".")
			}
		}
	}
	walk(s.symbols, 0, "")
	s.rowsDirty = false
}

// contains reports whether the range covers the position, with the end excluded.
func symbolContains(r core.PluginDocumentRange, line, column int) bool {
	after := func(p core.PluginDocumentPosition) bool {
		return line > p.Line || line == p.Line && column >= p.UTF16Column
	}
	return after(r.Start) && !after(r.End)
}

// caretRow is the row of the innermost symbol that contains the caret, or -1.
func (s *outlineState) caretRow(line, column int) int {
	best := -1
	for i, row := range s.rows {
		if symbolContains(row.symbol.Range, line, column) {
			// Rows are in tree order, so the last one that contains the caret is the innermost
			// of the first top-level symbol that does, unless a later sibling also contains it.
			best = i
		}
	}
	return best
}

// outlineID is the Tree's number for a symbol key.
func outlineID(key string) int {
	h := fnv.New32a()
	_, _ = h.Write([]byte(key))
	return int(h.Sum32() >> 1)
}
