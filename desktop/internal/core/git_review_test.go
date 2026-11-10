package core

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestGitDiffBlocksAndWorktrees(t *testing.T) {
	repo := committedRepository(t)
	client := NewClient()
	ctx := testContext(t)
	writeFile(t, filepath.Join(repo, "base.txt"), "base\nmore\nthree\n")

	files, err := client.GitDiff(ctx, GitDiffRequest{Root: repo, Path: "base.txt"})
	if err != nil || len(files) != 1 || files[0].Additions != 2 || len(files[0].Rows) == 0 {
		t.Fatalf("GitDiff() = %+v, %v; want one file with 2 additions", files, err)
	}
	target := DiffBlockTarget{Root: repo, Path: "base.txt"}
	plan, err := client.PlanDiffBlocks(ctx, target)
	if err != nil || len(plan.Blocks) != 1 || !plan.Blocks[0].CanToggle {
		t.Fatalf("PlanDiffBlocks() = %+v, %v; want one toggleable block", plan, err)
	}
	if err := client.ApplyDiffBlock(ctx, plan, target, plan.Blocks[0].ID, DiffBlockInclude); err != nil {
		t.Fatalf("ApplyDiffBlock(include) error: %v", err)
	}
	if got := runGit(t, repo, "diff", "--cached", "--numstat"); !strings.HasPrefix(got, "2\t0") {
		t.Fatalf("staged numstat = %q, want 2 additions", got)
	}
	// The plan is bound to the repository state it read: a second write with it is stale.
	if err := client.ApplyDiffBlock(ctx, plan, target, plan.Blocks[0].ID, DiffBlockExclude); err == nil {
		t.Fatal("ApplyDiffBlock with a stale plan succeeded, want GIT_DIFF_BLOCK_STALE")
	}
	plan, err = client.PlanDiffBlocks(ctx, target)
	if err != nil || !plan.Blocks[0].Checked {
		t.Fatalf("PlanDiffBlocks() after include = %+v, %v; want a checked block", plan, err)
	}
	if err := client.ApplyDiffBlock(ctx, plan, target, plan.Blocks[0].ID, DiffBlockExclude); err != nil {
		t.Fatalf("ApplyDiffBlock(exclude) error: %v", err)
	}
	if got := runGit(t, repo, "diff", "--cached", "--numstat"); got != "" {
		t.Fatalf("staged numstat after exclude = %q, want none", got)
	}

	lines, err := client.GitBlame(ctx, repo, "base.txt")
	if err != nil || len(lines) != 3 || lines[0].Uncommitted() || !lines[1].Uncommitted() {
		t.Fatalf("GitBlame() = %+v, %v; want line 1 committed and 2-3 not", lines, err)
	}
	history, err := client.GitLineHistory(ctx, LineHistoryRequest{Root: repo, Path: "base.txt", Content: "base\nmore\nthree\n", StartLine: 1, EndLine: 1})
	if err != nil || len(history.Commits) != 1 || history.Commits[0].Subject != "base" {
		t.Fatalf("GitLineHistory() = %+v, %v; want the base commit", history, err)
	}

	runGit(t, repo, "stash")
	stashes, err := client.GitStashes(ctx, repo)
	if err != nil || len(stashes) != 1 {
		t.Fatalf("GitStashes() = %+v, %v; want one stash", stashes, err)
	}
	if err := client.GitStashPop(ctx, repo, stashes[0]); err != nil {
		t.Fatalf("GitStashPop() error: %v", err)
	}
	if got := runGit(t, repo, "status", "--porcelain"); got != "M base.txt" {
		t.Fatalf("status after pop = %q, want the modification back", got)
	}

	wt := filepath.Join(t.TempDir(), "wt")
	main := localBranch("main")
	if err := client.GitCreateWorktree(ctx, repo, GitWorktreeCreation{
		Mode: GitWorktreeNewBranch, Name: "feat", Reference: &main, Destination: wt,
	}); err != nil {
		t.Fatalf("GitCreateWorktree() error: %v", err)
	}
	trees, err := client.GitWorktrees(ctx, repo)
	if err != nil || len(trees) != 2 || !trees[0].IsPrimary || trees[1].Branch != "refs/heads/feat" {
		t.Fatalf("GitWorktrees() = %+v, %v; want the primary and feat", trees, err)
	}
	if err := client.GitLockWorktree(ctx, repo, trees[1].Path); err != nil {
		t.Fatalf("GitLockWorktree() error: %v", err)
	}
	if err := client.GitRemoveWorktree(ctx, repo, trees[1].Path, false); err == nil {
		t.Fatal("GitRemoveWorktree of a locked worktree succeeded")
	}
	if err := client.GitUnlockWorktree(ctx, repo, trees[1].Path); err != nil {
		t.Fatalf("GitUnlockWorktree() error: %v", err)
	}
	if err := client.GitRemoveWorktree(ctx, repo, trees[1].Path, false); err != nil {
		t.Fatalf("GitRemoveWorktree() error: %v", err)
	}
}

func TestGitRollbackAndWatchContext(t *testing.T) {
	repo := committedRepository(t)
	client := NewClient()
	ctx := testContext(t)
	writeFile(t, filepath.Join(repo, "base.txt"), "changed\n")
	steps, err := client.GitRollbackPrepare(ctx, repo, []GitChange{{Path: "base.txt", Status: " M"}}, false)
	if err != nil || len(steps) == 0 {
		t.Fatalf("GitRollbackPrepare() = %+v, %v; want steps", steps, err)
	}
	for _, step := range steps {
		if err := client.GitRunRollbackStep(ctx, repo, step); err != nil {
			t.Fatalf("GitRunRollbackStep(%+v) error: %v", step, err)
		}
	}
	if got := runGit(t, repo, "status", "--porcelain"); got != "" {
		t.Fatalf("status after rollback = %q, want clean", got)
	}
	watch, ok, err := client.GitWatchContextOf(ctx, repo)
	if err != nil || !ok || watch.GitDirectory == "" {
		t.Fatalf("GitWatchContextOf() = %+v, %v, %v; want a context", watch, ok, err)
	}
	events, err := client.GitClassifyMetadataChanges(ctx, GitMetadataContext{
		RepositoryRoot: watch.RepositoryRoot, GitDirectory: watch.GitDirectory, GitCommonDirectory: watch.GitCommonDirectory,
	}, []string{filepath.Join(watch.GitDirectory, "HEAD"), filepath.Join(watch.GitDirectory, "index")})
	if err != nil || len(events) != 2 || events[0].Kind != "metadata" || !events[1].IndexOnly {
		t.Fatalf("GitClassifyMetadataChanges() = %+v, %v; want metadata and index-only", events, err)
	}
	if _, ok, err := client.GitWatchContextOf(ctx, t.TempDir()); err != nil || ok {
		t.Fatalf("GitWatchContextOf(outside) = %v, %v; want no context", ok, err)
	}
}

func TestGitRebasePreviewBlockersAndSession(t *testing.T) {
	repo := committedRepository(t)
	client := NewClient()
	ctx := testContext(t)
	preview, err := client.GitRebasePreview(ctx, repo, "HEAD")
	if err != nil || preview.Allowed || len(preview.Blockers) == 0 {
		t.Fatalf("GitRebasePreview(HEAD) = %+v, %v; want a blocker for the empty range", preview, err)
	}
	session, err := client.GitRebaseSession(ctx, repo)
	if err != nil || session != nil {
		t.Fatalf("GitRebaseSession() = %+v, %v; want none", session, err)
	}
	writeFile(t, filepath.Join(repo, "two.txt"), "two\n")
	runGit(t, repo, "add", "two.txt")
	runGit(t, repo, "commit", "-m", "two")
	preview, err = client.GitRebasePreview(ctx, repo, "HEAD~1")
	if err != nil || !preview.Allowed || len(preview.Commits) != 1 {
		t.Fatalf("GitRebasePreview(HEAD~1) = %+v, %v; want one allowed commit", preview, err)
	}
	started, err := client.GitRebaseStart(ctx, repo, preview, []RebaseStep{{Hash: preview.Commits[0].Hash, Action: "reword", Message: "second\n"}})
	if err != nil || started == nil || started.Status != "completed" {
		t.Fatalf("GitRebaseStart() = %+v, %v; want a completed session", started, err)
	}
	if got := runGit(t, repo, "log", "-1", "--format=%s"); got != "second" {
		t.Fatalf("subject after the reword = %q, want second", got)
	}
}

// GitStashDiff reads a stash whole, its untracked files among the files, by the stash's
// identity, and keeps reading the same stash after another is pushed over it.
func TestGitStashDiffReadsTheSavedFiles(t *testing.T) {
	repo := committedRepository(t)
	client := NewClient()
	ctx := testContext(t)
	writeFile(t, filepath.Join(repo, "base.txt"), "base\nmore\n")
	writeFile(t, filepath.Join(repo, "notes.txt"), "new\n")
	if err := client.GitStashPush(ctx, repo, "parked", true); err != nil {
		t.Fatalf("GitStashPush() error: %v", err)
	}
	stashes, err := client.GitStashes(ctx, repo)
	if err != nil || len(stashes) != 1 {
		t.Fatalf("GitStashes() = %+v, %v; want one stash", stashes, err)
	}
	parked := stashes[0]
	writeFile(t, filepath.Join(repo, "base.txt"), "other\n")
	runGit(t, repo, "stash")

	files, err := client.GitStashDiff(ctx, repo, parked)
	if err != nil {
		t.Fatalf("GitStashDiff() error: %v", err)
	}
	paths := map[string]GitDiffFile{}
	for _, file := range files {
		paths[file.Path] = file
	}
	base, notes := paths["base.txt"], paths["notes.txt"]
	if len(files) != 2 || base.Additions != 1 || notes.Additions != 1 || len(base.Lines) == 0 {
		t.Fatalf("GitStashDiff() = %+v; want base.txt and the untracked notes.txt, one line added each", files)
	}
}

// GitComparison lists what differs between two branches, and between a branch or HEAD and the
// working tree with its untracked files; GitDiff with the same sides reads a listed file.
func TestGitComparisonListsAndDiffsTheDifferingFiles(t *testing.T) {
	repo := committedRepository(t)
	client := NewClient()
	ctx := testContext(t)
	current := localBranch(runGit(t, repo, "rev-parse", "--abbrev-ref", "HEAD"))
	topic := localBranch("topic")
	runGit(t, repo, "checkout", "-q", "-b", "topic")
	writeFile(t, filepath.Join(repo, "base.txt"), "base\ntopic\n")
	runGit(t, repo, "commit", "-qam", "topic")
	runGit(t, repo, "checkout", "-q", current.ShortName)
	writeFile(t, filepath.Join(repo, "notes.txt"), "new\n")

	files, err := client.GitComparison(ctx, repo, current, &topic)
	if err != nil || len(files) != 1 || files[0].Path != "base.txt" || files[0].Untracked {
		t.Fatalf("GitComparison(current, topic) = %+v, %v; want base.txt", files, err)
	}
	diff, err := client.GitDiff(ctx, GitDiffRequest{Root: repo, Path: "base.txt", Base: &current, Target: &topic})
	if err != nil || len(diff) != 1 || diff[0].Additions != 1 || diff[0].Deletions != 0 {
		t.Fatalf("GitDiff(current, topic) = %+v, %v; want the topic line added", diff, err)
	}

	files, err = client.GitComparison(ctx, repo, topic, nil)
	if err != nil {
		t.Fatalf("GitComparison(topic, working tree) error: %v", err)
	}
	byPath := map[string]GitComparisonFile{}
	for _, file := range files {
		byPath[file.Path] = file
	}
	if len(files) != 2 || byPath["base.txt"].Untracked || !byPath["notes.txt"].Untracked {
		t.Fatalf("GitComparison(topic, working tree) = %+v; want base.txt and the untracked notes.txt", files)
	}
	diff, err = client.GitDiff(ctx, GitDiffRequest{Root: repo, Path: "base.txt", Base: &topic})
	if err != nil || len(diff) != 1 || diff[0].Deletions != 1 {
		t.Fatalf("GitDiff(topic, working tree) = %+v, %v; want the topic line removed", diff, err)
	}
	diff, err = client.GitDiff(ctx, GitDiffRequest{Root: repo, Path: "notes.txt", Base: &topic, Untracked: true})
	if err != nil || len(diff) != 1 || diff[0].Additions != 1 {
		t.Fatalf("GitDiff(topic, untracked notes.txt) = %+v, %v; want the new line", diff, err)
	}

	files, err = client.GitComparison(ctx, repo, GitReference{FullName: "HEAD", ShortName: "HEAD"}, nil)
	if err != nil || len(files) != 1 || files[0].Path != "notes.txt" {
		t.Fatalf("GitComparison(HEAD, working tree) = %+v, %v; want notes.txt", files, err)
	}
}
