package core

import (
	"path/filepath"
	"testing"
)

func TestGitPushPreviewAndPush(t *testing.T) {
	bare, mine, other := remoteWithClones(t)
	client := NewClient()
	ctx := testContext(t)

	writeFile(t, filepath.Join(mine, "pushed.txt"), "pushed\n")
	runGit(t, mine, "add", "pushed.txt")
	runGit(t, mine, "commit", "-m", "pushed")

	preview, err := client.GitPushPreviewOf(ctx, mine, GitReference{}, GitPushTagsNone, "")
	if err != nil || preview.Remote != "origin" || preview.RemoteBranch != "main" || len(preview.Commits) != 1 || preview.Commits[0].Subject != "pushed" {
		t.Fatalf("GitPushPreviewOf() = %+v, %v; want one commit to origin/main", preview, err)
	}
	// Another clone moves the remote after the review: the reviewed push must not go out.
	publish(t, other, "raced.txt")
	runGit(t, mine, "fetch", "origin")
	if err := client.GitPush(ctx, mine, preview, GitPushTagsNone, "", false); err == nil {
		t.Fatal("GitPush of a stale review succeeded, want a rejection")
	}
	runGit(t, mine, "rebase", "origin/main")
	preview, err = client.GitPushPreviewOf(ctx, mine, GitReference{}, GitPushTagsNone, "")
	if err != nil {
		t.Fatalf("GitPushPreviewOf() after the rebase error: %v", err)
	}
	if err := client.GitPush(ctx, mine, preview, GitPushTagsNone, "", false); err != nil {
		t.Fatalf("GitPush() error: %v", err)
	}
	if got := runGit(t, bare, "log", "-1", "--format=%s", "main"); got != "pushed" {
		t.Fatalf("remote tip = %q, want the pushed commit", got)
	}
}
