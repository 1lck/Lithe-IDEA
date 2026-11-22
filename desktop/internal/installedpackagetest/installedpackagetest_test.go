package installedpackagetest

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/installedpackage"
)

// writingEnv makes TestWorkflowThatWritesIntoThePackage run; only
// TestRunFailsWhenTheWorkflowWritesIntoThePackage sets it.
const writingEnv = "LITHE_TEST_INSTALLED_PACKAGE_WRITING_WORKFLOW"

func TestCompareNamesEachAddedRemovedAndChangedEntry(t *testing.T) {
	root := t.TempDir()
	for name, data := range map[string]string{"a/one": "1", "two": "2", "three": "3"} {
		path := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	was, err := entriesBelow(root)
	if err != nil {
		t.Fatal(err)
	}
	if differences := compare(was, was); len(differences) != 0 {
		t.Fatalf("a tree differs from itself: %q", differences)
	}

	// Same size, other bytes: only the digest tells them apart.
	if err := os.WriteFile(filepath.Join(root, "a", "one"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Read-only is the permission change Windows records too.
	if err := os.Chmod(filepath.Join(root, "two"), 0o444); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(root, "three")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "four"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	now, err := entriesBelow(root)
	if err != nil {
		t.Fatal(err)
	}
	differences := compare(was, now)
	want := []string{"added four:", "changed a/one:", "changed two:", "removed three"}
	if len(differences) != len(want) {
		t.Fatalf("differences = %q, want one per entry of %q", differences, want)
	}
	for i, prefix := range want {
		if !strings.HasPrefix(differences[i], prefix) {
			t.Fatalf("differences[%d] = %q, want it to start with %q", i, differences[i], prefix)
		}
	}
}

func TestWithinTellsAPathBelowADirectoryFromASibling(t *testing.T) {
	base := t.TempDir()
	dir := filepath.Join(base, "Lithe")
	for path, want := range map[string]bool{
		dir: true,
		filepath.Join(dir, "state", "not-yet.json"): true,
		filepath.Join(dir, "..state"):               true,
		filepath.Join(base, "Lithe.app"):            false,
		filepath.Join(base, "Lithe-cache", "state"): false,
		base: false,
	} {
		if got := within(t, dir, path); got != want {
			t.Errorf("within(%q, %q) = %v, want %v", dir, path, got, want)
		}
	}
}

// TestWorkflowThatWritesIntoThePackage is the workflow TestRunFailsWhenTheWorkflowWritesIntoThePackage
// expects Run to fail; it is skipped in every other run.
func TestWorkflowThatWritesIntoThePackage(t *testing.T) {
	if os.Getenv(writingEnv) == "" {
		t.Skip("run by TestRunFailsWhenTheWorkflowWritesIntoThePackage")
	}
	if !Run(t) {
		return
	}
	root, err := installedpackage.Root()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "state.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestRunFailsWhenTheWorkflowWritesIntoThePackage(t *testing.T) {
	if os.Getenv(copyEnv) != "" || os.Getenv(writingEnv) != "" {
		t.Fatal("run from the installed copy or the writing workflow; run the test binary directly")
	}
	executable, err := installedpackage.Executable()
	if err != nil {
		t.Fatal(err)
	}
	// Longer than the deadline Run gives the copy, so the writing workflow's own run reports first.
	ctx, cancel := context.WithTimeout(context.Background(), copyDeadline+30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, executable,
		"-test.run=^TestWorkflowThatWritesIntoThePackage$", "-test.count=1", "-test.v")
	cmd.Dir = t.TempDir()
	cmd.Env = append(os.Environ(), writingEnv+"=1")
	output, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("the writing workflow did not finish within the deadline:\n%s", output)
	}
	if err == nil {
		t.Fatalf("Run passed a workflow that wrote into the installed package:\n%s", output)
	}
	for _, want := range []string{"--- FAIL: TestWorkflowThatWritesIntoThePackage ", "the workflow changed 1 entries", "added state.json: file "} {
		if !strings.Contains(string(output), want) {
			t.Fatalf("output lacks %q:\n%s", want, output)
		}
	}
}
