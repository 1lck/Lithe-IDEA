package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/app"
)

// pluginWorkbench is the window as the plugin host services see it. Every method
// hands its work to the window's thread, where documents and editors may be
// touched, and returns when the work finished or the request's context ended.
// Work that already started is not undone by a cancellation, which the contract
// says a plugin must expect.
type pluginWorkbench struct{ app *App }

var _ pluginservice.Workbench = pluginWorkbench{}

// onWindow runs fn on the window thread and waits for its result.
func onWindow[T any](a *App, ctx context.Context, fn func(*App) (T, error)) (T, error) {
	type outcome struct {
		value T
		err   error
	}
	done := make(chan outcome, 1)
	a.post(func(a *App) {
		if err := ctx.Err(); err != nil {
			done <- outcome{err: err}
			return
		}
		value, err := fn(a)
		done <- outcome{value, err}
	})
	select {
	case result := <-done:
		return result.value, result.err
	case <-ctx.Done():
		var zero T
		return zero, ctx.Err()
	}
}

func hostError(code, message string) error {
	return &pluginservice.HostError{Code: code, Message: message}
}

// projectAt is the open project whose folder is root. A context that names any
// other folder is stale: the window moved on.
func (a *App) projectAt(root string) (*project, error) {
	if a.project == nil || filepath.Clean(a.project.root) != filepath.Clean(root) {
		return nil, hostError(pluginservice.CodeContextExpired, "The workspace is no longer open.")
	}
	return a.project, nil
}

const documentIDPrefix = "d"

func documentPublicID(d *document) string { return documentIDPrefix + strconv.Itoa(d.id) }

func (p *project) publicDocument(id string) *document {
	rest, ok := strings.CutPrefix(id, documentIDPrefix)
	if !ok {
		return nil
	}
	n, err := strconv.Atoi(rest)
	if err != nil || n <= 0 {
		return nil
	}
	return p.docs.find(n)
}

// summarize is the public description of a document. Version is the view's
// revision: the same number getSnapshot, getSelections and every edit use.
func summarize(p *project, d *document) pluginservice.DocumentSummary {
	summary := pluginservice.DocumentSummary{
		DocumentID: documentPublicID(d),
		Version:    d.view.Revision(),
		Path:       pluginservice.RelativePath(p.root, d.path),
		IsReadOnly: d.view.ReadOnly(),
		IsDirty:    d.dirty(),
		Encoding:   "utf-8",
		LineEnding: d.view.LineEnding(),
	}
	if d.languageID != "" {
		language := d.languageID
		summary.LanguageID = &language
	}
	return summary
}

func (w pluginWorkbench) Documents(ctx context.Context, root string) ([]pluginservice.DocumentSummary, error) {
	return onWindow(w.app, ctx, func(a *App) ([]pluginservice.DocumentSummary, error) {
		p, err := a.projectAt(root)
		if err != nil {
			return nil, err
		}
		documents := make([]pluginservice.DocumentSummary, 0, len(p.docs.list))
		for _, d := range p.docs.list {
			documents = append(documents, summarize(p, d))
		}
		return documents, nil
	})
}

func (w pluginWorkbench) Snapshot(ctx context.Context, root, id string, maxBytes int) (pluginservice.DocumentSummary, string, error) {
	type snapshot struct {
		summary pluginservice.DocumentSummary
		text    string
	}
	result, err := onWindow(w.app, ctx, func(a *App) (snapshot, error) {
		p, err := a.projectAt(root)
		if err != nil {
			return snapshot{}, err
		}
		d := p.publicDocument(id)
		if d == nil {
			return snapshot{}, hostError(pluginservice.CodeNotFound, "The document is not open.")
		}
		text := d.view.TextSnapshot()
		if text.Len() > maxBytes {
			return snapshot{}, hostError(pluginservice.CodeLimitExceeded, "The document is larger than a snapshot may be.")
		}
		return snapshot{summarize(p, d), text.String()}, nil
	})
	return result.summary, result.text, err
}

func (w pluginWorkbench) Active(ctx context.Context, root string) (*pluginservice.DocumentSummary, error) {
	return onWindow(w.app, ctx, func(a *App) (*pluginservice.DocumentSummary, error) {
		p, err := a.projectAt(root)
		if err != nil {
			return nil, err
		}
		d := p.selectedDocument(p.docs.group)
		if d == nil {
			return nil, nil
		}
		summary := summarize(p, d)
		return &summary, nil
	})
}

// position is the one-based public position of a byte offset.
func position(d *document, offset int) pluginservice.Position {
	line, column := d.view.PositionOf(offset)
	return pluginservice.Position{Line: line + 1, Column: column + 1}
}

func (w pluginWorkbench) Selections(ctx context.Context, root, id string) (pluginservice.SelectionsResult, error) {
	return onWindow(w.app, ctx, func(a *App) (pluginservice.SelectionsResult, error) {
		p, err := a.projectAt(root)
		if err != nil {
			return pluginservice.SelectionsResult{}, err
		}
		d := p.publicDocument(id)
		if d == nil {
			return pluginservice.SelectionsResult{}, hostError(pluginservice.CodeNotFound, "The document is not open.")
		}
		anchor, active := d.view.SelectionOffsets()
		return pluginservice.SelectionsResult{
			DocumentID: documentPublicID(d),
			Version:    d.view.Revision(),
			Selections: []pluginservice.Selection{{Anchor: position(d, anchor), Active: position(d, active)}},
		}, nil
	})
}

// Edit applies a batch to the editor's own text, so it joins the undo stack as
// one step and reaches the language-server session like typing does. A stale
// version, a read-only view and an input-method composition are refused before
// anything changes.
func (w pluginWorkbench) Edit(ctx context.Context, root string, request pluginservice.EditRequest) (pluginservice.EditResult, error) {
	return onWindow(w.app, ctx, func(a *App) (pluginservice.EditResult, error) {
		p, err := a.projectAt(root)
		if err != nil {
			return pluginservice.EditResult{}, err
		}
		d := p.publicDocument(request.DocumentID)
		if d == nil {
			return pluginservice.EditResult{}, hostError(pluginservice.CodeNotFound, "The document is not open.")
		}
		if current := d.view.Revision(); current != request.ExpectedVersion {
			return pluginservice.EditResult{}, &pluginservice.HostError{Code: pluginservice.CodeVersionConflict,
				Message: "The document changed since the plugin read it.", Details: map[string]any{"currentVersion": current}}
		}
		if d.view.ReadOnly() {
			return pluginservice.EditResult{}, hostError(pluginservice.CodeReadOnly, "The document is read-only.")
		}
		if d.view.IsComposing() {
			return pluginservice.EditResult{}, hostError(pluginservice.CodeBusy, "An input method composition is active.")
		}
		edits := make([]editorview.TextEdit, 0, len(request.Edits))
		for _, edit := range request.Edits {
			start, err := d.view.OffsetOf(edit.Range.Start.Line-1, edit.Range.Start.Column-1)
			if err != nil {
				return pluginservice.EditResult{}, hostError("plugin.host.invalidParams", "An edit starts outside the document.")
			}
			end, err := d.view.OffsetOf(edit.Range.End.Line-1, edit.Range.End.Column-1)
			if err != nil {
				return pluginservice.EditResult{}, hostError("plugin.host.invalidParams", "An edit ends outside the document.")
			}
			edits = append(edits, editorview.TextEdit{Range: editorview.Range{Start: start, End: end}, Text: edit.Text})
		}
		// Edits of one batch are given against the same text; applying them needs
		// document order, and two that overlap have no meaning.
		slices.SortStableFunc(edits, func(x, y editorview.TextEdit) int {
			if x.Start != y.Start {
				return x.Start - y.Start
			}
			return x.End - y.End
		})
		if err := d.view.ApplyEdits(edits); err != nil {
			switch {
			case errors.Is(err, editorview.ErrReadOnly):
				return pluginservice.EditResult{}, hostError(pluginservice.CodeReadOnly, "The document is read-only.")
			case errors.Is(err, editorview.ErrComposing):
				return pluginservice.EditResult{}, hostError(pluginservice.CodeBusy, "An input method composition is active.")
			}
			return pluginservice.EditResult{}, hostError("plugin.host.invalidParams", "The edits overlap or split a character.")
		}
		return pluginservice.EditResult{DocumentID: documentPublicID(d), Version: d.view.Revision(), Applied: true}, nil
	})
}

// openFinished runs the callers that waited for path to open.
func (a *App) openFinished(p *project, path string, err error) {
	waiters := p.docs.openWaiters[path]
	delete(p.docs.openWaiters, path)
	d := p.docs.byPath(path)
	for _, waiter := range waiters {
		waiter(d, err)
	}
}

func (w pluginWorkbench) Open(ctx context.Context, root string, request pluginservice.OpenRequest) (pluginservice.OpenResult, error) {
	type outcome struct {
		result pluginservice.OpenResult
		err    error
	}
	done := make(chan outcome, 1)
	_, err := onWindow(w.app, ctx, func(a *App) (struct{}, error) {
		p, err := a.projectAt(root)
		if err != nil {
			return struct{}{}, err
		}
		info, statErr := os.Stat(request.Path)
		switch {
		case statErr != nil:
			return struct{}{}, hostError(pluginservice.CodeNotFound, "The file does not exist.")
		case info.IsDir():
			return struct{}{}, hostError("plugin.host.invalidParams", "The resource is a directory.")
		}
		previous := p.selectedDocument(p.docs.group)
		finish := func(d *document, openErr error, already bool) {
			if openErr != nil || d == nil {
				done <- outcome{err: hostError(pluginservice.CodeNotFound, "The file could not be opened.")}
				return
			}
			var applied *pluginservice.AppliedCaret
			if request.Caret != nil {
				d.view.GoToNavigation(request.Caret.Line-1, request.Caret.Column-1, false)
				line, column := d.view.CaretUTF16()
				applied = &pluginservice.AppliedCaret{Kind: "caret", Line: line + 1, Column: column + 1}
			}
			if request.Background && previous != nil && previous != d {
				// A background open must not take the foreground tab.
				a.selectDocument(p, previous.id)
			}
			done <- outcome{result: pluginservice.OpenResult{
				DocumentSummary: summarize(p, d), WasAlreadyOpen: already,
				WindowIsForeground: true, AppliedSelection: applied,
			}}
		}
		if d := p.docs.byPath(request.Path); d != nil {
			if !request.Background {
				a.selectDocument(p, d.id)
			}
			finish(d, nil, true)
			return struct{}{}, nil
		}
		if p.docs.openWaiters == nil {
			p.docs.openWaiters = make(map[string][]func(*document, error))
		}
		p.docs.openWaiters[request.Path] = append(p.docs.openWaiters[request.Path], func(d *document, openErr error) { finish(d, openErr, false) })
		a.openFile(p, request.Path)
		return struct{}{}, nil
	})
	if err != nil {
		return pluginservice.OpenResult{}, err
	}
	select {
	case result := <-done:
		return result.result, result.err
	case <-ctx.Done():
		return pluginservice.OpenResult{}, ctx.Err()
	}
}

// openURL opens an address in the system browser. Tests replace it.
var openURL = app.OpenURL

func (w pluginWorkbench) OpenExternal(ctx context.Context, address string) error {
	_, err := onWindow(w.app, ctx, func(*App) (struct{}, error) {
		return struct{}{}, openURL(address)
	})
	return err
}
