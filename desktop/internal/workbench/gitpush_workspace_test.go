package workbench

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
)

// pushedRepository makes dir a repository on main with one commit, pushed to a bare remote
// named origin under remotes, and returns the remote's path.
func pushedRepository(t *testing.T, dir, remotes, name string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	gitRun(t, dir, "init")
	gitRun(t, dir, "symbolic-ref", "HEAD", "refs/heads/main")
	commitFile(t, dir, name+".txt", "initial")
	remote := filepath.Join(remotes, name+".git")
	gitRun(t, remotes, "init", "--bare", remote)
	gitRun(t, dir, "remote", "add", "origin", remote)
	gitRun(t, dir, "push", "-q", "-u", "origin", "main")
	return remote
}

// commitFile writes subject into name in dir and commits it with subject as the message.
func commitFile(t *testing.T, dir, name, subject string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(subject+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	gitRun(t, dir, "add", name)
	gitRun(t, dir, "commit", "-q", "-m", subject)
}

// remoteHead is the commit main points at in the bare remote.
func remoteHead(t *testing.T, remote string) string {
	t.Helper()
	return gitRun(t, remote, "rev-parse", "refs/heads/main")
}

// awaitWorkspacePush waits until the Push Commits dialog shows a review and nothing runs.
func (h *harness) awaitWorkspacePush(p *project) *workspacePushState {
	h.t.Helper()
	s := &p.review.workspacePush
	h.awaitWithin(reviewTimeout, "the Push Commits review", func() bool { return s.open && s.reviewed && !s.loading && !s.busy })
	return s
}

// Commit and Push commits first and then asks, as IDEA does, in the Push Commits dialog: the
// committed repository is checked with the commit listed, and Push sends it.
func TestCommitAndPushCommitsThenOpensThePushCommitsDialog(t *testing.T) {
	requireTestGit(t)
	root := t.TempDir()
	dir := filepath.Join(root, "project")
	remote := pushedRepository(t, dir, root, "project")
	if err := os.WriteFile(filepath.Join(dir, "project.txt"), []byte("changed\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	h.stageAll(p)
	p.commit.editor.Insert("Publish the change")
	h.settle()
	before := remoteHead(t, remote)

	h.sendNamed(h.app.text.Commit.CommitAndPush)
	s := h.awaitWorkspacePush(p)
	if got := gitRun(t, dir, "log", "-1", "--format=%s"); got != "Publish the change" {
		t.Fatalf("last commit = %q, want the commit to run before the push is asked", got)
	}
	if remoteHead(t, remote) != before {
		t.Fatal("the commit was pushed before the Push Commits dialog was confirmed")
	}
	if !s.checked[commitRepositoryID] || s.selCommit == "" {
		t.Fatalf("checked %v, selected %q: want the committed repository checked and its commit selected", s.checked, s.selCommit)
	}
	lang := h.app.language()
	for _, text := range []string{"Publish the change", "origin : main"} {
		if !h.shows(text) {
			t.Fatalf("the Push Commits dialog does not show %q", text)
		}
	}
	h.await("the changed files", func() bool { return s.fileState == logFilesReady })
	if !h.shows("project.txt") {
		t.Fatal("the Push Commits dialog does not list the selected commit's file")
	}

	h.sendNamed(i18n.Shared(lang, "desktop.git.pushAll.push"))
	h.awaitWithin(reviewTimeout, "the push", func() bool { return !s.busy && !s.open })
	if got, want := remoteHead(t, remote), gitRun(t, dir, "rev-parse", "HEAD"); got != want {
		t.Fatalf("remote main = %s, want the pushed %s", got, want)
	}
}

// The dialog pushes a submodule before the repository that records it, and skips that
// repository when the submodule failed to push, since Git would refuse it. A repository without
// a remote shows that it needs one and cannot be checked.
func TestPushCommitsDialogPushesInOrderAndSkipsWhatAFailedSubmoduleBlocks(t *testing.T) {
	requireTestGit(t)
	root := t.TempDir()
	parent := filepath.Join(root, "parent")
	parentRemote := pushedRepository(t, parent, root, "parent")
	child := filepath.Join(parent, "child")
	childRemote := pushedRepository(t, child, root, "child")
	commitFile(t, child, "child.txt", "child work")
	gitRun(t, parent, "add", "child")
	gitRun(t, parent, "commit", "-q", "-m", "record child")
	local := filepath.Join(root, "local")
	if err := os.MkdirAll(local, 0o700); err != nil {
		t.Fatal(err)
	}
	gitRun(t, local, "init")
	gitRun(t, local, "symbolic-ref", "HEAD", "refs/heads/main")
	commitFile(t, local, "local.txt", "local work")

	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(parent)
	bindings := []core.WorkspaceCommitRepository{
		{ID: commitRepositoryID, Root: parent}, {ID: "child", Root: child}, {ID: "local", Root: local},
	}
	h.app.openWorkspacePush(p, bindings, map[string]string{commitRepositoryID: "parent"}, nil, surfaceButton)
	s := h.awaitWorkspacePush(p)
	var order []string
	for _, repo := range s.repos {
		order = append(order, repo.ID)
	}
	if len(order) != 3 || order[0] != "child" || order[1] != commitRepositoryID || order[2] != "local" {
		t.Fatalf("listed %v, want the submodule before the repository that records it", order)
	}
	lang := h.app.language()
	if !h.shows(i18n.Shared(lang, "desktop.git.pushAll.defineRemote")) || s.checked["local"] {
		t.Fatal("the repository without a remote does not ask for one or is checked")
	}
	if !s.checked["child"] || !s.checked[commitRepositoryID] {
		t.Fatalf("checked %v, want both ready repositories", s.checked)
	}
	parentBefore, childBefore := remoteHead(t, parentRemote), remoteHead(t, childRemote)

	// The child's remote goes away after the review: its push fails, and the parent, which
	// records the child's new commit, is not pushed.
	moved := childRemote + ".moved"
	if err := os.Rename(childRemote, moved); err != nil {
		t.Fatal(err)
	}
	h.sendNamed(i18n.Shared(lang, "desktop.git.pushAll.push"))
	h.awaitWithin(reviewTimeout, "the failed push", func() bool { return len(s.outcomes) == 2 && !s.busy })
	if outcome := s.outcomes["child"]; outcome.pushed || outcome.err == "" {
		t.Fatalf("child outcome = %+v, want its push to fail", outcome)
	}
	if outcome := s.outcomes[commitRepositoryID]; outcome.skippedFor != "child" {
		t.Fatalf("parent outcome = %+v, want it skipped for the child", outcome)
	}
	if remoteHead(t, parentRemote) != parentBefore {
		t.Fatal("the parent was pushed although the child it records was not")
	}
	if !s.open || h.app.notice != i18n.Shared(lang, "desktop.git.pushAll.someFailed") {
		t.Fatalf("open %v, notice %q: want the dialog kept open with the failure noted", s.open, h.app.notice)
	}

	if err := os.Rename(moved, childRemote); err != nil {
		t.Fatal(err)
	}
	s = h.awaitWorkspacePush(p)
	h.sendNamed(i18n.Shared(lang, "desktop.git.pushAll.push"))
	h.awaitWithin(reviewTimeout, "the push", func() bool { return !s.busy && !s.open })
	if remoteHead(t, childRemote) == childBefore || remoteHead(t, parentRemote) == parentBefore {
		t.Fatal("the second push did not send both repositories")
	}
}
