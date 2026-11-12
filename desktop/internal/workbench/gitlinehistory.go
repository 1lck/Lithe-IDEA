package workbench

import (
	"context"
	"strconv"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// This file keeps the line history of the editor (matrix id git-line-history): the first-parent
// commits that touched the caret line or the selected lines of a file. Core traces the lines
// (git.lineHistory) against the editor's snapshot, so unsaved edits are answered too; this file
// starts the trace in the background, keeps the answer, drops an answer the dialog no longer
// waits for, and opens the file's diff of a commit. The dialog is declared in
// gitlinehistory_view.go, and the editor menu item in editor_menu.go.

// lineHistoryKernel is the part of the kernel the line history uses. *core.Client implements
// it; a kernel that does not (a test double) hides the item.
type lineHistoryKernel interface {
	GitLineHistory(ctx context.Context, request core.LineHistoryRequest) (core.LineHistory, error)
}

// lineHistoryState is the open line history dialog of a project.
type lineHistoryState struct {
	open bool
	// gen counts the traces started; an answer of an older trace is dropped.
	gen     int
	busy    bool
	path    string
	start   int
	end     int
	err     string
	history core.LineHistory
	list    ui.ListState
}

// lineHistoryRange is the one-based inclusive line range an editor asks about: the selected
// lines, or the caret line when nothing is selected. A selection that ends at the start of a
// line does not include that line.
func lineHistoryRange(d *document) (start, end int) {
	startLine, _, endLine, endColumn, selected := d.view.SelectionUTF16()
	if !selected {
		line, _ := d.view.CaretUTF16()
		return line + 1, line + 1
	}
	if endColumn == 0 && endLine > startLine {
		endLine--
	}
	return startLine + 1, endLine + 1
}

// startLineHistory traces the lines the editor asks about in d against the repository of the
// project and opens the dialog with the answer.
func (a *App) startLineHistory(p *project, d *document) {
	kernel, ok := a.kernel.(lineHistoryKernel)
	if !ok {
		return
	}
	root := p.git.repositoryRoot(p.root)
	rel, inside := gitRelativePath(root, d.path)
	h := &p.lineHistory
	if !inside {
		a.notify(i18n.Shared(a.language(), "desktop.lineHistory.outsideRepository"))
		return
	}
	a.performed("git.lineHistory", surfaceMenu)
	start, end := lineHistoryRange(d)
	content, _ := d.view.Text()
	h.gen++
	gen := h.gen
	*h = lineHistoryState{open: true, gen: gen, busy: true, path: rel, start: start, end: end}
	request := core.LineHistoryRequest{Root: root, Path: rel, Content: string(content), StartLine: start, EndLine: end}
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		history, err := kernel.GitLineHistory(ctx, request)
		return func(a *App) {
			h := &p.lineHistory
			if !h.open || h.gen != gen {
				return
			}
			h.busy = false
			if err != nil {
				h.err = reviewReason(err)
				a.gitOperationFailed("git_line_history", err)
				return
			}
			h.history = history
		}
	})
}

// closeLineHistory closes the dialog and drops the trace it waits for.
func (a *App) closeLineHistory(p *project) {
	h := &p.lineHistory
	h.open = false
	h.gen++
}

// openLineHistoryCommit opens the diff of the file a traced commit changed, the file as it is
// at that commit.
func (a *App) openLineHistoryCommit(p *project, commit core.LineHistoryCommit) {
	if commit.Hash == "" || commit.PathAtCommit == "" {
		return
	}
	a.performed("git.lineHistory.openCommit", surfaceButton)
	root := p.git.repositoryRoot(p.root)
	t := a.openCommitDiff(p, root, commit.Hash, core.GitCommitFile{Status: "M", Path: commit.PathAtCommit})
	if len(commit.RelevantRanges) > 0 {
		a.revealDiffLine(t, commit.RelevantRanges[0].NewStart)
	}
}

// unmappedLinesOf is the traced lines of kind, as a comma-separated list of line numbers.
func unmappedLinesOf(lines []core.LineHistoryUnmapped, kind string) string {
	var numbers []string
	for _, line := range lines {
		if line.Kind == kind {
			numbers = append(numbers, strconv.Itoa(line.Line))
		}
	}
	return strings.Join(numbers, ", ")
}

// gutterContextLine is called for a secondary press on line (zero-based) of the gutter of d. The
// line history then traces that line: unless the press lands inside the selection, the caret moves
// there, so the editor menu's Show Line History asks about it.
func (a *App) gutterContextLine(d *document, line int) {
	startLine, _, endLine, _, selected := d.view.SelectionUTF16()
	if selected && line >= startLine && line <= endLine {
		return
	}
	d.view.GoToLine(line + 1)
}

// revealDiffLine makes the diff tab t go to the change block that holds line (1-based, of the
// after side). A tab whose layout is not ready yet goes there when it is laid out.
func (a *App) revealDiffLine(t *diffTab, line int) {
	if t == nil || line <= 0 {
		return
	}
	t.revealLine = line
	a.applyDiffReveal(t)
}

// applyDiffReveal selects the difference whose after side holds the pending reveal line, the first
// one after it when the line is unchanged, and scrolls to it.
func (a *App) applyDiffReveal(t *diffTab) {
	if t.revealLine <= 0 || t.layout == nil || t.after == nil {
		return
	}
	line := t.revealLine - 1
	pick := -1
	for i, f := range t.layout.fragments {
		if line >= f.after.start && line < f.after.end {
			pick = i
			break
		}
		if f.after.start > line && pick < 0 {
			pick = i
		}
	}
	t.revealLine = 0
	if pick < 0 {
		return
	}
	t.current = pick
	t.scrollToCurrent()
}
