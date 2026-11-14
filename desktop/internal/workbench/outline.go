package workbench

import (
	"context"
	"hash/fnv"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/ui"
)

// The Structure tool window: the symbols of the selected file as a tree.
//
// Core asks the language server and normalizes the answer into one tree shape whichever form
// the server used; this file only decides when to ask (the Structure window is open, the
// selected file is in step with its server and its text changed), which answer is stale, and
// how the tree is shown: the caret's symbol selected, a click or Enter going to the symbol, a
// filter on the names, the levels sorted or folded.
//
// Most files have no language server at all. Whether one serves the file, is starting, failed
// or lacks document symbols is read from the session state on every frame and shown as a final
// state; none of those states asks for frames, because each way out of them (a server's state
// event, the end of its start, the end of the document's synchronization) wakes the window.
//
// A Markdown file needs no server: Core outlines its headings in the dialect the preview renders,
// so the window lists the headings the preview's outline lists, whatever plugins are installed.

const (
	// outlineDelay is how long after the last request the next one waits, so typing in a
	// large file does not ask the server for the symbols on every key.
	outlineDelay = 300 * time.Millisecond
)

// outlineAvailability says whether the selected file's symbols can be asked for and, when not,
// why.
type outlineAvailability int

const (
	// outlineAsk is a ready server that holds the document in step: ask it.
	outlineAsk outlineAvailability = iota
	// outlineNoServer is a file no enabled plugin serves.
	outlineNoServer
	// outlineStarting is a server that is still starting.
	outlineStarting
	// outlineOpening is a ready server that has not received the document's text yet.
	outlineOpening
	// outlineServerDown is a server that failed or stopped.
	outlineServerDown
	// outlineUnsupported is a server that does not offer document symbols.
	outlineUnsupported
	// outlineMarkdown is a Markdown file: ask Core for the outline of its headings.
	outlineMarkdown
)

// markdownOutlineKernel is what the Structure window asks Core for a Markdown file: its headings
// as a symbol tree.
type markdownOutlineKernel interface {
	MarkdownOutline(ctx context.Context, source string) ([]core.DocumentSymbol, error)
}

// outlineMarkdownRequest is one request for a Markdown file's headings; the state holds the one
// under way, so an answer to any other is stale.
type outlineMarkdownRequest struct {
	revision int
}

// outlineRow is one visible row of the tree.
type outlineRow struct {
	symbol *core.DocumentSymbol
	depth  int
	// key is the symbol's place in the tree ("2.0.1": the index at each level), which names it
	// across answers while the tree keeps its shape; id is the same as a number for the Tree.
	key string
	id  int
	// match says the symbol's own name contains the filter, rather than only a descendant's.
	match bool
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
	// outlining is the request for a Markdown file's headings under way, nil for none.
	outlining *outlineMarkdownRequest
	// loaded says symbols holds an answer; failed says the last request failed; tooLarge says
	// the Markdown file is over markdownPreviewMaxBytes and is not outlined, as it is not
	// previewed.
	loaded, failed, tooLarge bool
	// availability is what the last sync found about the file's server.
	availability outlineAvailability
	symbols      []core.DocumentSymbol
	// total counts every symbol of the answer, nested ones included.
	total int
	// sorted lists each level by name instead of by position; still keeps the selection where
	// it is instead of following the caret. Both are the user's choice and outlive the document.
	sorted, still bool
	// filter keeps the symbols whose name contains it, ignoring case, and their ancestors; the
	// search field edits it in place. rowsFilter is the filter rows were built for.
	filter, rowsFilter string
	// matches counts the symbols whose own name contains the filter.
	matches int
	// collapsed are the keys of the symbols the user folded.
	collapsed map[string]bool
	rows      []outlineRow
	// rowsDirty says rows is behind symbols, sorted, filter or collapsed.
	rowsDirty bool
	view      ui.TreeState
	// caretLine and caretColumn are where the caret was when the selection last followed it;
	// follow asks the next frame to follow it even if it did not move.
	caretLine, caretColumn int
	follow                 bool
	// selected is the row index the tree shows as selected, -1 for none.
	selected int
}

// outlineReset drops the answer, for another document or project. The filter is kept: it
// names what the user looks for, not something of the file.
func (a *App) outlineReset(p *project, documentID int) {
	s := &a.editor.outline
	if a.editorRequestWaiting(s.pending) {
		a.cancelSemantic(s.pending)
	}
	*s = outlineState{
		project: p, documentID: documentID, requested: -1, selected: -1,
		sorted: s.sorted, still: s.still, filter: s.filter,
		collapsed: map[string]bool{}, follow: true,
	}
}

// outlineAvailabilityOf classifies the server of the selected document. A Markdown file is
// Core's to outline.
func (a *App) outlineAvailabilityOf(d *document) outlineAvailability {
	if _, ok := a.kernel.(markdownOutlineKernel); ok && isMarkdownDocument(d) {
		return outlineMarkdown
	}
	if a.plugins == nil || d.virtual || d.languageID == "" {
		return outlineNoServer
	}
	a.pluginServerMu.Lock()
	starting := a.pluginServerStarting[d.languageID]
	server := a.pluginServers[a.pluginServerLanguages[d.languageID]]
	a.pluginServerMu.Unlock()
	switch {
	case server == nil || server.session == nil:
		if starting {
			return outlineStarting
		}
		return outlineNoServer
	case server.state == "failed" || server.state == "error" || server.state == "stopped":
		return outlineServerDown
	case !server.isReady():
		return outlineStarting
	case !a.semanticDocumentReady(d):
		return outlineOpening
	case !server.features[featureDocumentSymbols]:
		return outlineUnsupported
	}
	return outlineAsk
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
	s.availability = a.outlineAvailabilityOf(d)
	if s.availability == outlineMarkdown {
		return a.outlineMarkdownSync(p, d, revision, now)
	}
	if s.pending != nil || s.requested == revision || s.availability != outlineAsk {
		return 0
	}
	server, _ := a.editorServer(d, featureDocumentSymbols)
	if server == nil {
		return 0
	}
	if wait := s.requestedAt.Add(outlineDelay).Sub(now); wait > 0 {
		return wait
	}
	s.requested, s.requestedAt, s.failed = revision, now, false
	s.pending = a.submitEditorRequest(pluginSemanticDocumentSymbols, p, d, server, core.PluginSemanticRequest{})
	return 0
}

// outlineMarkdownSync asks Core for the headings of a Markdown document when its text changed
// since the last request and no request is under way, spaced like a server's requests. A file
// over markdownPreviewMaxBytes is not sent.
func (a *App) outlineMarkdownSync(p *project, d *document, revision int, now time.Time) (retryIn time.Duration) {
	s := &a.editor.outline
	kernel, ok := a.kernel.(markdownOutlineKernel)
	if !ok || s.outlining != nil || s.requested == revision {
		return 0
	}
	if wait := s.requestedAt.Add(outlineDelay).Sub(now); wait > 0 {
		return wait
	}
	s.requested, s.requestedAt, s.failed = revision, now, false
	text := d.view.TextSnapshot()
	if s.tooLarge = text.Len() > markdownPreviewMaxBytes; s.tooLarge {
		s.symbols, s.loaded, s.total, s.rowsDirty = nil, false, 0, true
		return 0
	}
	request := &outlineMarkdownRequest{revision: revision}
	s.outlining = request
	source := text.String()
	a.background(p, markdownRenderTimeout, func(ctx context.Context) func(*App) {
		symbols, err := kernel.MarkdownOutline(ctx, source)
		return func(a *App) { a.applyMarkdownOutline(request, symbols, err) }
	})
	return 0
}

// applyMarkdownOutline takes Core's outline of a Markdown document. The answer to a request that
// is no longer under way, because another document was selected since, is dropped.
func (a *App) applyMarkdownOutline(request *outlineMarkdownRequest, symbols []core.DocumentSymbol, err error) {
	s := &a.editor.outline
	if s.outlining != request {
		return
	}
	s.outlining = nil
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("markdown_outline", err))
		s.failed = true
		return
	}
	s.symbols, s.revision, s.loaded, s.failed = symbols, request.revision, true, false
	s.total = countSymbols(symbols)
	s.rowsDirty, s.follow = true, true
}

// retry asks again for the symbols of the same text after a request failed, at once: the
// delay between requests spaces out typing, not an explicit retry.
func (s *outlineState) retry() {
	s.requested, s.requestedAt, s.failed = -1, time.Time{}, false
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
	s.total = countSymbols(symbols)
	s.rowsDirty, s.follow = true, true
}

// countSymbols counts the symbols of a tree, nested ones included.
func countSymbols(symbols []core.DocumentSymbol) int {
	n := len(symbols)
	for i := range symbols {
		n += countSymbols(symbols[i].Children)
	}
	return n
}

// refresh rebuilds the rows when the symbols, the order, the folding or the filter changed, and
// reports whether it did.
func (s *outlineState) refresh() bool {
	if s.filter != s.rowsFilter {
		s.rowsDirty, s.follow = true, true
	}
	if !s.rowsDirty && s.rows != nil {
		return false
	}
	s.buildRows()
	return true
}

// setAllCollapsed folds every symbol that has children, or unfolds them all.
func (s *outlineState) setAllCollapsed(collapsed bool) {
	s.collapsed = map[string]bool{}
	if collapsed {
		var walk func(symbols []core.DocumentSymbol, prefix string)
		walk = func(symbols []core.DocumentSymbol, prefix string) {
			for i := range symbols {
				if len(symbols[i].Children) > 0 {
					key := prefix + strconv.Itoa(i)
					s.collapsed[key] = true
					walk(symbols[i].Children, key+".")
				}
			}
		}
		walk(s.symbols, "")
	}
	s.rowsDirty, s.follow = true, true
}

// filtering says a filter is in effect.
func (s *outlineState) filtering() bool {
	return strings.TrimSpace(s.filter) != ""
}

// buildRows flattens the symbols into the rows of the unfolded tree, in position order or by
// name. With a filter it keeps the symbols whose name contains it and their ancestors, all
// unfolded: a match hidden under a folded parent would read as no match.
func (s *outlineState) buildRows() {
	selected := ""
	if s.selected >= 0 && s.selected < len(s.rows) {
		selected = s.rows[s.selected].key
	}
	s.rows, s.matches, s.selected = s.rows[:0], 0, -1
	query := strings.ToLower(strings.TrimSpace(s.filter))
	var walk func(symbols []core.DocumentSymbol, depth int, prefix string) bool
	walk = func(symbols []core.DocumentSymbol, depth int, prefix string) bool {
		order := make([]int, len(symbols))
		for i := range order {
			order[i] = i
		}
		if s.sorted {
			sort.SliceStable(order, func(x, y int) bool { return symbols[order[x]].Name < symbols[order[y]].Name })
		}
		kept := false
		for _, i := range order {
			key := prefix + strconv.Itoa(i)
			match := query == "" || strings.Contains(strings.ToLower(symbols[i].Name), query)
			at := len(s.rows)
			s.rows = append(s.rows, outlineRow{symbol: &symbols[i], depth: depth, key: key, id: outlineID(key), match: match})
			descendant := false
			if len(symbols[i].Children) > 0 && (query != "" || !s.collapsed[key]) {
				descendant = walk(symbols[i].Children, depth+1, key+".")
			}
			if !match && !descendant {
				s.rows = s.rows[:at]
				continue
			}
			if match && query != "" {
				s.matches++
			}
			kept = true
		}
		return kept
	}
	walk(s.symbols, 0, "")
	// The selection stays on its symbol while the rows around it change.
	for i := range s.rows {
		if selected != "" && s.rows[i].key == selected {
			s.selected = i
		}
	}
	s.rowsDirty, s.rowsFilter = false, s.filter
}

// expanded says the tree shows a row's children.
func (s *outlineState) expanded(row outlineRow) bool {
	return s.filtering() || !s.collapsed[row.key]
}

// symbolContains reports whether the range covers the position, with the end excluded.
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
