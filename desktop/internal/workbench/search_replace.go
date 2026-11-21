package workbench

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"path/filepath"
	"strconv"
	"strings"

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
// bytes that were read. A remote workspace's closed files are read and written
// on its host the way its documents are (remote_documents.go).

// searchReplacer is the part of Core Replace in Files needs.
type searchReplacer interface {
	PreviewWorkspaceReplace(context.Context, core.WorkspaceReplaceRequest) ([]core.WorkspaceReplaceFile, error)
	ReplaceText(context.Context, core.TextReplaceRequest) (string, int, error)
	DecodeFileBytes(context.Context, []byte, string) (core.DecodedFile, error)
	EncodeFileText(context.Context, string, string, *bool) (core.EncodedText, error)
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
	if p == nil {
		return
	}
	replacer, ok := a.kernel.(searchReplacer)
	r := &p.replace
	if !ok || p == nil || strings.TrimSpace(query.text) == "" || r.loading || r.applying {
		return
	}
	snapshots := captureSearchText(p)
	revisions := map[string]int{}
	for _, doc := range p.docs.list {
		if path, inside := projectRelative(p.root, doc.path); inside && !doc.virtual {
			revisions[path] = doc.view.Revision()
		}
	}
	*r = projectReplace{open: true, loading: true, query: query, replacement: replacement, revisions: revisions, expanded: map[string]bool{}}
	root := p.root
	budget := a.searchPreferences.ReplacementMaxFileBytes
	a.background(p, searchTimeout, func(ctx context.Context) func(*App) {
		files, err := replacer.PreviewWorkspaceReplace(ctx, core.WorkspaceReplaceRequest{
			Root: root, Query: query.text, Replacement: replacement, FileMask: query.mask,
			CaseSensitive: query.matchCase, WholeWords: query.wholeWords, RegularExpression: query.regex,
			TextOverrides: materializeSearchText(snapshots), MaxFileBytes: budget, ScopeExpression: query.scope, IncludeIgnored: query.includeIgnored,
			IncludeGenerated: query.includeGenerated, FollowSymlinks: query.followSymlinks,
		})
		return func(a *App) {
			if !r.open || r.query != query || r.replacement != replacement {
				return
			}
			r.loading = false
			if err != nil {
				a.operationFailed("workspace_replace_preview", p.logError(err))
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
			revision, previewed := r.revisions[file.Path]
			if !previewed {
				outcomes = append(outcomes, replaceOutcome{path: path, skipped: true})
				continue
			}
			outcomes = append(outcomes, a.replaceInDocument(d, file, revision))
			continue
		}
		if _, wasOpen := r.revisions[file.Path]; wasOpen {
			outcomes = append(outcomes, replaceOutcome{path: path, skipped: true})
			continue
		}
		closed = append(closed, file)
	}
	query, replacement, root := r.query, r.replacement, p.root
	budget := int64(a.searchPreferences.ReplacementMaxFileBytes)
	read := a.documentBytesOf(p)
	write := func(_ context.Context, path string, data, expected []byte) error {
		return documentio.WriteGuardedLimit(path, data, expected, budget)
	}
	if remote := a.remoteDocuments(p); remote != nil {
		write = remote.save
	}
	r.applying = true
	a.background(p, searchTimeout, func(ctx context.Context) func(*App) {
		for _, file := range closed {
			path := filepath.Join(root, filepath.FromSlash(file.Path))
			outcomes = append(outcomes, replacePreviewInFile(ctx, replacer, read, write, path, query, replacement, budget, file.SourceIdentity))
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

// A closed file is read with read, decoded and re-encoded by Core, and written with write, which
// writes only while the file still holds the bytes read.
func replacePreviewInFile(ctx context.Context, replacer searchReplacer, read documentBytes, write func(context.Context, string, []byte, []byte) error, path string, query searchQuery, replacement string, limit int64, identity string) replaceOutcome {
	outcome := replaceOutcome{path: path}
	data, err := read(ctx, path, limit)
	if err != nil {
		outcome.err = err
		return outcome
	}
	if identity != "" {
		hash := sha256.Sum256(data)
		if hex.EncodeToString(hash[:]) != identity {
			outcome.err = documentio.ErrConflict
			return outcome
		}
	}
	decoded, err := replacer.DecodeFileBytes(ctx, data, "")
	if err != nil {
		outcome.err = err
		return outcome
	}
	text, count, err := replacer.ReplaceText(ctx, core.TextReplaceRequest{Text: decoded.Text, Query: query.text, Replacement: replacement, CaseSensitive: query.matchCase, WholeWords: query.wholeWords, RegularExpression: query.regex})
	if err != nil || count == 0 {
		outcome.err, outcome.skipped = err, err == nil
		return outcome
	}
	encoded, err := replacer.EncodeFileText(ctx, text, decoded.Encoding, &decoded.HasBOM)
	if err != nil {
		outcome.err = err
		return outcome
	}
	outcome.err = write(ctx, path, encoded.Bytes, data)
	outcome.before = []byte(decoded.Text)
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
		} else if words, remote := a.remoteDocumentReason(reason); remote {
			message = words
		}
		a.operationFailed("project_replace", documentLogError(reason))
		a.notifyError(t.ReplacePartlyFailed(strconv.Itoa(changed), strconv.Itoa(failed), message))
		return
	}
	if skipped > 0 {
		a.notify(t.ReplaceSkipped(strconv.Itoa(changed), strconv.Itoa(skipped)))
		return
	}
	a.notifyKind(t.ReplaceDone(strconv.Itoa(changed)), ui.ToastSuccess)
}

// projectRelative is path relative to root with forward slashes, and false when path is root
// itself or lies outside it.
func projectRelative(root, path string) (string, bool) {
	rel, err := filepath.Rel(root, path)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		return "", false
	}
	return filepath.ToSlash(rel), true
}
