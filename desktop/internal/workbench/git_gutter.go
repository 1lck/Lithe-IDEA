package workbench

import (
	"context"
	"path/filepath"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/editorview"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// This file keeps the editor's Git change markers: the changes of an open file against the Git
// index, drawn in the gutter. Core computes the diff (git.diff); this file only groups its
// lines into changes, places the markers and forwards the staging of one change to Core
// (git.stageGutterChange). The markers are read in the background when a file is saved, when
// the Git status is read again, and when the file opens; they are never read per keystroke.

// gitGutterKernel is what the markers ask of the kernel.
type gitGutterKernel interface {
	GitDiff(ctx context.Context, request core.GitDiffRequest) ([]core.GitDiffFile, error)
	StageGutterChange(ctx context.Context, root, path string, change core.GutterChange) error
}

// gitGutterState is one open file's markers and the one whose popover is open.
type gitGutterState struct {
	// gen counts the reads; an answer for an older read is dropped.
	gen   int
	hunks []gitHunk
	// peek is the marker a click chose, and peekOpen says its popover is open.
	peek     *gitHunk
	peekOpen bool
}

// gitHunk is one change of a file: the change Core's gutter stage takes, and its kind.
type gitHunk struct {
	kind   editorview.GutterKind
	change core.GutterChange
}

// hunksOf groups the lines of a file's diff into changes. Consecutive removed and added lines
// form one change: added only is an addition, removed only a deletion that sits above the next
// line, and both a modification. Spans are one-based and end-exclusive, as the stage takes them.
func hunksOf(file core.GitDiffFile) []gitHunk {
	var hunks []gitHunk
	lastOld, lastNew := 0, 0
	var removed, added []string
	oldStart, newStart := 0, 0
	flush := func() {
		if len(removed) == 0 && len(added) == 0 {
			return
		}
		change := core.GutterChange{OriginalLines: removed, ModifiedLines: added}
		if len(removed) > 0 {
			change.OriginalStart, change.OriginalEnd = oldStart, oldStart+len(removed)
		} else {
			change.OriginalStart, change.OriginalEnd = lastOld+1, lastOld+1
		}
		if len(added) > 0 {
			change.ModifiedStart, change.ModifiedEnd = newStart, newStart+len(added)
		} else {
			change.ModifiedStart, change.ModifiedEnd = lastNew+1, lastNew+1
		}
		kind := editorview.GutterModified
		switch {
		case len(removed) == 0:
			kind = editorview.GutterAdded
		case len(added) == 0:
			kind = editorview.GutterDeleted
		}
		hunks = append(hunks, gitHunk{kind: kind, change: change})
		removed, added = nil, nil
	}
	for _, line := range file.Lines {
		switch line.LineType {
		case "removed":
			if line.OldLine == nil {
				continue
			}
			if len(removed) == 0 {
				oldStart = *line.OldLine
			}
			removed = append(removed, line.Content)
			lastOld = *line.OldLine
		case "added":
			if line.NewLine == nil {
				continue
			}
			if len(added) == 0 {
				newStart = *line.NewLine
			}
			added = append(added, line.Content)
			lastNew = *line.NewLine
		default:
			flush()
			if line.OldLine != nil {
				lastOld = *line.OldLine
			}
			if line.NewLine != nil {
				lastNew = *line.NewLine
			}
		}
	}
	flush()
	return hunks
}

// decoration is the gutter mark of a change, with the zero-based lines the editor takes.
func (h gitHunk) decoration() editorview.GutterDecoration {
	if h.kind == editorview.GutterDeleted {
		return editorview.GutterDecoration{Kind: h.kind, StartLine: h.change.ModifiedStart - 1}
	}
	return editorview.GutterDecoration{Kind: h.kind, StartLine: h.change.ModifiedStart - 1, EndLine: h.change.ModifiedEnd - 2}
}

// gitHunkAt is the change a click on a marker line chose: the marker that covers the line, the
// deletion mark for its own line.
func gitHunkAt(hunks []gitHunk, line int, kind editorview.GutterKind) (gitHunk, bool) {
	for _, h := range hunks {
		d := h.decoration()
		if h.kind == kind && line >= d.StartLine && (line <= d.EndLine || h.kind == editorview.GutterDeleted && line == d.StartLine) {
			return h, true
		}
	}
	return gitHunk{}, false
}

// gitRelativePath is the path of file below the repository root, with "/" separators, or false
// when the file is outside it.
func gitRelativePath(root, file string) (string, bool) {
	rel, err := filepath.Rel(root, file)
	if err != nil || rel == "." || strings.HasPrefix(rel, "..") {
		return "", false
	}
	return filepath.ToSlash(rel), true
}

// changeAt is the status change of one repository-relative path.
func (g gitState) changeAt(path string) (core.GitChange, bool) {
	for _, change := range g.status.Changes {
		if change.Path == path {
			return change, true
		}
	}
	return core.GitChange{}, false
}

// gitGutterEnabled reports whether the markers show; the setting is stored as its negative.
func (a *App) gitGutterEnabled() bool { return !a.settings.HideGitGutter }

// refreshGitGutter reads the markers of one open file in the background. The old markers stay
// until the answer arrives; a failed read keeps them too.
func (a *App) refreshGitGutter(p *project, d *document) {
	if p == nil || d == nil || d.virtual || p.docs.find(d.id) != d {
		return
	}
	if !a.gitGutterEnabled() {
		d.gutter.hunks = nil
		d.view.SetGutterDecorations(nil)
		return
	}
	kernel, ok := a.kernel.(gitGutterKernel)
	if !ok || !p.git.isRepository() {
		return
	}
	root := p.git.repositoryRoot(p.root)
	rel, ok := gitRelativePath(root, d.path)
	if !ok {
		return
	}
	// A file Git does not track yet, or one added to the index, has no earlier version in
	// the index to compare with: it is compared with HEAD so its lines show as added.
	request := core.GitDiffRequest{Root: root, Path: rel}
	if change, found := p.git.changeAt(rel); found {
		request.Untracked = change.Untracked || change.Status == "??"
		if !request.Untracked && strings.HasPrefix(change.Status, "A") {
			request.Reference = "HEAD"
		}
	}
	d.gutter.gen++
	gen := d.gutter.gen
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		// The markers follow every edit and status, too often for the console.
		files, err := kernel.GitDiff(core.AutomaticRefresh(ctx), request)
		var hunks []gitHunk
		if err == nil && len(files) > 0 {
			hunks = hunksOf(files[0])
		}
		return func(a *App) {
			if d.gutter.gen != gen || p.docs.find(d.id) != d || !a.gitGutterEnabled() {
				return
			}
			if err != nil {
				a.gitOperationFailed("git_gutter", err)
				return
			}
			d.gutter.hunks = hunks
			decorations := make([]editorview.GutterDecoration, 0, len(hunks))
			for _, h := range hunks {
				decorations = append(decorations, h.decoration())
			}
			d.view.SetGutterDecorations(decorations)
		}
	})
}

// refreshGitGutters reads the markers of every open file of the project.
func (a *App) refreshGitGutters(p *project) {
	for _, d := range p.docs.list {
		a.refreshGitGutter(p, d)
	}
}

// setHideGitGutter stores the Version Control switch and applies it to the open files at once.
func (a *App) setHideGitGutter(hide bool) {
	if a.settings.HideGitGutter == hide {
		return
	}
	a.settings.HideGitGutter = hide
	a.saveSettings()
	if p := a.project; p != nil {
		a.refreshGitGutters(p)
	}
}

// gitGutterClicked opens the popover of the marker a click chose. The popover is declared by the
// file's control in the next paint.
func (a *App) gitGutterClicked(d *document, click editorview.GutterClick) {
	h, ok := gitHunkAt(d.gutter.hunks, click.Line, click.Kind)
	if !ok {
		return
	}
	d.gutter.peek = &h
	d.gutter.peekOpen = true
	a.invalidator.Invalidate()
}

// stageGitGutter stages exactly one change, read from the saved file. Core refuses the change
// when the index or the file moved since the markers were read; the markers are read again
// after the status is.
func (a *App) stageGitGutter(p *project, d *document, h gitHunk) {
	kernel, ok := a.kernel.(gitGutterKernel)
	if !ok || d.dirty() || d.virtual {
		return
	}
	root := p.git.repositoryRoot(p.root)
	rel, ok := gitRelativePath(root, d.path)
	if !ok {
		return
	}
	d.gutter.peekOpen, d.gutter.peek = false, nil
	a.performed("git.gutter.stage", surfaceButton)
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		err := kernel.StageGutterChange(ctx, root, rel, h.change)
		return func(a *App) {
			a.loadGit(p)
			if err != nil {
				a.reviewFailed("git_gutter_stage", err)
			}
		}
	})
}

// revertGitGutter opens the Diff of the file, where its blocks are rolled back under the
// existing confirmation. The marker does not roll back on its own: a rollback discards work.
func (a *App) revertGitGutter(p *project, d *document) {
	root := p.git.repositoryRoot(p.root)
	rel, ok := gitRelativePath(root, d.path)
	if !ok {
		return
	}
	d.gutter.peekOpen, d.gutter.peek = false, nil
	a.openDiff(p, core.GitChange{Path: rel, Status: "M", Worktree: true})
}

// gitGutterPeek declares the popover of a clicked marker: the text it replaced, and the stage and
// revert actions. It hangs off the file's control.
func (a *App) gitGutterPeek(c ui.C, p *project, d *document, anchor ui.Box) {
	if d.gutter.peek == nil || p == nil {
		return
	}
	h := *d.gutter.peek
	ui.Popover(c.Key("gutterpeek"), anchor, &d.gutter.peekOpen, func() {
		ui.Column(c).Gap(6).MinWidth(280).Children(func() {
			ui.Text(c, i18n.Shared(a.language(), "desktop.git.gutter.before")).FontSize(12).Weight(gfx.WeightSemibold).Color(a.colors.Subtle)
			const maxLines = 20
			if len(h.change.OriginalLines) == 0 {
				ui.Text(c, i18n.Shared(a.language(), "desktop.git.gutter.noEarlier")).FontSize(12).Color(a.colors.Subtle)
			}
			for i, line := range h.change.OriginalLines {
				if i == maxLines {
					break
				}
				ui.Text(c.KeyInt(i), line).Mono().FontSize(12).Color(a.colors.Text).Ellipsis()
			}
			ui.Row(c).Gap(6).Children(func() {
				if ui.Button(c.Key("stage"), i18n.Shared(a.language(), "desktop.git.gutter.stage")).Disabled(d.dirty()).Clicked() {
					c.After(func() { a.stageGitGutter(p, d, h) })
				}
				if ui.Button(c.Key("revert"), i18n.Shared(a.language(), "desktop.git.gutter.revert")).Outline().Clicked() {
					c.After(func() { a.revertGitGutter(p, d) })
				}
			})
		})
	})
	if !d.gutter.peekOpen {
		d.gutter.peek = nil
	}
}
