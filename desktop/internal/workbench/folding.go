package workbench

import (
	"context"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/icons"
	"github.com/vivaui/viva/ui"
)

// Code folding of the editor: the ranges come from the document's language server when it offers
// foldingRange (Core's foldingRanges operation), and from indentation otherwise, so every file
// folds. They are asked for again a moment after the text stops changing; an answer for a text
// that changed since is dropped, since the view has already moved the ranges it holds.

const (
	// pluginSemanticFoldingRanges is the operation, and featureFoldingRanges the feature a server
	// declares for it.
	pluginSemanticFoldingRanges = "foldingRanges"
	featureFoldingRanges        = "foldingRanges"
	// foldDelay is how long the text stays unchanged before the ranges are asked for again.
	foldDelay = 500 * time.Millisecond
	// foldIndentLimit is the largest text whose ranges are worked out from indentation.
	foldIndentLimit = 4 << 20
	// foldTabWidth is the columns a tab stands for when indentation is measured.
	foldTabWidth = 4
)

// foldSource is where a document's ranges came from.
type foldSource int

const (
	foldNone foldSource = iota
	foldIndent
	foldServer
)

// documentFolds is a document's folding requests.
type documentFolds struct {
	// revision is the text the ranges were last asked for, source where they came from.
	revision int
	source   foldSource
	// pending is the server request in flight; computing is true while indentation is read.
	pending   *semanticPending
	computing bool
	// changedAt is when the text was first seen at its current revision.
	changedAt time.Time
	seen      int
}

// setupFolding gives a new document's view its gutter arrows.
func setupFolding(d *document) {
	d.view.SetFoldIcons(icons.ChevronDown, icons.ChevronRight)
	d.folds.revision = -1
}

// foldSync asks for a shown document's ranges when its text has settled since they were last
// asked for, or when its language server became able to answer.
func (a *App) foldSync(c ui.C, p *project, d *document) {
	f := &d.folds
	if f.computing || a.editorRequestWaiting(f.pending) {
		return
	}
	f.pending = nil
	revision := d.view.Revision()
	now := a.now()
	if f.seen != revision {
		f.seen, f.changedAt = revision, now
	}
	server, offered := a.editorServer(d, featureFoldingRanges)
	useServer := server != nil && offered && !d.virtual && a.semanticDocumentReady(d)
	if f.revision == revision && (f.source == foldServer || !useServer) {
		return
	}
	if f.revision >= 0 {
		if wait := f.changedAt.Add(foldDelay).Sub(now); wait > 0 {
			c.Canvas().RequestFrameIn(wait)
			return
		}
	}
	f.revision = revision
	if useServer {
		f.source = foldServer
		f.pending = a.submitEditorRequest(pluginSemanticFoldingRanges, p, d, server, core.PluginSemanticRequest{})
		return
	}
	a.foldFromIndent(p, d, revision)
}

// foldFromIndent works the ranges out from indentation in the background.
func (a *App) foldFromIndent(p *project, d *document, revision int) {
	f := &d.folds
	text := d.view.TextSnapshot()
	if text.Len() > foldIndentLimit {
		d.view.SetFoldRanges(nil)
		return
	}
	f.source, f.computing = foldIndent, true
	a.background(p, 10*time.Second, func(context.Context) func(*App) {
		ranges := editorview.IndentFoldRanges(text.Bytes(), foldTabWidth)
		return func(a *App) {
			f.computing = false
			if d.view.Revision() == revision {
				d.view.SetFoldRanges(ranges)
			}
		}
	})
}

// applyFoldRanges takes a server's foldingRanges answer; a failed request falls back to
// indentation.
func (a *App) applyFoldRanges(pending *semanticPending, event core.BackendEvent, failed bool) {
	p, d := a.currentSemanticDocument(pending.documentID)
	if p != pending.project || d == nil || d.folds.pending != pending {
		return
	}
	d.folds.pending = nil
	defer a.invalidator.Invalidate()
	var ranges []core.FoldingRange
	var err error
	if !failed {
		ranges, err = core.PluginFoldingRanges(event)
	}
	if failed || err != nil {
		if err != nil {
			a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("plugin_folding_ranges", err))
		}
		a.foldFromIndent(p, d, pending.revision)
		return
	}
	if d.view.Revision() != pending.revision {
		return
	}
	folds := make([]editorview.FoldRange, 0, len(ranges))
	for _, r := range ranges {
		folds = append(folds, editorview.FoldRange{StartLine: r.StartLine, EndLine: r.EndLine})
	}
	d.view.SetFoldRanges(folds)
}

// foldCommand runs a folding action on the selected document.
func (a *App) foldCommand(d *document, action func(*editorview.View)) {
	if d == nil {
		return
	}
	action(d.view)
	a.invalidator.Invalidate()
}
