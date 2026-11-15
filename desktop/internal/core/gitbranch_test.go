package core

import (
	"path/filepath"
	"slices"
	"testing"
)

// committedRepository is a repository on main with one commit of base.txt.
func committedRepository(t *testing.T) string {
	t.Helper()
	requireGit(t)
	t.Setenv("GIT_AUTHOR_NAME", "Lithe Test")
	t.Setenv("GIT_AUTHOR_EMAIL", "test@example.invalid")
	t.Setenv("GIT_COMMITTER_NAME", "Lithe Test")
	t.Setenv("GIT_COMMITTER_EMAIL", "test@example.invalid")
	repo := newRepository(t)
	writeFile(t, filepath.Join(repo, "base.txt"), "base\n")
	runGit(t, repo, "add", "base.txt")
	runGit(t, repo, "commit", "-m", "base")
	return repo
}

// localBranch is the reference of the local branch name.
func localBranch(name string) GitReference {
	return GitReference{FullName: "refs/heads/" + name, ShortName: name, Kind: "local"}
}

func TestBranchCreateCheckoutRenameAndDelete(t *testing.T) {
	repo := committedRepository(t)
	client := NewClient()
	ctx := testContext(t)

	if err := client.GitCreateBranch(ctx, repo, "feature", localBranch("main"), false); err != nil {
		t.Fatalf("GitCreateBranch() error: %v", err)
	}
	if current := runGit(t, repo, "branch", "--show-current"); current != "main" {
		t.Fatalf("current branch after creating without checkout = %q, want main", current)
	}
	if err := client.GitCheckout(ctx, repo, localBranch("feature"), CheckoutPlain); err != nil {
		t.Fatalf("GitCheckout() error: %v", err)
	}
	if current := runGit(t, repo, "branch", "--show-current"); current != "feature" {
		t.Fatalf("current branch = %q, want feature", current)
	}
	requireCode(t, client.GitCheckout(ctx, repo, localBranch("feature"), CheckoutPlain), CodeInvalidRequest)

	if err := client.GitRenameBranch(ctx, repo, localBranch("feature"), "renamed"); err != nil {
		t.Fatalf("GitRenameBranch() error: %v", err)
	}
	if current := runGit(t, repo, "branch", "--show-current"); current != "renamed" {
		t.Fatalf("current branch after the rename = %q, want renamed", current)
	}

	if err := client.GitCreateBranch(ctx, repo, "spare", localBranch("main"), true); err != nil {
		t.Fatalf("GitCreateBranch() with checkout error: %v", err)
	}
	if current := runGit(t, repo, "branch", "--show-current"); current != "spare" {
		t.Fatalf("current branch after creating with checkout = %q, want spare", current)
	}
	_, err := client.GitDeleteBranch(ctx, repo, localBranch("spare"))
	requireCode(t, err, CodeInvalidRequest)
	head := runGit(t, repo, "rev-parse", "renamed")
	deletion, err := client.GitDeleteBranch(ctx, repo, localBranch("renamed"))
	if err != nil {
		t.Fatalf("GitDeleteBranch() error: %v", err)
	}
	if deletion.Name != "renamed" || deletion.DeletedTarget != head {
		t.Fatalf("deletion = %+v, want renamed at %s", deletion, head)
	}
	if branches := runGit(t, repo, "branch", "--format=%(refname:short)"); branches != "main\nspare" {
		t.Fatalf("branches = %q, want main and spare", branches)
	}

	if err := client.GitCheckoutRevision(ctx, repo, head); err != nil {
		t.Fatalf("GitCheckoutRevision() error: %v", err)
	}
	if current := runGit(t, repo, "branch", "--show-current"); current != "" {
		t.Fatalf("current branch after a detached checkout = %q, want none", current)
	}
}

func TestCheckoutPreflightAndModes(t *testing.T) {
	repo := committedRepository(t)
	client := NewClient()
	ctx := testContext(t)
	runGit(t, repo, "switch", "-c", "other")
	writeFile(t, filepath.Join(repo, "base.txt"), "other\n")
	runGit(t, repo, "commit", "-am", "other")
	runGit(t, repo, "switch", "main")
	writeFile(t, filepath.Join(repo, "base.txt"), "local\n")

	blocking, err := client.GitCheckoutPreflight(ctx, repo, localBranch("other"))
	if err != nil {
		t.Fatalf("GitCheckoutPreflight() error: %v", err)
	}
	if !slices.Equal(blocking, []string{"base.txt"}) {
		t.Fatalf("blocking paths = %q, want base.txt", blocking)
	}
	requireCode(t, client.GitCheckout(ctx, repo, localBranch("other"), CheckoutPlain), CodeProcessFailed)

	if err := client.GitCheckout(ctx, repo, localBranch("other"), CheckoutForce); err != nil {
		t.Fatalf("GitCheckout(force) error: %v", err)
	}
	if content := runGit(t, repo, "show", ":base.txt"); content != "other" {
		t.Fatalf("index after a forced checkout = %q, want the branch's content", content)
	}
	if status := runGit(t, repo, "status", "--porcelain"); status != "" {
		t.Fatalf("status after a forced checkout = %q, want clean", status)
	}

	blocking, err = client.GitCheckoutPreflight(ctx, repo, localBranch("main"))
	if err != nil || len(blocking) != 0 || blocking == nil {
		t.Fatalf("preflight of a clean tree = %#v, %v; want an empty list", blocking, err)
	}
	writeFile(t, filepath.Join(repo, "new.txt"), "carried\n")
	if err := client.GitCheckout(ctx, repo, localBranch("main"), CheckoutSmart); err != nil {
		t.Fatalf("GitCheckout(smart) error: %v", err)
	}
	if current := runGit(t, repo, "branch", "--show-current"); current != "main" {
		t.Fatalf("current branch after a smart checkout = %q, want main", current)
	}
	if status := runGit(t, repo, "status", "--porcelain"); status != "?? new.txt" {
		t.Fatalf("status after a smart checkout = %q, want the untracked file restored", status)
	}
}

func TestBranchNamePreviewCleansAndValidates(t *testing.T) {
	client := NewClient()
	ctx := testContext(t)
	references := []GitReference{localBranch("main"), {FullName: "refs/remotes/origin/topic", ShortName: "origin/topic", Kind: "remote"}}

	preview, err := client.GitBranchNamePreview(ctx, BranchNameRequest{RawName: "my new branch", References: references})
	if err != nil {
		t.Fatalf("GitBranchNamePreview() error: %v", err)
	}
	if preview.TypingCleanedName != "my-new-branch" || preview.CleanedName != "my-new-branch" || preview.Error != nil {
		t.Fatalf("preview = %+v, want spaces replaced and no error", preview)
	}

	preview, err = client.GitBranchNamePreview(ctx, BranchNameRequest{RawName: "main", References: references})
	if err != nil || preview.Error == nil || preview.Error.Code != BranchNameAlreadyExists {
		t.Fatalf("preview of an existing name = %+v, %v; want alreadyExists", preview, err)
	}
	preview, err = client.GitBranchNamePreview(ctx, BranchNameRequest{RawName: "", RequireName: true, References: references})
	if err != nil || preview.Error == nil || preview.Error.Code != BranchNameEmpty {
		t.Fatalf("preview of an empty submit = %+v, %v; want empty", preview, err)
	}
	preview, err = client.GitBranchNamePreview(ctx, BranchNameRequest{RawName: "", References: references})
	if err != nil || preview.Error != nil {
		t.Fatalf("preview of an empty name while typing = %+v, %v; want no error", preview, err)
	}

	from := references[1]
	preview, err = client.GitBranchNamePreview(ctx, BranchNameRequest{References: references, From: &from})
	if err != nil || preview.InitialName != "topic" {
		t.Fatalf("initial name from origin/topic = %+v, %v; want topic", preview, err)
	}
}
