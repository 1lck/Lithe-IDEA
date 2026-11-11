package workbench

import (
	"context"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/githubapi"
)

// github_checks.go is the checks and the review threads of the pull-request panel. The checks of a
// pull request's head commit are its check runs and its commit statuses, read through two Core
// operations and listed together. A check that has not completed is read again after a while, and
// only while the panel is open and shows that pull request. The review threads group the line
// comments of the review by file; a comment whose line is gone is outdated.

// checkRefreshInterval is how long the panel waits before it reads the checks again while one is
// still running.
const checkRefreshInterval = 20 * time.Second

// loadPullRequestChecks reads the checks of the selected pull request's head commit. A pull request
// whose head commit is unknown has no checks to show.
func (a *App) loadPullRequestChecks(p *project, number uint64) {
	pr := &a.pullRequests
	client := a.githubAPI()
	token := a.githubToken()
	if pr.repo == nil || pr.detail == nil || pr.detail.HeadSHA == nil || *pr.detail.HeadSHA == "" || client == nil || token == "" {
		pr.checks, pr.checksErr, pr.checksLoaded = nil, "", true
		return
	}
	pr.checkGen++
	gen := pr.checkGen
	repo, commit := *pr.repo, *pr.detail.HeadSHA
	pr.checksLoaded = false
	language := a.language()
	a.background(p, githubReadTimeout, func(ctx context.Context) func(*App) {
		var all []githubapi.CheckRun
		var firstErr error
		for _, operation := range []string{"listCheckRuns", "getCombinedStatus"} {
			raw, err := client.Do(ctx, core.GitHubRequest{Operation: operation, Repository: &repo, Commit: commit}, token)
			if err == nil {
				var items []githubapi.CheckRun
				items, err = githubapi.DecodeCheckRuns(raw)
				all = append(all, items...)
			}
			if err != nil && firstErr == nil {
				firstErr = err
			}
		}
		return func(a *App) {
			pr := &a.pullRequests
			if !pr.open || pr.checkGen != gen || pr.selected != number {
				return
			}
			pr.checksLoaded = true
			pr.checks = all
			pr.checksErr = ""
			if firstErr != nil {
				pr.checksErr = githubFailure(language, firstErr)
			}
			if pr.checksRunning() {
				a.scheduleCheckRefresh(p, number, gen)
			}
		}
	})
}

// scheduleCheckRefresh reads the checks again after checkRefreshInterval. The read is dropped if the
// panel closed or shows another pull request by then.
func (a *App) scheduleCheckRefresh(p *project, number uint64, gen int) {
	a.background(p, checkRefreshInterval+githubReadTimeout, func(ctx context.Context) func(*App) {
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(checkRefreshInterval):
		}
		return func(a *App) {
			pr := &a.pullRequests
			if !pr.open || pr.checkGen != gen || pr.selected != number {
				return
			}
			a.loadPullRequestChecks(p, number)
		}
	})
}

// checksRunning says a check has not completed yet.
func (pr *pullRequestState) checksRunning() bool {
	for _, check := range pr.checks {
		if !strings.EqualFold(check.Status, "completed") {
			return true
		}
	}
	return false
}

// reviewThread is a root line comment and the replies made to it, in the order the review has them.
type reviewThread struct {
	root    githubapi.ReviewComment
	replies []githubapi.ReviewComment
}

// reviewFile is the threads of one file, in the order of the review.
type reviewFile struct {
	path    string
	threads []reviewThread
}

// groupReviewThreads groups the line comments by file, sorted by path. A reply joins the thread of
// its root; a reply whose root is not in the list stands as a thread of its own.
func groupReviewThreads(items []githubapi.ReviewComment) []reviewFile {
	roots := map[uint64]bool{}
	for _, item := range items {
		if item.InReplyTo == nil {
			roots[item.ID] = true
		}
	}
	replies := map[uint64][]githubapi.ReviewComment{}
	for _, item := range items {
		if item.InReplyTo != nil && roots[*item.InReplyTo] {
			replies[*item.InReplyTo] = append(replies[*item.InReplyTo], item)
		}
	}
	var files []reviewFile
	index := map[string]int{}
	add := func(item githubapi.ReviewComment, thread reviewThread) {
		i, ok := index[item.Path]
		if !ok {
			i = len(files)
			index[item.Path] = i
			files = append(files, reviewFile{path: item.Path})
		}
		files[i].threads = append(files[i].threads, thread)
	}
	for _, item := range items {
		switch {
		case item.InReplyTo == nil:
			add(item, reviewThread{root: item, replies: replies[item.ID]})
		case !roots[*item.InReplyTo]:
			add(item, reviewThread{root: item})
		}
	}
	sort.SliceStable(files, func(i, j int) bool { return files[i].path < files[j].path })
	return files
}

// openReviewLine opens the file of a review comment at its line, under the repository's root. A
// comment whose line is outdated opens the file alone.
func (a *App) openReviewLine(p *project, path string, line *uint64) {
	pr := &a.pullRequests
	if pr.root == "" || path == "" {
		return
	}
	full := filepath.Join(pr.root, filepath.FromSlash(path))
	if line == nil {
		a.openFile(p, full)
		return
	}
	a.openFileAt(p, full, int(*line))
}
