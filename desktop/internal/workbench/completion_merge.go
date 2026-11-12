package workbench

import (
	"context"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// completionMergeTimeout bounds the Core call that chooses which candidates survive.
const completionMergeTimeout = 5 * time.Second

// completionMerger is the optional Core command that merges candidate lists. A test double
// without it gets the lists concatenated, which keeps every candidate visible.
type completionMerger interface {
	MergeCompletions(ctx context.Context, lists []core.CompletionMergeList) (core.CompletionMergeResult, error)
}

// completionMergeJoin waits for the language server and the plugin completion provider of one
// explicit completion request, then shows the merged list. Each side settles once; a request
// replaced or closed in the meantime marks the join closed, so its late answers are dropped.
type completionMergeJoin struct {
	project      *project
	documentID   int
	revision     int
	line, column int
	closed       bool
	finished     bool
	server       completionMergeSide
	provider     completionMergeSide
}

// completionMergeSide is one source's answer. A side that failed or went stale settles with no
// items so the other side can still be shown.
type completionMergeSide struct {
	done       bool
	items      []core.PluginSemanticCompletionItem
	incomplete bool
}

// newCompletionMergeJoin starts a join for an explicit request when a plugin completion provider
// also serves the document. Automatic requests keep the language server's list alone.
func (a *App) newCompletionMergeJoin(p *project, d *document, line, column int, automatic bool) *completionMergeJoin {
	if automatic || a.plugins == nil || d.virtual || d.path == "" || !a.plugins.HasCompletionProvider(p.root, d.path, d.languageID) {
		return nil
	}
	join := &completionMergeJoin{project: p, documentID: d.id, revision: d.view.Revision(), line: line, column: column}
	a.semantics.merge = join
	return join
}

// settleMergeSide records one source's answer and shows the merged list once both sides answered.
func (a *App) settleMergeSide(join *completionMergeJoin, server bool, items []core.PluginSemanticCompletionItem, incomplete bool) {
	if join == nil || join.closed {
		return
	}
	side := &join.provider
	if server {
		side = &join.server
	}
	side.done, side.items, side.incomplete = true, items, incomplete
	if !join.server.done || !join.provider.done || join.finished {
		return
	}
	join.finished = true
	if a.semantics.merge == join {
		a.semantics.merge = nil
	}
	// Priority is the plugin provider first, then the language server, as the legacy client
	// ordered its local completions before the server's.
	lists := []core.CompletionMergeList{
		completionMergeList(join.provider),
		completionMergeList(join.server),
	}
	sources := [][]core.PluginSemanticCompletionItem{join.provider.items, join.server.items}
	anyIncomplete := join.provider.incomplete || join.server.incomplete
	// One side without candidates has nothing to collapse, so Core is not asked.
	if len(join.provider.items) == 0 || len(join.server.items) == 0 {
		a.finishMergedCompletion(join, concatCompletionSources(sources), anyIncomplete)
		return
	}
	merger, ok := a.kernel.(completionMerger)
	if !ok {
		a.finishMergedCompletion(join, concatCompletionSources(sources), anyIncomplete)
		return
	}
	p := join.project
	a.background(p, completionMergeTimeout, func(ctx context.Context) func(*App) {
		result, err := merger.MergeCompletions(ctx, lists)
		return func(a *App) {
			if err != nil {
				a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_semantics", err))
				a.finishMergedCompletion(join, concatCompletionSources(sources), anyIncomplete)
				return
			}
			a.finishMergedCompletion(join, keepCompletionSources(sources, result.Keep), anyIncomplete || result.IsIncomplete)
		}
	})
}

// completionMergeList is one source's labels for Core, in its own order.
func completionMergeList(side completionMergeSide) core.CompletionMergeList {
	labels := make([]string, 0, len(side.items))
	for _, item := range side.items {
		labels = append(labels, item.Label)
	}
	return core.CompletionMergeList{Labels: labels, IsIncomplete: side.incomplete}
}

// keepCompletionSources applies Core's kept indices to each source's items, in priority order.
func keepCompletionSources(sources [][]core.PluginSemanticCompletionItem, keep [][]int) []core.PluginSemanticCompletionItem {
	merged := []core.PluginSemanticCompletionItem{}
	for index, items := range sources {
		if index >= len(keep) {
			break
		}
		for _, position := range keep[index] {
			if position >= 0 && position < len(items) {
				merged = append(merged, items[position])
			}
		}
	}
	return merged
}

// concatCompletionSources keeps every candidate of every source in priority order.
func concatCompletionSources(sources [][]core.PluginSemanticCompletionItem) []core.PluginSemanticCompletionItem {
	merged := []core.PluginSemanticCompletionItem{}
	for _, items := range sources {
		merged = append(merged, items...)
	}
	return merged
}

// finishMergedCompletion opens the popup with the merged list when the document and caret still
// name the request. A closed or replaced join never opens anything.
func (a *App) finishMergedCompletion(join *completionMergeJoin, items []core.PluginSemanticCompletionItem, incomplete bool) {
	if join.closed || a.project != join.project {
		return
	}
	d := join.project.docs.find(join.documentID)
	if d == nil || d.view.Revision() != join.revision {
		return
	}
	if line, column := d.view.CaretUTF16(); line != join.line || column != join.column {
		return
	}
	if len(items) > maxCompletionItems {
		items = items[:maxCompletionItems]
	}
	if len(items) == 0 {
		a.closeSemanticCompletion()
		return
	}
	a.semantics.completion = completionState{
		open:       true,
		items:      items,
		documentID: join.documentID,
		revision:   join.revision,
		line:       join.line,
		column:     join.column,
		incomplete: incomplete,
	}
}

// settleServerCompletion feeds the language server's answer of a joined request into the join. A
// stale or failed answer settles the server side with no items.
func (a *App) settleServerCompletion(pending *semanticPending, event core.BackendEvent, stale bool) {
	if stale {
		a.settleMergeSide(pending.join, true, nil, false)
		return
	}
	items, incomplete, err := core.PluginSemanticCompletions(event)
	if err != nil {
		a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_semantics", err))
		a.settleMergeSide(pending.join, true, nil, false)
		return
	}
	a.settleMergeSide(pending.join, true, items, incomplete)
}
