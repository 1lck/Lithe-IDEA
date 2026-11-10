package core

import (
	"path/filepath"
	"testing"
)

// remoteWithClones is a bare origin, a clone that tracks it and a second clone that publishes
// commits to it.
func remoteWithClones(t *testing.T) (bare, mine, other string) {
	t.Helper()
	seed := committedRepository(t)
	bare = filepath.Join(t.TempDir(), "origin.git")
	runGit(t, seed, "clone", "--bare", seed, bare)
	mine = filepath.Join(t.TempDir(), "mine")
	runGit(t, seed, "clone", bare, mine)
	other = filepath.Join(t.TempDir(), "other")
	runGit(t, seed, "clone", bare, other)
	return bare, mine, other
}

func publish(t *testing.T, clone, name string) {
	t.Helper()
	writeFile(t, filepath.Join(clone, name), name+"\n")
	runGit(t, clone, "add", name)
	runGit(t, clone, "commit", "-m", name)
	runGit(t, clone, "push", "origin", "HEAD")
}

func TestGitFetchAndPull(t *testing.T) {
	_, mine, other := remoteWithClones(t)
	client := NewClient()
	ctx := testContext(t)
	publish(t, other, "one.txt")

	if err := client.GitFetch(ctx, mine, nil); err != nil {
		t.Fatalf("GitFetch() error: %v", err)
	}
	if got := runGit(t, mine, "rev-list", "--count", "main..origin/main"); got != "1" {
		t.Fatalf("commits fetched but not merged = %q, want 1", got)
	}
	pre, err := client.GitPullPreflight(ctx, mine)
	if err != nil {
		t.Fatalf("GitPullPreflight() error: %v", err)
	}
	if pre.Upstream != "origin/main" || pre.Behind != 1 || pre.Diverged || pre.IsUpToDate() {
		t.Fatalf("preflight = %+v, want 1 behind origin/main", pre)
	}
	if err := client.GitPull(ctx, mine, GitPullFastForward); err != nil {
		t.Fatalf("GitPull() error: %v", err)
	}
	if got := runGit(t, mine, "rev-list", "--count", "main..origin/main"); got != "0" {
		t.Fatalf("commits behind after the pull = %q, want 0", got)
	}
}

func TestGitFetchOptionsAndDivergedPull(t *testing.T) {
	_, mine, other := remoteWithClones(t)
	client := NewClient()
	ctx := testContext(t)
	publish(t, other, "remote.txt")
	writeFile(t, filepath.Join(mine, "local.txt"), "local\n")
	runGit(t, mine, "add", "local.txt")
	runGit(t, mine, "commit", "-m", "local")

	remote := "origin"
	options := DefaultGitFetchOptions()
	options.Remote = &remote
	options.Tags = GitFetchTagsAll
	if err := client.GitFetch(ctx, mine, &options); err != nil {
		t.Fatalf("GitFetch(options) error: %v", err)
	}
	pre, err := client.GitPullPreflight(ctx, mine)
	if err != nil || !pre.Diverged || pre.Ahead != 1 || pre.Behind != 1 {
		t.Fatalf("preflight = %+v, %v; want diverged 1/1", pre, err)
	}
	requireCode(t, client.GitPull(ctx, mine, GitPullFastForward), CodeProcessFailed)
	if err := client.GitPull(ctx, mine, GitPullRebase); err != nil {
		t.Fatalf("GitPull(rebase) error: %v", err)
	}
	if got := runGit(t, mine, "rev-list", "--count", "origin/main..main"); got != "1" {
		t.Fatalf("local commits on top of upstream = %q, want 1", got)
	}
	unknown := "nowhere"
	options.Remote = &unknown
	if err := client.GitFetch(ctx, mine, &options); err == nil {
		t.Fatal("GitFetch(unknown remote) succeeded")
	}
}

func TestGitUpdateOtherBranch(t *testing.T) {
	_, mine, other := remoteWithClones(t)
	client := NewClient()
	ctx := testContext(t)
	runGit(t, mine, "checkout", "-b", "work")
	publish(t, other, "later.txt")
	if err := client.GitUpdateBranch(ctx, mine, localBranch("main")); err != nil {
		t.Fatalf("GitUpdateBranch() error: %v", err)
	}
	if got := runGit(t, mine, "rev-list", "--count", "HEAD..main"); got != "1" {
		t.Fatalf("main after the update is %q commits ahead of work, want 1", got)
	}
}

func TestIsAuthenticationFailure(t *testing.T) {
	err := &Error{Code: CodeProcessFailed, Message: "fatal: x", Details: "remote: ...\nfatal: Authentication failed for 'https://h/'"}
	if !IsAuthenticationFailure(err) || IsAuthenticationFailure(&Error{Message: "other"}) || IsAuthenticationFailure(nil) {
		t.Fatal("authentication markers not recognised")
	}
}
