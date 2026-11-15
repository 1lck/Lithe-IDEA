package core

import (
	"os"
	"path/filepath"
	"testing"
)

// TestWorktreeLifecycleAndRefusalCodes creates a linked worktree, checks that each refusal
// of a removal, lock or unlock carries its own code, and removes the worktree with force once
// it holds a change.
func TestWorktreeLifecycleAndRefusalCodes(t *testing.T) {
	repo := committedRepository(t)
	client := NewClient()
	ctx := testContext(t)
	parent, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatalf("EvalSymlinks() error: %v", err)
	}
	main := localBranch("main")
	creation := GitWorktreeCreation{
		Mode:        GitWorktreeNewBranch,
		Name:        "feature",
		Reference:   &main,
		Destination: filepath.Join(parent, "linked"),
	}
	if err := client.GitCreateWorktree(ctx, repo, creation); err != nil {
		t.Fatalf("GitCreateWorktree() error: %v", err)
	}
	worktrees, err := client.GitWorktrees(ctx, repo)
	if err != nil {
		t.Fatalf("GitWorktrees() error: %v", err)
	}
	if len(worktrees) != 2 {
		t.Fatalf("worktrees = %+v, want the primary and the linked one", worktrees)
	}
	primary, linked := worktrees[0], worktrees[1]
	if !primary.IsPrimary || !primary.IsCurrent || linked.IsPrimary || linked.IsCurrent {
		t.Fatalf("worktrees = %+v, want the current primary first", worktrees)
	}
	if linked.Branch != "refs/heads/feature" {
		t.Fatalf("linked branch = %q, want refs/heads/feature", linked.Branch)
	}

	requireCode(t, client.GitRemoveWorktree(ctx, repo, primary.Path, false), CodeGitWorktreePrimary)
	requireCode(t, client.GitLockWorktree(ctx, repo, primary.Path), CodeGitWorktreePrimary)
	requireCode(t, client.GitUnlockWorktree(ctx, repo, primary.Path), CodeGitWorktreePrimary)
	requireCode(t, client.GitRemoveWorktree(ctx, linked.Path, linked.Path, false), CodeGitWorktreeCurrent)
	requireCode(t, client.GitRemoveWorktree(ctx, repo, filepath.Join(parent, "missing"), false), CodeGitWorktreeNotRegistered)

	if err := client.GitLockWorktree(ctx, repo, linked.Path); err != nil {
		t.Fatalf("GitLockWorktree() error: %v", err)
	}
	requireCode(t, client.GitRemoveWorktree(ctx, repo, linked.Path, false), CodeGitWorktreeLocked)
	if err := client.GitUnlockWorktree(ctx, repo, linked.Path); err != nil {
		t.Fatalf("GitUnlockWorktree() error: %v", err)
	}

	dirty := filepath.Join(linked.Path, "dirty.txt")
	writeFile(t, dirty, "dirty\n")
	requireCode(t, client.GitRemoveWorktree(ctx, repo, linked.Path, false), CodeGitWorktreeHasChanges)
	if _, err := os.Stat(dirty); err != nil {
		t.Fatalf("the refused removal touched the change: %v", err)
	}
	if err := client.GitRemoveWorktree(ctx, repo, linked.Path, true); err != nil {
		t.Fatalf("GitRemoveWorktree(force) error: %v", err)
	}
	if _, err := os.Stat(linked.Path); !os.IsNotExist(err) {
		t.Fatalf("checkout after the forced removal: %v, want it gone", err)
	}
	if branches := runGit(t, repo, "branch", "--format=%(refname:short)"); branches != "feature\nmain" {
		t.Fatalf("branches = %q, want the worktree's branch kept", branches)
	}
}
