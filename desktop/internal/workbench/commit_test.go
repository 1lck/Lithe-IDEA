package workbench

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/vivaui/viva/gfx"
)

// requireTestGit skips the test without Git and gives Git an empty, isolated
// configuration and a fixed identity, so the user's settings never change a result.
func requireTestGit(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	home := t.TempDir()
	config := filepath.Join(home, ".gitconfig")
	if err := os.WriteFile(config, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("GIT_CONFIG_GLOBAL", config)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	t.Setenv("GIT_TERMINAL_PROMPT", "0")
	t.Setenv("GIT_AUTHOR_NAME", "Lithe Test")
	t.Setenv("GIT_AUTHOR_EMAIL", "test@example.invalid")
	t.Setenv("GIT_COMMITTER_NAME", "Lithe Test")
	t.Setenv("GIT_COMMITTER_EMAIL", "test@example.invalid")
}

// gitRun runs Git in dir and returns its trimmed output.
func gitRun(t *testing.T, dir string, args ...string) string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	base := []string{"-c", "user.name=Lithe Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false"}
	command := exec.CommandContext(ctx, "git", append(base, args...)...)
	command.Dir = dir
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, output)
	}
	return strings.TrimSpace(string(output))
}

// newTestRepository is a repository on main with one commit and one modified file,
// changed.txt, that is not staged.
func newTestRepository(t *testing.T) string {
	t.Helper()
	requireTestGit(t)
	dir := t.TempDir()
	gitRun(t, dir, "init")
	gitRun(t, dir, "symbolic-ref", "HEAD", "refs/heads/main")
	write := func(name, value string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(value), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write("changed.txt", "first\n")
	gitRun(t, dir, "add", "changed.txt")
	gitRun(t, dir, "commit", "-m", "initial")
	write("changed.txt", "second\n")
	return dir
}

// gitKernel answers everything, Git status included, with the real kernel.
type gitKernel struct{ *core.Client }

// openCommit opens dir and the commit tool window, and waits for the status.
func (h *harness) openCommit(dir string) *project {
	h.t.Helper()
	h.open(dir)
	h.click(center(h.button(itemCommit)))
	h.settle()
	p := h.app.project
	if p == nil || !p.git.isRepository() {
		h.t.Fatalf("the project is not a loaded repository: %+v", p)
	}
	return p
}

// gitChainSteps bounds how many background steps one click may chain: a commit plans, runs,
// then reloads the status, and each step starts the next from the window thread.
const gitChainSteps = 6

// click clicks at point and paints what it did, after every background step the click
// chained. Each settle waits for the running work, so the count is a bound, not a timer.
func (h *harness) click(point gfx.Point) {
	h.t.Helper()
	if err := h.driver.Click(point.X, point.Y); err != nil {
		h.t.Fatal(err)
	}
	for range gitChainSteps {
		h.settle()
	}
}

// topHit is the smallest rectangle the hit id was laid out in: a dialog's scrim shares its
// id with the cancel button, and the button is the one inside the surface.
func (h *harness) topHit(id gfx.ID) gfx.Rect {
	h.t.Helper()
	var found gfx.Rect
	for _, hit := range h.driver.Snapshot().Hits {
		if hit.ID == id && (found.Width == 0 || hit.Bounds.Width*hit.Bounds.Height < found.Width*found.Height) {
			found = hit.Bounds
		}
	}
	if found.Width == 0 {
		h.t.Fatalf("hit %v is not shown", id)
	}
	return found
}

// stageAll stages every change through the window and waits for the new status.
func (h *harness) stageAll(p *project) {
	h.t.Helper()
	h.click(center(h.hit(commitChecks.At(0))))
	h.settle()
	if p.git.stagedCount() != len(p.git.status.Changes) {
		h.t.Fatalf("staged %d of %d changes", p.git.stagedCount(), len(p.git.status.Changes))
	}
}

func TestCommitCheckboxStagesAndUnstagesAChange(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	if !h.shows("changed.txt") {
		t.Fatal("the changed file is not listed")
	}

	h.stageAll(p)
	if got := gitRun(t, dir, "diff", "--cached", "--name-only"); got != "changed.txt" {
		t.Fatalf("staged files = %q, want changed.txt", got)
	}

	h.click(center(h.hit(commitChecks.At(0))))
	h.settle()
	if got := gitRun(t, dir, "diff", "--cached", "--name-only"); got != "" {
		t.Fatalf("staged files after unstaging = %q, want none", got)
	}
}

func TestCommitButtonCommitsTheStagedChanges(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	h.stageAll(p)

	if p.canCommit() {
		t.Fatal("the commit buttons are enabled without a message")
	}
	h.click(center(h.hit(commitMessageID)))
	if err := h.driver.Type("Explain the change"); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if !p.canCommit() {
		t.Fatalf("the commit buttons are disabled with a message %q and staged changes", p.commit.message())
	}
	h.click(center(h.hit(commitButtonID)))
	h.settle()

	if got := gitRun(t, dir, "log", "-1", "--format=%s"); got != "Explain the change" {
		t.Fatalf("last commit = %q, want the typed message", got)
	}
	if p.commit.review != nil || p.commit.busy || p.commit.attempt != nil {
		t.Fatalf("commit state after success = review %v, busy %v, attempt %v", p.commit.review, p.commit.busy, p.commit.attempt)
	}
	if p.commit.message() != "" {
		t.Fatalf("message after the commit = %q, want empty", p.commit.message())
	}
	if h.app.notice != h.app.text.Commit.Done {
		t.Fatalf("notice = %q, want %q", h.app.notice, h.app.text.Commit.Done)
	}
	if len(p.git.status.Changes) != 0 {
		t.Fatalf("changes after the commit = %+v, want none", p.git.status.Changes)
	}
}

func TestCommitAndPushShowsTheReviewFirst(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	h.stageAll(p)
	p.commit.editor.Insert("Publish the change")
	h.settle()

	h.click(center(h.hit(commitPushID)))
	h.settle()
	if p.commit.review == nil {
		t.Fatal("commit and push ran without showing the review")
	}
	if got := gitRun(t, dir, "log", "-1", "--format=%s"); got != "initial" {
		t.Fatalf("last commit before the review was confirmed = %q, want initial", got)
	}

	h.click(center(h.topHit(commitReviewCancel)))
	if p.commit.review != nil {
		t.Fatal("cancel left the review open")
	}
}

func TestCommitWithoutAMessageAsksForOne(t *testing.T) {
	dir := newTestRepository(t)
	h := newHarness(t, &gitKernel{Client: core.NewClient()})
	p := h.openCommit(dir)
	h.stageAll(p)

	h.app.startCommit(p, false, surfaceShortcut)
	h.settle()
	if h.app.notice != h.app.text.Commit.EnterMessage {
		t.Fatalf("notice = %q, want %q", h.app.notice, h.app.text.Commit.EnterMessage)
	}
	if got := gitRun(t, dir, "log", "-1", "--format=%s"); got != "initial" {
		t.Fatalf("last commit = %q, want no new commit", got)
	}
}
