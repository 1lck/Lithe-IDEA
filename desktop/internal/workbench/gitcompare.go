package workbench

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// This file holds the comparisons of the Log tab's buttons, as the macOS Log has them: the
// current branch against the selected reference or against the working tree. Core lists the
// files that differ and reads each one's diff; the comparison shows in a Diff tab that steps
// through the files. Each request runs on the project's context, so Git's output shows in the
// Git console like any other command's.

// primaryComparison is what the reference pane's compare button compares, as the macOS Log
// does: the current branch with the selected reference when one other than it is selected,
// and with the working tree otherwise. A detached HEAD is a revision Core cannot compare with
// a reference, so ok is false for it with a reference selected.
func (l *gitLogState) primaryComparison() (base core.GitReference, target *core.GitReference, ok bool) {
	base = l.currentReference()
	selected, hasSelected := l.findReference(l.refSelected)
	if !hasSelected || selected.IsCurrent || selected.FullName == base.FullName {
		return base, nil, true
	}
	if base.Kind == "" {
		return base, nil, false
	}
	return base, &selected, true
}

// compareReferences compares references of the repository the log walks, see
// compareReferencesAt.
func (a *App) compareReferences(p *project, base core.GitReference, target *core.GitReference) {
	a.compareReferencesAt(p, p.logRepositoryRoot(), base, target)
}

// compareReferencesAt lists the files that differ between base and target, or between base and
// the working tree when target is nil, in the repository at root, and opens the Diff tab of the
// first one. A comparison with nothing to show says so instead.
func (a *App) compareReferencesAt(p *project, root string, base core.GitReference, target *core.GitReference) {
	kernel, ok := a.reviewKernel()
	l := &p.log
	if !ok || !p.git.isRepository() || l.comparing || base.FullName == "" {
		return
	}
	l.comparing = true
	a.performed("git.compare", surfaceButton)
	a.background(p, reviewTimeout, func(ctx context.Context) func(*App) {
		files, err := kernel.GitComparison(ctx, root, base, target)
		return func(a *App) {
			p.log.comparing = false
			lang := a.language()
			if err != nil {
				if target == nil {
					a.notifyError(i18n.SharedFormat(lang, "git.log.workingTreeComparisonFailed", map[string]string{"branch": base.ShortName, "error": reviewReason(err)}))
				} else {
					a.notifyError(i18n.SharedFormat(lang, "git.diff.compareRefsFailed", map[string]string{"base": base.ShortName, "target": target.ShortName, "error": reviewReason(err)}))
				}
				a.gitOperationFailed("git_comparison", err)
				return
			}
			if len(files) == 0 {
				a.notifyInfo(i18n.Shared(lang, "git.diff.noDifferences"))
				return
			}
			a.openComparisonDiff(p, root, &diffComparison{base: base, target: target}, files)
		}
	})
}

// openComparisonDiff opens the Diff tab of the first of the files a comparison listed, in the
// repository at root. The tab steps through the others and reads each one as it shows it.
func (a *App) openComparisonDiff(p *project, root string, compare *diffComparison, files []core.GitComparisonFile) *diffTab {
	if len(files) == 0 {
		return nil
	}
	changes := make([]core.GitChange, len(files))
	for i, f := range files {
		changes[i] = core.GitChange{Path: f.Path, Status: f.Status, Untracked: f.Untracked}
	}
	return a.showDiff(p, root, compare.key(), changes[0], changes, diffOrigin{compare: compare})
}
