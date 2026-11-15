package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/documentio"
	"github.com/1lck/Lithe-IDEA/desktop/internal/gitmetadata"
)

func TestRecentBranchReadsNormalAndWorktreeMetadata(t *testing.T) {
	ctx := context.Background()
	kernel := core.NewClient()
	root := t.TempDir()
	if got, err := gitmetadata.ReadBranch(ctx, kernel, root); err != nil || got != "" {
		t.Fatalf("non-repository = %q, %v", got, err)
	}
	gitdir := filepath.Join(root, ".git")
	if err := os.Mkdir(gitdir, 0o700); err != nil {
		t.Fatal(err)
	}
	head := filepath.Join(gitdir, "HEAD")
	if err := os.WriteFile(head, []byte("ref: refs/heads/feature/search\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, err := gitmetadata.ReadBranch(ctx, kernel, root); err != nil || got != "feature/search" {
		t.Fatalf("branch = %q, %v", got, err)
	}
	if err := os.WriteFile(head, []byte("0123456789abcdef0123456789abcdef01234567\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, err := gitmetadata.ReadBranch(ctx, kernel, root); err != nil || got != "01234567" {
		t.Fatalf("detached revision = %q, %v", got, err)
	}
	worktree := filepath.Join(t.TempDir(), "checkout")
	if err := os.Mkdir(worktree, 0o700); err != nil {
		t.Fatal(err)
	}
	relative, err := filepath.Rel(worktree, gitdir)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(worktree, ".git"), []byte("gitdir: "+relative+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, err := gitmetadata.ReadBranch(ctx, kernel, worktree); err != nil || got != "01234567" {
		t.Fatalf("worktree revision = %q, %v", got, err)
	}
	if err := os.WriteFile(head, []byte(strings.Repeat("x", gitmetadata.MetadataLimit+1)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := gitmetadata.ReadBranch(ctx, kernel, root); !errors.Is(err, documentio.ErrTooLarge) {
		t.Fatalf("oversized HEAD error = %v", err)
	}
	if err := os.WriteFile(head, []byte{0xff}, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := gitmetadata.ReadBranch(ctx, kernel, root); !errors.Is(err, gitmetadata.ErrEncoding) {
		t.Fatalf("invalid UTF-8 error = %v", err)
	}
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := gitmetadata.ReadBranch(canceled, kernel, root); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled read error = %v", err)
	}
}

func TestWelcomeBranchRowsGrowAndDoNotOverlap(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, ".git"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".git", "HEAD"), []byte("ref: refs/heads/feature/welcome\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	h.app.recent = []core.RecentProject{{Path: root}, {Path: t.TempDir()}}
	h.app.refreshWelcomeBranches()
	if err := h.driver.Resize(900, 600); err != nil {
		t.Fatal(err)
	}
	h.settle()
	awaitDocumentState(t, h, func() bool { return h.shows("feature/welcome") })
	first, second := h.welcomeRowHit(h.app.recent[0].Path).Bounds, h.welcomeRowHit(h.app.recent[1].Path).Bounds
	if first.Height <= welcomeRowHeight || first.Y+first.Height > second.Y {
		t.Fatalf("branch row overlaps the next row: first %v, second %v", first, second)
	}
}

type delayedCheckoutKernel struct {
	*testKernel
	started chan struct{}
	release chan struct{}
	once    sync.Once
}

func (k *delayedCheckoutKernel) GitCheckoutBranch(ctx context.Context, text string) (string, error) {
	if strings.Contains(text, "old-branch") {
		k.once.Do(func() { close(k.started) })
		<-k.release
		return "old-branch", nil
	}
	return k.Client.GitCheckoutBranch(ctx, text)
}

func TestWelcomeDiscardsStaleBranchReadAfterRecentListChanges(t *testing.T) {
	makeProject := func(branch string) string {
		t.Helper()
		root := t.TempDir()
		if err := os.Mkdir(filepath.Join(root, ".git"), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, ".git", "HEAD"), []byte("ref: refs/heads/"+branch+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		return root
	}
	oldRoot, newRoot := makeProject("old-branch"), makeProject("new-branch")
	k := &delayedCheckoutKernel{testKernel: &testKernel{Client: core.NewClient()}, started: make(chan struct{}), release: make(chan struct{})}
	h := newHarness(t, k)
	var released bool
	t.Cleanup(func() {
		if !released {
			close(k.release)
		}
	})
	h.app.recent = []core.RecentProject{{Path: oldRoot}}
	h.app.refreshWelcomeBranches()
	if err := h.driver.Resize(900, 600); err != nil {
		t.Fatal(err)
	}
	select {
	case <-k.started:
	case <-time.After(5 * time.Second):
		t.Fatal("old branch read did not start")
	}
	h.app.recent = []core.RecentProject{{Path: newRoot}}
	h.app.refreshWelcomeBranches()
	close(k.release)
	released = true
	awaitDocumentState(t, h, func() bool { return h.shows("new-branch") })
	if h.shows("old-branch") {
		t.Fatal("a stale branch read replaced the new recent-project state")
	}
}
