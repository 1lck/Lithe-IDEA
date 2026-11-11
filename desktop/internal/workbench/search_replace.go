package workbench

import (
	"bytes"
	"context"
	"errors"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/vivaui/viva/ui"
)

// Replace in Files: Core plans every replacement (workspace.replacePreview) from
// the files and the unsaved text of open documents, the user confirms the
// preview, and the host applies it. An open document is changed in its editor
// as one undoable edit and saved by the user; a closed file is read again,
// replaced by Core (workspace.replaceText) and written only if it still holds the
// bytes that were read.

// searchReplacer is the part of Core Replace in Files needs.
type searchReplacer interface {
	PreviewWorkspaceReplace(context.Context, core.WorkspaceReplaceRequest) ([]core.WorkspaceReplaceFile, error)
	ReplaceText(context.Context, core.TextReplaceRequest) (string, int, error)
}

// projectReplace is one project's Replace in Files preview and its application.
type projectReplace struct {
	// open shows the preview dialog; loading and applying are the two background steps.
	open, loading, applying bool
	query                   searchQuery
	replacement             string
	files                   []core.WorkspaceReplaceFile
	// revisions are the editor revisions of the open documents the preview read.
	revisions map[string]int
	// include parallels files: whether the user keeps each file in the replacement.
	include []bool
	failure string
	// expanded are the preview files whose changed lines are shown.
	expanded map[string]bool
}

// previewProjectReplace asks Core what Replace All would change and opens the preview.
func (a *App) previewProjectReplace(p *project, query searchQuery, replacement string) {
	replacer, ok := a.kernel.(searchReplacer)
	r := &p.replace
	if !ok || p == nil || strings.TrimSpace(query.text) == "" || r.loading || r.applying {
		return
	}
	overrides := map[string]string{}
	revisions := map[string]int{}
	for _, d := range p.docs.list {
		if d.virtual {
			continue
		}
		rel, inside := projectRelative(p.root, d.path)
		if !inside {
			continue
		}
		revisions[rel] = d.view.Revision()
		if d.dirty() {
			data, _ := d.view.Text()
			overrides[rel] = string(data)
		}
	}
	*r = projectReplace{open: true, loading: true, query: query, replacement: replacement, revisions: revisions, expanded: map[string]bool{}}
	root := p.root
	a.background(p, searchTimeout, func(ctx context.Context) func(*App) {
		files, err := replacer.PreviewWorkspaceReplace(ctx, core.WorkspaceReplaceRequest{
			Root: root, Query: query.text, Replacement: replacement, FileMask: query.mask,
			CaseSensitive: query.matchCase, WholeWords: query.wholeWords, RegularExpression: query.regex,
			TextOverrides: overrides,
		})
		return func(a *App) {
			if !r.open || r.query != query || r.replacement != replacement {
				return
			}
			r.loading = false
			if err != nil {
				r.failure = a.text.Search.ReplaceFailed(err.Error())
				return
			}
			r.files = files
			r.include = make([]bool, len(files))
			for i := range r.include {
				r.include[i] = true
			}
		}
	})
	a.performed("workspace.search.replacePreview", surfaceButton)
}

// closeProjectReplace dismisses the preview without changing anything.
func (a *App) closeProjectReplace(p *project) {
	if p == nil || p.replace.applying {
		return
	}
	p.replace = projectReplace{}
}

// replaceCounts is how many files and occurrences the ticked preview rows change.
func (r *projectReplace) replaceCounts() (files, occurrences int) {
	for i, file := range r.files {
		if !r.include[i] {
			continue
		}
		files++
		for _, match := range file.Matches {
			occurrences += match.OccurrenceCount
		}
	}
	return files, occurrences
}

// replaceOutcome is what applying one file came to.
type replaceOutcome struct {
	path    string
	err     error
	skipped bool
	// before is the text the replacement changed, recorded in local history.
	before []byte
}

// applyProjectReplace applies the confirmed preview.
func (a *App) applyProjectReplace(p *project) {
	replacer, ok := a.kernel.(searchReplacer)
	r := &p.replace
	if !ok || r.loading || r.applying || len(r.files) == 0 {
		return
	}
	var closed []core.WorkspaceReplaceFile
	var outcomes []replaceOutcome
	for i, file := range r.files {
		if !r.include[i] {
			continue
		}
		path := filepath.Join(p.root, filepath.FromSlash(file.Path))
		if d := p.docs.byPath(path); d != nil && !d.virtual {
			outcomes = append(outcomes, a.replaceInDocument(d, file, r.revisions[file.Path]))
			continue
		}
		closed = append(closed, file)
	}
	query, replacement, root := r.query, r.replacement, p.root
	write := a.documentWriter
	r.applying = true
	a.background(p, searchTimeout, func(ctx context.Context) func(*App) {
		for _, file := range closed {
			path := filepath.Join(root, filepath.FromSlash(file.Path))
			outcomes = append(outcomes, replaceInFile(ctx, replacer, write, path, query, replacement))
		}
		return func(a *App) {
			p.replace = projectReplace{}
			for _, outcome := range outcomes {
				if outcome.err == nil && !outcome.skipped && outcome.before != nil {
					a.recordLocalHistory(p, outcome.path, "beforeBatchReplace", historyTexts{before: outcome.before})
				}
			}
			a.reportProjectReplace(outcomes)
			a.refreshProjectSearch(p)
		}
	})
	a.performed("workspace.search.replaceAll", surfaceButton)
}

// replaceInDocument puts a file's replaced text in its open editor as one undo step.
// A document edited since the preview is left alone: the preview no longer
// describes it.
func (a *App) replaceInDocument(d *document, file core.WorkspaceReplaceFile, revision int) replaceOutcome {
	outcome := replaceOutcome{path: file.Path}
	if d.view.IsComposing() || d.view.Revision() != revision {
		outcome.skipped = true
		return outcome
	}
	data, _ := d.view.Text()
	if string(data) == file.ReplacementText {
		outcome.skipped = true
		return outcome
	}
	outcome.before = append([]byte(nil), data...)
	outcome.path = d.path
	outcome.err = d.view.ApplyEdits([]editorview.TextEdit{{Range: editorview.Range{Start: 0, End: len(data)}, Text: file.ReplacementText}})
	return outcome
}

// replaceInFile replaces the matches of a closed file. It reads the file again so the
// write is guarded by the bytes the replacement was computed from; a file that is not
// UTF-8 is left alone rather than re-encoded.
func replaceInFile(ctx context.Context, replacer searchReplacer, write func(string, []byte, []byte) error, path string, query searchQuery, replacement string) replaceOutcome {
	outcome := replaceOutcome{path: path}
	data, err := documentio.ReadFile(path)
	if err != nil {
		outcome.err = err
		return outcome
	}
	body, bom := bytes.CutPrefix(data, utf8BOM)
	if !utf8.Valid(body) {
		outcome.skipped = true
		return outcome
	}
	text, count, err := replacer.ReplaceText(ctx, core.TextReplaceRequest{
		Text: string(body), Query: query.text, Replacement: replacement,
		CaseSensitive: query.matchCase, WholeWords: query.wholeWords, RegularExpression: query.regex,
	})
	if err != nil || count == 0 {
		outcome.err, outcome.skipped = err, err == nil
		return outcome
	}
	out := []byte(text)
	if bom {
		out = append(append([]byte{}, utf8BOM...), out...)
	}
	outcome.err = write(path, out, data)
	outcome.before = body
	return outcome
}

// reportProjectReplace tells the user what Replace All changed and what it could not.
func (a *App) reportProjectReplace(outcomes []replaceOutcome) {
	t := a.text.Search
	changed, skipped, failed := 0, 0, 0
	var reason error
	for _, outcome := range outcomes {
		switch {
		case outcome.err != nil:
			failed++
			if reason == nil {
				reason = outcome.err
			}
		case outcome.skipped:
			skipped++
		default:
			changed++
		}
	}
	if failed > 0 {
		message := reason.Error()
		if errors.Is(reason, documentio.ErrConflict) {
			message = t.ReplaceConflict
		}
		a.notify(t.ReplacePartlyFailed(strconv.Itoa(changed), strconv.Itoa(failed), message))
		return
	}
	if skipped > 0 {
		a.notify(t.ReplaceSkipped(strconv.Itoa(changed), strconv.Itoa(skipped)))
		return
	}
	a.notifyKind(t.ReplaceDone(strconv.Itoa(changed)), ui.ToastSuccess)
}

// projectRelative is path relative to root with forward slashes, and false when it
// lies outside root.
func projectRelative(root, path string) (string, bool) {
	rel, err := filepath.Rel(root, path)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		return "", false
	}
	return filepath.ToSlash(rel), true
}
