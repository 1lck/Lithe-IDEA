package workbench

import (
	"context"
	"slices"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/ui"
)

// This file holds the state and the actions of the Commit tool window's Stash tab, as the macOS
// Commit window has it: the repository's stashes, the files the selected one saved, and the
// buttons that apply, pop, drop and make stashes. The tab is declared in stash_view.go.

// stashListHeight is the height the stash list starts with over the selected stash's files,
// and stashListMin and stashFilesMin the least the splitter leaves each of them.
const (
	stashListHeight = 160
	stashListMin    = 60
	stashFilesMin   = 80
)

// stashState is the Stash tab of a project.
type stashState struct {
	// loaded says the list was read since the tab was asked to read it again, and loading
	// that a read is running; gen counts the reads, and the answer of an older one is
	// dropped.
	loaded, loading bool
	gen             int
	// err is why the last read failed, writeErr why the last write did. A read clears only
	// err, so a failed write stays shown after the list is read again.
	err, writeErr string
	// busy is set while a stash is made, applied, popped or dropped.
	busy bool
	list []core.GitStash

	// selected is the identity of the selected stash, "" for none, files what it saved and
	// tree the list of them.
	selected string
	files    []core.GitDiffFile
	tree     savedFiles
	// filesLoading says the selected stash's files are being read, and filesGen counts the
	// reads; filesErr is why the last one failed.
	filesLoading bool
	filesGen     int
	filesErr     string

	// pushOpen says the dialog that stashes the local changes is open; message and untracked
	// shape the stash it makes.
	pushOpen  bool
	message   ui.Field
	untracked bool
	// dropping is the stash waiting for the user to confirm dropping it, nil for none.
	dropping *core.GitStash

	stashes ui.ListState
	split   ui.SplitterState
}

// selectedStash is the selected stash.
func (s *stashState) selectedStash() (core.GitStash, bool) {
	i := slices.IndexFunc(s.list, func(stash core.GitStash) bool { return stash.OID == s.selected })
	if i < 0 {
		return core.GitStash{}, false
	}
	return s.list[i], true
}

// clearSelection forgets the selected stash and what it saved.
func (s *stashState) clearSelection() {
	s.selected, s.files, s.filesErr = "", nil, ""
	s.filesLoading, s.filesGen = false, s.filesGen+1
	s.tree.reset()
}

// showStashes shows the Commit tool window on its Stash tab and reads the stashes again.
func (a *App) showStashes() {
	a.performed("git.stashes.show", surfaceMenu)
	a.layout.commitTab = commitTabStash
	if !a.chrome.isOpen(catalogIndex[itemCommit]) {
		a.reduceChrome(core.SetChromeOpen(itemCommit, true))
	}
	if p := a.project; p != nil {
		p.stash.loaded = false
	}
}

// loadStashes reads the repository's stashes. A selected stash that is gone is no longer
// selected; one that is still there keeps its files.
func (a *App) loadStashes(p *project) {
	kernel, ok := a.reviewKernel()
	s := &p.stash
	if !ok || !p.git.isRepository() {
		return
	}
	s.loading, s.gen = true, s.gen+1
	gen, root := s.gen, p.git.repositoryRoot(p.root)
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		list, err := kernel.GitStashes(ctx, root)
		return func(a *App) {
			s := &p.stash
			if s.gen != gen {
				return
			}
			s.loading, s.loaded = false, true
			if err != nil {
				s.err = reviewReason(err)
				a.gitOperationFailed("git_stash_list", err)
				return
			}
			s.err, s.list = "", list
			if _, ok := s.selectedStash(); !ok && s.selected != "" {
				s.clearSelection()
			}
		}
	})
}

// selectStash selects the stash with identity oid and reads the files it saved. Selecting the
// selected stash again reads them again only when the last read failed.
func (a *App) selectStash(p *project, oid string) {
	kernel, ok := a.reviewKernel()
	s := &p.stash
	if !ok || (s.selected == oid && s.filesErr == "") {
		return
	}
	s.clearSelection()
	s.selected = oid
	stash, found := s.selectedStash()
	if !found {
		s.selected = ""
		return
	}
	s.filesLoading = true
	gen, root := s.filesGen, p.git.repositoryRoot(p.root)
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		files, err := kernel.GitStashDiff(ctx, root, stash)
		return func(a *App) {
			s := &p.stash
			if s.filesGen != gen || s.selected != oid {
				return
			}
			s.filesLoading = false
			if err != nil {
				s.filesErr = i18n.SharedFormat(a.language(), "git.diff.getStashDiffFailed", map[string]string{"stash": stash.Reference, "error": reviewReason(err)})
				a.gitOperationFailed("git_stash_diff", err)
				return
			}
			s.files = files
			s.tree.reset(newSavedLayer("", files))
		}
	})
}

// stashDate is the date a stash row shows: Git's ISO date in local time, as the Log tab shows a
// commit's, or as Git wrote it when it does not parse.
func stashDate(stash core.GitStash) string {
	t, err := time.Parse("2006-01-02 15:04:05 -0700", stash.Date)
	if err != nil {
		return stash.Date
	}
	return t.Local().Format(logDateFormat)
}

// stashCommitFiles are a stash's files as the Log tab's grouping takes a commit's.
func stashCommitFiles(files []core.GitDiffFile) []core.GitCommitFile {
	out := make([]core.GitCommitFile, len(files))
	for i, f := range files {
		out[i] = core.GitCommitFile{Path: f.Path, Status: f.Status}
	}
	return out
}

// openStashFile opens the Diff tab of the file at path the selected stash saved.
func (a *App) openStashFile(p *project, file string) {
	s := &p.stash
	stash, ok := s.selectedStash()
	if !ok || file == "" {
		return
	}
	a.openStashDiff(p, p.git.repositoryRoot(p.root), stash, file, s.files)
}

// stashWrite runs one write of the Stash tab, then reads the status, the stashes and the open
// diffs of the working tree again whatever the outcome. The failure is shown in the tab.
func (a *App) stashWrite(p *project, operation string, write func(ctx context.Context, kernel gitReviewKernel, root string) error) {
	kernel, ok := a.reviewKernel()
	s := &p.stash
	if !ok || s.busy {
		return
	}
	s.busy, s.writeErr, s.dropping = true, "", nil
	root := p.git.repositoryRoot(p.root)
	a.performed("git."+operation, surfaceButton)
	a.showGitConsole(itemCommit)
	a.background(p, syncTimeout, func(ctx context.Context) func(*App) {
		err := write(ctx, kernel, root)
		return func(a *App) {
			s := &p.stash
			s.busy = false
			a.loadGit(p)
			a.loadStashes(p)
			a.reloadDiffs(p, root)
			if err != nil {
				s.writeErr = reviewReason(err)
				a.gitOperationFailed(operation, err)
			}
		}
	})
}

// openStashPush opens the dialog that stashes the local changes.
func (a *App) openStashPush(p *project) {
	s := &p.stash
	s.pushOpen, s.writeErr = true, ""
	s.message.SetText("")
}

// pushStash stashes the local changes with the typed message, the untracked files too when
// the dialog asks for them, and closes the dialog.
func (a *App) pushStash(p *project) {
	s := &p.stash
	message, untracked := strings.TrimSpace(s.message.Text()), s.untracked
	s.pushOpen = false
	a.stashWrite(p, "git_stash_push", func(ctx context.Context, k gitReviewKernel, root string) error {
		return k.GitStashPush(ctx, root, message, untracked)
	})
	s.message.SetText("")
}

// applyStash applies stash to the working tree, and drops it once applied when pop is set.
// Core finds the stash by its identity, so a stash made meanwhile does not change which one.
func (a *App) applyStash(p *project, stash core.GitStash, pop bool) {
	if pop {
		a.stashWrite(p, "git_stash_pop", func(ctx context.Context, k gitReviewKernel, root string) error {
			return k.GitStashPop(ctx, root, stash)
		})
		return
	}
	a.stashWrite(p, "git_stash_apply", func(ctx context.Context, k gitReviewKernel, root string) error {
		return k.GitStashApply(ctx, root, stash)
	})
}

// confirmDropStash asks the user to confirm dropping stash.
func (s *stashState) confirmDropStash(stash core.GitStash) {
	s.dropping = &stash
}

// dropStash drops the stash the user confirmed dropping.
func (a *App) dropStash(p *project) {
	s := &p.stash
	if s.dropping == nil {
		return
	}
	stash := *s.dropping
	a.stashWrite(p, "git_stash_drop", func(ctx context.Context, k gitReviewKernel, root string) error {
		return k.GitStashDrop(ctx, root, stash)
	})
}
