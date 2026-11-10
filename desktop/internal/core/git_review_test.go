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
	if err := client.GitCreateWorktree(ctx, repo, wt, GitWorktreeNewBranch, "feat", localBranch("main")); err != nil {
		t.Fatalf("GitCreateWorktree() error: %v", err)
	}
	trees, err := client.GitWorktrees(ctx, repo)
	if err != nil || len(trees) != 2 || !trees[0].IsPrimary || trees[1].Branch == nil || *trees[1].Branch != "refs/heads/feat" {
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
