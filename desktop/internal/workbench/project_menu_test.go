package workbench

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/gitmetadata"
)

func TestProjectMenuRemovesRecentRecordWithoutOpeningOrDeleting(t *testing.T) {
	for _, missing := range []bool{false, true} {
		t.Run(map[bool]string{false: "existing", true: "missing"}[missing], func(t *testing.T) {
			h := newHarness(t, &testKernel{Client: core.NewClient()})
			h.open(t.TempDir())
			p := h.app.project
			path := filepath.Join(t.TempDir(), "RecentProject")
			if !missing {
				if err := os.Mkdir(path, 0700); err != nil {
					t.Fatal(err)
				}
			}
			entries := append([]core.RecentProject{{Path: path, LastOpenedAt: 123}}, h.app.recent...)
			h.app.reduceRecent(entries, core.NormalizeRecent(), true)
			h.app.openProjectMenu()
			h.settle()
			hit, ok := h.findPageHit(h.app.text.Welcome.MenuRemove)
			if !ok {
				t.Fatal("recent project has no remove X")
			}
			h.click(center(hit.Bounds))
			h.settle()
			if h.app.project != p || !h.app.title.projectOpen {
				t.Fatal("removing recent switched project or closed menu")
			}
			if slices.ContainsFunc(h.app.recent, func(entry core.RecentProject) bool { return entry.Path == path }) {
				t.Fatal("recent record remains")
			}
			var saved []core.RecentProject
			if _, err := h.store.Load(recentFile, &saved); err != nil {
				t.Fatal(err)
			}
			if slices.ContainsFunc(saved, func(entry core.RecentProject) bool { return entry.Path == path }) {
				t.Fatal("removed record was not persisted")
			}
			if !missing {
				if info, err := os.Stat(path); err != nil || !info.IsDir() {
					t.Fatalf("project folder was removed: %v", err)
				}
			}
			h.clickNamed(h.app.text.Title.CloseProject)
			h.settle()
			if h.app.project != nil {
				t.Fatal("open project's X no longer closes it")
			}
			if !slices.ContainsFunc(h.app.recent, func(entry core.RecentProject) bool { return entry.Path == p.root }) {
				t.Fatal("closing project also erased recent record")
			}
		})
	}
}

type recentMenuBranchKernel struct {
	*testKernel
	statusCalls atomic.Int32
	recentPaths map[string]bool
}

// Opening the active project can still refresh its own Git state. Only the
// recent paths must not issue full status scans merely to label menu entries.
func (k *recentMenuBranchKernel) GitStatus(ctx context.Context, root string) (core.GitStatus, error) {
	if !k.recentPaths[root] {
		return k.testKernel.GitStatus(ctx, root)
	}
	k.statusCalls.Add(1)
	return core.GitStatus{}, errors.New("menu performed a full git status scan")
}

func TestProjectMenuReadsRecentBranchesWithoutFullGitStatus(t *testing.T) {
	normal, worktree, detached, invalid, missing := t.TempDir(), t.TempDir(), t.TempDir(), t.TempDir(), t.TempDir()
	makeHead := func(root, head string) {
		t.Helper()
		if err := os.Mkdir(filepath.Join(root, ".git"), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, ".git", "HEAD"), []byte(head), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	makeHead(normal, "ref: refs/heads/feature/menu\n")
	makeHead(detached, strings.Repeat("a", 40)+"\n")
	makeHead(invalid, strings.Repeat("x", gitmetadata.MetadataLimit+1))
	relative, err := filepath.Rel(worktree, filepath.Join(normal, ".git"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(worktree, ".git"), []byte("gitdir: "+relative+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	kernel := &recentMenuBranchKernel{
		testKernel:  &testKernel{Client: core.NewClient()},
		recentPaths: map[string]bool{normal: true, worktree: true, detached: true, invalid: true, missing: true},
	}
	h := newHarness(t, kernel)
	h.open(t.TempDir())
	log := &treeRecordingLog{}
	h.app.logSink = log
	t.Cleanup(func() { h.app.logSink = nil })
	h.app.recent = []core.RecentProject{
		{Path: normal}, {Path: worktree}, {Path: detached}, {Path: invalid}, {Path: missing},
	}
	h.app.openProjectMenu()
	h.await("recent menu checkout metadata", func() bool {
		branches := h.app.title.branches
		return len(h.app.title.reading) == 0 &&
			branches[normal] == "feature/menu" && branches[worktree] == "feature/menu" &&
			branches[detached] == "aaaaaaaa" &&
			branches[invalid] == "" && branches[missing] == ""
	})
	h.settle()
	if !h.shows("feature/menu") || !h.shows("aaaaaaaa") {
		t.Fatal("project menu did not render resolved recent branches")
	}
	if got := kernel.statusCalls.Load(); got != 0 {
		t.Fatalf("GitStatus calls = %d, want none for recent project branches", got)
	}
	log.mu.Lock()
	defer log.mu.Unlock()
	found := false
	for _, event := range log.events {
		if event.Event == "app.background.operation_failed" && event.Fields["operation"] == "workspace_recent_branch" {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("oversized recent HEAD was ignored without a background diagnostic")
	}
}

type menuBranchCancelKernel struct {
	*testKernel
	started  chan struct{}
	release  chan struct{}
	once     sync.Once
	calls    atomic.Int32
	canceled atomic.Bool
}

func (k *menuBranchCancelKernel) GitCheckoutBranch(ctx context.Context, text string) (string, error) {
	if strings.Contains(text, "stale-menu-branch") {
		k.calls.Add(1)
		k.once.Do(func() { close(k.started) })
		select {
		case <-ctx.Done():
			k.canceled.Store(true)
			return "", ctx.Err()
		case <-k.release:
			return "stale-menu-branch", nil
		}
	}
	return k.testKernel.GitCheckoutBranch(ctx, text)
}

func TestProjectMenuDeduplicatesAndDiscardsStaleBranchOnProjectSwitch(t *testing.T) {
	recent := t.TempDir()
	if err := os.Mkdir(filepath.Join(recent, ".git"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(recent, ".git", "HEAD"), []byte("ref: refs/heads/stale-menu-branch\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	k := &menuBranchCancelKernel{
		testKernel: &testKernel{Client: core.NewClient()},
		started:    make(chan struct{}),
		release:    make(chan struct{}),
	}
	var released bool
	t.Cleanup(func() {
		if !released {
			close(k.release)
		}
	})
	h := newHarness(t, k)
	h.open(t.TempDir())
	h.app.recent = []core.RecentProject{{Path: recent}}
	h.app.openProjectMenu()
	select {
	case <-k.started:
	case <-time.After(5 * time.Second):
		t.Fatal("menu branch read did not start")
	}
	// Re-opening the menu while a read for recent is in flight must not start a duplicate read.
	h.app.openProjectMenu()
	if got := k.calls.Load(); got != 1 {
		t.Fatalf("GitCheckoutBranch calls = %d, want 1 while read is in flight", got)
	}
	// Switching projects cancels the previous project's read and discards its answer.
	h.app.openProjectHere(t.TempDir())
	close(k.release)
	released = true
	h.settle()
	if !k.canceled.Load() {
		t.Fatal("switching projects did not cancel the previous menu branch read")
	}
	if len(h.app.title.reading) != 0 || h.app.title.branches[recent] != "" {
		t.Fatalf("stale branch state leaked across project switch: reading=%v branches=%v", h.app.title.reading, h.app.title.branches)
	}
}
